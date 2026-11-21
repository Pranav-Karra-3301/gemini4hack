import SwiftUI

/// The `ISO | SS | EV` readout row: three horizontal drums with hairline dividers, 84pt tall.
///
///     InstrumentDrums(iso: $iso, shutter: $shutter, ev: $ev, actor: lastChangeBy)
///
/// - At rest each drum shows its value with the whole ±1 neighbours faded (35%, half size).
/// - Drag a drum with momentum; it snaps to a detent (spring 300/28) and ticks (iOS haptic) on
///   settle. Drags write the binding live. Double-tap returns ISO/SS to `AUTO` and EV to 0.0.
/// - When a binding changes from outside, the drum animates to it. With `actor == .gemini` it
///   rolls one detent per 240ms: motion blur, a small overshoot, settle, while the iridescent
///   inner glow peaks and fades over 420ms. With `.user` it springs straight there.
/// - While the user is dragging a drum, outside changes to it are ignored (the user has control).
public struct InstrumentDrums: View {
    @Binding private var iso: InstrumentValue
    @Binding private var shutter: InstrumentValue
    @Binding private var ev: InstrumentValue
    private let actor: CoachActor
    private let seeds: [InstrumentValue.Kind: DrumState]

    public init(iso: Binding<InstrumentValue>, shutter: Binding<InstrumentValue>, ev: Binding<InstrumentValue>,
                actor: CoachActor = .user) {
        self.init(iso: iso, shutter: shutter, ev: ev, actor: actor, seeds: [:])
    }

    /// Seeds drum motion (e.g. a Gemini change already in flight) for previews and snapshots.
    init(iso: Binding<InstrumentValue>, shutter: Binding<InstrumentValue>, ev: Binding<InstrumentValue>,
         actor: CoachActor, seeds: [InstrumentValue.Kind: DrumState]) {
        _iso = iso
        _shutter = shutter
        _ev = ev
        self.actor = actor
        self.seeds = seeds
    }

    public var body: some View {
        HStack(spacing: 0) {
            DrumCell(value: $iso, actor: actor, seed: seeds[.iso])
            DrumCell(value: $shutter, actor: actor, seed: seeds[.shutter])
            DrumCell(value: $ev, actor: actor, seed: seeds[.ev])
        }
        .frame(height: 84)
        .overlay {
            GeometryReader { geo in
                ForEach(1..<3, id: \.self) { i in
                    Rectangle().fill(GXColor.hairline)
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: (geo.size.width * CGFloat(i) / 3).rounded())
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - One drum

struct DrumCell: View {
    @Binding var value: InstrumentValue
    let actor: CoachActor
    @State private var state: DrumState
    @State private var lastWritten: InstrumentValue?
    @State private var settleTick = 0
    @Environment(\.coachClock) private var fixedClock

    init(value: Binding<InstrumentValue>, actor: CoachActor, seed: DrumState?) {
        _value = value
        self.actor = actor
        _state = State(initialValue: seed ?? DrumState(value.wrappedValue))
    }

    private var now: Date { fixedClock ?? Date() }

    var body: some View {
        GeometryReader { geo in
            let spacing = DrumFace.spacing(state.kind) * geo.size.width / 131
            CoachTimeline(animating: state.isActive) { date in
                DrumFace(state: state, label: value.label, date: date, size: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(drag(spacing: spacing))
        }
        .frame(maxWidth: .infinity)
        .onTapGesture(count: 2) { reset() }
        .onChange(of: value) { _, new in
            guard new != lastWritten, state.drag == nil else { return }
            state.change(to: new, by: actor, at: now)
        }
        .task(id: state.motionEnd) { await settle() }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: settleTick)
        #endif
        .accessibilityElement()
        .accessibilityLabel(value.label)
        .accessibilityValue(value.text)
        .accessibilityAdjustableAction { direction in
            let i = state.target + (direction == .increment ? 1 : -1)
            guard state.strip.indices.contains(i) else { return }
            write(InstrumentValue(state.kind, state.strip[i]))
            state.change(to: InstrumentValue(state.kind, state.strip[i]), by: .user, at: now)
        }
    }

    private func drag(spacing: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in
                if state.drag == nil { state.beginDrag(at: Date()) }
                state.updateDrag(translation: g.translation.width, velocity: g.velocity.width, spacing: spacing)
                let i = state.nearestIndex
                if lastWritten?.number != state.strip[i] || value.isAuto {
                    write(InstrumentValue(state.kind, state.strip[i]))
                }
            }
            .onEnded { g in
                let i = state.endDrag(velocity: g.velocity.width, spacing: spacing, at: Date())
                write(InstrumentValue(state.kind, state.strip[i]))
            }
    }

    private func reset() {
        let v = state.kind == .ev ? InstrumentValue.ev(0) : InstrumentValue(state.kind, value.number, auto: true)
        guard v != value else { return }
        write(v)
        state.change(to: v, by: .user, at: now)
    }

    private func write(_ v: InstrumentValue) {
        lastWritten = v
        if value != v { value = v }
    }

    private func settle() async {
        guard fixedClock == nil, let end = state.motionEnd, let done = state.done else { return }
        let toSettle = end.timeIntervalSinceNow
        if toSettle > 0 { try? await Task.sleep(for: .seconds(toSettle)) }
        guard !Task.isCancelled else { return }
        settleTick &+= 1
        let toDone = done.timeIntervalSinceNow
        if toDone > 0 { try? await Task.sleep(for: .seconds(toDone)) }
        guard !Task.isCancelled else { return }
        state.finish()
    }
}

// MARK: - Motion

/// A drum's strip and its motion, as pure functions of time (so any frame can be rendered).
/// Positions are fractional indices into `strip`.
struct DrumState: Equatable {
    /// Detent snap (design: "spring 300 / 28").
    static let spring = CoachSpring(stiffness: 300, damping: 28)
    /// Gemini rolls one detent per step.
    static let step = 0.24
    /// Each Gemini detent first pulls toward a point this far past the detent, then retargets to
    /// it after `pull` seconds: crisp at the start, blurred mid-roll, a small overshoot, settle.
    static let overshoot = 0.25
    static let pull = 0.1
    /// Glow fade after settling.
    static let fade = 0.42
    static let epsilon = 0.004

    struct Drag: Equatable {
        var origin: Double
        var position: Double
        var velocity: Double
    }

    var kind: InstrumentValue.Kind
    var strip: [Double]
    var target: Int
    var isAuto: Bool
    var segments: [Glide] = []
    var motionStart: Date?
    /// When the move is considered settled (haptic tick; glow starts its 420ms fade).
    var motionEnd: Date?
    var glowFrom = 0.5
    var glowPeak = 0.82
    var drag: Drag?

    init(_ v: InstrumentValue) {
        kind = v.kind
        strip = InstrumentValue.strip(v.kind, including: [v.number])
        target = InstrumentValue.index(of: v.number, in: strip, kind: v.kind)
        isAuto = v.isAuto
    }

    /// A drum that started changing from `from` to `to` at `start`.
    static func changing(from: InstrumentValue, to: InstrumentValue, by actor: CoachActor, at start: Date) -> DrumState {
        var s = DrumState(from)
        s.change(to: to, by: actor, at: start)
        return s
    }

    var isActive: Bool { drag != nil || motionStart != nil }

    /// When the glow has faded and the spring has settled.
    var done: Date? {
        guard let e = motionEnd else { return nil }
        let fade = e.addingTimeInterval(Self.fade)
        return max(fade, segments.last?.end ?? fade)
    }

    var nearestIndex: Int {
        let p = drag?.position ?? Double(target)
        return Int(min(max(p.rounded(), 0), Double(strip.count - 1)))
    }

    func segment(at date: Date) -> Glide? { segments.last { $0.start <= date } ?? segments.first }

    func position(at date: Date) -> Double {
        if let drag { return drag.position }
        return segment(at: date)?.value(at: date) ?? Double(target)
    }

    func velocity(at date: Date) -> Double {
        if let drag { return drag.velocity }
        return segment(at: date)?.velocity(at: date) ?? 0
    }

    /// Inner-glow opacity: 0.5 at the start, ~0.82 while moving, 0.3 at settle, 0 after 420ms.
    func glow(at t: Date) -> Double {
        if let drag { return glowFrom + (0.82 - glowFrom) * GXMath.clamp01(abs(drag.velocity) / 3) }
        guard let s = motionStart, let e = motionEnd else { return 0 }
        let rise = s.addingTimeInterval(glowPeak > glowFrom ? 0.09 : 0)
        let fall = max(rise, e.addingTimeInterval(-0.15))
        if t <= s { return glowFrom }
        if t < rise { return GXMath.lerp(glowFrom, glowPeak, t.timeIntervalSince(s) / 0.09) }
        if t < fall { return glowPeak }
        if t < e {
            let u = t.timeIntervalSince(fall) / max(e.timeIntervalSince(fall), 1e-6)
            return glowPeak - (glowPeak - 0.3) * u * u * u
        }
        let u = t.timeIntervalSince(e) / Self.fade
        return u >= 1 ? 0 : 0.3 * (1 - GXMath.easeOut(u))
    }

    mutating func change(to v: InstrumentValue, by actor: CoachActor, at now: Date) {
        let p = position(at: now), vel = velocity(at: now), g = glow(at: now)
        let stops = InstrumentValue.stops(atPosition: p, in: strip, kind: kind)
        let keep = strip.indices.contains(target) ? strip[target] : v.number
        let newStrip = InstrumentValue.strip(kind, including: [v.number, keep])
        let from = InstrumentValue.position(ofStops: stops, in: newStrip, kind: kind)
        let to = InstrumentValue.index(of: v.number, in: newStrip, kind: kind)
        strip = newStrip
        target = to
        isAuto = v.isAuto
        drag = nil
        segments = []
        guard abs(from - Double(to)) > 0.001 || abs(vel) > 0.01 else {
            motionStart = nil
            motionEnd = nil
            return
        }
        glowFrom = max(0.5, g)
        glowPeak = 0.82
        motionStart = now
        switch actor {
        case .gemini:
            let dir: Double = Double(to) > from ? 1 : -1
            var stepsTo: [Double] = []
            var next = dir > 0 ? (from + 0.02).rounded(.up) : (from - 0.02).rounded(.down)
            while dir > 0 ? next < Double(to) : next > Double(to) {
                stepsTo.append(next)
                next += dir
            }
            stepsTo.append(Double(to))
            // One detent per 240ms; very long rolls compress to ~1.4s total.
            let interval = min(Self.step, 1.44 / Double(stepsTo.count))
            var t = now, pos = from, v0 = vel
            for (i, x) in stepsTo.enumerated() {
                let past = x + dir * Self.overshoot * min(1, abs(x - pos))
                let pull = Glide(from: pos, to: past, velocity: v0, start: t, spring: Self.spring, epsilon: Self.epsilon)
                let t1 = t.addingTimeInterval(min(Self.pull, interval))
                let glide = Glide(from: pull.value(at: t1), to: x, velocity: pull.velocity(at: t1), start: t1,
                                  spring: Self.spring, epsilon: Self.epsilon)
                segments += [pull, glide]
                if i < stepsTo.count - 1 {
                    t = t.addingTimeInterval(interval)
                    pos = glide.value(at: t)
                    v0 = glide.velocity(at: t)
                }
            }
            motionEnd = t.addingTimeInterval(Self.step)
        case .user:
            let glide = Glide(from: from, to: Double(to), velocity: vel, start: now, spring: Self.spring, epsilon: Self.epsilon)
            segments = [glide]
            motionEnd = now.addingTimeInterval(max(Self.step, min(glide.duration, 0.45)))
        }
    }

    mutating func beginDrag(at now: Date) {
        let p = position(at: now)
        glowFrom = max(0.5, glow(at: now))
        drag = Drag(origin: p, position: p, velocity: 0)
        segments = []
        motionStart = nil
        motionEnd = nil
        isAuto = false
    }

    mutating func updateDrag(translation dx: CGFloat, velocity vx: CGFloat, spacing: CGFloat) {
        guard var d = drag, spacing > 0 else { return }
        let raw = d.origin - Double(dx / spacing)
        let last = Double(strip.count - 1)
        d.position = raw < 0 ? -Self.rubber(-raw) : raw > last ? last + Self.rubber(raw - last) : raw
        d.velocity = -Double(vx / spacing)
        drag = d
    }

    /// Settles a drag on the detent its momentum carries it to; returns that index.
    mutating func endDrag(velocity vx: CGFloat, spacing: CGFloat, at now: Date) -> Int {
        guard let d = drag else { return target }
        let v = min(max(spacing > 0 ? -Double(vx / spacing) : 0, -40), 40)
        let projected = d.position + v * 0.2
        let to = Int(min(max(projected.rounded(), 0), Double(strip.count - 1)))
        let g = glow(at: now)
        let glide = Glide(from: d.position, to: Double(to), velocity: v, start: now, spring: Self.spring, epsilon: Self.epsilon)
        drag = nil
        target = to
        isAuto = false
        segments = [glide]
        glowFrom = g
        glowPeak = g
        motionStart = now
        motionEnd = now.addingTimeInterval(max(0.15, min(glide.duration, 0.45)))
        return to
    }

    mutating func finish() {
        segments = []
        motionStart = nil
        motionEnd = nil
    }

    /// iOS-style rubber band past the ends, in detents.
    static func rubber(_ x: Double) -> Double { (1 - 1 / (x * 0.55 / 0.6 + 1)) * 0.6 }
}

// MARK: - Drawing

/// One drum cell at one instant (design: 131 × 84, label at 12/12, strip at y 31, 36 tall).
struct DrumFace: View {
    let state: DrumState
    let label: String
    let date: Date
    let size: CGSize

    /// Centre-to-centre distance of neighbours at rest, per drum, at a 131pt cell.
    static func spacing(_ kind: InstrumentValue.Kind) -> CGFloat {
        switch kind {
        case .iso: return 46
        case .shutter: return 49
        case .ev: return 44
        }
    }

    /// Neighbour size at rest relative to the 30pt value (ISO 14pt, SS/EV 15pt).
    static func restScale(_ kind: InstrumentValue.Kind) -> Double { kind == .iso ? 14.0 / 30 : 0.5 }

    var body: some View {
        let glow = state.glow(at: date)
        ZStack(alignment: .topLeading) {
            if glow > 0.002 {
                IridescentEdge(opacity: glow, date: date)
            }
            Text(label)
                .font(GXFont.mono(10))
                .tracking(1.4)
                .foregroundStyle(GXColor.label)
                .fixedSize()
                .frame(height: 12)
                .offset(x: 12, y: 12)
            strip(glow: glow)
                .frame(width: size.width, height: 36)
                .offset(y: 31)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func strip(glow: Double) -> some View {
        let pos = state.position(at: date)
        let vel = state.velocity(at: date)
        let speed = GXMath.clamp01(abs(vel) / 10)
        let motion = max(speed, min(1, abs(pos - pos.rounded()) * 3))
        let tint = GXMath.clamp01((glow - 0.25) / 0.35)
        if state.isAuto && !state.isActive {
            Text("AUTO")
                .font(GXFont.display(22))
                .tracking(0.02 * 22)
                .foregroundStyle(GXColor.frost)
                .fixedSize()
                .frame(width: size.width, height: 36)
        } else {
            let lo = max(0, Int((pos - 2.2).rounded(.up)))
            let hi = min(state.strip.count - 1, Int((pos + 2.2).rounded(.down)))
            ZStack {
                if lo <= hi {
                    ForEach(lo...hi, id: \.self) { i in
                        item(i, d: Double(i) - pos, tint: tint, speed: speed, direction: vel >= 0 ? 1 : -1)
                    }
                }
            }
            .frame(width: size.width, height: 36)
            .blur(radius: 0.25 * speed)
            .mask { edgeFade(width: 18 * motion) }
        }
    }

    private func item(_ i: Int, d: Double, tint: Double, speed: Double, direction: Double) -> some View {
        let kind = state.kind
        let a = abs(d)
        let rest = Self.restScale(kind)
        let scale = a <= 1 ? 1 - (1 - rest) * a : max(0.3, rest - 0.1 * (a - 1))
        let opacity = a <= 1 ? 1 - 0.65 * a : max(0, 0.35 * (2 - a))
        let spacing = Self.spacing(kind) * size.width / 131
        let x = a <= 1 ? d * spacing : (d < 0 ? -1 : 1) * (spacing + (a - 1) * spacing * 0.85)
        let parts = InstrumentValue.parts(kind, state.strip[i])
        let prefixAmount = parts.prefix.isEmpty ? 0 : GXMath.clamp01(1 - 2 * a)
        let prefixWidth = parts.prefix.isEmpty ? 0 : GXFont.displayWidth(parts.prefix, size: 16, tracking: -0.32)
        // Full "1/125" is centred at the centre; neighbours centre their body ("250").
        let shift = -(1 - prefixAmount) * prefixWidth / 2 * scale
        let w = tint * GXMath.clamp01(1 - a)
        let tracking = (kind == .iso ? -0.03 : -0.02) * 30
        let body = Text(parts.body).font(GXFont.display(30)).tracking(tracking)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !parts.prefix.isEmpty {
                Text(parts.prefix).font(GXFont.display(16)).tracking(-0.32)
                    .foregroundStyle(GXColor.label.alpha(prefixAmount))
            }
            ZStack {
                if speed > 0.05 {
                    body.foregroundStyle(Color(rgba: 0xE8DAFFFF))
                        .opacity(0.22 * speed)
                        .offset(x: direction * 3 * speed)
                }
                body.foregroundStyle(GXColor.frost).opacity(1 - w)
                if w > 0.001 {
                    body.foregroundStyle(Iridescent.numeral).opacity(w)
                }
            }
        }
        .fixedSize()
        .scaleEffect(scale)
        .opacity(opacity)
        .offset(x: x + shift)
    }

    private func edgeFade(width f: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: f)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: f)
        }
    }
}
