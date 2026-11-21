import CoachAPI
import CoachModels
import CoachUI
import Foundation
import Observation
import SwiftUI

/// Launch options (UserDefaults argument domain, e.g. `-mockCamera YES`).
enum LaunchOptions {
    static var mockCamera: Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "mockCamera")
        #else
        return false
        #endif
    }
    #if DEBUG
    /// `-demoCoach YES`: play scripted tool calls (no Gemini) to show the dials moving.
    static var demoCoach: Bool { UserDefaults.standard.bool(forKey: "demoCoach") }
    /// `-coachPrompt "…"`: typed user turn sent once Live is up (QA without a mic).
    static var coachPrompt: String? { UserDefaults.standard.string(forKey: "coachPrompt") }
    #endif
}

/// App state: the camera, the instruments, the coach, the local roll and the shot viewer.
/// Standalone: every Gemini call goes straight from the phone (GeminiDirect).
@MainActor
@Observable
final class AppModel: CoachHost {
    let camera: CameraController
    let coach = CoachSession()
    /// Every shot, kept in the app's documents (the roll).
    let shots = ShotStore()
    let reveal = RevealModel()
    /// Hold-to-talk edits of the open shot (on-device speech → Gemini → faders).
    let voice = VoiceEdit()

    private(set) var capturing = false
    /// Bumps on each capture (viewfinder blink).
    private(set) var shutterCount = 0
    var showSettings = false
    /// The gallery (the roll button next to the shutter).
    var showRoll = false
    /// The 3D exploded depth view of the open shot (#34).
    var explode: ExplodeItem?

    // MARK: Instruments (v2 drums + focus ruler)

    /// What the ISO / SS / EV drums show. User drags arrive through `userSet(_:)`.
    private(set) var iso: InstrumentValue = .iso(100, auto: true)
    private(set) var shutter: InstrumentValue = .shutter(1.0 / 120, auto: true)
    private(set) var ev: InstrumentValue = .ev(0)
    /// Focus distance on the ruler (metres, `.infinity` for ∞).
    private(set) var focusMetres: Double = 1.2
    /// Who made the last change (Gemini's play the rolling animation).
    private(set) var drumActor: CoachActor = .user
    private(set) var rulerActor: CoachActor = .user
    /// Display zoom on the zoom ruler (0.5 = ultra-wide, 1 = wide).
    private(set) var zoom: Double = 1
    private(set) var zoomActor: CoachActor = .user

    var coachEnabled: Bool { didSet { defaults.set(coachEnabled, forKey: "coach.enabled") } }
    var voiceOn: Bool {
        didSet {
            defaults.set(voiceOn, forKey: "coach.voice")
            coach.voiceOn = voiceOn
        }
    }
    var saveToPhotos: Bool { didSet { defaults.set(saveToPhotos, forKey: "photos.save") } }
    /// The viewfinder's live depth tile (Settings → Live depth). The depth stream runs only while on.
    var liveDepth: Bool {
        didSet {
            defaults.set(liveDepth, forKey: "depth.live")
            syncLiveDepth()
        }
    }
    /// Newest live depth frame (~15 fps); kept when the tile turns off so it can fade out.
    private(set) var depthFrame: LiveDepthFrame?
    /// Median depth at the frame's centre (metres), from the live depth stream; nil without it.
    @ObservationIgnored private(set) var subjectMetres: Double?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var actorReset: Task<Void, Never>?
    @ObservationIgnored private var lastAutoRefresh = Date.distantPast
    @ObservationIgnored private var lastFocusWrite = Date.distantPast
    @ObservationIgnored private var lastZoomWrite = Date.distantPast

    init() {
        defaults.register(defaults: ["coach.enabled": true, "coach.voice": true, "photos.save": true,
                                     "depth.live": true])
        coachEnabled = defaults.bool(forKey: "coach.enabled")
        voiceOn = defaults.bool(forKey: "coach.voice")
        saveToPhotos = defaults.bool(forKey: "photos.save")
        liveDepth = defaults.bool(forKey: "depth.live")
        camera = CameraController(mock: LaunchOptions.mockCamera)
        coach.voiceOn = voiceOn
        coach.host = self
        camera.engine.frameSink = FrameSinks([coach.frames, SubjectTracker.shared])
        camera.onSnapshot = { [weak self] s in self?.syncInstruments(s) }
        syncLiveDepth()
        reveal.speaker = { [weak self] line in
            guard self?.voiceOn == true else { return }
            Speaker.shared.say(line)
        }
        RevealModel.localDepthPNG = { PhotoDepth.depthPNGmm(fromPhotoData: $0) }
        voice.onRelease = { [weak self] wav in self?.reveal.voiceReleased(wav: wav) }
        voice.onText = { [weak self] text in self?.reveal.voiceEdit(text) }
        // The shot viewer pauses the camera coach (Live frames, ticks, director) so it never talks
        // about the camera behind the photo; a new shot or dismiss ends voice edit on the old one.
        reveal.onPresent = { [weak self] shown in
            guard let self else { return }
            if self.voice.isListening { self.voice.cancel() }
            if shown { self.coach.stop() } else { Task { await self.startCoachIfReady() } }
        }
        reveal.onShow3D = { [weak self] photo, depth in
            guard let cg = photo.cgImage else { return }
            self?.explode = ExplodeItem(photo: cg, depthPNG: depth)
        }
    }

    // MARK: Lifecycle

    func launch() async {
        await camera.start()
        DepthPro2.warmUp()   // so the first shot already gets Depth Pro 2 depth
        #if DEBUG
        if LaunchOptions.demoCoach {
            await DemoScript.run(self)
            return
        }
        #endif
        await startCoachIfReady()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task {
                await camera.start()
                await startCoachIfReady()
            }
        case .background:
            coach.stop()
            camera.stop()
        default:
            break
        }
    }

    func startCoachIfReady() async {
        guard coachEnabled, camera.isRunning, !coach.isActive, !reveal.isShown else { return }
        #if DEBUG
        if LaunchOptions.demoCoach { return }   // the scripted coach only
        #endif
        await coach.start()
        // A shot opened while the coach was starting: the viewer owns the mic now.
        if reveal.isShown { coach.stop(); return }
        #if DEBUG
        if let p = LaunchOptions.coachPrompt, coach.phase == .live {
            try? await Task.sleep(for: .seconds(2.5))   // let a frame or two arrive first
            coach.debugSend(p)
        }
        #endif
    }

    /// Live dot tap: pause or resume the coach.
    func statusTapped() {
        if coach.isActive {
            coach.stop()
            coachEnabled = false
        } else {
            coachEnabled = true
            Task { await startCoachIfReady() }
        }
    }

    /// Opens a shot from the gallery in the shot viewer.
    func open(_ shot: LocalShot) {
        guard let jpeg = try? Data(contentsOf: shot.jpegURL) else { return }
        let file = shot.fileURL.flatMap { try? Data(contentsOf: $0) }
        reveal.begin(jpeg: jpeg, photoData: file)
    }

    /// The mic key: talk to Gemini. Starts the coach if it's off, else toggles voice mode.
    func micTapped() {
        if coach.phase == .live || coach.isActive {
            voiceOn.toggle()
            return
        }
        voiceOn = true
        coachEnabled = true
        Task { await startCoachIfReady() }
    }

    // MARK: Camera ↔ instruments

    /// Device truth → instruments. AUTO drums keep showing AUTO (their metered number only
    /// refreshes on a big change, so the drum doesn't flicker); the ruler follows autofocus live.
    private func syncInstruments(_ s: CameraSnapshot) {
        let now = Date()
        if now.timeIntervalSince(lastAutoRefresh) > 3 {
            var refreshed = false
            if iso.isAuto, s.isoAuto, abs(log2(max(s.iso, 1) / max(iso.number, 1))) > 1.5 {
                iso = .iso(s.iso.rounded(), auto: true)
                refreshed = true
            }
            if shutter.isAuto, s.shutterAuto, abs(log2(max(s.shutter, 1e-6) / max(shutter.number, 1e-6))) > 1.5 {
                shutter = .shutter(s.shutter, auto: true)
                refreshed = true
            }
            if refreshed { drumActor = .user; lastAutoRefresh = now }
        }
        if zoomActor == .user, now.timeIntervalSince(lastZoomWrite) > 1, s.zoom > 0,
           abs(log2(s.zoom / max(zoom, 0.01))) > 0.01 {
            zoom = s.zoom
        }
        if s.focusAuto, rulerActor == .user, now.timeIntervalSince(lastFocusWrite) > 1 {
            let m = FocusDistance.metres(lensPosition: s.focus, minFocus: s.minFocus)
            if abs(Self.ticks(m) - Self.ticks(focusMetres)) > 0.25 { focusMetres = m }
        }
    }

    /// Ruler position for a distance (minor ticks; 0 at ∞), to skip sub-tick autofocus jitter.
    private static func ticks(_ m: Double) -> Double { m.isFinite ? -10 / max(m, 0.1) : 0 }

    /// A drum drag or double-tap (AUTO / EV 0).
    func userSet(_ v: InstrumentValue) {
        drumActor = .user
        switch v.kind {
        case .iso:
            iso = v
            camera.applyUser(CameraSettings(iso: v.isAuto ? .auto : .value(v.number)))
        case .shutter:
            shutter = v
            camera.applyUser(CameraSettings(shutter: v.isAuto ? .auto : .value(v.number)))
        case .ev:
            ev = v
            camera.applyUser(CameraSettings(ev: v.number))
        }
        coach.noteUserChange(key: v.kind.rawValue, text: "\(v.label) to \(v.text)")
    }

    /// A focus ruler drag.
    func userSetFocus(_ m: Double) {
        rulerActor = .user
        focusMetres = m
        lastFocusWrite = Date()
        let lp = FocusDistance.lensPosition(metres: m, minFocus: camera.snapshot.minFocus)
        camera.applyUser(CameraSettings(focus: .value(lp)))
        coach.noteUserChange(key: "focus", text: m.isFinite ? String(format: "focus to %.1f m", m) : "focus to infinity")
    }

    /// Pinch or a zoom ruler drag.
    func userZoom(_ z: Double) {
        let r = camera.snapshot.zoomRange
        let v = min(max(z, r.lowerBound), r.upperBound)
        zoomActor = .user
        zoom = v
        lastZoomWrite = Date()
        camera.applyUser(CameraSettings(zoom: v))
        coach.noteUserChange(key: "zoom", text: String(format: "zoom to %.1fx", v))
    }

    /// Tap to focus: continuous autofocus at that point; the ruler follows it.
    func userFocus(atUpright p: CGPoint) {
        camera.focus(atUpright: p)
        rulerActor = .user
        lastFocusWrite = .distantPast
    }

    /// Shows what a `set_camera` actually applied, with Gemini's rolling animation.
    private func showApplied(_ a: CameraSettings, by actor: CoachActor) {
        let s = camera.snapshot
        if a.iso != nil || a.shutter != nil || a.ev != nil { drumActor = actor }
        if let n = a.iso { iso = n.number.map { .iso($0) } ?? .iso(s.iso.rounded(), auto: true) }
        if let n = a.shutter { shutter = n.number.map { .shutter($0) } ?? .shutter(s.shutter, auto: true) }
        if let v = a.ev { ev = .ev(v) }
        if let z = a.zoom { zoomActor = actor; zoom = z }
        if let f = a.focus {
            if let lp = f.number {
                rulerActor = actor
                focusMetres = FocusDistance.metres(lensPosition: lp, minFocus: s.minFocus)
            } else {
                rulerActor = .user
                lastFocusWrite = .distantPast
            }
        }
        actorReset?.cancel()
        actorReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self else { return }
            self.drumActor = .user
            self.rulerActor = .user
            self.zoomActor = .user
        }
    }

    // MARK: CoachHost

    var coachCamera: QuickCommands.Camera {
        let c = camera.snapshot
        return QuickCommands.Camera(ev: c.ev, zoom: c.zoom, wbKelvin: c.wbKelvin)
    }

    var coachStateLine: String {
        guard let m = subjectMetres else { return camera.snapshot.stateLine }
        return camera.snapshot.stateLine + String(format: ", subject_m %.1f", m)
    }

    private func syncLiveDepth() {
        if liveDepth {
            depthFrame = nil
            camera.engine.setLiveDepth(true) { [weak self] frame in
                guard let self, self.liveDepth else { return }
                self.depthFrame = frame
                self.subjectMetres = frame?.subjectMetres
            }
        } else {
            camera.engine.setLiveDepth(false, handler: nil)
            subjectMetres = nil
        }
    }

    func coachSetCamera(_ settings: CameraSettings) async -> CameraSettings {
        let applied = await camera.apply(settings)
        showApplied(applied, by: .gemini)
        return applied
    }

    func coachTakePhoto(reason: String?) async -> [String: Any] {
        await capture(byCoach: true)
    }

    // MARK: Capture

    @discardableResult
    func capture(byCoach: Bool = false) async -> [String: Any] {
        guard !capturing else { return ["ok": false, "error": "already taking a photo"] }
        capturing = true
        defer { capturing = false }
        shutterCount += 1
        let t0 = Date()
        do {
            let photo = try await camera.capture()
            // The shot lands in the roll (the thumbnail flies in); the viewer opens only from it.
            shots.add(jpeg: photo.jpeg, file: photo.fileData, thumbnail: photo.thumbnail)
            if saveToPhotos {
                let file = photo.fileData
                Task.detached(priority: .utility) { await PhotoLibrarySaver.save(file) }
            }
            coach.photoTaken(byCoach: byCoach)
            return ["ok": true, "capture_ms": Int(Date().timeIntervalSince(t0) * 1000), "depth": photo.hasDepth]
        } catch {
            return ["ok": false, "error": CoachSession.describe(error)]
        }
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// e.g. "iPhone17,1" (the hardware model identifier).
    static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return id.hasPrefix("iPhone") ? id : "iPhone (\(id))"
    }()
}

/// A shot shown in the 3D exploded depth view.
struct ExplodeItem: Identifiable {
    let id = UUID()
    let photo: CGImage
    let depthPNG: Data
}
