import CoachAPI
import CoachEdit
import CoachModels
import CoachUI
import CoreImage
import Foundation
import ImageIO
import os
import UIKit

/// The shot viewer: the photo, a depth sweep when the photo carries depth, then a few physical
/// faders. "Edit for Me" asks Gemini for a short sequence of fader moves and plays them one after
/// another; talking asks for one change ("warmer", "brighter face"). Gemini says one short line
/// back. Everything renders on device (CoachEdit); every Gemini call goes straight from the phone.
@MainActor
@Observable
final class RevealModel {
    enum Phase: Equatable { case scanning, depth, fix }

    private(set) var isShown = false
    private(set) var phase: Phase = .scanning
    private(set) var photo: UIImage?
    private(set) var depthMap: UIImage?
    private(set) var edited: UIImage?
    /// Bumps when the depth sweep starts / an edit lands (haptics in the view).
    private(set) var depthSerial = 0
    private(set) var fixSerial = 0
    /// Gemini is planning an edit (the scan line runs over the photo).
    private(set) var working = false
    /// The depth map (16-bit mm PNG) when the photo carried depth (the 3D view needs it).
    private(set) var depthPNG: Data?
    /// The faders on screen.
    let sliders = EditSlidersModel(sliders: RevealModel.faders)

    /// Gemini's spoken line (the app routes it to `Speaker`).
    @ObservationIgnored var speaker: ((String) -> Void)?
    @ObservationIgnored var onShow3D: ((UIImage, Data) -> Void)?
    /// Shown / dismissed (the camera coach pauses while the viewer is up).
    @ObservationIgnored var onPresent: ((Bool) -> Void)?
    /// Depth from the photo file itself (LiDAR / dual camera), as a 16-bit mm PNG.
    @ObservationIgnored nonisolated(unsafe) static var localDepthPNG: (@Sendable (Data) -> Data?)?

    @ObservationIgnored let renderer = EditRenderer()
    @ObservationIgnored private var source: CIImage?
    @ObservationIgnored private var depth: CIImage?
    @ObservationIgnored private var editTask: Task<Void, Never>?
    @ObservationIgnored private var fastTask: Task<FastOutcome, Never>?
    @ObservationIgnored private var voiceSerial = 0
    /// The faders before the last edit (for "undo" / a disappointed reaction).
    @ObservationIgnored private var lastEditBefore: [Slider: Double]?
    @ObservationIgnored private var lastEditAt = Date.distantPast
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private lazy var gemini: GeminiDirect? = GeminiDirect.keyFromBundle().map { GeminiDirect(apiKey: $0) }

    /// A small set of faders: light, then colour, then depth.
    static let faders: [Slider] = [.exposure, .contrast, .shadows, .warmth, .vibrance, .depthBlur]
    /// Gemini's plan plays like a hand on a mixing desk: each fader glides (the `lift` spring,
    /// ~0.7 s) and the next one starts this long before the previous one lands.
    static let stepOverlap: TimeInterval = 0.25
    private static let log = Logger(subsystem: "app.heliocam.CoachCam", category: "Edit")
    nonisolated static let previewSide = 1080

    // MARK: Lifecycle

    /// Opens a shot: the photo at once; with depth in the file, the depth sweep first.
    func begin(jpeg: Data, photoData: Data? = nil) {
        cancelAll()
        generation += 1
        depth = nil; depthMap = nil; edited = nil; depthPNG = nil; working = false
        sliders.load([:])
        phase = .scanning
        photo = UIImage(data: jpeg).map(Self.upright)
        source = EditRenderer.sourceImage(data: jpeg)
        isShown = true
        onPresent?(true)
        startRenderLoop()
        // Depth (Depth Pro 2 or the camera's own) can take a while: off the main thread.
        if let f = Self.localDepthPNG {
            let gen = generation
            let inputs = [photoData, jpeg].compactMap { $0 }
            tasks.append(Task { [weak self] in
                let png = await Task.detached(priority: .userInitiated) { inputs.lazy.compactMap(f).first }.value
                guard let self, gen == self.generation else { return }
                if let png { await self.depthArrived(png) } else { self.phase = .fix }
            })
            // Never keep the faders waiting on depth for long.
            tasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, gen == self.generation, self.phase == .scanning else { return }
                self.phase = .fix
            })
        } else {
            phase = .fix
        }
    }

    func dismiss() {
        cancelAll()
        working = false
        generation += 1
        isShown = false
        onPresent?(false)
    }

    private func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
        editTask?.cancel(); editTask = nil
        fastTask?.cancel(); fastTask = nil
        lastEditBefore = nil
        renderTask?.cancel(); renderTask = nil
        sliders.cancelGuide()
    }

    private func depthArrived(_ data: Data) async {
        guard phase == .scanning else { return }
        let gen = generation
        let map = await Task.detached(priority: .userInitiated) { Self.colourise(png: data) }.value
        guard gen == generation, phase == .scanning else { return }
        depth = EditRenderer.depthImage(pngData: data)
        depthPNG = data
        depthMap = map
        phase = .depth
        depthSerial += 1
        // Sweep (0.8 s, in the view) + hold, then cross-fade back to the photo and its faders.
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, gen == self.generation else { return }
            self.phase = .fix
        })
    }

    // MARK: Rendering

    /// Renders whenever the faders on screen move (user scrubs and Gemini's glides alike), as fast
    /// as the GPU allows at ~1080 px. Idle costs one dictionary compare per frame.
    private func startRenderLoop() {
        renderTask?.cancel()
        let gen = generation
        renderTask = Task { [weak self] in
            var last: [Slider: Double]?
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                let now = Date()
                var v: [Slider: Double] = [:]
                for s in Self.faders { if let x = self.sliders.displayedValue(s, at: now) { v[s] = x } }
                if v != last {
                    let first = last == nil
                    last = v
                    let inputs = RenderInputs(renderer: self.renderer, source: self.source, depth: self.depth)
                    let neutral = v.allSatisfy { $0.value == $0.key.spec.neutralValue }
                    if neutral, !first {
                        self.edited = nil
                    } else if !neutral {
                        let img = await Task.detached(priority: .userInitiated) { inputs.render(values: v) }.value
                        guard !Task.isCancelled, gen == self.generation else { return }
                        if let img { self.edited = img }
                    }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: Gemini edits

    /// Edit for Me: Gemini looks at the photo and plays a few fader moves, one after another.
    func editForMe() {
        plan(request: nil, model: GeminiDirect.strongModel)
    }

    // MARK: Talk to edit: Gemini Decision first (~1 s), Gemini 4 only when needed

    enum FastOutcome: Sendable { case moved(String), undone, nothing }

    /// Mic released: the photo (low res), the voice clip and the fader values go to Gemini
    /// Decision, which picks one fader move (or an undo when the user sounds let down right after
    /// an edit). The move glides at once; `voiceEdit(_:)` decides whether Gemini 4 refines it.
    func voiceReleased(wav: Data?) {
        guard isShown, phase == .fix, let gemini, let photo, let wav else { fastTask = nil; return }
        editTask?.cancel(); editTask = nil
        sliders.cancelGuide()
        let gen = generation
        let values = sliders.values
        let recent = lastEditBefore != nil && Date().timeIntervalSince(lastEditAt) < 30
        working = true
        voiceSerial += 1
        let vs = voiceSerial
        // The transcript (`voiceEdit`) normally follows within ~1 s; if the hold was cancelled it
        // never comes, so never leave the faders and Edit for Me waiting on it.
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, gen == self.generation, vs == self.voiceSerial, self.fastTask != nil else { return }
            Self.log.notice("Voice edit: no transcript after release; unlocking")
            self.fastTask = nil
            self.working = false
        })
        fastTask = Task { [weak self] in
            let jpeg = await Task.detached(priority: .userInitiated) { Self.smallJPEG(photo, side: 512) }.value
            guard let jpeg else { return .nothing }
            let state = Self.faders.map { "\($0.rawValue)=\(GeminiEdit.fmt(values[$0] ?? $0.spec.neutralValue))" }
                .joined(separator: ", ")
            let input = [GeminiDirect.decisionImage(jpeg), GeminiDirect.decisionAudio(wav),
                         GeminiDirect.decisionText("A photographer is editing this photo by voice. Faders now: \(state).")]
            let questions: [String: GeminiDirect.Choice] = ["edit": Self.editQuestion, "reaction": Self.reactionQuestion]
            let d: GeminiDirect.Decision
            do { d = try await gemini.decide(input: input, questions: questions) } catch {
                Self.log.error("Decide failed: \(error.localizedDescription, privacy: .public)")
                return .nothing
            }
            guard let self, gen == self.generation, !Task.isCancelled else { return .nothing }
            let edit = d.top("edit") ?? ("none", 0)
            let reaction = d.top("reaction")
            Self.log.debug("Decide \(d.milliseconds) ms edit=\(edit.option, privacy: .public) \(edit.p) reaction=\(reaction?.option ?? "-", privacy: .public)")
            if recent, edit.option == "undo" && edit.p > 0.4 || (reaction?.option == "disappointed" && (reaction?.p ?? 0) > 0.5 && edit.option == "none") {
                self.undoLast()
                return .undone
            }
            guard edit.p >= 0.35, let move = Self.fastMoves[edit.option] else { return .nothing }
            var target = values
            let now = target[move.slider] ?? move.slider.spec.neutralValue
            target[move.slider] = move.absolute ? move.amount : now + move.amount
            self.remember(values)
            _ = await self.sliders.coachStep(EditStep(slider: move.slider, value: target[move.slider]))
            self.fixSerial += 1
            return .moved(edit.option)
        }
    }

    /// The transcript of the same hold (may be empty): a short request already handled by the
    /// fast move just gets a word back; anything else goes to Gemini 4, which speaks its line.
    func voiceEdit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fast = fastTask
        fastTask = nil
        let gen = generation
        Task { [weak self] in
            let outcome = await fast?.value ?? .nothing
            guard let self, gen == self.generation, self.isShown else { return }
            switch outcome {
            case .undone:
                self.working = false
                self.speaker?("Back to how it was")
                return
            case .moved(let option):
                if t.split(whereSeparator: \.isWhitespace).count <= 4 {
                    self.working = false
                    self.speaker?(Self.fastMoves[option]?.ack ?? "Done")
                    return
                }
            case .nothing:
                break
            }
            guard !t.isEmpty else { self.working = false; return }
            self.plan(request: t, model: GeminiDirect.fastModel)
        }
    }

    /// Restores the faders from before the last edit (Gemini's or a fast move).
    private func undoLast() {
        guard let before = lastEditBefore else { return }
        lastEditBefore = nil
        let steps = Self.faders.compactMap { s -> EditStep? in
            let from = sliders.values[s] ?? s.spec.neutralValue, to = before[s] ?? s.spec.neutralValue
            return from == to ? nil : EditStep(slider: s, value: to)
        }
        Task { [weak self] in
            for step in steps {
                guard let self else { return }
                _ = await self.sliders.coachStep(step)
            }
        }
    }

    private func remember(_ values: [Slider: Double]) {
        lastEditBefore = values
        lastEditAt = Date()
    }

    struct FastMove: Sendable {
        let slider: Slider
        let amount: Double
        var absolute = false
        let ack: String
    }

    /// Gemini Decision's `edit` options → one fader move each.
    static let fastMoves: [String: FastMove] = [
        "warmer": FastMove(slider: .warmth, amount: 18, ack: "Warmer"),
        "cooler": FastMove(slider: .warmth, amount: -18, ack: "Cooler"),
        "brighter": FastMove(slider: .exposure, amount: 0.35, ack: "Brighter"),
        "darker": FastMove(slider: .exposure, amount: -0.35, ack: "Darker"),
        "more_contrast": FastMove(slider: .contrast, amount: 18, ack: "More punch"),
        "softer": FastMove(slider: .contrast, amount: -18, ack: "Softer"),
        "more_colour": FastMove(slider: .vibrance, amount: 22, ack: "Richer colour"),
        "less_colour": FastMove(slider: .vibrance, amount: -22, ack: "Quieter colour"),
        "brighter_subject": FastMove(slider: .shadows, amount: 22, ack: "Lifted the shadows"),
        "blur_background": FastMove(slider: .depthBlur, amount: 30, ack: "Background softened"),
        "sharpen_background": FastMove(slider: .depthBlur, amount: 0, absolute: true, ack: "Background sharp again"),
    ]

    static let editQuestion = GeminiDirect.Choice(
        instructions: "In the audio clip the photographer asks for a change to the photo. Which single fader move matches what they asked for?",
        criteria: [
            "warmer": "Warmer, more golden or orange, less blue.",
            "cooler": "Cooler, bluer, less yellow or orange.",
            "brighter": "Brighter overall, lighter, more exposure.",
            "darker": "Darker overall, moodier, less exposure.",
            "more_contrast": "More contrast, more punch, more pop.",
            "softer": "Less contrast, softer, flatter, gentler.",
            "more_colour": "More colour, more vivid or saturated.",
            "less_colour": "Less colour, muted, more natural or desaturated.",
            "brighter_subject": "Brighter face or subject, lift the shadows, see the dark parts.",
            "blur_background": "Blur the background, more bokeh, make the subject stand out.",
            "sharpen_background": "Less blur, sharpen or bring back the background.",
            "undo": "Undo, go back, the previous version was better, not that.",
            "none": "Something else, several changes at once, or no clear request.",
        ])

    /// `server/cam.py` REACTION_QUESTION.
    static let reactionQuestion = GeminiDirect.Choice(
        instructions: "In the audio clip of the user's voice, how does the user feel about the current shot or the coach's last suggestion?",
        criteria: [
            "disappointed": "Unhappy or unconvinced: a sigh, 'hmm, no', 'not that', 'I don't like it', a let-down tone.",
            "neutral": "No clear feeling: silence, background noise, or just saying what they want or giving instructions.",
            "pleased": "Happy or approving: 'oh that's good', 'yes, that one', 'perfect', 'love it', an excited or satisfied tone.",
        ])

    /// Back to the original photo: every fader glides home.
    func resetEdits() {
        editTask?.cancel(); editTask = nil
        working = false
        sliders.reset()
    }

    private func plan(request: String?, model: String) {
        guard let gemini, let photo else {
            speaker?("I can't reach Gemini right now")
            return
        }
        editTask?.cancel()
        sliders.cancelGuide()
        let gen = generation
        let values = sliders.values
        working = true
        editTask = Task { [weak self] in
            let jpeg = await Task.detached(priority: .userInitiated) { Self.smallJPEG(photo) }.value
            guard let jpeg else {
                Self.log.error("Edit: couldn't encode the photo")
                self?.working = false
                self?.editTask = nil
                return
            }
            do {
                let plan = try await GeminiEdit.plan(gemini: gemini, jpeg: jpeg, values: values,
                                                     sliders: Self.faders, request: request, model: model)
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                Self.log.debug("Gemini edit \(model, privacy: .public) \(plan.milliseconds) ms: \(plan.steps.map { "\($0.slider.rawValue)=\($0.value ?? 0)" }, privacy: .public)")
                self.working = false
                if plan.steps.isEmpty {
                    self.speaker?(plan.say.isEmpty ? "It already looks good to me" : plan.say)
                    self.editTask = nil
                    return
                }
                if !plan.say.isEmpty { self.speaker?(plan.say) }
                self.remember(values)
                var landing = Date()
                for (i, step) in plan.steps.enumerated() {
                    guard gen == self.generation, !Task.isCancelled else { return }
                    let (_, lands) = self.sliders.beginCoachStep(step, index: i, of: plan.steps.count, at: Date())
                    landing = max(landing, lands)
                    self.fixSerial += 1
                    let next = lands.addingTimeInterval(-Self.stepOverlap).timeIntervalSinceNow
                    try? await Task.sleep(for: .seconds(max(0.3, next)))
                }
                let rest = landing.timeIntervalSinceNow
                if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
            } catch {
                guard let self, gen == self.generation else { return }
                self.working = false
                self.editTask = nil
                if !(error is CancellationError) {
                    Self.log.error("Gemini edit (\(model, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                    self.speaker?("That didn't go through. Try again")
                }
                return
            }
            if let self, gen == self.generation { self.editTask = nil }
        }
    }

    /// ≤1024 px JPEG of the upright photo for Gemini.
    nonisolated static func smallJPEG(_ img: UIImage, side: CGFloat = 1024) -> Data? {
        let s = min(1, side / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.82)
    }

    nonisolated private static func upright(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }
        let r = UIGraphicsImageRenderer(size: img.size)
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
    }

    /// depth.png (16-bit mm) → a smooth ramp: near = warm amber, far = deep blue (by inverse depth).
    nonisolated static func colourise(png: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var mm = [UInt16](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        let ok = mm.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 2,
                                      space: cg.colorSpace?.model == .monochrome ? cg.colorSpace! : gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let valid = mm.filter { $0 > 0 }.sorted()
        guard valid.count > 16 else { return nil }
        let near = Double(valid[valid.count * 2 / 100]), far = Double(valid[valid.count * 98 / 100])
        let invN = 1 / max(near, 1), invF = 1 / max(far, near + 1)
        // Stops from near to far (matte, low saturation at the ends).
        let stops: [(Double, Double, Double)] = [
            (255, 176, 92), (214, 118, 78), (120, 84, 120), (46, 62, 128), (14, 22, 58),
        ]
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let d = Double(mm[i])
            var c: (Double, Double, Double) = (10, 10, 12)
            if d > 0 {
                let t = 1 - max(0, min(1, (1 / d - invF) / (invN - invF)))
                let f = t * Double(stops.count - 1)
                let k = min(Int(f), stops.count - 2), u = f - Double(k)
                let s = u * u * (3 - 2 * u)
                let a = stops[k], b = stops[k + 1]
                c = (a.0 + (b.0 - a.0) * s, a.1 + (b.1 - a.1) * s, a.2 + (b.2 - a.2) * s)
            }
            rgba[i * 4] = UInt8(c.0); rgba[i * 4 + 1] = UInt8(c.1); rgba[i * 4 + 2] = UInt8(c.2); rgba[i * 4 + 3] = 255
        }
        let out = rgba.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return out.map { UIImage(cgImage: $0) }
    }
}

/// What a background render needs (the renderer is thread-safe; CIImages are immutable).
private struct RenderInputs: @unchecked Sendable {
    let renderer: EditRenderer
    let source: CIImage?
    let depth: CIImage?

    func render(values: [Slider: Double]) -> UIImage? {
        guard let source else { return nil }
        let recipe = EditRecipe(values: values)
        let out = renderer.render(source: source, depth: depth, subjectMask: nil,
                                  recipe: recipe, quality: .preview(maxSide: RevealModel.previewSide))
        guard let cg = renderer.cgImage(out) else { return nil }
        return UIImage(cgImage: cg)
    }
}
