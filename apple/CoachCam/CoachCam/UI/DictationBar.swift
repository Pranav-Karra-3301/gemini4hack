import CoachUI
import SwiftUI

/// The listening capsule: a slim glass pill at the bottom of the photo that shows the mic is live
/// and what it has heard so far. Shared by the Looks page and the edit page.
///
/// - `isListening`: shows or hides the bar (soft fade in and out).
/// - `transcript`: the live partial transcript; only the newest ~60 characters are shown.
/// - `level`: the mic level, 0...1; drives the red dot's pulse.
struct DictationBar: View {
    let isListening: Bool
    let transcript: String
    let level: Float

    var body: some View {
        ZStack {
            if isListening {
                capsule
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28), value: isListening)
        .allowsHitTesting(false)
    }

    private var capsule: some View {
        HStack(alignment: .center, spacing: 10) {
            LiveDot(level: level)
            if tail.isEmpty {
                BreathingDots()
            } else {
                Text(tail)
                    .font(GXFont.display(13))
                    .foregroundStyle(GXColor.frost.opacity(0.88))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: tail.isEmpty ? nil : .infinity)
        .background {
            let shape = Capsule(style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(red: 10 / 255, green: 14 / 255, blue: 28 / 255).opacity(0.72))
                shape.fill(Color.red.opacity(0.08))
                shape.strokeBorder(GXColor.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        }
    }

    /// The newest ~60 characters, cut on a word boundary when one is close.
    private var tail: String {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 60 else { return t }
        let cut = String(t.suffix(60))
        if let space = cut.firstIndex(of: " "), cut.distance(from: cut.startIndex, to: space) < 14 {
            return "…" + cut[cut.index(after: space)...]
        }
        return "…" + cut
    }
}

/// The red recording dot; its halo grows with the mic level.
private struct LiveDot: View {
    let level: Float

    var body: some View {
        let l = CGFloat(min(max(level, 0), 1))
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.28))
                .frame(width: 8 + 12 * l, height: 8 + 12 * l)
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
        }
        .frame(width: 20, height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Three dots breathing in turn: it is recording, nothing heard yet.
private struct BreathingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * 2 * .pi / 1.2 - Double(i) * 0.7
                    Circle()
                        .fill(GXColor.frost)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.6 * (0.5 + 0.5 * sin(phase)))
                }
            }
            .frame(height: 18)
        }
    }
}
