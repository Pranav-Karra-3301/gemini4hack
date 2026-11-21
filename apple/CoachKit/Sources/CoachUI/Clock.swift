import SwiftUI

// CoachUI animations that matter (coach-driven dial and slider moves, arrow loops, the ready glow)
// are pure functions of time. Views sample them from a TimelineView that only runs while something
// moves, and tests can pin "now" to render any frame of an animation deterministically.

private struct CoachClockKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

public extension EnvironmentValues {
    /// A fixed "now" for CoachUI's time-driven animations; `nil` (default) means the real clock.
    var coachClock: Date? {
        get { self[CoachClockKey.self] }
        set { self[CoachClockKey.self] = newValue }
    }
}

public extension View {
    /// Renders CoachUI components at a fixed instant (previews, ImageRenderer snapshots).
    /// Also swaps blurred materials for their opaque fallback, which ImageRenderer can draw.
    func coachClock(_ date: Date?) -> some View {
        environment(\.coachClock, date)
    }
}

/// Calls `content` with the current time: every display frame while `animating`, otherwise only
/// when the view re-renders. With a fixed `coachClock`, renders exactly that instant.
struct CoachTimeline<Content: View>: View {
    var animating: Bool
    @ViewBuilder var content: (Date) -> Content
    @Environment(\.coachClock) private var fixedClock

    var body: some View {
        if let fixedClock {
            content(fixedClock)
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: !animating)) { context in
                content(context.date)
            }
        }
    }
}
