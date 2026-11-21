import SwiftUI

/// The focus tick-ruler strip: ticks every 6pt (major every 30pt) sliding under a fixed centre
/// needle, and the focus distance at the right end (`1.2 m`). 44pt tall, full width.
///
///     FocusRuler(metres: $focusMetres, actor: lastChangeBy)
///
/// - Distance is in metres (`.infinity` for ∞), 0.1 m … ∞. One minor tick is 0.1 dioptre, so
///   far distances are compressed the way a lens is; farther is to the right.
/// - Drag to focus (continuous, with momentum); the binding is written live.
/// - When the binding changes from outside with `actor == .gemini`, the ticks glide there with the
///   iridescent inner glow (the "Gemini moving" state); `.user` changes jump without a glow.
public struct FocusRuler: View {
    @Binding private var metres: Double
    private let actor: CoachActor
    @State private var state: RulerState
    @State private var lastWritten: Double?
    @Environment(\.coachClock) private var fixedClock

    public init(metres: Binding<Double>, actor: CoachActor = .user) {
        self.init(metres: metres, actor: actor, seed: nil)
    }

    /// Seeds motion (e.g. a Gemini move already in flight) for previews and snapshots.
    init(metres: Binding<Double>, actor: CoachActor, seed: RulerState?) {
        _metres = metres
        self.actor = actor
        _state = State(initialValue: seed ?? RulerState(metres: metres.wrappedValue))
    }

    private var now: Date { fixedClock ?? Date() }

    public var body: some View {
        CoachTimeline(animating: state.isActive) { date in
            RulerFace(state: state, date: date)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                if state.drag == nil { state.beginDrag(at: Date()) }
                state.updateDrag(translation: g.translation.width, velocity: g.velocity.width)
                write(state.metres(atTicks: state.drag?.position ?? state.target))
            }
            .onEnded { g in
                let end = state.endDrag(velocity: g.velocity.width, at: Date())
                write(state.metres(atTicks: end))
            })
        .onChange(of: metres) { _, new in
            guard new != lastWritten, state.drag == nil else { return }
            state.change(to: new, by: actor, at: now)
        }
        .task(id: state.done) {
            guard fixedClock == nil, let done = state.done else { return }
            let wait = done.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            state.finish()
        }
        .accessibilityElement()
        .accessibilityLabel("Focus")
        .accessibilityValue(RulerFace.format(metres).joined())
        .accessibilityAdjustableAction { direction in
            let t = state.target + (direction == .increment ? 5 : -5)
            let m = state.metres(atTicks: t)
            write(m)
            state.change(to: m, by: .user, at: now)
        }
    }

    private func write(_ m: Double) {
        lastWritten = m
        if metres != m { metres = m }
    }
}

/// Ruler position in minor ticks: 0 at ∞, -100 at 0.1 m (ticks = -10 / metres).
struct RulerState: Equatable {
    static let tick: CGFloat = 6
    static let range: ClosedRange<Double> = -100...0
    /// Gemini's move: slow enough to watch.
    static let geminiSpring = CoachSpring.glide

    struct Drag: Equatable {
        var origin: Double
        var position: Double
        var velocity: Double
    }

    var target: Double
    var glide: Glide?
    var glowing = false
    var drag: Drag?

    init(metres: Double) { target = Self.ticks(metres: metres) }

    /// A ruler Gemini started moving at `start`.
    static func changing(from: Double, to: Double, at start: Date) -> RulerState {
        var s = RulerState(metres: from)
        s.change(to: to, by: .gemini, at: start)
        return s
    }

    static func ticks(metres m: Double) -> Double {
        guard m.isFinite else { return 0 }
        return min(max(-10 / max(m, 0.1), range.lowerBound), range.upperBound)
    }

    func metres(atTicks t: Double) -> Double {
        let c = min(max(t, Self.range.lowerBound), Self.range.upperBound)
        return c > -0.05 ? .infinity : -10 / c
    }

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

    mutating func change(to m: Double, by actor: CoachActor, at now: Date) {
        let p = position(at: now)
        let v = glide?.velocity(at: now) ?? 0
        target = Self.ticks(metres: m)
        drag = nil
        switch actor {
        case .gemini:
            glide = Glide(from: p, to: target, velocity: v, start: now, spring: Self.geminiSpring, epsilon: 0.02)
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

    mutating func updateDrag(translation dx: CGFloat, velocity vx: CGFloat) {
        guard var d = drag else { return }
        let raw = d.origin - Double(dx / Self.tick)
        let lo = Self.range.lowerBound, hi = Self.range.upperBound
        d.position = raw < lo ? lo - DrumState.rubber(lo - raw) * 5 : raw > hi ? hi + DrumState.rubber(raw - hi) * 5 : raw
        d.velocity = -Double(vx / Self.tick)
        drag = d
    }

    /// Lets go with momentum (scroll-view deceleration, no detents); returns the resting position.
    mutating func endDrag(velocity vx: CGFloat, at now: Date) -> Double {
        guard let d = drag else { return target }
        let v = min(max(-Double(vx / Self.tick), -400), 400)
        // CoachSpring.coast is critically damped at 4/s, so it coasts v/4 without overshoot.
        target = min(max(d.position + v / 4, Self.range.lowerBound), Self.range.upperBound)
        glide = Glide(from: d.position, to: target, velocity: v, start: now, spring: .coast, epsilon: 0.02)
        glowing = false
        drag = nil
        return target
    }

    mutating func finish() {
        glide = nil
        glowing = false
    }
}

/// The ruler at one instant (design: 393 × 44; ticks over the left 312pt, needle at its centre,
/// value right-aligned 12pt from the edge).
struct RulerFace: View {
    let state: RulerState
    let date: Date

    /// `["1.2", " m"]`, `["12", " m"]`, `["∞", ""]`.
    static func format(_ m: Double) -> [String] {
        guard m.isFinite, m < 100 else { return ["\u{221E}", ""] }
        if m < 1 { return [String(format: "%.2f", m), " m"] }
        if m < 10 { return [String(format: "%.1f", m), " m"] }
        return [String(Int(m.rounded())), " m"]
    }

    var body: some View {
        let pos = state.position(at: date)
        let glow = state.glow(at: date)
        let tint = GXMath.clamp01((glow - 0.25) / 0.35)
        let parts = Self.format(state.metres(atTicks: pos))
        ZStack(alignment: .topLeading) {
            // The strip is half a drum's height, so its glow runs a little softer.
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
        let tick = RulerState.tick
        let centre = area / 2
        let first = Int((position - Double(centre / tick)).rounded(.down)) - 1
        let last = Int((position + Double(centre / tick)).rounded(.up)) + 1
        for k in first...last {
            let x = centre + CGFloat(Double(k) - position) * tick
            guard x >= 0, x <= area else { continue }
            let major = k % 5 == 0
            let u = x / area
            // The design's stroke gradients: minor 0 → .34 → .34 → 0, major .06 → .62 → .62 → .06.
            let ramp = u < 0.28 ? u / 0.28 : u > 0.72 ? (1 - u) / 0.28 : 1
            let alpha = major ? 0.06 + 0.56 * ramp : 0.34 * ramp
            var line = Path()
            // Pixel-crisp at rest; sub-pixel while sliding so slow moves don't step.
            let px = snap ? x.rounded() + 0.5 : x + 0.5
            line.move(to: CGPoint(x: px, y: major ? 14 : 18))
            line.addLine(to: CGPoint(x: px, y: major ? 30 : 26))
            ctx.stroke(line, with: .color(GXColor.frost.alpha(alpha)), lineWidth: 1)
        }
    }
}
