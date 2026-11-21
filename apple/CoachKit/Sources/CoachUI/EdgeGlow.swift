import CoachModels
import SwiftUI

/// The viewfinder's own border as the guide (replaces arrows). Overlay it on the viewfinder
/// *after* clipping, with the same corner radius; it bleeds a little past the frame:
///
///     viewfinder
///         .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
///         .overlay(EdgeGlow(.move([.left, .top]), strength: offBy))
///
/// - `.move(edges)`: the edge(s) you should move toward glow Gemini blue (hot at the very edge,
///   falling off ~40pt inward, slight bleed outside) with a slow shimmer along the edge. Two
///   adjacent edges make a hot corner.
/// - `.roll(clockwise:)`: opposite corners glow (level the phone by rotating that way).
/// - `.closer` / `.back`: the whole frame breathes (inward for closer, outward for back).
/// - `.aligned`: one soft full-perimeter pulse when it appears, then it fades.
/// - `.hold`: nothing.
///
/// `strength` (0…1, how far off you are) scales the intensity. Cue changes cross-fade over 420ms.
public struct EdgeGlow: View {
    /// Viewfinder edges.
    public struct Edges: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1)
        public static let right = Edges(rawValue: 2)
        public static let top = Edges(rawValue: 4)
        public static let bottom = Edges(rawValue: 8)
    }

    public enum Cue: Hashable, Sendable {
        case move(Edges)
        case roll(clockwise: Bool)
        case closer
        case back
        case aligned
        case hold
    }

    private let cue: Cue
    private let strength: Double
    private let cornerRadius: CGFloat
    @State private var previous: Cue
    @State private var changedAt: Date
    @State private var settled = false
    @Environment(\.coachClock) private var fixedClock

    public init(_ cue: Cue, strength: Double = 1, cornerRadius: CGFloat = 30) {
        self.init(cue, strength: strength, cornerRadius: cornerRadius, previous: cue, changedAt: .distantPast)
    }

    /// From the `guide` tool's direction (nil = hold). Strength: small .55, medium .8, large 1.
    public init(_ direction: GuideDirection?, strength: GuideStrength = .medium, cornerRadius: CGFloat = 30) {
        let k: Double
        switch strength {
        case .small: k = 0.55
        case .medium: k = 0.8
        case .large: k = 1
        }
        self.init(Self.cue(for: direction), strength: k, cornerRadius: cornerRadius)
    }

    /// Seeds a cue change at `changedAt` (previews and snapshots).
    init(_ cue: Cue, strength: Double, cornerRadius: CGFloat, previous: Cue, changedAt: Date) {
        self.cue = cue
        self.strength = strength
        self.cornerRadius = cornerRadius
        _previous = State(initialValue: previous)
        _changedAt = State(initialValue: changedAt)
    }

    static func cue(for d: GuideDirection?) -> Cue {
        switch d {
        case .left: return .move(.left)
        case .right: return .move(.right)
        case .up: return .move(.top)
        case .down: return .move(.bottom)
        case .closer: return .closer
        case .back: return .back
        case .rotateLeft: return .roll(clockwise: false)
        case .rotateRight: return .roll(clockwise: true)
        case .hold, nil: return .hold
        }
    }

    private var now: Date { fixedClock ?? Date() }

    private var loops: Bool {
        switch cue {
        case .move, .roll, .closer, .back: return true
        case .aligned, .hold: return false
        }
    }

    public var body: some View {
        CoachTimeline(animating: loops || !settled) { date in
            let f = GXMath.easeOut(date.timeIntervalSince(changedAt) / 0.42)
            ZStack {
                if f < 1, previous != cue {
                    EdgeGlowLayer(cue: previous, k: strength * (1 - f), radius: cornerRadius, date: date, since: .distantPast)
                }
                EdgeGlowLayer(cue: cue, k: strength * (previous == cue ? 1 : f), radius: cornerRadius, date: date, since: changedAt)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if cue == .aligned, changedAt == .distantPast {
                changedAt = now
                settled = false
            }
        }
        .onChange(of: cue) { old, _ in
            previous = old
            changedAt = now
            settled = false
        }
        .task(id: changedAt) {
            guard fixedClock == nil else { return }
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { settled = true }
        }
    }
}

/// One cue at intensity `k`.
struct EdgeGlowLayer: View {
    let cue: EdgeGlow.Cue
    let k: Double
    let radius: CGFloat
    let date: Date
    /// When the cue appeared (for the one-shot aligned pulse).
    let since: Date

    private static let hot = GXColor.geminiHot
    private static let blue = GXColor.gemini

    var body: some View {
        GeometryReader { geo in
            let s = max(0.6, min(1, min(geo.size.width, geo.size.height) / 377))
            let k = GXMath.clamp01(self.k)
            if k > 0.002 {
                switch cue {
                case .move(let edges):
                    move(edges, k: k, scale: s)
                case .roll(let clockwise):
                    ZStack {
                        corner(clockwise ? [.right, .top] : [.left, .top], k: k, scale: s, size: geo.size)
                        corner(clockwise ? [.left, .bottom] : [.right, .bottom], k: k, scale: s, size: geo.size)
                    }
                case .closer:
                    let b = breathe
                    ZStack {
                        InsetShadow(color: Self.blue.alpha((0.3 + 0.3 * b) * k), blur: (28 + 30 * b) * s, radius: radius, style: .continuous)
                        InsetShadow(color: Self.hot.alpha((0.45 + 0.3 * b) * k), spread: 1.5, radius: radius, style: .continuous)
                    }
                case .back:
                    let b = breathe
                    ZStack {
                        OuterGlow(color: Self.blue.alpha((0.35 + 0.35 * b) * k), blur: (16 + 16 * b) * s, radius: radius, style: .continuous)
                        InsetShadow(color: Self.blue.alpha(0.25 * k), blur: 24 * s, radius: radius, style: .continuous)
                        InsetShadow(color: Self.hot.alpha((0.4 + 0.2 * b) * k), spread: 1.5, radius: radius, style: .continuous)
                    }
                case .aligned:
                    let a = pulse * k
                    ZStack {
                        InsetShadow(color: Self.blue.alpha(0.42 * a), blur: 34 * s, radius: radius, style: .continuous)
                        InsetShadow(color: Self.hot.alpha(0.7 * a), spread: 1.5, radius: radius, style: .continuous)
                    }
                case .hold:
                    EmptyView()
                }
            }
        }
    }

    /// 0…1…0 every 1.8s.
    private var breathe: Double {
        0.5 - 0.5 * cos(date.timeIntervalSinceReferenceDate * 2 * .pi / 1.8)
    }

    /// Aligned: rises over 240ms, holds 200ms, fades over 1s.
    private var pulse: Double {
        let t = date.timeIntervalSince(since)
        if t < 0 { return 0 }
        if t < 0.24 { return GXMath.easeOut(t / 0.24) }
        if t < 0.44 { return 1 }
        return max(0, 1 - GXMath.easeOut((t - 0.44) / 1.0))
    }

    private func move(_ edges: EdgeGlow.Edges, k: Double, scale s: CGFloat) -> some View {
        let dx: CGFloat = edges.contains(.left) ? 1 : edges.contains(.right) ? -1 : 0
        let dy: CGFloat = edges.contains(.top) ? 1 : edges.contains(.bottom) ? -1 : 0
        let corner = dx != 0 && dy != 0
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let wash: [Gradient.Stop] = corner
            ? [.init(color: Self.hot.alpha(0.8 * k), location: 0), .init(color: Self.blue.alpha(0.4 * k), location: 0.18),
               .init(color: Self.blue.alpha(0), location: 0.42)]
            : [.init(color: Self.hot.alpha(0.55 * k), location: 0), .init(color: Self.blue.alpha(0.25 * k), location: 0.45),
               .init(color: Self.blue.alpha(0), location: 1)]
        let lap = 2.4
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: lap) / lap * 1.6 - 0.3
        let vertical = dx != 0
        return ZStack {
            OuterGlow(color: Self.blue.alpha(0.65 * k), x: -7 * dx * s, y: -7 * dy * s, blur: 22 * s, spread: -6 * s,
                      radius: radius, style: .continuous)
            EllipticalFill(stops: wash, rx: 0, ry: 0, cx: dx > 0 ? 0 : dx < 0 ? 1 : 0.5,
                           cy: dy > 0 ? 0 : dy < 0 ? 1 : 0.52, farthestCorner: true)
                .clipShape(shape)
            ForEach(Array(Self.single(edges).enumerated()), id: \.offset) { _, e in
                InsetShadow(color: Self.blue.alpha(0.62 * k), x: 44 * e.dx * s, y: 44 * e.dy * s, blur: 40 * s, spread: -22 * s,
                            radius: radius, style: .continuous)
            }
            InsetShadow(color: Self.hot.alpha(0.9 * k), x: 2 * dx, y: 2 * dy, radius: radius, style: .continuous)
            // Shimmer: a brighter band travelling along the lit edge.
            InsetShadow(color: Self.hot.alpha(0.6 * k), x: 3 * dx, y: 3 * dy, blur: 6, radius: radius, style: .continuous)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: phase - 0.22), .init(color: .black, location: phase),
                                           .init(color: .clear, location: phase + 0.22)],
                                   startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
                }
        }
    }

    /// A corner of `.roll`: the corner part of a two-edge move.
    private func corner(_ edges: EdgeGlow.Edges, k: Double, scale s: CGFloat, size: CGSize) -> some View {
        let cx: CGFloat = edges.contains(.left) ? 0 : 1
        let cy: CGFloat = edges.contains(.top) ? 0 : 1
        let reach = min(size.width, size.height) * 0.6
        return move(edges, k: k, scale: s)
            .mask {
                // Padded so the outside bleed survives the mask; centre mapped into the padded box.
                RadialGradient(colors: [.black, .black, .clear],
                               center: UnitPoint(x: (cx * size.width + 40) / (size.width + 80),
                                                 y: (cy * size.height + 40) / (size.height + 80)),
                               startRadius: 0, endRadius: reach)
                    .padding(-40)
            }
    }

    private static func single(_ edges: EdgeGlow.Edges) -> [(dx: CGFloat, dy: CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        if edges.contains(.left) { out.append((1, 0)) }
        if edges.contains(.right) { out.append((-1, 0)) }
        if edges.contains(.top) { out.append((0, 1)) }
        if edges.contains(.bottom) { out.append((0, -1)) }
        return out
    }
}
