import SwiftUI
import CoachModels
#if canImport(AppKit)
import AppKit
#endif

/// One editor slider, Paper-style: label and mono value above a slim track with a centred zero for
/// bipolar sliders. Drag anywhere on the row to scrub (relative, so the knob never jumps); hold
/// Option on the Mac, or slide your finger away from the track on iPhone, for fine control.
/// Double-click (double-tap) resets. When the coach drives it, the knob glides in amber with a
/// trail from the old value, and the step's "why" appears under the track.
public struct EditSliderRow: View {
    private let model: EditSlidersModel
    private let slider: CoachModels.Slider

    /// - Parameters:
    ///   - model: shared editor state.
    ///   - slider: which slider (CORE_API.md §4).
    public init(model: EditSlidersModel, slider: CoachModels.Slider) {
        self.model = model
        self.slider = slider
    }

    public var body: some View {
        CoachTimeline(animating: model.isAnimating(slider, at: Date())) { now in
            SliderRowFace(model: model, slider: slider, now: now)
        }
    }
}

struct SliderRowFace: View {
    let model: EditSlidersModel
    let slider: CoachModels.Slider
    let now: Date

    @State private var trackWidth: CGFloat = 240
    @State private var scrubOrigin: Double?
    @State private var hovering = false

    var body: some View {
        let spec = slider.spec
        let position = model.displayedPosition(slider, at: now)
        let glide = model.coachMotion(slider, at: now)
        let coach = coachAmount(glide)
        let spot = model.spotlight?.slider == slider ? model.spotlight : nil
        let shown = model.displayedValue(slider, at: now)
        let isDefault = shown == spec.defaultValue || (spec.defaultValue == nil && shown == nil)
        let scrubbing = model.isScrubbing(slider)

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.displayName)
                    .font(CoachFont.sans(13, weight: .medium))
                    .foregroundStyle(spot != nil ? CoachColor.paper : (isDefault ? CoachColor.paper62 : CoachColor.paper))
                Spacer(minLength: 8)
                valueText(spec: spec, value: shown, coach: coach, isDefault: isDefault)
            }
            SliderTrack(spec: spec, position: position, isAuto: shown == nil, isDefault: isDefault, coach: coach,
                        trailFrom: glide?.from, trailOpacity: trailOpacity(glide), active: scrubbing || hovering)
                .frame(height: 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = max(1, $0) }
            if let spot, !spot.why.isEmpty {
                let t = min(1, max(0, now.timeIntervalSince(spot.start) / CoachDuration.base))
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(CoachColor.safelight).frame(width: 5, height: 5)
                        .shadow(color: CoachColor.safelight.opacity(0.9), radius: 3)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                    Text(spot.why)
                        .font(CoachFont.sans(12.5, weight: .medium))
                        .foregroundStyle(CoachColor.paper.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(CoachEase.outCurve(t))
                .offset(y: (1 - CoachEase.outCurve(t)) * 4)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, spot != nil ? 10 : 6)
        .background {
            RoundedRectangle(cornerRadius: CoachRadius.sm, style: .continuous)
                .fill(spot != nil ? CoachColor.safelight.opacity(0.07) : Color.white.opacity(hovering ? 0.03 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: CoachRadius.sm, style: .continuous)
                .strokeBorder(CoachColor.safelight.opacity(spot != nil ? 0.38 : 0), lineWidth: 1)
        }
        .shadow(color: CoachColor.safelight.opacity(spot != nil ? 0.16 : 0), radius: 14)
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .onTapGesture(count: 2) { model.userReset(slider) }
        .onHover { hovering = $0 }
        #if os(macOS)
        .pointerStyle(.columnResize)
        #endif
        .sensoryFeedback(.selection, trigger: scrubbing && isDefault) { old, new in new && !old }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.displayName)
        .accessibilityValue(spec.format(shown))
        .accessibilityHint(spec.meaning)
        .accessibilityAdjustableAction { direction in
            let step = slider == .exposure ? 0.1 : (slider == .focusDepth ? 0.5 : 5)
            let current = model.value(slider) ?? spec.neutralValue
            let p = model.beginScrub(slider, at: Date())
            _ = p
            model.scrub(slider, to: spec.normalized(current + (direction == .increment ? step : -step)))
            model.endScrub(slider)
        }
    }

    @ViewBuilder
    private func valueText(spec: SliderSpec, value: Double?, coach: Double, isDefault: Bool) -> some View {
        let ink = coach > 0.01 ? CoachColor.userToCoach(coach) : (isDefault ? CoachColor.paper45 : CoachColor.paper)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let value {
                Text(Self.number(spec, value))
                    .font(CoachFont.mono(12, weight: .medium))
                    .foregroundStyle(ink)
                if !spec.unit.isEmpty {
                    Text(spec.unit)
                        .font(CoachFont.mono(10))
                        .foregroundStyle(ink.opacity(0.6))
                }
            } else {
                Text("AUTO")
                    .font(CoachFont.mono(10.5, weight: .medium))
                    .tracking(CoachFont.labelTracking(10.5))
                    .foregroundStyle(coach > 0.01 ? ink : CoachColor.paper55)
            }
        }
    }

    /// "+0.30", "−12", "0", "2.4".
    static func number(_ spec: SliderSpec, _ v: Double) -> String {
        switch spec.slider {
        case .exposure:
            let r = (v * 100).rounded() / 100
            return r == 0 ? "0.00" : (r > 0 ? "+" : "\u{2212}") + String(format: "%.2f", abs(r))
        case .focusDepth:
            return String(format: v < 10 ? "%.1f" : "%.0f", v)
        default:
            let n = Int(v.rounded())
            if !spec.isBipolar || n == 0 { return "\(n)" }
            return (n > 0 ? "+" : "\u{2212}") + "\(abs(n))"
        }
    }

    private func coachAmount(_ glide: Glide?) -> Double {
        guard let glide else { return 0 }
        let after = now.timeIntervalSince(glide.end)
        let fadeOut = 1 - min(1, max(0, (after - (SliderMotion.afterglow - 0.5)) / 0.5))
        return min(1, max(0, now.timeIntervalSince(glide.start) / 0.12)) * fadeOut
    }

    private func trailOpacity(_ glide: Glide?) -> Double {
        guard let glide else { return 0 }
        let after = now.timeIntervalSince(glide.end)
        return 1 - min(1, max(0, after / (SliderMotion.afterglow - 0.3)))
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let origin = scrubOrigin ?? model.beginScrub(slider, at: Date())
                if scrubOrigin == nil { scrubOrigin = origin }
                model.scrub(slider, to: origin + g.translation.width / trackWidth * fineFactor(g))
            }
            .onEnded { _ in
                scrubOrigin = nil
                model.endScrub(slider)
            }
    }

    private func fineFactor(_ g: DragGesture.Value) -> Double {
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
        #else
        // iOS scrubbing: the farther the finger drifts from the track, the finer the control.
        return max(0.1, 1 / (1 + abs(g.translation.height) / 60))
        #endif
    }
}

/// The track: rail, zero tick, fill from zero, coach trail, knob.
struct SliderTrack: View {
    let spec: SliderSpec
    let position: Double
    let isAuto: Bool
    let isDefault: Bool
    let coach: Double
    let trailFrom: Double?
    let trailOpacity: Double
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let inset: CGFloat = 7
            let w = size.width - inset * 2
            let y = size.height / 2
            func x(_ p: Double) -> CGFloat { inset + CGFloat(min(1, max(0, p))) * w }
            let rail = CGRect(x: inset, y: y - 1.5, width: w, height: 3)
            ctx.fill(Path(roundedRect: rail, cornerRadius: 1.5), with: .color(Color.white.opacity(active ? 0.16 : 0.11)))

            let zero = spec.isBipolar ? spec.normalized(0) : 0
            if spec.isBipolar {
                let zx = x(zero)
                ctx.fill(Path(roundedRect: CGRect(x: zx - 0.75, y: y - 5, width: 1.5, height: 10), cornerRadius: 0.75),
                         with: .color(CoachColor.paper.opacity(0.32)))
            }

            let knobX = x(position)
            let ink = CoachColor.userToCoach(coach)
            if !isAuto {
                let a = min(x(zero), knobX), b = max(x(zero), knobX)
                if b - a > 0.5 {
                    ctx.fill(Path(roundedRect: CGRect(x: a, y: y - 1.5, width: b - a, height: 3), cornerRadius: 1.5),
                             with: .color(ink.opacity(coach > 0.01 ? 0.75 : 0.62)))
                }
            }

            // Coach trail: amber from the old value to the knob, glowing, with a ghost mark.
            if let trailFrom, trailOpacity > 0 {
                let fx = x(trailFrom)
                let a = min(fx, knobX), b = max(fx, knobX)
                if b - a > 1 {
                    let toRight = fx < knobX
                    let grad = Gradient(colors: [CoachColor.safelight.opacity(toRight ? 0 : trailOpacity),
                                                 CoachColor.safelight.opacity(toRight ? trailOpacity : 0)])
                    let band = Path(roundedRect: CGRect(x: a, y: y - 2, width: b - a, height: 4), cornerRadius: 2)
                    var glow = ctx
                    glow.addFilter(.blur(radius: 4))
                    glow.fill(band, with: .linearGradient(grad, startPoint: CGPoint(x: a, y: y), endPoint: CGPoint(x: b, y: y)))
                    ctx.fill(band, with: .linearGradient(grad, startPoint: CGPoint(x: a, y: y), endPoint: CGPoint(x: b, y: y)))
                }
                ctx.fill(Path(roundedRect: CGRect(x: fx - 1, y: y - 6, width: 2, height: 12), cornerRadius: 1),
                         with: .color(CoachColor.paper.opacity(0.45 * trailOpacity)))
            }

            if isAuto {
                // Auto focus depth: a hollow knob at the near end.
                let r: CGFloat = 5.5
                ctx.stroke(Path(ellipseIn: CGRect(x: knobX - r, y: y - r, width: r * 2, height: r * 2)),
                           with: .color(CoachColor.paper.opacity(0.5)), lineWidth: 1.5)
                return
            }
            let r: CGFloat = active ? 7.5 : (isDefault && coach < 0.01 ? 5.5 : 6.5)
            let knob = Path(ellipseIn: CGRect(x: knobX - r, y: y - r, width: r * 2, height: r * 2))
            if coach > 0.01 {
                var glow = ctx
                glow.addFilter(.blur(radius: 6))
                glow.fill(Path(ellipseIn: CGRect(x: knobX - r - 3, y: y - r - 3, width: r * 2 + 6, height: r * 2 + 6)),
                          with: .color(CoachColor.safelight.opacity(0.7 * coach)))
            }
            var shadow = ctx
            shadow.addFilter(.shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1))
            shadow.fill(knob, with: .color(isDefault && coach < 0.01 && !active ? CoachColor.paper.opacity(0.7) : ink))
        }
    }
}
