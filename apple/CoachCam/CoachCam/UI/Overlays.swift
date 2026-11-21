import AVFoundation
import CoachModels
import CoreMotion
import CoachUI
import SwiftUI

/// A brief wash over the frame when the coach hears the user react (pleased = Gemini blue, disappointed = dim).
struct ReactionWash: View {
    let reaction: UserReaction?
    let id: Int
    @State private var opacity = 0.0

    var body: some View {
        RadialGradient(colors: [color.opacity(0.0), color.opacity(0.55)], center: .center, startRadius: 120, endRadius: 520)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: id) { _, _ in
                guard reaction != nil, reaction != .neutral else { return }
                opacity = 0.9
                withAnimation(CoachEase.out(0.9)) { opacity = 0 }
            }
    }

    private var color: Color { reaction == .pleased ? GXColor.gemini : GXColor.void }
}

/// The capture flash: white 0 → .6 → 0 over 180ms.
struct CaptureFlash: View {
    let trigger: Int

    var body: some View {
        Color.white
            .allowsHitTesting(false)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, v in
                content.opacity(v)
            } keyframes: { _ in
                LinearKeyframe(0.6, duration: 0.06)
                LinearKeyframe(0.0, duration: 0.12)
            }
    }
}

struct CameraDeniedNote: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 30))
            Text("Camera access is off")
                .font(CoachFont.sans(20, weight: .semibold))
            Text("Turn it on in Settings to shoot with Heliocam.")
                .font(CoachFont.sans(15))
                .foregroundStyle(CoachColor.paper62)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(CoachFont.sans(16, weight: .semibold))
            .foregroundStyle(CoachColor.ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(GXColor.frost))
        }
        .foregroundStyle(CoachColor.paper)
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

// MARK: - Stage choreography (wake-up opening + capture → depth scan)

/// Drives the launch opening and the post-shutter sequence. Every value is 0…1 (or a flag) and
/// is changed inside `withAnimation`, so views just read it.
@MainActor
@Observable
final class StageFX {
    // Opening (HANDOFF "Opening = camera wakes up"), all 1 once awake.
    var wordmark = 0.0
    var iris = 0.0
    var hairlines = 0.0
    var drums = 0.0
    var keys = 0.0
    var thumb = 0.0
    var sweep = 0.0
    var sweepOn = 0.0
    var dot = 0.0

    // Capture
    var frozen = false
    var frozenMock: CGImage?
    var flashSerial = 0
    var scanOn = false
    var scanProgress = 0.0
    var holdThumb = false
    var heldThumb: CGImage?
    var check = false
    var pulse = false

    @ObservationIgnored private var woke = false
    @ObservationIgnored private var shotTask: Task<Void, Never>?

    /// ~1.7s, zero taps: wordmark, iris, hairlines, drums, keys + thumbnail, border sweep → live dot.
    func wake(reduceMotion: Bool) {
        guard !woke else { return }
        woke = true
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                iris = 1; hairlines = 1; drums = 1; keys = 1; thumb = 1; dot = 1
            }
            return
        }
        Task { @MainActor in
            let t0 = ContinuousClock.now
            func at(_ ms: Int) async { try? await Task.sleep(until: t0 + .milliseconds(ms), clock: .continuous) }
            withAnimation(.easeOut(duration: 0.2)) { wordmark = 0.4 }
            await at(250)
            withAnimation(.easeIn(duration: 0.2)) { wordmark = 0 }
            await at(300)
            withAnimation(.timingCurve(0.6, 0, 0.2, 1, duration: 0.6)) { iris = 1 }
            await at(500)
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)) { hairlines = 1 }
            await at(560)
            withAnimation(.spring(response: 0.56, dampingFraction: 0.78)) { drums = 1 }
            await at(700)
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)) { keys = 1 }
            await at(860)
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)) { thumb = 1 }
            await at(1100)
            sweepOn = 1
            withAnimation(.timingCurve(0.45, 0, 0.25, 1, duration: 0.56)) { sweep = 1 }
            await at(1660)
            withAnimation(.easeOut(duration: 0.28)) { sweepOn = 0 }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) { dot = 1 }
        }
    }

    /// The shutter fired: freeze the frame, flash, sweep the depth line, then land the thumbnail
    /// and show the check.
    func shot(lastThumb: CGImage?, mockFrame: CGImage?) {
        shotTask?.cancel()
        if !holdThumb { heldThumb = lastThumb }
        holdThumb = true
        frozenMock = mockFrame
        frozen = true
        check = false
        pulse = false
        scanOn = false
        scanProgress = 0
        flashSerial += 1
        shotTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            scanOn = true
            withAnimation(.timingCurve(0.45, 0.05, 0.35, 1, duration: 1.6)) { scanProgress = 1 }
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.32)) { scanOn = false }
            frozen = false
            frozenMock = nil
            pulse = true
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { holdThumb = false }
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)) { check = true }
            heldThumb = nil
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            pulse = false
            withAnimation(.easeOut(duration: 0.3)) { check = false }
        }
    }
}

/// The 6-blade aperture: a hexagon that grows (and turns) from nothing to past the corners.
struct IrisShape: Shape {
    var open: Double
    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let v = IrisShape.vertices(in: rect, open: open)
        var p = Path()
        guard open > 0.001 else { return p }
        p.addLines(v)
        p.closeSubpath()
        return p
    }

    static func vertices(in rect: CGRect, open: Double) -> [CGPoint] {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // At open = 1 the hexagon's inscribed circle clears the corners.
        let full = hypot(rect.width, rect.height) / 2 / cos(.pi / 6) * 1.04
        let r = max(1, CGFloat(open) * full)
        let turn = (1 - open) * .pi / 2
        return (0..<6).map { i in
            let a = turn + Double(i) * .pi / 3 - .pi / 2
            return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        }
    }
}

/// The blade seams: each hexagon side carried on past its vertex to the frame edge.
struct IrisBlades: Shape {
    var open: Double
    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let v = IrisShape.vertices(in: rect, open: open)
        let reach = hypot(rect.width, rect.height)
        var p = Path()
        for i in 0..<6 {
            let a = v[i], b = v[(i + 1) % 6]
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let d = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
            p.move(to: a)
            p.addLine(to: CGPoint(x: b.x + d.x * reach, y: b.y + d.y * reach))
        }
        return p
    }
}

/// A short bright segment travelling once around the viewfinder border, clockwise from the
/// top-left corner and back to it (where the live dot sits).
struct BorderSweep: Shape {
    var progress: Double
    var cornerRadius: CGFloat
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0.001 else { return Path() }
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let i = rect.insetBy(dx: 1, dy: 1)
        var p = Path()
        p.move(to: CGPoint(x: i.minX + r, y: i.minY))
        p.addLine(to: CGPoint(x: i.maxX - r, y: i.minY))
        p.addArc(center: CGPoint(x: i.maxX - r, y: i.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: i.maxX, y: i.maxY - r))
        p.addArc(center: CGPoint(x: i.maxX - r, y: i.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: i.minX + r, y: i.maxY))
        p.addArc(center: CGPoint(x: i.minX + r, y: i.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: i.minX, y: i.minY + r))
        p.addArc(center: CGPoint(x: i.minX + r, y: i.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        let head = min(1, progress)
        return p.trimmedPath(from: max(0, head - 0.16), to: head)
    }
}

/// The depth scan over the frozen frame: a thin #B4CEFF line with a blue glow sweeping
/// top → bottom; the passed area keeps a faint blue tint. Stylised (no depth map on the phone).
struct DepthScanSweep: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let y = geo.size.height * CGFloat(progress)
            ZStack(alignment: .top) {
                LinearGradient(colors: [GXColor.gemini.opacity(0.06), GXColor.gemini.opacity(0.14)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: max(0, y))
                LinearGradient(colors: [GXColor.gemini.opacity(0), GXColor.gemini.opacity(0.32)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 64)
                    .offset(y: y - 64)
                Rectangle()
                    .fill(GXColor.geminiHot)
                    .frame(height: 1.5)
                    .shadow(color: GXColor.gemini, radius: 8)
                    .shadow(color: GXColor.geminiHot.opacity(0.9), radius: 2)
                    .offset(y: y - 0.75)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}

/// Opening: an instrument row rolls in like a drum turning into place.
struct RollIn: ViewModifier {
    let k: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(-75 * (1 - k)), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .offset(y: 10 * (1 - k))
            .opacity(k)
    }
}

/// `CameraPreview` that can freeze on the current frame (the preview connection is paused while
/// the depth scan plays; capture is unaffected).
struct FreezablePreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let frozen: Bool
    let onCaptureRotation: (CGFloat) -> Void

    func makeUIView(context: Context) -> CameraPreview.PreviewView {
        let v = CameraPreview.PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: CameraPreview.PreviewView, context: Context) {
        view.onCaptureRotation = onCaptureRotation
        if let device { view.attach(device) }
        if let conn = view.previewLayer.connection, conn.isEnabled == frozen {
            conn.isEnabled = !frozen
        }
    }
}

// MARK: - Holding the phone sideways (the interface stays portrait, like the iOS Camera)

/// How the phone is physically held. The interface is locked to portrait; each control's content
/// turns in place to stay upright for the user. Gravity comes from Core Motion, so it still works
/// with the system rotation lock on. Flat (face up / down) and upside down keep the last value.
@MainActor
@Observable
final class DeviceTilt {
    /// Clockwise rotation (degrees) that turns content upright for the user: 0 portrait,
    /// +90 landscape left (top of the phone to the left), -90 landscape right.
    private(set) var angle: Double = 0
    var sideways: Bool { angle != 0 }

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var running = false

    func start() {
        guard !running else { return }
        running = true
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                guard let g = m?.gravity else { return }
                MainActor.assumeIsolated { self?.update(x: g.x, y: g.y, z: g.z) }
            }
        } else if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: .main) { [weak self] d, _ in
                guard let a = d?.acceleration else { return }
                MainActor.assumeIsolated { self?.update(x: a.x, y: a.y, z: a.z) }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
    }

    private func update(x: Double, y: Double, z: Double) {
        // Lying flat: the screen's plane has no "up"; keep the last orientation.
        guard abs(z) < 0.8, hypot(x, y) > 0.35 else { return }
        // Where the phone's top points: 0 up, +90 right (landscape right), -90 left.
        let tilt = atan2(x, -y) * 180 / .pi
        let nearest: Double = abs(tilt) <= 45 ? 0 : (tilt > 45 && tilt < 135 ? 90 : (tilt < -45 && tilt > -135 ? -90 : .nan))
        guard !nearest.isNaN else { return }               // upside down
        let next = nearest == 0 ? 0 : -nearest
        // 10° of hysteresis past the 45° line so it doesn't flicker at the boundary.
        guard next != angle, abs(tilt - nearest) < 35 else { return }
        angle = next
    }
}

extension View {
    /// Turns this control's content to face the user (spring, 0.35 s); its position stays.
    func upright(_ tilt: DeviceTilt) -> some View {
        rotationEffect(.degrees(tilt.angle))
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: tilt.angle)
    }
}

/// Lays content out in the user's frame (landscape when the phone is sideways) and turns it to
/// face them, so `.top` is whichever edge of the card is up.
struct UserFrame<Content: View>: View {
    @Environment(DeviceTilt.self) private var tilt
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let w = tilt.sideways ? geo.size.height : geo.size.width
            let h = tilt.sideways ? geo.size.width : geo.size.height
            content
                .frame(width: w, height: h)
                .rotationEffect(.degrees(tilt.angle))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: tilt.angle)
    }
}

// MARK: - The suggestion tag (iOS Camera's yellow tag)

/// The coach's current suggestion as one small yellow tag: ≤5 words, fades + scales in (0.2 s),
/// replaces the previous one, hides 3 s after the coach stops updating it.
struct SuggestionTag: View {
    let feed: SuggestionFeed
    static let yellow = Color(red: 1, green: 0xD6 / 255, blue: 0x0A / 255)

    var body: some View {
        ZStack {
            if let text = feed.text {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.yellow)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(Color.black.opacity(0.55))
                        }
                        .environment(\.colorScheme, .dark)
                    }
                    .id(feed.serial)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .accessibilityLabel(text)
            }
        }
        .animation(.easeOut(duration: 0.2), value: feed.serial)
        .animation(.easeOut(duration: 0.2), value: feed.text == nil)
        .allowsHitTesting(false)
    }
}

/// Turns the coach's streaming caption into tag text. A turn's tag settles once its first clause
/// is complete (later words don't churn it); an unfinished clause shows after a short pause.
@MainActor
@Observable
final class SuggestionFeed {
    private(set) var text: String?
    private(set) var serial = 0

    @ObservationIgnored private var last: String?
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var hide: Task<Void, Never>?

    func feed(_ caption: String?) {
        guard let caption else { last = nil; return }   // the 3 s timer hides the tag
        let tail = caption.hasPrefix("…")
        let continuing = tail || (last.map { caption.hasPrefix($0) } ?? false)
        last = caption
        if !continuing { settled = false }
        scheduleHide()
        guard !settled, !tail, let (short, complete) = Suggestion.tag(from: caption) else { return }
        pending?.cancel()
        if complete {
            settled = true
            show(short)
        } else {
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.show(short)
            }
        }
    }

    /// Shows a coach hint exactly as written (already short), held for 5 s or until the next one.
    func pin(_ hint: String?) {
        guard let hint, !hint.isEmpty else { return }
        pending?.cancel()
        settled = true
        show(hint)
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.text = nil
        }
    }

    private func show(_ s: String) {
        guard s != text else { return }
        text = s
        serial += 1
    }

    private func scheduleHide() {
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.pending?.cancel()
            self.text = nil
        }
    }
}

/// Shortens a coach line to a tag: the first clause that says something, filler stripped,
/// at most 5 words ("Okay, nice. Now move a little to the left so…" → "Move to the left").
@MainActor
enum Suggestion {
    static let maxWords = 5

    /// Words that make a whole clause empty on their own ("Okay", "Nice", "Perfect").
    private static let interjections: Set<String> = [
        "okay", "ok", "so", "alright", "now", "great", "nice", "perfect", "good", "cool", "hey", "hi",
        "um", "uh", "hmm", "well", "yeah", "yes", "yep", "oh", "awesome", "lovely", "beautiful",
        "excellent", "sure", "wow", "amazing", "right", "gorgeous", "brilliant", "fantastic", "very",
    ]
    private static let emptyPhrases: Set<String> = [
        "there we go", "there you go", "that's it", "got it", "love it", "looks good", "looking good",
        "looks great", "that's good", "that's great", "that's nice", "good job", "nice job", "well done",
        "all right", "here we go", "i see", "let me see", "let's see", "if you can", "if possible",
    ]
    /// Openers that soften an instruction ("Now", "you could", "let's").
    private static let leadIns: [[String]] = [
        ["you", "might", "want", "to"], ["you", "may", "want", "to"], ["why", "don't", "you"],
        ["go", "ahead", "and"], ["try", "to"], ["can", "you"], ["could", "you"], ["you", "could"],
        ["you", "should"], ["you", "can"], ["i", "think"], ["how", "about"], ["we", "should"],
        ["we", "could"], ["let's"], ["lets"], ["i'd"], ["okay"], ["ok"], ["so"], ["alright"], ["now"],
        ["then"], ["just"], ["um"], ["uh"], ["well"], ["please"], ["maybe"], ["and"], ["but"],
        ["oh"], ["hey"], ["also"],
    ]
    private static let fillers: Set<String> = ["just", "please", "really", "actually", "maybe", "basically", "kinda"]
    private static let softeners: [[String]] = [["a", "little", "bit"], ["a", "little"], ["a", "bit"], ["slightly"]]
    private static let danglers: Set<String> = [
        "the", "a", "an", "to", "of", "your", "my", "our", "at", "on", "in", "for", "with", "and", "so",
        "but", "or", "that", "this", "is", "are", "be", "from", "by", "into", "onto", "as", "toward",
    ]
    /// Clause ends: sentence punctuation and commas (followed by a space or the end), dashes, and
    /// the joins that start a reason or a second step.
    private static let boundary = try! NSRegularExpression(
        pattern: #"[.!?;:,]+(?=\s|$)|\s[-—–]+\s|[—–]|\b(?:so that|so|because|and then|then|and|but|while|which|until|to make|to get)\b"#,
        options: [.caseInsensitive])

    /// The tag text, and whether its clause is finished (a boundary follows it).
    static func tag(from caption: String) -> (String, Bool)? {
        let text = CoachSession.spoken(caption).replacingOccurrences(of: "…", with: " ")
        let ns = text as NSString
        var clauses: [(String, Bool)] = []
        var start = 0
        for m in boundary.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            clauses.append((ns.substring(with: NSRange(location: start, length: m.range.location - start)), true))
            start = m.range.location + m.range.length
        }
        clauses.append((ns.substring(from: start), false))
        for (clause, complete) in clauses {
            if let s = shorten(clause) { return (s, complete) }
        }
        return nil
    }

    private static func shorten(_ clause: String) -> String? {
        var words = clause.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(["'", "/", "%", "+", "-"])) }
            .filter { !$0.isEmpty }
        func lower(_ w: [String]) -> [String] { w.map { $0.lowercased().replacingOccurrences(of: "’", with: "'") } }
        guard !words.isEmpty else { return nil }
        let l = lower(words)
        if l.allSatisfy(interjections.contains) || emptyPhrases.contains(l.joined(separator: " ")) { return nil }
        var stripped = true
        while stripped, !words.isEmpty {
            stripped = false
            let l = lower(words)
            for lead in leadIns where l.starts(with: lead) && words.count > lead.count {
                words.removeFirst(lead.count)
                stripped = true
                break
            }
        }
        words = words.filter { !fillers.contains($0.lowercased()) }
        if words.count > maxWords {
            for soft in softeners {
                let l = lower(words)
                if let i = (0...(l.count - soft.count)).first(where: { Array(l[$0..<($0 + soft.count)]) == soft }) {
                    words.removeSubrange(i..<(i + soft.count))
                }
                if words.count <= maxWords { break }
            }
        }
        // Still long: an infinitive after the action is usually the reason ("tilt down to cut…").
        if words.count > maxWords, let i = words.indices.dropFirst(2).first(where: { words[$0].lowercased() == "to" }) {
            words = Array(words[..<i])
        }
        if words.count > maxWords {
            words = Array(words.prefix(maxWords))
            while let w = words.last, words.count > 1, danglers.contains(w.lowercased()) { words.removeLast() }
        }
        guard !words.isEmpty, !lower(words).allSatisfy(interjections.contains) else { return nil }
        var s = words.joined(separator: " ")
        s = s.prefix(1).uppercased() + s.dropFirst()
        return s
    }
}
