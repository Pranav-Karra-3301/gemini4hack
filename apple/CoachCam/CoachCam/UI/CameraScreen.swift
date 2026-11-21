import CoachLive
import CoachModels
import CoachUI
import SwiftUI

/// The Heliocam camera (HANDOFF "iPhone camera"): a rounded viewfinder card whose own edge is
/// the guide (EdgeGlow, no arrows or captions), then the instrument panel: ISO / SS / EV drums,
/// the focus ruler, and the two keys (mic = talk to Gemini, lantern = shutter). Launch plays the
/// wake-up opening; each shot plays flash → depth scan → thumbnail + check (`StageFX`).
struct CameraScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var fx = StageFX()
    @State private var tilt = DeviceTilt()
    @State private var suggestion = SuggestionFeed()
    static let panelHeight: CGFloat = 252

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            let card = CGSize(width: geo.size.width - 16, height: max(200, geo.size.height - Self.panelHeight - 16))
            VStack(spacing: 0) {
                Viewfinder(size: card)
                    .padding(8)
                InstrumentPanel()
                    .frame(height: Self.panelHeight)
            }
        }
        .ignoresSafeArea()
        .background { ZStack { GXColor.void; GrainOverlay() }.ignoresSafeArea() }
        .overlay { if app.reveal.isShown { ShotReveal(model: app.reveal).transition(.opacity) } }
        .onChange(of: app.voice.values) { _, v in app.reveal.show(values: v, layers: app.voice.layers) }
        .onChange(of: app.reveal.isShown) { _, shown in if !shown, app.voice.isLive { app.toggleVoiceEdit() } }
        .animation(.easeOut(duration: 0.2), value: app.reveal.isShown)
        .environment(fx)
        .environment(tilt)
        .environment(suggestion)
        .onAppear {
            fx.wake(reduceMotion: reduceMotion)
            tilt.start()
        }
        .onDisappear { tilt.stop() }
        .onChange(of: scenePhase) { _, p in if p == .active { tilt.start() } else if p == .background { tilt.stop() } }
        .onChange(of: app.coach.caption) { _, c in suggestion.feed(c) }
        .onChange(of: app.shutterCount) { _, _ in
            fx.shot(lastThumb: app.sync.lastThumb, mockFrame: app.camera.isMock ? app.camera.mockFrame : nil)
        }
        .sheet(isPresented: $app.showPairing) { PairingSheet() }
        .sheet(isPresented: $app.showSettings) { SettingsSheet() }
        .sheet(isPresented: $app.showRoll) {
            if let c = app.coachClient {
                SessionRoll(client: c, since: app.launchedAt) { shot in
                    app.showRoll = false
                    Task { await app.reveal.open(shot: shot, client: c) }
                }
            }
        }
        .fullScreenCover(item: $app.explode) { item in
            DepthExplodeView(photo: item.photo, depthPNG: item.depthPNG)
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button { app.explode = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8)).padding(14)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .padding(.top, 54).padding(.trailing, 18)
                }
        }
    }
}

// MARK: - Viewfinder card

private struct Viewfinder: View {
    @Environment(AppModel.self) private var app
    @Environment(StageFX.self) private var fx
    let size: CGSize
    @State private var focusMark: CGPoint?
    @State private var focusMarkID = 0
    @State private var pinchStart: Double?
    static let radius: CGFloat = 30

    var body: some View {
        ZStack {
            GXColor.night
            // The picture and everything painted on it open behind the 6-blade iris.
            ZStack {
                preview
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { tapFocus($0) }
                    .gesture(MagnifyGesture()
                        .onChanged { v in
                            let start = pinchStart ?? app.camera.snapshot.zoom
                            pinchStart = start
                            app.userZoom(start * v.magnification)
                        }
                        .onEnded { _ in pinchStart = nil })
                FrameTargetOverlay(input: SubjectTracker.shared.input, tracked: SubjectTracker.shared.tracked)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                Vignette(radius: Self.radius).allowsHitTesting(false)
                ReactionWash(reaction: app.coach.reaction, id: app.coach.reactionID)
                DepthScanSweep(progress: fx.scanProgress)
                    .opacity(fx.scanOn ? 1 : 0)
                CaptureFlash(trigger: fx.flashSerial)
                if let p = focusMark {
                    FocusMarkFlash().position(p).id(focusMarkID)
                }
            }
            .mask(IrisShape(open: fx.iris))
            IrisBlades(open: fx.iris)
                .stroke(GXColor.geminiHot.opacity(0.22), lineWidth: 1)
                .opacity(1 - fx.iris)
                .allowsHitTesting(false)
            Text("Heliocam")
                .font(GXFont.display(24))
                .tracking(24 * 0.04)
                .foregroundStyle(GXColor.frost)
                .opacity(fx.wordmark)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if app.camera.denied { CameraDeniedNote() }
            ViewfinderHUD()
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(GuideGlow())
        .overlay(
            BorderSweep(progress: fx.sweep, cornerRadius: Self.radius)
                .stroke(GXColor.geminiHot, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: GXColor.gemini, radius: 6)
                .shadow(color: GXColor.gemini.opacity(0.8), radius: 2)
                .opacity(fx.sweepOn)
                .allowsHitTesting(false))
    }

    @ViewBuilder
    private var preview: some View {
        if app.camera.isMock {
            if let img = fx.frozen ? (fx.frozenMock ?? app.camera.mockFrame) : app.camera.mockFrame {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42), value: app.camera.snapshot)
            } else {
                GXColor.night
            }
        } else if let session = app.camera.avSession {
            FreezablePreview(session: session, device: app.camera.avDevice, frozen: fx.frozen) { angle in
                app.camera.setCaptureRotation(angle)
            }
        } else {
            GXColor.night
        }
    }

    /// Tap → focus/expose there. The preview is a 3:4 frame filling the card (aspect fill).
    private func tapFocus(_ loc: CGPoint) {
        let frameAspect: CGFloat = 3.0 / 4.0
        let fillW = max(size.width, size.height * frameAspect)
        let fillH = max(size.height, size.width / frameAspect)
        let x = (loc.x + (fillW - size.width) / 2) / fillW
        let y = (loc.y + (fillH - size.height) / 2) / fillH
        app.userFocus(atUpright: CGPoint(x: x, y: y))
        focusMark = loc
        focusMarkID += 1
    }
}

/// The card's vignette: a soft elliptical falloff, an 80pt inner shadow and a 1px frost rim.
private struct Vignette: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            EllipticalGradient(stops: [.init(color: GXColor.void.opacity(0), location: 0.5),
                                       .init(color: GXColor.void.opacity(0.55), location: 1)],
                               center: UnitPoint(x: 0.5, y: 0.46), startRadiusFraction: 0, endRadiusFraction: 0.62)
            shape.stroke(GXColor.void.opacity(0.5), lineWidth: 60).blur(radius: 36)
            shape.strokeBorder(Color(red: 0.706, green: 0.808, blue: 1).opacity(0.10), lineWidth: 1)
        }
        .clipShape(shape)
    }
}

/// The guide: the viewfinder's own edge glows toward the move (`guide`), pulses once when the
/// coach says hold (aligned), and carries the review's first card as a softer hint.
private struct GuideGlow: View {
    @Environment(AppModel.self) private var app
    @Environment(StageFX.self) private var fx
    @Environment(DeviceTilt.self) private var tilt

    var body: some View {
        let (cue, k) = cue
        EdgeGlow(cue, strength: k, cornerRadius: Viewfinder.radius)
            .allowsHitTesting(false)
    }

    private var cue: (EdgeGlow.Cue, Double) {
        // The border pulses once when a shot's depth scan lands.
        if fx.pulse { return (.aligned, 1) }
        if let g = app.coach.guide {
            if g == .hold { return (.aligned, 1) }
            let k: Double
            switch app.coach.guideStrength {
            case .small: k = 0.55
            case .medium: k = 0.8
            case .large: k = 1
            }
            return (Self.cue(g, tilt: tilt.angle), k)
        }
        if let d = app.review.hint, d != .hold { return (Self.cue(d, tilt: tilt.angle), 0.6) }
        return (.hold, 1)
    }

    /// The coach speaks in the upright picture it sees (the user's frame: frames go out level
    /// with the horizon); the glow lives on the portrait card. Sideways, "left" is the card's
    /// top (+90, phone top to the left) or bottom (-90). Roll, closer and back don't change.
    static func cue(_ d: GuideDirection, tilt: Double) -> EdgeGlow.Cue {
        switch d {
        case .left: return .move(edge(x: -1, y: 0, tilt: tilt))
        case .right: return .move(edge(x: 1, y: 0, tilt: tilt))
        case .up: return .move(edge(x: 0, y: -1, tilt: tilt))
        case .down: return .move(edge(x: 0, y: 1, tilt: tilt))
        case .closer: return .closer
        case .back: return .back
        case .rotateLeft: return .roll(clockwise: false)
        case .rotateRight: return .roll(clockwise: true)
        case .hold: return .aligned
        }
    }

    /// Turns a user-frame direction (y down) clockwise by the tilt onto the card's edges.
    static func edge(x: Int, y: Int, tilt: Double) -> EdgeGlow.Edges {
        let (sx, sy) = tilt > 45 ? (-y, x) : (tilt < -45 ? (y, -x) : (x, y))
        if sx < 0 { return .left }
        if sx > 0 { return .right }
        return sy < 0 ? .top : .bottom
    }
}

/// The few marks on the card: the live dot (top-left), the last shot (bottom-left), the frame
/// aspect (bottom-right) and the coach's yellow suggestion tag (top-centre as the user holds the
/// phone). Marks stay put when the phone turns; their content turns to face the user.
private struct ViewfinderHUD: View {
    @Environment(StageFX.self) private var fx
    @Environment(DeviceTilt.self) private var tilt
    @Environment(SuggestionFeed.self) private var suggestion

    var body: some View {
        ZStack {
            UserFrame {
                SuggestionTag(feed: suggestion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 14)
            }
            CoachDot()
                .opacity(fx.dot)
                .scaleEffect(0.4 + 0.6 * fx.dot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(3)
            LastShot()
                .opacity(fx.thumb)
                .offset(y: 12 * (1 - fx.thumb))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(12)
            Text("4:3")
                .font(GXFont.mono(9))
                .tracking(9 * 0.14)
                .foregroundStyle(GXColor.frost.opacity(0.55))
                .fixedSize()
                .upright(tilt)
                .opacity(fx.thumb)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 16)
                .padding(.bottom, 26)
                .allowsHitTesting(false)
            UserFrame { TalkStack() }
        }
    }
}

/// 6pt Gemini dot: lit while the coach is live, breathing while it connects, red when Core is
/// unreachable or unpaired, dim when the coach is paused. Tap: pair / reconnect / pause.
private struct CoachDot: View {
    @Environment(AppModel.self) private var app
    @Environment(DeviceTilt.self) private var tilt

    var body: some View {
        let (color, glow, pulse, label) = state
        Button { app.statusTapped() } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !pulse)) { ctx in
                let k = pulse ? 0.45 + 0.55 * (0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.4)) : 1
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(color.opacity(glow ? 0.18 : 0), lineWidth: 3).frame(width: 9, height: 9))
                    .shadow(color: glow ? color.opacity(0.95) : .clear, radius: 4)
                    .opacity(k)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .leading) {
                // The link type, only when it's the USB cable.
                if app.viaUSB, app.link == .online {
                    Text("USB")
                        .font(GXFont.mono(8))
                        .tracking(8 * 0.14)
                        .foregroundStyle(GXColor.frost.opacity(0.5))
                        .fixedSize()
                        .upright(tilt)
                        .offset(x: 30)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.24), value: app.viaUSB)
        .accessibilityLabel("Heliocam: \(label)\(app.viaUSB ? ", over USB" : "")")
    }

    private var state: (Color, Bool, Bool, String) {
        switch app.link {
        case .unpaired: return (GXColor.signal, true, false, "pair with your Mac")
        case .unauthorized: return (GXColor.signal, true, false, "pair again")
        case .offline: return (GXColor.signal, true, false, "Mac offline, tap to retry")
        case .checking: return (GXColor.gemini, false, true, "finding your Mac")
        case .online: break
        }
        switch app.coach.phase {
        case .live: return (GXColor.gemini, true, false, "live")
        case .connecting, .reconnecting: return (GXColor.gemini, false, true, "connecting")
        case .failed: return (GXColor.signal, true, false, "failed, tap to retry")
        case .off: return (GXColor.frost.opacity(0.45), false, false, "paused, tap to start")
        }
    }
}

/// The last shot, 40pt in the card's corner (tap: settings). A small dot shows sync trouble.
private struct LastShot: View {
    @Environment(AppModel.self) private var app
    @Environment(StageFX.self) private var fx
    @Environment(DeviceTilt.self) private var tilt

    /// The previous shot stays put until the new one's depth scan finishes.
    private var shown: CGImage? { fx.holdThumb ? fx.heldThumb : app.sync.lastThumb }

    var body: some View {
        Button { app.showSettings = true } label: {
            ZStack {
                if let img = shown {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                        .id(ObjectIdentifier(img))
                        .transition(.opacity.combined(with: .scale(scale: 1.3)))
                } else {
                    GXColor.night
                }
            }
            .frame(width: 38, height: 38)
            .upright(tilt)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(GXColor.frost.opacity(0.3), lineWidth: 1))
            .frame(width: 40, height: 40)
            .shadow(color: .black.opacity(0.4), radius: 5, y: 4)
            .overlay(alignment: .topTrailing) { SyncDot().offset(x: 3, y: -3) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Last shot and settings, \(syncLabel)")
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

private struct SyncDot: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.sync.status {
            case .queued, .failed:
                Circle().fill(GXColor.signal).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(GXColor.void, lineWidth: 1.5))
            default:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.24), value: app.sync.status)
    }
}

/// Tap-to-focus: the blue "+" pops in and fades after a second.
private struct FocusMarkFlash: View {
    @State private var shown = true
    @State private var scale = 1.3

    var body: some View {
        TapFocusMark()
            .scaleEffect(scale)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { scale = 1 }
                withAnimation(.easeIn(duration: 0.35).delay(1.1)) { shown = false }
            }
    }
}

// MARK: - Instrument panel

private struct InstrumentPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(StageFX.self) private var fx
    @Environment(DeviceTilt.self) private var tilt

    private var scanning: Bool {
        if fx.scanOn { return true }
        if case .scanning = app.scan { return true } else { return false }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack { GXColor.panel; GrainOverlay() }
            VStack(spacing: 0) {
                hairline
                InstrumentDrums(iso: drum(\.iso), shutter: drum(\.shutter), ev: drum(\.ev), actor: app.drumActor)
                    .frame(height: 84)
                    .frame(height: 83, alignment: .bottom)
                    .clipped()
                    .modifier(RollIn(k: fx.drums))
                hairline
                FocusRuler(metres: Binding(get: { app.focusMetres }, set: { app.userSetFocus($0) }),
                           actor: app.rulerActor)
                    .frame(height: 44)
                    .frame(height: 43)
                    .clipped()
                    .modifier(RollIn(k: fx.drums))
                hairline
                Spacer(minLength: 0)
            }
            .opacity(scanning ? 0.3 : 1)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42), value: scanning)
            Keys()
                .opacity(fx.keys)
                .offset(y: 12 * (1 - fx.keys))
                .frame(height: 124)
                .offset(y: 128)
        }
        .instrumentGlyphAngle(.degrees(tilt.angle))
    }

    /// Hairlines draw in from the left during the opening.
    private var hairline: some View {
        Rectangle().fill(GXColor.hairline).frame(height: 1)
            .scaleEffect(x: fx.hairlines, y: 1, anchor: .leading)
    }

    private func drum(_ key: KeyPath<AppModel, InstrumentValue>) -> Binding<InstrumentValue> {
        Binding(get: { app[keyPath: key] }, set: { app.userSet($0) })
    }
}

/// Mic + lantern shutter. Kept separate so the 30 Hz mic level only redraws the keys.
private struct Keys: View {
    @Environment(AppModel.self) private var app
    @Environment(StageFX.self) private var fx

    var body: some View {
        // Listening only while the engine really runs (not merely "voice on + live"), so a failed
        // or interrupted mic shows as off, and its level is the real processed input.
        let audio = app.coach.audio
        let engineUp = audio?.isRunning ?? false
        let listening = app.voiceOn && app.coach.phase == .live && engineUp
        HStack(spacing: 0) {
        CoachKeys(shutter: shutter, listening: listening,
                  level: listening ? Double(audio?.inputLevel ?? 0) : 0,
                  onMic: {
                      // Voice on and live but the engine is down: bring the mic back, don't mute.
                      if app.voiceOn, app.coach.phase == .live, !engineUp {
                          Task { await app.coach.restartAudio() }
                      } else {
                          app.micTapped()
                      }
                  },
                  onShutter: { Task { await app.capture() } })
            // Last shot → session roll (#34); without a roll, the last reveal again.
            Button { if let open = app.reveal.onOpenRoll { open() } else { app.reveal.reopen() } } label: {
                ZStack {
                    if let img = app.sync.lastThumb { Image(decorative: img, scale: 1).resizable().scaledToFill() } else { GXColor.night }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .accessibilityLabel("Session roll")
        }
    }

    private var shutter: CoachKeys.Shutter {
        switch app.scan {
        case .scanning(let p): return .scanning(p)
        case .ready: return .depthReady
        case .idle:
            if fx.check { return .depthReady }
            return app.coach.ready ? .ready : .idle
        }
    }
}

// MARK: - Words, kept small

/// Bottom of the card (the user's bottom when sideways): the user's own words as a faint "you"
/// line while they speak, and after a shot the review as chips (verdict, then icon + ≤8 words
/// each). The coach's spoken line is the yellow `SuggestionTag` at the top.
private struct TalkStack: View {
    @Environment(AppModel.self) private var app
    @Environment(DeviceTilt.self) private var tilt

    var body: some View {
        let review = app.review
        let showReview = review.visible && review.verdict != nil && !app.reveal.isShown
        VStack(spacing: 6) {
            if let heard = app.coach.heard {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("YOU")
                        .font(GXFont.mono(9))
                        .tracking(9 * 0.14)
                        .foregroundStyle(GXColor.frost.opacity(0.45))
                    Text(heard)
                        .font(GXFont.display(13))
                        .foregroundStyle(GXColor.frost.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                .transition(.opacity)
            }
            if showReview {
                ReviewChips(review: review)
                    .contentShape(Rectangle())
                    .onTapGesture { app.review.dismiss() }
                    .transition(.asymmetric(insertion: .offset(y: 10).combined(with: .opacity),
                                            removal: .opacity))
                    .id(review.serial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 16)
        // Portrait clears the thumbnail row; sideways the user's bottom is a long edge.
        .padding(.bottom, tilt.sideways ? 16 : 62)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32), value: app.coach.heard == nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showReview)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: review.cards)
    }
}

/// The review as badges: `● ALMOST`, then one chip per suggestion (the first at `suggestion`,
/// the rest at `final`).
private struct ReviewChips: View {
    let review: InstantReview

    var body: some View {
        let accent = Self.color(review.verdict)
        let cards = review.isFinal ? Array(review.cards.prefix(3)) : Array(review.cards.prefix(1))
        VStack(spacing: 6) {
            Text("● " + (review.verdict?.rawValue.uppercased() ?? ""))
                .font(GXFont.mono(10))
                .tracking(10 * 0.1)
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassPill(cornerRadius: 12, tint: accent)
            ForEach(Array(cards.enumerated()), id: \.offset) { i, c in
                HStack(spacing: 7) {
                    Image(systemName: Self.icon(c))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(i == 0 ? GXColor.geminiHot : GXColor.frost.opacity(0.6))
                    Text(c.action)
                        .font(GXFont.display(14))
                        .foregroundStyle(GXColor.frost.opacity(i == 0 ? 1 : 0.78))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassPill(cornerRadius: 16)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismiss")
    }

    static func color(_ v: ReviewVerdict?) -> Color {
        switch v {
        case .keeper: return Color(red: 0x8C / 255, green: 0xF5 / 255, blue: 0xD2 / 255)
        case .almost: return Color(red: 1, green: 0xC2 / 255, blue: 0x7A / 255)
        case .retake: return GXColor.signal
        case nil: return GXColor.label
        }
    }

    static func icon(_ c: ReviewCard) -> String {
        switch c.guide {
        case .left?: return "arrow.left"
        case .right?: return "arrow.right"
        case .up?: return "arrow.up"
        case .down?: return "arrow.down"
        case .closer?: return "plus.magnifyingglass"
        case .back?: return "minus.magnifyingglass"
        case .rotateLeft?: return "arrow.counterclockwise"
        case .rotateRight?: return "arrow.clockwise"
        case .hold?, nil: break
        }
        switch c.kind {
        case "light": return "sun.max"
        case "timing": return "timer"
        case "setting": return "slider.horizontal.3"
        case "subject": return "person.crop.circle"
        case "angle": return "camera.rotate"
        default: return "viewfinder"
        }
    }
}

private extension View {
    /// The v2 glass: night blue over a blur, a hairline, a soft drop shadow.
    func glassPill(cornerRadius r: CGFloat, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(red: 10 / 255, green: 14 / 255, blue: 28 / 255).opacity(0.72))
                if let tint { shape.fill(tint.opacity(0.08)) }
                shape.strokeBorder(GXColor.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        }
    }
}
