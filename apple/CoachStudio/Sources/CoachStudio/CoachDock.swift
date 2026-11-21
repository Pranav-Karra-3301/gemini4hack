import SwiftUI
import CoachLive
import CoachModels
import CoachUI

/// The coach's words over the photo: the current step's "why" (guided edit) or the live
/// conversation (Talk). Amber = coach, paper = user (DESIGN.md).
struct CoachCaption: View {
    let model: EditorModel
    let talk: TalkController

    var body: some View {
        VStack(spacing: 8) {
            if talk.isActive || talk.isFailed {
                if !talk.userLine.isEmpty {
                    Text(talk.userLine)
                        .font(CoachFont.sans(15, weight: .regular))
                        .foregroundStyle(CoachColor.paper62)
                }
                if !talk.coachLine.isEmpty {
                    Text(talk.coachLine)
                        .font(CoachFont.sans(20, weight: .medium))
                        .foregroundStyle(CoachColor.safelightHot)
                } else if let spot = model.sliders.spotlight, !spot.why.isEmpty {
                    Text(spot.why)
                        .font(CoachFont.sans(20, weight: .medium))
                        .foregroundStyle(CoachColor.safelightHot)
                }
            } else if let g = model.guide, let step = g.step {
                Text(stepLabel(step, g))
                    .font(CoachFont.mono(10.5, weight: .semibold))
                    .tracking(CoachFont.labelTracking(10.5))
                    .foregroundStyle(CoachColor.safelight)
                Text(step.why.isEmpty ? step.slider.spec.meaning : step.why)
                    .font(CoachFont.sans(21, weight: .medium))
                    .foregroundStyle(CoachColor.safelightHot)
                    .id(g.index)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else if let g = model.guide {
                Text(g.suggestion.summary)
                    .font(CoachFont.sans(21, weight: .medium))
                    .foregroundStyle(CoachColor.safelightHot)
                Text("\(g.count) STEPS · \(g.origin.uppercased())")
                    .font(CoachFont.mono(10.5)).tracking(CoachFont.labelTracking(10.5))
                    .foregroundStyle(CoachColor.paper55)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .frame(maxWidth: 620)
        .shadow(color: .black.opacity(0.85), radius: 10)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .animation(CoachEase.out(CoachDuration.slow), value: model.guide?.index)
        .animation(CoachEase.out(CoachDuration.base), value: talk.coachLine)
    }

    private func stepLabel(_ step: EditStep, _ g: EditorModel.Guide) -> String {
        let spec = step.slider.spec
        let v = spec.format(step.value)
        var s = "STEP \(g.index + 1)/\(g.count) · \(spec.displayName.uppercased()) → \(v)"
        if let r = step.region { s += " · \(r.uppercased())" }
        return s
    }
}

/// Glass dock at the bottom of the photo: Coach me (+ optional goal) and Talk; during a guide the
/// step controls; during Talk the live state and a type-to-coach field.
struct CoachDock: View {
    let model: EditorModel
    let talk: TalkController
    @Binding var goal: String
    @FocusState private var goalFocused: Bool
    @State private var typed = ""

    var body: some View {
        Group {
            if talk.isActive || talk.isFailed {
                talkBar
            } else if model.thinking {
                thinkingBar
            } else if let g = model.guide {
                guideBar(g)
            } else {
                idleBar
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .coachGlass(cornerRadius: 22, coach: model.guide != nil || talk.isActive || model.thinking, strong: true)
        .animation(CoachEase.out(CoachDuration.base), value: model.guide != nil)
        .animation(CoachEase.out(CoachDuration.base), value: talk.isActive)
        .animation(CoachEase.out(CoachDuration.base), value: model.thinking)
    }

    // Idle: Coach me · goal · Talk
    private var idleBar: some View {
        HStack(spacing: 8) {
            Button { model.coachMe(goal: goal); goal = "" } label: {
                Label("Coach me", systemImage: "sparkles")
            }
            .buttonStyle(StudioButtonStyle(kind: .coach))
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.source == nil)
            .help("Gemini edits step by step and explains each move (⌘K)")
            TextField("", text: $goal, prompt: Text("or ask for a look: “moody”, “make them pop”").foregroundStyle(CoachColor.paper45))
                .textFieldStyle(.plain)
                .font(CoachFont.sans(13.5, weight: .regular))
                .foregroundStyle(CoachColor.paper)
                .frame(width: 270)
                .focused($goalFocused)
                .onSubmit { model.coachMe(goal: goal); goal = "" }
            Divider().frame(height: 22).overlay(CoachColor.paper.opacity(0.12))
            Button { talk.start(editor: model) } label: {
                Label("Talk", systemImage: "waveform")
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model.source == nil)
            .help("Talk to the editing coach: “make it warmer”, “teach me how to make them pop” (⌘T)")
        }
    }

    private var thinkingBar: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            HStack(spacing: 10) {
                PulsingOrb(size: 14)
                Text("Gemini is reading the photo")
                    .font(CoachFont.sans(13.5)).foregroundStyle(CoachColor.paper)
                if let t0 = model.thinkingSince {
                    Text(String(format: "%.1f s", ctx.date.timeIntervalSince(t0)))
                        .font(CoachFont.mono(11)).foregroundStyle(CoachColor.paper55)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }

    private func guideBar(_ g: EditorModel.Guide) -> some View {
        HStack(spacing: 6) {
            Button { model.prev() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(StudioIconButtonStyle())
                .disabled(g.index < 0)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Previous step (⌘←)")
            Button { model.toggleAutoplay() } label: {
                Image(systemName: g.autoplay ? "pause.fill" : (g.isFinished ? "arrow.counterclockwise" : "play.fill"))
            }
            .buttonStyle(StudioIconButtonStyle(coach: true))
            .help(g.autoplay ? "Pause" : (g.isFinished ? "Replay" : "Play"))
            Button { model.next() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(StudioIconButtonStyle())
                .disabled(g.isFinished)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Next step (⌘→)")
            StepDots(count: g.count, index: g.index)
                .padding(.horizontal, 8)
            if g.isFinished && !g.autoplay {
                if model.isDirty {
                    Button { Task { await model.save() } } label: { Text("Keep · Save") }
                        .buttonStyle(StudioButtonStyle(kind: .coach))
                } else {
                    Text("SAVED").font(CoachFont.mono(10.5, weight: .semibold)).tracking(CoachFont.labelTracking(10.5))
                        .foregroundStyle(CoachColor.safelight).padding(.horizontal, 6)
                }
                Button { model.endGuide(keepValues: false) } label: { Text("Undo all") }
                    .buttonStyle(StudioButtonStyle(kind: .quiet))
            }
            Button { model.endGuide() } label: { Image(systemName: "xmark") }
                .buttonStyle(StudioIconButtonStyle())
                .help("Close the guide (keeps the edit)")
        }
    }

    private var talkBar: some View {
        HStack(spacing: 10) {
            TalkOrb(talk: talk)
            VStack(alignment: .leading, spacing: 1) {
                Text(talkStatus)
                    .font(CoachFont.mono(10.5, weight: .semibold)).tracking(CoachFont.labelTracking(10.5))
                    .foregroundStyle(talk.isFailed ? CoachColor.signal : CoachColor.safelight)
                    .lineLimit(1)
                if talk.toolCount > 0, let t = talk.lastTool {
                    Text("\(talk.toolCount) \(talk.toolCount == 1 ? "move" : "moves") · last \(t)")
                        .font(CoachFont.mono(10)).foregroundStyle(CoachColor.paper45)
                }
            }
            .frame(width: 150, alignment: .leading)
            TextField("", text: $typed, prompt: Text("say it, or type: “make it warmer”").foregroundStyle(CoachColor.paper45))
                .textFieldStyle(.plain)
                .font(CoachFont.sans(13.5, weight: .regular))
                .foregroundStyle(CoachColor.paper)
                .frame(width: 240)
                .onSubmit { talk.send(text: typed); typed = "" }
                .disabled(talk.state != .live)
            Button { talk.stop() } label: { Text(talk.isFailed ? "Close" : "End") }
                .buttonStyle(StudioButtonStyle(kind: .quiet))
                .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var talkStatus: String {
        switch talk.state {
        case .idle: return "OFF"
        case .connecting: return "CONNECTING…"
        case .live: return talk.micAllowed ? (talk.coachSpeaking ? "COACH SPEAKING" : "LISTENING") : "LIVE · MIC OFF"
        case .reconnecting: return "RECONNECTING…"
        case .failed(let m): return "FAILED · \(m)"
        }
    }
}

/// Step progress: done = amber, current = amber ring, ahead = dim.
private struct StepDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? CoachColor.safelight : CoachColor.paper.opacity(0.18))
                    .frame(width: i == index ? 16 : 6, height: 6)
            }
        }
        .animation(CoachEase.out(CoachDuration.base), value: index)
    }
}

/// The amber orb that breathes while Gemini thinks.
struct PulsingOrb: View {
    var size: CGFloat
    @State private var on = false
    var body: some View {
        Circle()
            .fill(CoachColor.safelightOrb(diameter: size))
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.15 : 0.8)
            .opacity(on ? 1 : 0.6)
            .shadow(color: CoachColor.safelight.opacity(0.6), radius: on ? 8 : 3)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

/// Talk orb: grows with the coach's voice level (amber) or the mic (paper).
private struct TalkOrb: View {
    let talk: TalkController
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !talk.isActive)) { _ in
            let out = CGFloat(talk.audio?.outputLevel ?? 0)
            let input = CGFloat(talk.audio?.inputLevel ?? 0)
            let speaking = out > 0.02
            ZStack {
                Circle().fill((speaking ? CoachColor.safelight : CoachColor.paper).opacity(0.18))
                    .frame(width: 30 + 14 * max(out, input), height: 30 + 14 * max(out, input))
                Circle().fill(speaking ? CoachColor.safelight : (talk.state == .live ? CoachColor.paper : CoachColor.paper45))
                    .frame(width: 12, height: 12)
            }
            .frame(width: 44, height: 44)
        }
    }
}

// MARK: - Buttons

struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, coach, quiet }
    var kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CoachFont.sans(13, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(CoachEase.out(CoachDuration.instant), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var fg: Color {
        switch kind {
        case .primary: return CoachColor.ink
        case .coach: return CoachColor.ink
        case .quiet: return CoachColor.paper
        }
    }
    private var bg: AnyShapeStyle {
        switch kind {
        case .primary: return AnyShapeStyle(CoachColor.paper)
        case .coach: return AnyShapeStyle(CoachColor.safelightGradient)
        case .quiet: return AnyShapeStyle(CoachColor.paper.opacity(0.08))
        }
    }
    private var edge: Color {
        kind == .quiet ? CoachColor.paper.opacity(0.12) : .clear
    }
}

struct StudioIconButtonStyle: ButtonStyle {
    var coach = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 34, height: 34)
            .foregroundStyle(coach ? CoachColor.ink : CoachColor.paper)
            .background(Circle().fill(coach ? AnyShapeStyle(CoachColor.safelightGradient) : AnyShapeStyle(CoachColor.paper.opacity(configuration.isPressed ? 0.16 : 0.08))))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Circle())
    }
}
