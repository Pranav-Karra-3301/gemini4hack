import SwiftUI

/// A row of parameter chips (ISO · SHUTTER · EV · FOCUS · WB · ZOOM); tapping one expands its dial.
///
/// When the coach changes settings, the strip takes over: it expands each changed dial in turn,
/// glides it to the new value in amber under the coach's caption, then settles back to whatever
/// the user had open. Touching a chip or a dial hands control back immediately.
public struct CameraDialStrip: View {
    private let model: CameraControlsModel

    /// - Parameter model: shared camera controls state.
    public init(model: CameraControlsModel) {
        self.model = model
    }

    public var body: some View {
        CoachTimeline(animating: model.isAnimating(at: Date())) { now in
            StripFace(model: model, now: now)
        }
    }
}

struct StripFace: View {
    let model: CameraControlsModel
    let now: Date

    var body: some View {
        let shown = model.presentedSelection(at: now)
        let caption = model.caption(at: now)
        VStack(spacing: 8) {
            if let caption {
                CoachWhy(text: caption.text)
                    .opacity(caption.opacity)
                    .offset(y: (1 - caption.opacity) * 8)
                    .transition(.opacity)
            }
            ZStack {
                if let shown {
                    let coach = model.coachAmount(shown, at: now)
                    DialFace(model: model, parameter: shown, now: now, showsCaption: false)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .coachGlass(cornerRadius: CoachRadius.md, coach: coach > 0.5)
                        .shadow(color: CoachColor.safelight.opacity(0.22 * coach), radius: 14)
                        .id(shown)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity))
                }
            }
            chips(shown: shown)
        }
        .animation(CoachEase.out(CoachDuration.base), value: shown)
        .animation(CoachEase.out(CoachDuration.base), value: caption == nil)
        .sensoryFeedback(.impact(weight: .light), trigger: model.coachStepIndex(at: now)) { old, new in
            new != nil && old != new
        }
    }

    private func chips(shown: CameraParameter?) -> some View {
        HStack(spacing: 2) {
            ForEach(model.parameters) { p in
                let coach = model.coachAmount(p, at: now)
                DialChip(parameter: p,
                         text: chipText(p),
                         selected: shown == p,
                         coach: coach) {
                    model.select(model.selection == p ? nil : p)
                }
            }
        }
        .padding(4)
        .coachGlass(cornerRadius: CoachRadius.md)
    }

    private func chipText(_ p: CameraParameter) -> String {
        if case .auto = model.setting(p) { return "AUTO" }
        return p.shortFormat(model.displayedValue(p, at: now))
    }
}

/// One chip: caps title over a mono value. Selected chips sit on a lighter plate; chips the coach
/// is changing turn amber.
struct DialChip: View {
    let parameter: CameraParameter
    let text: String
    let selected: Bool
    let coach: Double
    let action: () -> Void

    var body: some View {
        let ink = CoachColor.userToCoach(coach)
        Button(action: action) {
            VStack(spacing: 5) {
                Text(parameter.title)
                    .font(CoachFont.mono(9))
                    .tracking(CoachFont.labelTracking(9))
                    .foregroundStyle(coach > 0.01 ? ink.opacity(0.85) : CoachColor.paper55)
                Text(text)
                    .font(CoachFont.mono(text.count > 5 ? 12 : 13, weight: .semibold))
                    .foregroundStyle(text == "AUTO" && coach < 0.01 ? CoachColor.paper62 : ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(selected ? CoachColor.paper.mix(with: CoachColor.safelight, by: coach).opacity(0.10 + 0.04 * coach)
                                   : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(CoachColor.safelight.opacity(selected ? 0.45 * coach : 0), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(parameter.spokenName)
        .accessibilityValue(text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
