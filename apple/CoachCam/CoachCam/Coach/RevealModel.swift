import CoachAPI
import CoachEdit
import CoachModels
import CoreImage
import Foundation
import ImageIO
import UIKit

/// The post-shot moment (#34): the photo at once, a scan while Core computes depth, the depth map
/// swept over the photo, then the fix rendered on device (default depth look, then Gemini's
/// suggestion) with its one-line reason spoken. Fails soft to a gentle look without depth.
@MainActor
@Observable
final class RevealModel {
    enum Phase: Equatable { case scanning, depth, fix }

    private(set) var isShown = false
    private(set) var phase: Phase = .scanning
    private(set) var photo: UIImage?
    private(set) var depthMap: UIImage?
    private(set) var edited: UIImage?
    /// Bumps when the depth map should sweep in, and when the fix lands (haptics + animation keys).
    private(set) var depthSerial = 0
    private(set) var fixSerial = 0

    /// Edit for Me is running (subtle shimmer).
    private(set) var working = false
    /// The shot on screen (for VoiceEdit.start).
    private(set) var shotID: String?
    /// Raw 16-bit mm depth PNG on screen (LiDAR or Core), for the 3D view.
    private(set) var depthPNG: Data?
    /// Slider values on screen (VoiceEdit can read them and drive `show(values:layers:)`).
    var values: [Slider: Double] { current }
    /// The open shot's slider values by name and its layers (the starting point for voice editing).
    var namedValues: [String: Double] { Dictionary(uniqueKeysWithValues: current.map { ($0.key.rawValue, $0.value) }) }
    var currentLayers: [EditLayer] { layers }

    /// Says a short line in the coach voice (set by AppModel).
    @ObservationIgnored var speaker: ((String) -> Void)?
    /// Hooks for the lead: mic → VoiceEdit, cube → DepthExplodeView(photo:depthPNG:), thumb → SessionRoll.
    @ObservationIgnored var onMic: (() -> Void)?
    @ObservationIgnored var onShow3D: ((UIImage, Data) -> Void)?
    @ObservationIgnored var onOpenRoll: (() -> Void)?
    /// Embedded (LiDAR) depth of the local photo as a 16-bit mm PNG; set to `PhotoDepth.depthPNGmm(fromPhotoData:)`.
    @ObservationIgnored static var localDepthPNG: ((Data) -> Data?)?

    @ObservationIgnored let renderer = EditRenderer()
    @ObservationIgnored private var source: CIImage?
    @ObservationIgnored private var depth: CIImage?
    @ObservationIgnored private var mask: CIImage?
    @ObservationIgnored private var subject: String?
    @ObservationIgnored private var client: CoachClient?
    @ObservationIgnored private var entry: String?
    @ObservationIgnored private var layers: [EditLayer] = []
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var lastUpload: (entry: String, shot: Shot)?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var current: [Slider: Double] = [:]
    @ObservationIgnored private var suggestion: EditSuggestion?
    @ObservationIgnored private var fixStarted = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var animTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    static let goal = "make the subject stand out and calm the messy background"
    static let depthTimeout: TimeInterval = 12
    static let previewSide = 1080
    /// Default depth look: background melts away, subject a touch brighter.
    static let depthLook: [Slider: Double] = [.depthBlur: 55, .subjectLight: 10, .backgroundLight: -10]
    /// Without depth: a gentle vignette and a little local contrast.
    static let gentleLook: [Slider: Double] = [.vignette: -25, .clarity: 8]

    // MARK: Lifecycle

    /// Shutter: show the photo right away. `client` nil (offline) → the gentle look only.
    func begin(jpeg: Data, photoData: Data? = nil, client: CoachClient?) {
        cancelAll()
        generation += 1
        self.client = client
        entry = nil; shotID = nil; depth = nil; mask = nil; subject = nil; suggestion = nil
        depthMap = nil; edited = nil; current = [:]; fixStarted = false; layers = []; depthPNG = nil; working = false
        phase = .scanning
        started = Date()
        photo = UIImage(data: jpeg).map(Self.upright)
        source = EditRenderer.sourceImage(data: jpeg)
        isShown = true
        let gen = generation
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.depthTimeout))
            guard let self, gen == self.generation, self.phase == .scanning else { return }
            self.failSoft()
        })
        // LiDAR depth embedded in the photo: instant sweep, no wait for Core.
        if let f = Self.localDepthPNG, let png = [photoData, jpeg].compactMap({ $0 }).lazy.compactMap(f).first {
            Task { await self.depthArrived(png) }
        } else if client == nil { failSoft() }
    }

    /// Opens an existing shot (session roll): the photo, its depth and the fix as after capture.
    func open(shot: Shot, client: CoachClient) async {
        guard let data = try? await client.assetData(shot.assets.image.url ?? "/api/shots/\(shot.id)/image.jpg") else { return }
        begin(jpeg: data, client: client)
        attach(shot)
    }

    /// Shows the last reveal again (thumbnail tap without a roll).
    func reopen() { if photo != nil { isShown = true } }

    /// Puts `values` (+ layers) on screen, eased; for VoiceEdit and Edit for Me.
    func show(values: [String: Double], layers newLayers: [EditLayer]? = nil) {
        if let newLayers { layers = newLayers }
        fixStarted = true
        animate(to: SliderValues.parse(values.mapValues { .number($0) })) { [weak self] in self?.fixSerial += 1 }
    }

    /// The outbox entry for this shot (its upload result arrives through `uploaded`).
    func track(entry: String) {
        self.entry = entry
        if let u = lastUpload, u.entry == entry { attach(u.shot) }
    }

    func uploaded(entry: String, shot: Shot) {
        lastUpload = (entry, shot)
        guard isShown, entry == self.entry, shotID == nil else { return }
        attach(shot)
    }

    func dismiss() {
        cancelAll()
        working = false
        generation += 1
        isShown = false
    }

    private func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
        animTask?.cancel()
        animTask = nil
        autoTask?.cancel()
        autoTask = nil
    }

    // MARK: Core

    private func attach(_ shot: Shot) {
        guard let client else { return }
        shotID = shot.id
        let gen = generation
        let id = shot.id
        // Gemini's suggestion, in parallel with depth.
        tasks.append(Task { [weak self] in
            guard let s = try? await client.suggestEdit(shotID: id, goal: Self.goal) else { return }
            guard let self, gen == self.generation else { return }
            self.suggestion = s
            if self.fixStarted { self.applySuggestion() }
        })
        // Depth, then the subject mask.
        tasks.append(Task { [weak self] in
            var depthDone = false
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                if let s = try? await client.shot(id: id) {
                    if self.depth != nil { depthDone = true }
                    if !depthDone, s.assets.depth.status == .done, self.phase == .scanning {
                        if let data = try? await client.assetData(s.assets.depth.url ?? "/api/shots/\(id)/depth.png") {
                            depthDone = true
                            await self.depthArrived(data)
                        }
                    }
                    if s.assets.depth.status == .error { self.failSoft(); depthDone = true }
                    if s.assets.masks.status == .done, let urls = s.assets.masks.urls {
                        await self.loadMask(client: client, shotID: id, urls: urls, meta: s.meta)
                        return
                    }
                    if s.assets.masks.status == .error { return }
                }
                if Date().timeIntervalSince(self.started) > 40 { return }
                try? await Task.sleep(for: .milliseconds(400))
            }
        })
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
        // Sweep (0.8 s, in the view) + hold 1.2 s + cross-fade back, then the fix.
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.0))
            guard let self, gen == self.generation else { return }
            self.phase = .fix
            try? await Task.sleep(for: .seconds(0.45))
            guard gen == self.generation else { return }
            self.startFix(look: Self.depthLook)
        })
    }

    private func loadMask(client: CoachClient, shotID: String, urls: [String: String], meta: ShotMeta?) async {
        var name = suggestion?.subject ?? meta?.subject
        if name == nil || urls[name!] == nil,
           let r = try? await client.assetJSON("/api/shots/\(shotID)/regions.json", as: RegionsResponse.self) {
            name = r.regions.first(where: \.isFocus)?.id
        }
        guard let name, let url = urls[name], let data = try? await client.assetData(url),
              let m = EditRenderer.maskImage(pngData: data) else { return }
        mask = m
        subject = name
        if fixStarted, animTask == nil { renderOnce() }
    }

    private func failSoft() {
        guard phase == .scanning else { return }
        phase = .fix
        startFix(look: Self.gentleLook)
    }

    // MARK: The fix

    private func startFix(look: [Slider: Double]) {
        fixStarted = true
        animate(to: look) { [weak self] in
            guard let self else { return }
            if self.suggestion != nil { self.applySuggestion() } else { self.fixSerial += 1 }
        }
    }

    private func applySuggestion() {
        guard let s = suggestion else { return }
        suggestion = nil
        // Gemini's values on top of the depth look (it rarely sets depth blur itself).
        let base = depth != nil ? Self.depthLook : Self.gentleLook
        let target = base.merging(s.values) { _, new in new }
        let line = Self.shortLine(s.summary)
        animate(to: target) { [weak self] in self?.fixSerial += 1 }
        if !line.isEmpty { speaker?(line) }
    }

    /// Eases every slider from its current value to `target` over ~1.2 s, rendering frames as fast
    /// as the GPU allows (~1080 px).
    private func animate(to target: [Slider: Double], duration: Double = 1.2, then done: @escaping @MainActor () -> Void) {
        animTask?.cancel()
        let from = current
        let keys = Set(from.keys).union(target.keys).subtracting([.focusDepth])
        let focus = target[.focusDepth]
        let inputs = RenderInputs(renderer: renderer, source: source, depth: depth, mask: mask, layers: layers)
        let gen = generation
        animTask = Task { [weak self] in
            let t0 = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(t0) / duration)
                let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                var v: [Slider: Double] = [:]
                for k in keys {
                    let a = from[k] ?? k.spec.neutralValue, b = target[k] ?? k.spec.neutralValue
                    v[k] = a + (b - a) * e
                }
                if let focus { v[.focusDepth] = focus }
                guard let self, gen == self.generation else { return }
                let maskNow = self.mask
                let img = await Task.detached(priority: .userInitiated) {
                    inputs.render(values: v, mask: maskNow)
                }.value
                guard !Task.isCancelled, gen == self.generation else { return }
                self.current = v
                if let img { self.edited = img }
                if t >= 1 { break }
            }
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.animTask = nil
            done()
        }
    }

    private func renderOnce() {
        let inputs = RenderInputs(renderer: renderer, source: source, depth: depth, mask: mask, layers: layers)
        let v = current, m = mask, gen = generation
        tasks.append(Task { [weak self] in
            let img = await Task.detached(priority: .userInitiated) { inputs.render(values: v, mask: m) }.value
            guard let self, gen == self.generation, let img else { return }
            self.edited = img
        })
    }

    // MARK: Edit for Me (`POST /api/shots/{id}/autoedit`, SSE: stage / step / done / error)

    func editForMe() {
        guard let client, let id = shotID, autoTask == nil else { return }
        let gen = generation
        working = true
        autoTask = Task { [weak self] in
            var ok = false
            do {
                var req = try CoreExtras.request(client, "/api/shots/\(id)/autoedit", method: "POST", timeout: 120)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.httpBody = Data("{}".utf8)
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                    throw CoachError.invalidURL("autoedit unavailable")
                }
                var parser = SSEParser()
                var line: [UInt8] = []
                var lastSaid = ""   // speak each new edit line once; stage lines only shimmer
                for try await byte in bytes {
                    line.append(byte)
                    guard byte == 0x0A else { continue }
                    for item in parser.feed(line) {
                        guard case .event(let e) = item, let self, gen == self.generation else { continue }
                        let obj = (try? JSONSerialization.jsonObject(with: Data(e.data.utf8))) as? [String: Any] ?? [:]
                        if e.event == "step" || e.event == "done", let say = obj["say"] as? String, !say.isEmpty,
                           say != lastSaid {
                            lastSaid = say
                            self.speaker?(Self.shortLine(say))
                        }
                        switch e.event {
                        case "stage": self.working = true
                        case "step", "done":
                            let layers = await Self.layers(obj["layers"], client: client, renderer: self.renderer)
                            guard gen == self.generation else { return }
                            let v = (obj["values"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
                            self.show(values: v, layers: layers)
                            if e.event == "done" { ok = true }
                        case "error": break
                        default: break
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                }
            } catch {
                #if DEBUG
                print("CoachCam[reveal] autoedit: \(error)")
                #endif
            }
            guard let self, gen == self.generation else { return }
            self.working = false
            self.autoTask = nil
            // Fallback until /autoedit exists: Gemini's suggestion.
            if !ok, let s = try? await client.suggestEdit(shotID: id, goal: Self.goal), gen == self.generation {
                self.suggestion = s
                self.applySuggestion()
            }
        }
    }

    /// `[{"id","target","mask_url","values"}]` → layers, masks registered with the renderer.
    private static func layers(_ raw: Any?, client: CoachClient, renderer: EditRenderer) async -> [EditLayer]? {
        guard let arr = raw as? [[String: Any]] else { return nil }
        var out: [EditLayer] = []
        for l in arr {
            guard let id = l["id"] as? String else { continue }
            if let url = l["mask_url"] as? String, let data = try? await client.assetData(url),
               let m = EditRenderer.maskImage(pngData: data) {
                renderer.register(mask: m, named: id)
            } else { continue }
            let v = (l["values"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            out.append(EditLayer(id: id, target: l["target"] as? String ?? "", mask: LayerMask(source: id),
                                 values: SliderValues.parse(v.mapValues { .number($0) })))
        }
        return out
    }

    // MARK: Helpers

    /// ≤10 words, no trailing period.
    static func shortLine(_ s: String) -> String {
        let words = s.split(whereSeparator: \.isWhitespace)
        return words.prefix(10).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
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
    let mask: CIImage?
    let layers: [EditLayer]

    func render(values: [Slider: Double], mask override: CIImage?) -> UIImage? {
        guard let source else { return nil }
        var recipe = EditRecipe(values: values)
        if !layers.isEmpty { recipe.layers = layers }
        let out = renderer.render(source: source, depth: depth, subjectMask: override ?? mask,
                                  recipe: recipe, quality: .preview(maxSide: RevealModel.previewSide))
        guard let cg = renderer.cgImage(out) else { return nil }
        return UIImage(cgImage: cg)
    }
}
