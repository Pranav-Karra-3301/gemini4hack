import SwiftUI
import CoachModels

/// The editor's slider column: groups (Light, Color, Detail, Subject, Lens) of ``EditSliderRow``s.
/// During a guided edit it shows the summary and step count, scrolls to the coach's slider and
/// spotlights it while the other rows step back.
public struct EditSliderPanel: View {
    private let model: EditSlidersModel
    private let groups: [SliderGroup]

    /// - Parameters:
    ///   - model: shared editor state.
    ///   - groups: groups to show, in order (default: all).
    public init(model: EditSlidersModel, groups: [SliderGroup] = SliderGroup.allCases) {
        self.model = model
        self.groups = groups
    }

    @Environment(\.coachClock) private var fixedClock

    public var body: some View {
        let spot = model.spotlight?.slider
        Group {
            if fixedClock != nil {
                // ImageRenderer can't draw scroll views: snapshots render the column directly.
                column(spot: spot).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { column(spot: spot) }
                        .scrollIndicators(.never)
                        .onChange(of: spot) { _, new in
                            guard let new else { return }
                            withAnimation(CoachEase.inOut(CoachDuration.slow)) { proxy.scrollTo(new, anchor: .center) }
                        }
                }
            }
        }
        .animation(CoachEase.out(CoachDuration.base), value: spot)
        .animation(CoachEase.out(CoachDuration.base), value: model.banner)
    }

    private func column(spot: CoachModels.Slider?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ForEach(groups, id: \.self) { group in
                GroupSection(model: model, group: group, spotlight: spot)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
    }

    private struct GroupSection: View {
        let model: EditSlidersModel
        let group: SliderGroup
        let spotlight: CoachModels.Slider?

        var body: some View {
            let rows = group.sliders.filter { model.sliders.contains($0) }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.displayName.uppercased())
                        .font(CoachFont.mono(10.5))
                        .tracking(CoachFont.labelTracking(10.5))
                        .foregroundStyle(CoachColor.paper55)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)
                    ForEach(rows, id: \.self) { s in
                        EditSliderRow(model: model, slider: s)
                            .id(s)
                            .opacity(spotlight == nil || spotlight == s ? 1 : 0.42)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("ADJUST")
                    .font(CoachFont.mono(11))
                    .tracking(CoachFont.labelTracking(11))
                    .foregroundStyle(CoachColor.paper62)
                Spacer()
                if let s = model.spotlight, let i = s.index, let n = s.count {
                    HStack(spacing: 6) {
                        Circle().fill(CoachColor.safelight).frame(width: 6, height: 6)
                            .shadow(color: CoachColor.safelight.opacity(0.9), radius: 4)
                        Text("COACH \(i)/\(n)")
                            .font(CoachFont.mono(10.5, weight: .semibold))
                            .tracking(CoachFont.labelTracking(10.5))
                            .foregroundStyle(CoachColor.safelight)
                            .contentTransition(.numericText())
                    }
                    .transition(.opacity)
                } else if !model.values.isEmpty {
                    Button("RESET") { model.reset() }
                        .buttonStyle(.plain)
                        .font(CoachFont.mono(10.5))
                        .tracking(CoachFont.labelTracking(10.5))
                        .foregroundStyle(CoachColor.paper55)
                        .accessibilityLabel("Reset all sliders")
                }
            }
            if let banner = model.banner {
                Text(banner)
                    .font(CoachFont.sans(14, weight: .medium))
                    .foregroundStyle(CoachColor.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .padding(.horizontal, 12)
    }
}
