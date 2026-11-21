import SwiftUI

/// The hero control of the camera: a horizontal ruler dial for one parameter, VWFNDR/Moment style.
///
/// Drag it (with momentum, detents and selection haptics on iOS), or tap AUTO. When the coach
/// changes the value through ``CameraControlsModel/coachApply(_:why:at:)`` the ruler glides there
/// on a spring, turns amber, leaves a short trail from the old value and shows the coach's "why".
public struct CameraDial: View {
    private let model: CameraControlsModel
    private let parameter: CameraParameter

    /// - Parameters:
    ///   - model: shared camera controls state.
    ///   - parameter: which setting this dial controls.
    public init(model: CameraControlsModel, parameter: CameraParameter) {
        self.model = model
        self.parameter = parameter
    }

    public var body: some View {
        CoachTimeline(animating: model.isAnimating(at: Date())) { now in
            DialFace(model: model, parameter: parameter, now: now, showsCaption: true)
        }
    }
}

/// One dial rendered at a given instant (the strip embeds this inside its own timeline).
struct DialFace: View {
    let model: CameraControlsModel
    let parameter: CameraParameter
    let now: Date
    var showsCaption: Bool

    @State private var dragOrigin: Double?

    var body: some View {
        let position = model.displayedPosition(parameter, at: now)
        let coach = model.coachAmount(parameter, at: now)
        let setting = model.setting(parameter)
        let userDetent: Int? = model.isUserMoving(parameter, at: now) ? Int(position.rounded()) : nil

        VStack(spacing: 8) {
            if showsCaption, let caption = model.caption(at: now), coach > 0 {
                CoachWhy(text: caption.text)
                    .opacity(caption.opacity)
                    .offset(y: (1 - caption.opacity) * 6)
            }
            header(setting: setting, coach: coach)
            DialRuler(parameter: parameter, position: position, range: model.range(parameter),
                      isAuto: setting.isAuto, coach: coach, trail: trail(position: position))
                .frame(height: 54)
                .contentShape(Rectangle())
                .gesture(dragGesture)
        }
        .sensoryFeedback(.selection, trigger: userDetent) { old, new in
            old != nil && new != nil && old != new
        }
        .sensoryFeedback(.impact(weight: .light), trigger: showsCaption && coach > 0.5) { _, new in new }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parameter.spokenName)
        .accessibilityValue(parameter.format(DialSetting.manual(model.displayedValue(parameter, at: now))))
        .accessibilityAdjustableAction { direction in
            let p = model.beginDrag(parameter, at: Date())
            model.drag(parameter, to: p.rounded() + (direction == .increment ? 1 : -1))
            model.endDrag(parameter, velocity: 0, at: Date())
        }
    }

    // MARK: Header: title · readout · AUTO

    @ViewBuilder
    private func header(setting: DialSetting, coach: Double) -> some View {
        let value = model.displayedValue(parameter, at: now)
        let ink = CoachColor.userToCoach(coach)
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if setting.isAuto {
                    Text("AUTO")
                        .font(CoachFont.mono(22, weight: .semibold))
                        .foregroundStyle(ink)
                    if setting.value != nil {
                        Text(parameter.format(value))
                            .font(CoachFont.mono(13))
                            .foregroundStyle(CoachColor.paper55)
                    }
                } else {
                    Text(parameter.format(value))
                        .font(CoachFont.mono(22, weight: .semibold))
                        .foregroundStyle(ink)
                }
            }
            .shadow(color: CoachColor.safelight.opacity(0.45 * coach), radius: 10)
            .frame(maxWidth: .infinity)

            HStack {
                Text(parameter == .iso ? "" : parameter.title)
                    .font(CoachFont.mono(10))
                    .tracking(CoachFont.labelTracking(10))
                    .foregroundStyle(CoachColor.userToCoach(coach * 0.9).opacity(0.55 + 0.45 * coach))
                Spacer()
                if parameter.supportsAuto {
                    AutoPill(isOn: setting.isAuto, coach: coach) { model.toggleAuto(parameter) }
                }
            }
        }
        .frame(height: 28)
    }

    // MARK: Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let origin = dragOrigin ?? model.beginDrag(parameter, at: Date())
                if dragOrigin == nil { dragOrigin = origin }
                model.drag(parameter, to: origin - g.translation.width / parameter.tickSpacing)
            }
            .onEnded { g in
                dragOrigin = nil
                model.endDrag(parameter, velocity: -g.velocity.width / parameter.tickSpacing, at: Date())
            }
    }

    /// Amber trail from where the coach started to the index, fading after the glide lands.
    private func trail(position: Double) -> DialRuler.Trail? {
        guard let s = model.sequence, s.steps.contains(where: { $0.parameter == parameter }),
              let m = model.motionForTrail(parameter), m.coach else { return nil }
        let since = now.timeIntervalSince(m.glide.end)
        let fade = 1 - min(1, max(0, since / 0.9))
        guard now >= m.glide.start, fade > 0 else { return nil }
        return .init(from: m.glide.from, opacity: fade)
    }
}

extension CameraControlsModel {
    func motionForTrail(_ parameter: CameraParameter) -> DialMotion? { motionsSnapshot[parameter] }
}

/// The ruler: ticks on a gently curved drum, a centre index, major labels.
struct DialRuler: View {
    struct Trail { var from: Double; var opacity: Double }

    let parameter: CameraParameter
    let position: Double
    let range: ClosedRange<Double>
    let isAuto: Bool
    let coach: Double
    let trail: Trail?

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let maxAngle = 1.2
            let radius = cx / sin(maxAngle)
            let spacing = parameter.tickSpacing
            let lo = Int(ceil(parameter.position(for: range.lowerBound) - 1e-6))
            let hi = Int(floor(parameter.position(for: range.upperBound) + 1e-6))
            let span = Int(ceil(maxAngle * radius / spacing))
            let first = max(lo, Int(floor(position)) - span)
            let last = min(hi, Int(ceil(position)) + span)
            let tickTop: CGFloat = 8
            let dim = isAuto ? 0.42 : 1.0

            func x(_ u: Double) -> CGFloat? {
                let angle = (u - position) * spacing / radius
                guard abs(angle) < maxAngle else { return nil }
                return cx + radius * sin(angle)
            }

            // Coach trail: a soft amber line from the old value to the index, with a dot where it started.
            if let trail {
                let x0 = x(trail.from) ?? (trail.from < position ? 0 : size.width)
                let a = min(x0, cx), b = max(x0, cx)
                if b - a > 2 {
                    let y = tickTop + 27
                    let toRight = x0 < cx
                    let shade = Gradient(colors: [CoachColor.safelight.opacity(toRight ? 0.05 : 0.85 * trail.opacity),
                                                  CoachColor.safelight.opacity(toRight ? 0.85 * trail.opacity : 0.05)])
                    ctx.fill(Path(roundedRect: CGRect(x: a, y: y - 1, width: b - a, height: 2), cornerRadius: 1),
                             with: .linearGradient(shade, startPoint: CGPoint(x: a, y: y), endPoint: CGPoint(x: b, y: y)))
                    if x(trail.from) != nil {
                        ctx.fill(Path(ellipseIn: CGRect(x: x0 - 2.5, y: y - 2.5, width: 5, height: 5)),
                                 with: .color(CoachColor.safelight.opacity(0.7 * trail.opacity)))
                    }
                }
            }

            guard first <= last else { return }
            for u in first...last {
                let angle = (Double(u) - position) * spacing / radius
                guard abs(angle) < maxAngle, let px = x(Double(u)) else { continue }
                let falloff = pow(max(0, cos(angle)), 1.8)
                let major = parameter.isMajor(u)
                let near = max(0, 1 - abs(Double(u) - position) / 4)
                // Ticks the coach swept over stay lit for a moment, brightest near the index.
                var lit = coach * near
                if let trail {
                    let lo = min(trail.from, position), hi = max(trail.from, position)
                    if Double(u) >= lo - 0.01, Double(u) <= hi + 0.01, hi - lo > 0.01 {
                        let along = 1 - abs(Double(u) - position) / (hi - lo)
                        lit = max(lit, trail.opacity * (0.35 + 0.65 * along))
                    }
                }
                let color = CoachColor.paper.mix(with: CoachColor.safelight, by: lit)
                let w: CGFloat = major ? 1.5 : 1
                let h: CGFloat = major ? 18 : 10
                let y = tickTop + (major ? 0 : 4)
                let alpha = (major ? 0.92 : 0.46 + 0.3 * lit) * falloff * dim
                ctx.fill(Path(roundedRect: CGRect(x: px - w / 2, y: y, width: w, height: h), cornerRadius: w / 2),
                         with: .color(color.opacity(alpha)))
                // Labels fade out early where the drum compresses them.
                let labelAlpha = smoothstep(0.4, 0.78, cos(angle))
                if major, labelAlpha > 0, let label = parameter.majorLabel(u), !label.isEmpty {
                    let text = Text(label).font(CoachFont.mono(10))
                        .foregroundColor(color.opacity((0.6 * dim + 0.25 * near) * labelAlpha))
                    ctx.draw(text, at: CGPoint(x: px, y: tickTop + 36), anchor: .center)
                }
            }

            // Focus range ends: near and far glyphs.
            if parameter == .focus {
                for (u, symbol) in [(lo, "camera.macro"), (hi, "mountain.2")] {
                    guard let px = x(Double(u)) else { continue }
                    let a = pow(max(0, cos((Double(u) - position) * spacing / radius)), 1.8)
                    let img = Text(Image(systemName: symbol)).font(.system(size: 11, weight: .medium))
                        .foregroundColor(CoachColor.paper.opacity(0.7 * a * dim))
                    ctx.draw(img, at: CGPoint(x: px, y: tickTop + 36), anchor: .center)
                }
            }

            // Centre index.
            let ink = isAuto && coach < 0.01 ? CoachColor.paper.opacity(0.6) : CoachColor.userToCoach(coach)
            let index = Path(roundedRect: CGRect(x: cx - 1.25, y: tickTop - 6, width: 2.5, height: 28), cornerRadius: 1.25)
            if coach > 0.01 {
                var glow = ctx
                glow.addFilter(.blur(radius: 5))
                glow.fill(index, with: .color(CoachColor.safelight.opacity(0.9 * coach)))
            }
            ctx.fill(index, with: .color(ink))
            var tri = Path()
            tri.move(to: CGPoint(x: cx - 4.5, y: tickTop - 9))
            tri.addLine(to: CGPoint(x: cx + 4.5, y: tickTop - 9))
            tri.addLine(to: CGPoint(x: cx, y: tickTop - 4))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(ink))
        }
    }
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

/// The AUTO toggle at the right of a dial.
struct AutoPill: View {
    let isOn: Bool
    let coach: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("AUTO")
                .font(CoachFont.mono(10, weight: isOn ? .semibold : .medium))
                .tracking(CoachFont.labelTracking(10))
                .foregroundStyle(isOn ? CoachColor.ink : CoachColor.paper62)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background {
                    Capsule().fill(isOn ? CoachColor.userToCoach(coach) : Color.white.opacity(0.06))
                }
                .overlay { Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.14), lineWidth: 1) }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The coach's short "why": an amber dot and one line of paper text on strong glass.
struct CoachWhy: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(CoachColor.safelight)
                .frame(width: 6, height: 6)
                .shadow(color: CoachColor.safelight.opacity(0.9), radius: 4)
            Text(text)
                .font(CoachFont.sans(14, weight: .medium))
                .tracking(-0.14)
                .foregroundStyle(CoachColor.paper)
                .lineLimit(1)
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .frame(height: 30)
        .coachGlass(cornerRadius: 15, coach: true, strong: true)
    }
}
