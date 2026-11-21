import SwiftUI

/// The zoom tick-ruler strip, the focus ruler's twin: a logarithmic lens scale sliding under a
/// fixed centre needle, with the display zoom at the right end (`2 ×`). 44pt tall, full width.
///
///     ZoomRuler(zoom: $zoom, range: 0.5...10, stops: [0.5, 1, 2, 5], actor: lastChangeBy)
///
/// - Zoom is the *display* zoom (0.5 = ultra-wide, 1 = wide). Equal distances are equal zoom
///   ratios (60pt per doubling), so 0.5–1× gets as much room as 1–2×; zooming in is to the right.
/// - Drag to zoom (live, with momentum). The stops are detents: the wheel holds at them for a
///   moment, lands on one when released near it, and gives a light tick as it passes each.
/// - When the binding changes from outside with `actor == .gemini`, the ticks glide there with the
///   iridescent inner glow (the "Gemini moving" state); `.user` changes jump without a glow.
public struct ZoomRuler: View {
    @Binding private var zoom: Double
    private let range: ClosedRange<Double>
    private let stops: [Double]
    private let actor: CoachActor
    @State private var state: ZoomRulerState
    @State private var lastWritten: Double?
    @State private var detents = 0
    @Environment(\.coachClock) private var fixedClock

    public init(zoom: Binding<Double>, range: ClosedRange<Double> = 0.5...10,
                stops: [Double] = [0.5, 1, 2, 5], actor: CoachActor = .user) {
        _zoom = zoom
        self.range = range
        self.stops = stops
        self.actor = actor
        _state = State(initialValue: ZoomRulerState(zoom: zoom.wrappedValue, range: range, stops: stops))
    }

    private var now: Date { fixedClock ?? Date() }

    public var body: some View {
        CoachTimeline(animating: state.isActive) { date in
            ZoomRulerFace(state: state, date: date)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                if state.drag == nil { state.beginDrag(at: Date()) }
                let before = state.stopIndex(at: state.drag?.position ?? state.target)
                state.updateDrag(translation: g.translation.width, velocity: g.velocity.width)
                let pos = state.drag?.position ?? state.target
                if state.stopIndex(at: pos) != before { detents += 1 }
                write(state.zoom(at: pos))
            }
            .onEnded { g in
                let end = state.endDrag(velocity: g.velocity.width, at: Date())
                if state.isStop(end) { detents += 1 }
                write(state.zoom(at: end))
            })
        .sensoryFeedback(.impact(weight: .light), trigger: detents)
        .onChange(of: zoom) { _, new in
            guard new != lastWritten, state.drag == nil else { return }
            state.change(to: new, by: actor, at: now)
        }
        .onChange(of: range) { _, new in state.range = ZoomRulerState.octaves(new) }
        .onChange(of: stops) { _, new in state.stops = new.map { log2($0) } }
        .task(id: state.done) {
            guard fixedClock == nil, let done = state.done else { return }
            let wait = done.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            state.finish()
        }
        .accessibilityElement()
        .accessibilityLabel("Zoom")
        .accessibilityValue(ZoomRulerFace.format(zoom).joined())
        .accessibilityAdjustableAction { direction in
            let p = state.target
            let next = direction == .increment
                ? state.stops.first { $0 > p + 0.01 } ?? state.range.upperBound
                : state.stops.last { $0 < p - 0.01 } ?? state.range.lowerBound
            let z = state.zoom(at: next)
            write(z)
            state.change(to: z, by: .user, at: now)
        }
    }

    private func write(_ z: Double) {
        lastWritten = z
        if zoom != z { zoom = z }
    }
}

/// Ruler position in octaves of zoom: `log2(zoom)` (0 at 1×, -1 at 0.5×, 1 at 2×).
struct ZoomRulerState: Equatable {
    /// Points per doubling of zoom.
    static let octave: CGFloat = 60
    /// Half-width of a detent's hold while dragging, and the snap reach when released.
    static let hold = 0.05
    static let snap = 0.14
    static let geminiSpring = CoachSpring.glide

    struct Drag: Equatable {
        var origin: Double
        var position: Double
        var velocity: Double
    }

    var range: ClosedRange<Double>
    var stops: [Double]
    var target: Double
    var glide: Glide?
    var glowing = false
    var drag: Drag?

    init(zoom: Double, range: ClosedRange<Double>, stops: [Double]) {
        self.range = Self.octaves(range)
        self.stops = stops.map { log2($0) }
        target = 0
        target = clamp(log2(max(zoom, 0.01)))
    }

    static func octaves(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        let lo = log2(max(r.lowerBound, 0.01))
        return lo...max(lo, log2(max(r.upperBound, 0.01)))
    }

    func clamp(_ p: Double) -> Double { min(max(p, range.lowerBound), range.upperBound) }

    /// Display zoom at a position, rounded to 0.01 so a detent lands exactly on 0.5 / 1 / 2 / 5.
    func zoom(at p: Double) -> Double { (pow(2, clamp(p)) * 100).rounded() / 100 }

    func isStop(_ p: Double) -> Bool { stops.contains { abs($0 - p) < 0.001 } }

    /// How many stops sit at or below `p` (changes as the wheel passes one).
    func stopIndex(at p: Double) -> Int { stops.filter { $0 <= p + 0.0005 }.count }

    var isActive: Bool { drag != nil || glide != nil }

    var done: Date? { glide.map { $0.end.addingTimeInterval(glowing ? DrumState.fade : 0) } }

    func position(at date: Date) -> Double { drag?.position ?? glide?.value(at: date) ?? target }

    func glow(at date: Date) -> Double {
        if drag != nil { return 0 }
        guard glowing, let g = glide else { return 0 }
        let t = date.timeIntervalSince(g.start)
        if t < 0 { return 0 }
        if t < 0.09 { return GXMath.lerp(0.5, 0.82, t / 0.09) }
        let e = g.duration
        if t < e - 0.15 { return 0.82 }
        if t < e { let u = (t - (e - 0.15)) / 0.15; return 0.82 - 0.52 * u * u * u }
        let u = (t - e) / DrumState.fade
        return u >= 1 ? 0 : 0.3 * (1 - GXMath.easeOut(u))
    }

    mutating func change(to z: Double, by actor: CoachActor, at now: Date) {
        let p = position(at: now)
        let v = glide?.velocity(at: now) ?? 0
        target = clamp(log2(max(z, 0.01)))
        drag = nil
        switch actor {
        case .gemini:
            glide = Glide(from: p, to: target, velocity: v, start: now, spring: Self.geminiSpring, epsilon: 0.003)
            glowing = true
        case .user:
            glide = nil
            glowing = false
        }
    }

    mutating func beginDrag(at now: Date) {
        let p = position(at: now)
        drag = Drag(origin: p, position: p, velocity: 0)
        glide = nil
        glowing = false
    }

    /// Follows the finger; inside a stop's hold the wheel sits on the stop (the detent).
    mutating func updateDrag(translation dx: CGFloat, velocity vx: CGFloat) {
        guard var d = drag else { return }
        let raw = d.origin - Double(dx / Self.octave)
        let lo = range.lowerBound, hi = range.upperBound
        var p = raw < lo ? lo - DrumState.rubber((lo - raw) * 10) / 10 : raw > hi ? hi + DrumState.rubber((raw - hi) * 10) / 10 : raw
        if let s = stops.first(where: { abs($0 - p) < Self.hold }) { p = s }
        d.position = p
        d.velocity = -Double(vx / Self.octave)
        drag = d
    }

    /// Lets go with momentum, settling on a stop when it comes to rest near one; returns the
    /// resting position.
    mutating func endDrag(velocity vx: CGFloat, at now: Date) -> Double {
        guard let d = drag else { return target }
        let v = min(max(-Double(vx / Self.octave), -8), 8)
        // CoachSpring.coast is critically damped at 4/s, so it coasts v/4 without overshoot.
        var rest = clamp(d.position + v / 4)
        if let s = stops.min(by: { abs($0 - rest) < abs($1 - rest) }), abs(s - rest) < Self.snap { rest = clamp(s) }
        target = rest
        glide = Glide(from: d.position, to: target, velocity: v, start: now, spring: .coast, epsilon: 0.003)
        glowing = false
        drag = nil
        return target
    }

    mutating func finish() {
        glide = nil
        glowing = false
    }
}

/// The zoom ruler at one instant: the focus ruler's layout (ticks over the left area, needle at
/// its centre, value right-aligned 12pt from the edge), with a lens scale of 0.1 / 0.2 / 0.5 / 1
/// steps and taller ticks at the stops.
struct ZoomRulerFace: View {
    let state: ZoomRulerState
    let date: Date

    /// Zoom values that get a tick (log-spaced on screen).
    static let marks: [Double] = {
        var m: [Double] = []
        var z = 0.5
        while z < 0.999 { m.append(z); z += 0.1 }
        z = 1; while z < 1.999 { m.append(z); z += 0.2 }
        z = 2; while z < 4.999 { m.append(z); z += 0.5 }
        z = 5; while z < 25.001 { m.append(z); z += 1 }
        return m.map { ($0 * 100).rounded() / 100 }
    }()

    /// `["0.5", " ×"]`, `["2", " ×"]`, `["2.4", " ×"]`.
    static func format(_ z: Double) -> [String] {
        let r = (z * 10).rounded() / 10
        let s = abs(r - r.rounded()) < 0.01 && r >= 1 ? String(Int(r.rounded())) : String(format: "%.1f", r)
        return [s, " \u{00D7}"]
    }

    var body: some View {
        let pos = state.position(at: date)
        let glow = state.glow(at: date)
        let tint = GXMath.clamp01((glow - 0.25) / 0.35)
        let parts = Self.format(pow(2, state.clamp(pos)))
        ZStack(alignment: .topLeading) {
            if glow > 0.002 { IridescentEdge(opacity: glow * 0.8, date: date) }
            Canvas { ctx, size in
                let area = max(0, size.width - 81)
                drawTicks(ctx, area: area, position: pos, snap: !state.isActive)
                let needle = CGRect(x: (area / 2 - 1).rounded(), y: 8, width: 2, height: 28)
                ctx.fill(Path(roundedRect: needle, cornerRadius: 1), with: .color(GXColor.frost))
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                let value = Text(parts[0]).font(GXFont.display(22)).tracking(-0.44).monospacedDigit()
                ZStack {
                    value.foregroundStyle(GXColor.frost).opacity(1 - tint)
                    if tint > 0.001 { value.foregroundStyle(Iridescent.numeral).opacity(tint) }
                }
                Text(parts[1]).font(GXFont.display(13)).tracking(0.26).foregroundStyle(GXColor.label)
            }
            .fixedSize()
            .instrumentGlyphTurn()
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
            .offset(y: 8)
        }
        .frame(height: 44)
        .clipped()
    }

    private func drawTicks(_ ctx: GraphicsContext, area: CGFloat, position: Double, snap: Bool) {
        guard area > 0 else { return }
        let centre = area / 2
        let r = state.range
        for z in Self.marks {
            let o = log2(z)
            guard o >= r.lowerBound - 0.001, o <= r.upperBound + 0.001 else { continue }
            let x = centre + CGFloat(o - position) * ZoomRulerState.octave
            guard x >= 0, x <= area else { continue }
            let major = state.isStop(o)
            let u = x / area
            // Same stroke ramps as the focus ruler: minor 0 → .34 → .34 → 0, major .06 → .62 → .62 → .06.
            let ramp = u < 0.28 ? u / 0.28 : u > 0.72 ? (1 - u) / 0.28 : 1
            let alpha = major ? 0.06 + 0.56 * ramp : 0.34 * ramp
            var line = Path()
            let px = snap ? x.rounded() + 0.5 : x + 0.5
            line.move(to: CGPoint(x: px, y: major ? 14 : 18))
            line.addLine(to: CGPoint(x: px, y: major ? 30 : 26))
            ctx.stroke(line, with: .color(GXColor.frost.alpha(alpha)), lineWidth: 1)
        }
    }
}
