import CoachLive
import CoachModels
import CoachUI
import SwiftUI

/// The camera (DESIGN.md §4.1): full-bleed viewfinder, status + readout on top, the coach's intent,
/// arrows and caption over the frame, then the dial strip, modes and the shutter row.
struct CameraScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusMark: CGPoint?
    @State private var focusMarkID = 0
    @State private var pinchStart: Double?

    var body: some View {
        @Bindable var app = app
        ZStack {
            // Full-bleed layers (under the Dynamic Island and home indicator).
            GeometryReader { geo in
                ZStack {
                    viewfinder(size: geo.size)
                    Scrims().allowsHitTesting(false)
                    ReactionWash(reaction: app.coach.reaction, id: app.coach.reactionID)
                    ShutterBlink(count: app.shutterCount)
                    if let p = focusMark {
                        FocusMark().position(p).id(focusMarkID).allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea()
            // Guidance zone (DESIGN.md: y 120–600 on a 852 pt phone), inside the safe area.
            Group {
                if app.coach.ready {
                    ReadyBrackets()
                        .padding(.horizontal, 20)
                        .transition(.opacity.animation(CoachEase.out(CoachDuration.base)))
                }
                GuideArrow(app.coach.guide, strength: app.coach.guideStrength)
            }
            .padding(.top, 124)       // below the top bar and the intent chip
            .padding(.bottom, 300)
            overlay
        }
        .background(CoachColor.ink)
        .onAppear { app.controls.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, v in app.controls.reduceMotion = v }
        .sheet(isPresented: $app.showPairing) { PairingSheet() }
        .sheet(isPresented: $app.showSettings) { SettingsSheet() }
    }

    // MARK: Viewfinder

    @ViewBuilder
    private func viewfinder(size: CGSize) -> some View {
        Group {
            if app.camera.isMock {
                if let img = app.camera.mockFrame {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .animation(CoachEase.out(CoachDuration.slow), value: app.camera.snapshot)
                } else {
                    CoachColor.graphite
                }
            } else if let session = app.camera.avSession {
                CameraPreview(session: session, device: app.camera.avDevice) { angle in
                    app.camera.setCaptureRotation(angle)
                }
            } else {
                CoachColor.ink
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            if app.camera.denied { CameraDeniedNote() }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { loc in tapFocus(loc, size: size) }
        .gesture(
            MagnifyGesture()
                .onChanged { v in
                    let start = pinchStart ?? app.camera.snapshot.zoom
                    pinchStart = start
                    app.userZoom(start * v.magnification)
                }
                .onEnded { _ in pinchStart = nil }
        )
    }

    /// Tap → focus/expose there. The preview is a 3:4 frame filling the screen (aspect fill).
    private func tapFocus(_ loc: CGPoint, size: CGSize) {
        let frameAspect: CGFloat = 3.0 / 4.0
        let fillW = max(size.width, size.height * frameAspect)
        let fillH = max(size.height, size.width / frameAspect)
        let x = (loc.x + (fillW - size.width) / 2) / fillW
        let y = (loc.y + (fillH - size.height) / 2) / fillH
        app.userFocus(atUpright: CGPoint(x: x, y: y))
        focusMark = loc
        focusMarkID += 1
    }

    // MARK: Overlay

    private var overlay: some View {
        VStack(spacing: 0) {
            TopBar()
                .padding(.horizontal, 16)
            if let intent = app.coach.intent {
                IntentChip(intent: intent, subject: app.coach.subject, modeByCoach: app.coach.coachMode)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            Spacer(minLength: 0)
            CoachLine()
                .padding(.horizontal, 28)
                .padding(.bottom, 10)
            CameraDialStrip(model: app.controls)
                .padding(.horizontal, 12)
            ModeSelector()
                .padding(.top, 14)
            ControlRow()
                .padding(.horizontal, 36)
                .padding(.top, 14)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
        .animation(CoachEase.out(CoachDuration.base), value: app.coach.intent)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            StatusPill()
            Spacer(minLength: 0)
            ReadoutPill()
            Spacer(minLength: 0)
            Button { app.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CoachColor.paper)
                    .frame(width: 44, height: 44)
                    .coachGlass(cornerRadius: 22)
            }
            .accessibilityLabel("Settings")
        }
        .frame(height: 44)
    }
}

private struct StatusPill: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let (label, color, glow) = state
        Button { app.statusTapped() } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: glow ? color.opacity(0.9) : .clear, radius: 5)
                    .overlay(Circle().stroke(color.opacity(glow ? 0.22 : 0), lineWidth: 3).scaleEffect(1.6))
                Text(label)
                    .font(CoachFont.label)
                    .tracking(CoachFont.labelTracking(11))
                    .foregroundStyle(CoachColor.paper)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 32)
            .coachGlass(cornerRadius: 16)
        }
        .accessibilityLabel("Coach status: \(label)")
    }

    private var state: (String, Color, Bool) {
        switch app.link {
        case .unpaired: return ("PAIR MAC", CoachColor.signal, false)
        case .unauthorized: return ("PAIR AGAIN", CoachColor.signal, false)
        case .checking: return ("CORE…", CoachColor.paper55, false)
        case .offline: return ("OFFLINE", CoachColor.signal, false)
        case .online: break
        }
        switch app.coach.phase {
        case .off: return (app.coachEnabled ? "COACH" : "COACH OFF", CoachColor.paper, false)
        case .connecting: return ("CONNECTING", CoachColor.safelight, false)
        case .reconnecting: return ("RECONNECT", CoachColor.safelight, false)
        case .live: return ("LIVE", CoachColor.safelight, true)
        case .failed: return ("RETRY", CoachColor.signal, false)
        }
    }
}

/// zoom · ISO · EV, values the coach just changed in safelight.
private struct ReadoutPill: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.camera.snapshot
        HStack(spacing: 7) {
            value(String(format: s.zoom < 0.95 ? "%.1f×" : (s.zoom.truncatingRemainder(dividingBy: 1) < 0.05 ? "%.0f×" : "%.1f×"), s.zoom), .zoom)
            dot
            value("ISO \(Int(s.iso.rounded()))", .iso)
            dot
            value(String(format: "%@%.1f", s.ev >= 0 ? "+" : "−", abs(s.ev)), .ev)
        }
        .font(CoachFont.readout)
        .monospacedDigit()
        .padding(.horizontal, 14)
        .frame(height: 32)
        .coachGlass(cornerRadius: 16)
        .animation(CoachEase.out(CoachDuration.fast), value: app.coachTouched)
    }

    private var dot: some View { Text("·").foregroundStyle(CoachColor.paper.opacity(0.4)) }

    private func value(_ text: String, _ p: CameraParameter) -> some View {
        Text(text).foregroundStyle(app.coachTouched.contains(p) ? CoachColor.safelight : CoachColor.paper)
    }
}

// MARK: - Coach line / what the user said

private struct CoachLine: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            if let heard = app.coach.heard, app.coach.caption == nil {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .semibold))
                    Text("“\(heard)”")
                        .font(CoachFont.sans(16, weight: .medium).italic())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(CoachColor.paper)
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
                .coachGlass(cornerRadius: 22)
                .transition(.opacity)
            } else if let caption = app.coach.caption {
                HStack(spacing: 10) {
                    Circle().fill(CoachColor.safelight).frame(width: 8, height: 8)
                    Text(caption)
                        .font(CoachFont.sans(17, weight: .medium))
                        .foregroundStyle(CoachColor.paper)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.leading, 14)
                .padding(.trailing, 18)
                .padding(.vertical, 11)
                .coachGlass(cornerRadius: CoachRadius.md, strong: true)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(minHeight: 44)
        .animation(CoachEase.out(CoachDuration.base), value: app.coach.caption == nil)
        .animation(CoachEase.out(CoachDuration.base), value: app.coach.heard == nil)
    }
}

// MARK: - Modes

private struct ModeSelector: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let active = app.camera.snapshot.mode
        HStack(spacing: 22) {
            ForEach(CaptureMode.allCases, id: \.self) { m in
                let on = m == active
                let coach = on && app.coach.coachMode == m
                Button { app.userMode(m) } label: {
                    VStack(spacing: 6) {
                        Text(m.rawValue.uppercased())
                            .font(CoachFont.mono(12, weight: .semibold))
                            .tracking(CoachFont.labelTracking(12))
                            .foregroundStyle(on ? (coach ? CoachColor.safelight : CoachColor.paper) : CoachColor.paper62)
                        Circle()
                            .fill(coach ? CoachColor.safelight : CoachColor.paper)
                            .frame(width: 4, height: 4)
                            .shadow(color: coach ? CoachColor.safelight : .clear, radius: 4)
                            .opacity(on ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.rawValue) mode")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(CoachEase.out(CoachDuration.base), value: active)
    }
}

// MARK: - Shutter row

private struct ControlRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack {
            LastShotThumb()
            Spacer()
            ShutterButton(state: shutterState) {
                Task { await app.capture() }
            }
            Spacer()
            VoiceToggle()
        }
        .frame(height: 84)
    }

    private var shutterState: ShutterState {
        if !app.camera.isRunning { return .disabled }
        if app.capturing { return .busy }
        return app.coach.ready ? .ready : .idle
    }
}

private struct LastShotThumb: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { app.showSettings = true } label: {
            ZStack {
                if let img = app.sync.lastThumb {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                } else {
                    CoachColor.graphite.overlay(
                        Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(CoachColor.paper45))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: CoachRadius.thumb, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CoachRadius.thumb, style: .continuous)
                .stroke(CoachColor.paper.opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
            .overlay(alignment: .topTrailing) { SyncBadge().offset(x: 6, y: -6) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Last shot, \(syncLabel)")
    }

    private var syncLabel: String {
        switch app.sync.status {
        case .uploading: return "syncing to the Mac"
        case .synced: return "synced"
        case .queued: return "\(app.sync.pending) waiting to sync"
        case .failed(let m): return "sync failed: \(m)"
        case .idle: return "no shots yet"
        }
    }
}

/// The small dot on the last-shot thumb: spinning while uploading, a count while queued,
/// a check once Core has it.
private struct SyncBadge: View {
    @Environment(AppModel.self) private var app
    @State private var spin = false

    var body: some View {
        Group {
            switch app.sync.status {
            case .uploading:
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(CoachColor.safelight, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
                    .padding(3)
                    .background(Circle().fill(CoachColor.ink.opacity(0.8)))
            case .synced:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CoachColor.ink)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(CoachColor.safelight))
            case .queued:
                Text("\(app.sync.pending)")
                    .font(CoachFont.mono(11, weight: .bold))
                    .foregroundStyle(CoachColor.ink)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(CoachColor.paper))
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CoachColor.paper)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(CoachColor.signal))
            case .idle:
                EmptyView()
            }
        }
        .transition(.scale.combined(with: .opacity))
        .animation(CoachEase.pop(), value: app.sync.status)
    }
}

/// Coach voice on/off (mutes playback; the mic stays live). Bars follow the coach's voice.
private struct VoiceToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button { app.voiceOn.toggle() } label: {
            ZStack {
                if app.voiceOn {
                    Circle().fill(CoachColor.safelight.opacity(0.16))
                    Circle().stroke(CoachColor.safelight, lineWidth: 1.5)
                    VoiceBars(audio: app.coach.audio)
                } else {
                    Circle().fill(.clear).coachGlass(cornerRadius: 28)
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(CoachColor.paper)
                }
            }
            .frame(width: 56, height: 56)
            .shadow(color: app.voiceOn ? CoachColor.safelight.opacity(0.35) : .clear, radius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.voiceOn ? "Coach voice on" : "Coach voice off")
        .animation(CoachEase.out(CoachDuration.base), value: app.voiceOn)
    }
}

private struct VoiceBars: View {
    let audio: LiveAudio?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let level = CGFloat(audio?.currentOutputLevel ?? 0)
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<6, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * (7 + Double(i) * 1.7) + Double(i))
                    let h = 4 + (level > 0.02 ? 22 * level * CGFloat(wobble) : 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == 3 ? CoachColor.safelightHot : CoachColor.safelight)
                        .frame(width: 3, height: min(26, max(4, h)))
                }
            }
        }
    }
}

// MARK: - Intent chip

private struct IntentChip: View {
    let intent: ShotIntent
    let subject: String?
    let modeByCoach: CaptureMode?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CoachColor.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(CoachColor.safelightGradient))
            Text(text)
                .font(CoachFont.sans(16, weight: .semibold))
                .foregroundStyle(CoachColor.paper)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 18)
        .frame(height: 44)
        .coachGlass(cornerRadius: 22, coach: true)
        .shadow(color: CoachColor.safelight.opacity(0.18), radius: 14)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        if modeByCoach == .portrait, intent == .portrait { return "Portrait on" + (subject.map { " · \($0)" } ?? "") }
        let name = intent.rawValue.capitalized
        return subject.map { "\(name) · \($0)" } ?? name
    }

    private var glyph: String {
        switch intent {
        case .portrait: return "person.fill"
        case .group: return "person.3.fill"
        case .landscape: return "mountain.2.fill"
        case .object: return "cube.fill"
        case .food: return "fork.knife"
        case .street: return "building.2.fill"
        case .document: return "doc.text.fill"
        case .other: return "sparkles"
        }
    }
}
