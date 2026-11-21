import SwiftUI
import CoachModels

/// The coach's framing guidance as one big amber glyph (DESIGN.md §5): triple chevrons with an
/// edge glow for left/right/up/down, converging or diverging rings for closer/back, a circular
/// arrow for rotate, and a steady ring for hold. Fill the viewfinder's guidance zone with it.
/// Directions are camera moves in the raw (unmirrored) frame; mirror the view for selfies.
public struct GuideArrow: View {
    private let direction: GuideDirection?
    private let strength: GuideStrength
    private let subject: CGRect?
    private let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - direction: the move to show, or `nil` for nothing.
    ///   - strength: small / medium / large: glyph scale and nudge distance.
    ///   - subject: the subject's box in 0...1 coordinates of this view; rings centre on it.
    ///   - compact: phone sizes (stroke 11); `false` uses the laptop stroke (14).
    public init(_ direction: GuideDirection?, strength: GuideStrength = .medium,
                subject: CGRect? = nil, compact: Bool = true) {
        self.direction = direction
        self.strength = strength
        self.subject = subject
        self.compact = compact
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if let direction {
                    // Reduce Motion: loops hold still (DESIGN.md §6).
                    CoachTimeline(animating: !reduceMotion) { now in
                        GuideGlyph(direction: direction, strength: strength, subject: subject,
                                   compact: compact, size: geo.size,
                                   time: reduceMotion ? 0.3 : now.timeIntervalSinceReferenceDate)
                    }
                    .id(direction)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(Self.travel(direction, -24)))
                            .animation(CoachEase.out(CoachDuration.base)),
                        removal: .opacity.combined(with: .offset(Self.travel(direction, 16)))
                            .animation(CoachEase.in(CoachDuration.fast))))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(direction.map(Self.spoken) ?? "")
        .accessibilityHidden(direction == nil)
    }

    /// "Move left", "Get closer", "Hold still"...
    public static func spoken(_ d: GuideDirection) -> String {
        switch d {
        case .left: return "Move left"
        case .right: return "Move right"
        case .up: return "Move up"
        case .down: return "Move down"
        case .closer: return "Get closer"
        case .back: return "Step back"
        case .rotateLeft: return "Rotate left"
        case .rotateRight: return "Rotate right"
        case .hold: return "Hold still"
        }
    }

    static func travel(_ d: GuideDirection, _ amount: CGFloat) -> CGSize {
        switch d {
        case .left: return CGSize(width: -amount, height: 0)
        case .right: return CGSize(width: amount, height: 0)
        case .up: return CGSize(width: 0, height: -amount)
        case .down: return CGSize(width: 0, height: amount)
        default: return .zero
        }
    }
}

struct GuideGlyph: View {
    let direction: GuideDirection
    let strength: GuideStrength
    let subject: CGRect?
    let compact: Bool
    let size: CGSize
    let time: TimeInterval

    private var scale: CGFloat {
        switch strength { case .small: return 0.82; case .medium: return 1; case .large: return 1.14 }
    }

    var body: some View {
        switch direction {
        case .left, .right, .up, .down: chevrons
        case .closer, .back: rings
        case .rotateLeft, .rotateRight: rotate
        case .hold: hold
        }
    }

    // MARK: Chevrons + edge glow

    private var chevrons: some View {
        let phase = (time / 0.9).truncatingRemainder(dividingBy: 1)
        let amp: CGFloat = strength == .small ? 6 : (strength == .large ? 14 : 10)
        let nudge = amp * CGFloat(0.5 - 0.5 * cos(2 * .pi * phase))
        let glowPulse = 0.8 + 0.2 * sin(2 * .pi * time / 1.8)
        let horizontal = direction == .left || direction == .right
        let lead = GuideArrow.travel(direction, 1)
        let stroke: CGFloat = compact ? 11 : 14
        let glyph = CGSize(width: 180, height: 120)
        // Rotate the left-pointing glyph into place.
        let angle: Angle = direction == .left ? .zero : direction == .right ? .degrees(180)
            : direction == .up ? .degrees(90) : .degrees(-90)
        let along = horizontal ? glyph.width : glyph.height
        let edgeInset: CGFloat = 24 + along * scale / 2
        let center: CGPoint = {
            switch direction {
            case .left: return CGPoint(x: edgeInset, y: size.height * 0.42)
            case .right: return CGPoint(x: size.width - edgeInset, y: size.height * 0.42)
            case .up: return CGPoint(x: size.width / 2, y: edgeInset)
            default: return CGPoint(x: size.width / 2, y: size.height - edgeInset)
            }
        }()
        let glowLength: CGFloat = compact ? 380 : 500
        let glowWidth: CGFloat = compact ? 6 : 4
        let glowCenter: CGPoint = {
            switch direction {
            case .left: return CGPoint(x: 0, y: center.y)
            case .right: return CGPoint(x: size.width, y: center.y)
            case .up: return CGPoint(x: size.width / 2, y: 0)
            default: return CGPoint(x: size.width / 2, y: size.height)
            }
        }()

        return ZStack {
            // Edge glow: a bright bar half off-canvas inside a wide soft bloom (0 0 40px 14px).
            ZStack {
                Capsule()
                    .fill(CoachColor.safelight.opacity(0.5))
                    .frame(width: horizontal ? glowWidth + 40 : glowLength,
                           height: horizontal ? glowLength : glowWidth + 40)
                    .blur(radius: 18)
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: CoachColor.safelight.opacity(0), location: 0),
                                                 .init(color: CoachColor.safelight, location: 0.2),
                                                 .init(color: CoachColor.safelightHot, location: 0.5),
                                                 .init(color: CoachColor.safelight, location: 0.8),
                                                 .init(color: CoachColor.safelight.opacity(0), location: 1)],
                                         startPoint: horizontal ? .top : .leading,
                                         endPoint: horizontal ? .bottom : .trailing))
                    .frame(width: horizontal ? glowWidth * 2 : glowLength, height: horizontal ? glowLength : glowWidth * 2)
            }
            .opacity(glowPulse)
            .position(glowCenter)

            Canvas { ctx, sz in
                let bases: [Double] = [1, 0.55, 0.22]        // leading → trailing
                for i in 0..<3 {
                    let x0 = 20 + CGFloat(i) * 48
                    var p = Path()
                    p.move(to: CGPoint(x: x0 + 44, y: 16))
                    p.addLine(to: CGPoint(x: x0, y: 60))
                    p.addLine(to: CGPoint(x: x0 + 44, y: 104))
                    // Chase: a brightness wave runs from the trailing chevron to the leading one.
                    let delay = Double(2 - i) * 0.133
                    let wave = pow(0.5 + 0.5 * cos(2 * .pi * (phase - delay)), 3)
                    let o = bases[i] * 0.78 + (1 - bases[i] * 0.78) * wave * (i == 0 ? 1 : 0.7)
                    ctx.stroke(p, with: .color(CoachColor.safelight.opacity(o)),
                               style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: glyph.width, height: glyph.height)
            .rotationEffect(angle)
            .scaleEffect(scale)
            .shadow(color: .black.opacity(0.5), radius: 7, y: 2)
            .position(x: center.x + lead.width * nudge, y: center.y + lead.height * nudge)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Rings

    private var rings: some View {
        let c = ringCenter
        let radii: [CGFloat] = [108, 138, 166]
        let strokes: [CGFloat] = [5, 3, 2]
        let peaks: [Double] = [1, 0.38, 0.16]
        let closer = direction == .closer
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                let p = ((time - Double(i) * 0.3) / 1.2).truncatingRemainder(dividingBy: 1)
                let e = CoachEase.inOutCurve(p < 0 ? p + 1 : p)
                let s = closer ? 1.25 - 0.4 * e : 0.85 + 0.4 * e
                let o = peaks[i] * sin(.pi * e) * 0.6 + peaks[i] * 0.4
                Circle()
                    .stroke(CoachColor.safelight.opacity(o), lineWidth: strokes[i])
                    .frame(width: radii[i] * 2 * scale, height: radii[i] * 2 * scale)
                    .scaleEffect(s)
                    .position(c)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 7, y: 2)
        .frame(width: size.width, height: size.height)
    }

    private var ringCenter: CGPoint {
        guard let subject else { return CGPoint(x: size.width / 2, y: size.height * 0.5) }
        return CGPoint(x: subject.midX * size.width, y: subject.midY * size.height)
    }

    // MARK: Rotate

    private var rotate: some View {
        let ccw = direction == .rotateLeft
        let wobble = 8 * sin(2 * .pi * time / 1.2)
        let r: CGFloat = 62
        let stroke: CGFloat = compact ? 11 : 14
        return Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            // Arc of 250°, opening at the top-right (cw) or top-left (ccw); arrowhead at the end.
            let startDeg = ccw ? -35.0 : 215.0
            let endDeg = ccw ? -285.0 : 465.0
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .degrees(startDeg), endAngle: .degrees(endDeg), clockwise: ccw)
            ctx.stroke(arc, with: .linearGradient(
                Gradient(colors: [CoachColor.safelight.opacity(0.25), CoachColor.safelight]),
                startPoint: CGPoint(x: ccw ? c.x + r : c.x - r, y: c.y), endPoint: CGPoint(x: ccw ? c.x - r : c.x + r, y: c.y)),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            let end = endDeg * .pi / 180
            let tip = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
            // Tangent direction of travel at the end of the arc.
            let tan = ccw ? CGPoint(x: sin(end), y: -cos(end)) : CGPoint(x: -sin(end), y: cos(end))
            let nrm = CGPoint(x: -tan.y, y: tan.x)
            let L: CGFloat = 22
            var head = Path()
            head.move(to: CGPoint(x: tip.x - tan.x * L + nrm.x * L * 0.9, y: tip.y - tan.y * L + nrm.y * L * 0.9))
            head.addLine(to: CGPoint(x: tip.x + tan.x * 4, y: tip.y + tan.y * 4))
            head.addLine(to: CGPoint(x: tip.x - tan.x * L - nrm.x * L * 0.9, y: tip.y - tan.y * L - nrm.y * L * 0.9))
            ctx.stroke(head, with: .color(CoachColor.safelight),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 220, height: 220)
        .rotationEffect(.degrees(ccw ? -abs(wobble) : abs(wobble)))
        .scaleEffect(scale)
        .shadow(color: .black.opacity(0.5), radius: 7, y: 2)
        .position(x: size.width / 2, y: size.height * 0.45)
    }

    // MARK: Hold

    private var hold: some View {
        let breath = 0.5 - 0.5 * cos(2 * .pi * time / 1.6)
        let sonar = (time / 1.6).truncatingRemainder(dividingBy: 1)
        return ZStack {
            Circle()
                .stroke(CoachColor.safelight.opacity(0.5 * (1 - sonar)), lineWidth: 2)
                .frame(width: 84, height: 84)
                .scaleEffect(1 + 0.6 * sonar)
            Circle()
                .stroke(CoachColor.safelight, lineWidth: compact ? 5 : 6)
                .frame(width: 84, height: 84)
            Circle()
                .fill(CoachColor.safelight)
                .frame(width: 14, height: 14)
                .shadow(color: CoachColor.safelight.opacity(0.9), radius: 6)
        }
        .scaleEffect(scale * (1 + 0.04 * breath))
        .shadow(color: .black.opacity(0.5), radius: 7, y: 2)
        .position(ringCenter)
    }
}
