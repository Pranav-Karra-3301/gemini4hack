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
    static let panelHeight: CGFloat = 296

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
        .overlay { if app.showRoll { Gallery().transition(.opacity) } }
        .overlay { if app.reveal.isShown { ShotReveal(model: app.reveal, voice: app.voice).transition(.opacity) } }
        .animation(.easeOut(duration: 0.2), value: app.reveal.isShown)
        .animation(.easeOut(duration: 0.24), value: app.showRoll)
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
        .onChange(of: app.coach.hintSerial) { _, _ in suggestion.pin(app.coach.hint) }
        .onChange(of: app.shutterCount) { _, _ in
            fx.shot(lastThumb: app.shots.lastThumb, mockFrame: app.camera.isMock ? app.camera.mockFrame : nil)
        }
        .sheet(isPresented: $app.showSettings) { SettingsSheet() }
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
            LiveDepthTile()
                .opacity(fx.dot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 14)
                .padding(.trailing, 14)
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

/// The live depth map in a small tile (Settings → Live depth): near is bright. Hidden when the
/// camera has no streaming depth.
private struct LiveDepthTile: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let frame = app.depthFrame
        let shown = app.liveDepth && frame != nil
        ZStack {
            GXColor.night
            if let frame {
                Image(decorative: frame.image, scale: 1, orientation: Image.Orientation(frame.orientation))
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 96, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(GXColor.frost.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.94, anchor: .topTrailing)
        .animation(.easeInOut(duration: 0.28), value: shown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Image.Orientation {
    init(_ o: CGImagePropertyOrientation) {
        switch o {
        case .right: self = .right
        case .down: self = .down
        case .left: self = .left
        default: self = .up
        }
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
            return (Self.cue(g, tilt: tilt.angle), k * SubjectTracker.shared.glowScale)
        }
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
/// aspect (bottom-right) and the coach's yellow suggestion tag (bottom-centre as the user holds the
/// phone). Marks stay put when the phone turns; their content turns to face the user.
private struct ViewfinderHUD: View {
    @Environment(StageFX.self) private var fx
    @Environment(DeviceTilt.self) private var tilt
    @Environment(SuggestionFeed.self) private var suggestion

    var body: some View {
        ZStack {
            UserFrame {
                SuggestionTag(feed: suggestion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 20)
            }
            CoachDot()
                .opacity(fx.dot)
                .scaleEffect(0.4 + 0.6 * fx.dot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(3)
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

/// 6pt Gemini dot: lit while the coach is live, breathing while it connects, red when it failed,
/// dim when the coach is paused. Tap: pause / resume. Long press: settings.
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in app.showSettings = true })
        .accessibilityLabel("Heliocam: \(label)")
        .accessibilityAction(named: "Settings") { app.showSettings = true }
    }

    private var state: (Color, Bool, Bool, String) {
        switch app.coach.phase {
        case .live: return (GXColor.gemini, true, false, "live")
        case .connecting, .reconnecting: return (GXColor.gemini, false, true, "connecting")
        case .failed: return (GXColor.signal, true, false, "failed, tap to retry")
        case .off: return (GXColor.frost.opacity(0.45), false, false, "paused, tap to start")
        }
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

    private var scanning: Bool { fx.scanOn }

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
                ZoomRuler(zoom: Binding(get: { app.zoom }, set: { app.userZoom($0) }),
                          range: app.camera.snapshot.zoomRange, stops: zoomStops, actor: app.zoomActor)
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
                .offset(y: 172)
        }
        .instrumentGlyphAngle(.degrees(tilt.angle))
    }

    /// Hairlines draw in from the left during the opening.
    private var hairline: some View {
        Rectangle().fill(GXColor.hairline).frame(height: 1)
            .scaleEffect(x: fx.hairlines, y: 1, anchor: .leading)
    }

    /// Zoom detents: 0.5× / 1× / 2× plus each lens this iPhone has (5× tele on a 15 Pro Max).
    private var zoomStops: [Double] {
        let r = app.camera.snapshot.zoomRange
        return Set([0.5, 1, 2] + app.camera.snapshot.lenses.values).filter { r.contains($0) }.sorted()
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
            RollKey()
                .padding(.leading, -4)   // the keys' 12 pt gap (CoachKeys pads 16 on each side)
                .padding(.trailing, 16)
        }
    }

    private var shutter: CoachKeys.Shutter {
        if fx.check { return .depthReady }
        return app.coach.ready ? .ready : .idle
    }
}

/// The one gallery entry point: the newest shot, the keys' height (72 pt) and radius. A fresh
/// shot lands here (the previous one holds until the capture flash and sweep finish); tap opens
/// the gallery.
private struct RollKey: View {
    @Environment(AppModel.self) private var app
    @Environment(StageFX.self) private var fx
    @Environment(DeviceTilt.self) private var tilt

    private var shown: CGImage? { fx.holdThumb ? fx.heldThumb : app.shots.lastThumb }

    var body: some View {
        Button { if !app.shots.shots.isEmpty { app.showRoll = true } } label: {
            ZStack {
                GXColor.night
                if let img = shown {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                        .upright(tilt)
                        .id(ObjectIdentifier(img))
                        .transition(.opacity.combined(with: .scale(scale: 1.3)))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(GXColor.frost.opacity(0.14), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyPressStyle())
        .animation(.spring(response: 0.42, dampingFraction: 0.7), value: shown.map(ObjectIdentifier.init))
        .accessibilityLabel(app.shots.shots.isEmpty ? "No shots yet" : "Gallery")
    }
}

// MARK: - Words, kept small

/// Bottom of the card (the user's bottom when sideways): the user's own words as a faint "you"
/// line while they speak. The coach's spoken line is the yellow `SuggestionTag` at the top.
private struct TalkStack: View {
    @Environment(AppModel.self) private var app
    @Environment(DeviceTilt.self) private var tilt

    var body: some View {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32), value: app.coach.heard == nil)
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
