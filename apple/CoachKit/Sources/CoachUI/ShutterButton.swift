import SwiftUI

/// Shutter state (DESIGN.md §5 "Shutter").
public enum ShutterState: Sendable, Hashable {
    /// Paper ring, paper core.
    case idle
    /// The coach says the shot is ready: amber ring, safelight orb core, breathing glow.
    case ready
    /// Saving: a dim ring with a spinning amber arc.
    case busy
    /// No camera.
    case disabled
}

/// The 84 pt shutter: a 3 pt ring, a 5 pt gap and a 68 pt core that presses to 0.9.
/// Plays a rigid haptic on press and a medium one when it turns ready.
public struct ShutterButton: View {
    private let state: ShutterState
    private let action: () -> Void
    @State private var presses = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - state: idle, ready (glow), busy or disabled.
    ///   - action: takes the photo.
    public init(state: ShutterState, action: @escaping () -> Void) {
        self.state = state
        self.action = action
    }

    public var body: some View {
        Button {
            presses += 1
            action()
        } label: {
            CoachTimeline(animating: state == .busy || (state == .ready && !reduceMotion)) { now in
                ShutterFace(state: state, time: reduceMotion && state == .ready ? 0.8 : now.timeIntervalSinceReferenceDate)
            }
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(state == .disabled || state == .busy)
        .animation(CoachSpring.pop.animation, value: state)
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: presses)
        .sensoryFeedback(.impact(weight: .medium), trigger: state == .ready) { _, ready in ready }
        .accessibilityLabel(state == .ready ? "Take photo, ready" : "Take photo")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.shutterPressed, configuration.isPressed)
    }
}

private struct ShutterPressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    fileprivate var shutterPressed: Bool {
        get { self[ShutterPressedKey.self] }
        set { self[ShutterPressedKey.self] = newValue }
    }
}

struct ShutterFace: View {
    let state: ShutterState
    let time: TimeInterval
    @Environment(\.shutterPressed) private var pressed

    var body: some View {
        let ready = state == .ready
        let halo = 6 + 4 * (0.5 - 0.5 * cos(2 * .pi * time / 1.6))   // spread 6↔10
        ZStack {
            // --glow-ready: an 8 pt halo ring at 16% plus a wide 55% bloom.
            Circle()
                .fill(CoachColor.safelight.opacity(ready ? 0.16 : 0))
                .frame(width: 84 + halo * 2, height: 84 + halo * 2)
            Circle()
                .fill(CoachColor.safelight.opacity(ready ? 0.55 : 0))
                .frame(width: 84 + 12, height: 84 + 12)
                .blur(radius: 18)
                .scaleEffect(ready ? 1 : 0.6)

            Circle()
                .strokeBorder(ringColor, lineWidth: 3)
                .frame(width: 84, height: 84)

            if state == .busy {
                let turn = (time / 0.9).truncatingRemainder(dividingBy: 1)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(CoachColor.safelight, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 83, height: 83)
                    .rotationEffect(.degrees(turn * 360 - 90))
            }

            Group {
                if ready {
                    Circle().fill(CoachColor.safelightOrb(diameter: 68)
                        .shadow(.inner(color: Color(red: 120 / 255, green: 50 / 255, blue: 0).opacity(0.25), radius: 3, y: -2)))
                } else {
                    Circle().fill(RadialGradient(
                        stops: [.init(color: .white, location: 0),
                                .init(color: Color(hex: 0xECE9E3), location: 0.6),
                                .init(color: Color(hex: 0xD9D5CE), location: 1)],
                        center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 58)
                        .shadow(.inner(color: .black.opacity(0.12), radius: 2, y: -2)))
                }
            }
            .frame(width: 68, height: 68)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(pressed ? CoachEase.out(CoachDuration.instant) : CoachSpring.pop.animation, value: pressed)
        }
        .frame(width: 84, height: 84)
        .shadow(color: .black.opacity(ready ? 0 : 0.35), radius: 14, y: 8)
        .opacity(state == .disabled ? 0.4 : 1)
        .contentShape(Circle())
    }

    private var ringColor: Color {
        switch state {
        case .ready: return CoachColor.safelight
        case .busy: return CoachColor.paper.opacity(0.4)
        default: return CoachColor.paper.opacity(0.95)
        }
    }
}
