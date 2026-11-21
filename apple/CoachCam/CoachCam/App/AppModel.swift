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
    /// `-coreURL http://127.0.0.1:8797` (with optional `-coreToken`): skip pairing.
    static var coreURL: String? { UserDefaults.standard.string(forKey: "coreURL") }
    static var coreToken: String? { UserDefaults.standard.string(forKey: "coreToken") }
    /// `-demoCoach YES`: play scripted tool calls (no Gemini) to show the dials moving.
    static var demoCoach: Bool { UserDefaults.standard.bool(forKey: "demoCoach") }
    /// `-coachPrompt "…"`: typed user turn sent once Live is up (QA without a mic).
    static var coachPrompt: String? { UserDefaults.standard.string(forKey: "coachPrompt") }
    #endif
}

/// App state: pairing with Core, the camera, the instruments, the coach, the review and sync.
@MainActor
@Observable
final class AppModel: CoachHost {
    enum Link: Equatable {
        case unpaired, checking, online
        case offline(String)
        case unauthorized
    }

    let camera: CameraController
    let coach = CoachSession()
    let sync = SyncModel()
    let review = InstantReview()
    let reveal = RevealModel()
    /// Talk to edit the open shot (the shot viewer's mic, #34).
    let voice = VoiceEdit()

    private(set) var pairing: Pairing?
    private(set) var link: Link = .unpaired
    /// Online over the USB cable (USBUplink) rather than the network.
    private(set) var viaUSB = false
    private(set) var capturing = false
    /// Bumps on each capture (viewfinder blink).
    private(set) var shutterCount = 0
    var showPairing = false
    var showSettings = false
    /// Session roll (#34): this session's shots, keepers first.
    var showRoll = false
    let launchedAt = Date()
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

    // MARK: Depth scan (the shutter's ring while Core analyses the last shot)

    enum Scan: Equatable { case idle, scanning(Double), ready }
    private(set) var scan: Scan = .idle

    var coachEnabled: Bool { didSet { defaults.set(coachEnabled, forKey: "coach.enabled") } }
    var voiceOn: Bool {
        didSet {
            defaults.set(voiceOn, forKey: "coach.voice")
            coach.voiceOn = voiceOn
        }
    }
    var saveToPhotos: Bool { didSet { defaults.set(saveToPhotos, forKey: "photos.save") } }

    @ObservationIgnored private(set) var client: CoachClient?
    @ObservationIgnored private let store = PairingStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var actorReset: Task<Void, Never>?
    @ObservationIgnored private var lastAutoRefresh = Date.distantPast
    @ObservationIgnored private var lastFocusWrite = Date.distantPast
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanEntry: String?
    @ObservationIgnored private var scanShot: String?
    @ObservationIgnored private var scanTarget = 0.0

    init() {
        defaults.register(defaults: ["coach.enabled": true, "coach.voice": true, "photos.save": true])
        coachEnabled = defaults.bool(forKey: "coach.enabled")
        voiceOn = defaults.bool(forKey: "coach.voice")
        saveToPhotos = defaults.bool(forKey: "photos.save")
        camera = CameraController(mock: LaunchOptions.mockCamera)
        coach.voiceOn = voiceOn
        coach.host = self
        camera.engine.frameSink = FrameSinks([coach.frames, SubjectTracker.shared])
        camera.onSnapshot = { [weak self] s in self?.syncInstruments(s) }
        review.speaker = { [weak self] line, verdict in self?.sayReview(line, verdict: verdict) }
        reveal.speaker = { [weak self] line in self?.sayReview(line, verdict: nil, reveal: true) }
        RevealModel.localDepthPNG = { PhotoDepth.depthPNGmm(fromPhotoData: $0) }
        voice.register(into: reveal.renderer)
        reveal.onMic = { [weak self] in self?.toggleVoiceEdit() }
        reveal.onOpenRoll = { [weak self] in self?.showRoll = true }
        reveal.onShow3D = { [weak self] photo, depth in
            guard let cg = photo.cgImage else { return }
            self?.explode = ExplodeItem(photo: cg, depthPNG: depth)
        }
        sync.clientProvider = { [weak self] in self?.link == .online ? self?.client : nil }
        sync.onUnauthorized = { [weak self] in
            self?.link = .unauthorized
            self?.showPairing = true
        }
        sync.onNetworkBack = { [weak self] in
            guard let self, case .offline = self.link else { return }
            Task { await self.connect() }
        }
        sync.onOffline = { [weak self] _ in
            // The saved address stopped answering (e.g. Wi-Fi off, cable on): look again.
            guard let self, self.link == .online else { return }
            Task { await self.connect() }
        }
        sync.onUploaded = { [weak self] entry, shot in
            self?.reveal.uploaded(entry: entry, shot: shot)
            self?.uploaded(entry: entry, shot: shot)
        }
        // Plugging or unplugging the cable re-connects (cable first, then the network).
        NotificationCenter.default.addObserver(forName: USBUplink.linkDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.connect() }
        }
    }

    // MARK: Lifecycle

    func launch() async {
        async let cam: Void = camera.start()
        await connect()
        await cam
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
                if link != .online { await connect() }
                await startCoachIfReady()
                sync.kick()
            }
        case .background:
            coach.stop()
            camera.stop()
        default:
            break
        }
    }

    func startCoachIfReady() async {
        guard coachEnabled, link == .online, camera.isRunning, !coach.isActive else { return }
        #if DEBUG
        if LaunchOptions.demoCoach { return }   // the scripted coach only
        #endif
        await coach.start()
        #if DEBUG
        if let p = LaunchOptions.coachPrompt, coach.phase == .live {
            try? await Task.sleep(for: .seconds(2.5))   // let a frame or two arrive first
            coach.debugSend(p)
        }
        #endif
    }

    /// Live dot tap: pair, reconnect, or pause/resume the coach.
    func statusTapped() {
        switch link {
        case .unpaired, .unauthorized: showPairing = true
        case .offline, .checking: Task { await connect(); await startCoachIfReady() }
        case .online:
            if coach.isActive {
                coach.stop()
                coachEnabled = false
            } else {
                coachEnabled = true
                Task { await startCoachIfReady() }
            }
        }
    }

    /// The shot viewer's mic: Gemini Live in edit mode on the open shot. The camera coach's Live
    /// session pauses meanwhile (one LiveAudio engine at a time) and resumes when editing stops.
    func toggleVoiceEdit() {
        if voice.isLive {
            voice.stop()
            if coachEnabled, link == .online { Task { await startCoachIfReady() } }
            return
        }
        guard let client = coachClient, let id = reveal.shotID else { return }
        coach.stop()
        voice.seed(values: reveal.namedValues, layers: reveal.currentLayers)
        Task { await voice.start(client: client, shotID: id) }
    }

    /// The mic key: talk to Gemini. Starts the coach if it's off, else toggles voice mode.
    func micTapped() {
        if coach.phase == .live || coach.isActive {
            voiceOn.toggle()
            return
        }
        voiceOn = true
        coachEnabled = true
        if link == .online { Task { await startCoachIfReady() } } else { statusTapped() }
    }

    // MARK: Pairing

    /// Checks the saved pairing; if that address doesn't answer, finds Core again over Bonjour on
    /// any link (Wi-Fi or the USB hotspot cable) and keeps the token.
    func connect() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        var saved = store.load()
        #if DEBUG
        if let url = LaunchOptions.coreURL, let p = Pairing(address: url, token: LaunchOptions.coreToken) { saved = p }
        #endif
        // The USB cable first: Core sees cable requests as loopback, so no pairing is needed.
        USBUplink.shared.start()
        if await USBUplink.shared.waitForLink() {
            let c = CoachClient(baseURL: USBUplink.shared.baseURL, token: saved?.token)
            if case .ok = await Self.check(c) {
                setOnline(saved, c, usb: true)
                showPairing = false
                return
            }
        }
        guard let p = saved else {
            viaUSB = false
            link = .unpaired
            #if DEBUG
            if LaunchOptions.demoCoach { return }
            #endif
            showPairing = true
            return
        }
        pairing = p
        if link != .online { link = .checking }
        let c = CoachClient(pairing: p)
        switch await Self.check(c) {
        case .ok:
            setOnline(p, c)
        case .unauthorized:
            link = .unauthorized
            viaUSB = false
            showPairing = true
        case .failed(let message):
            viaUSB = false
            #if DEBUG
            if LaunchOptions.coreURL != nil { link = .offline(message); return }
            #endif
            switch await CoreFinder.find(token: p.token) {
            case .found(let moved):
                if moved.host != p.host || moved.port != p.port { store.updateAddress(host: moved.host, port: moved.port) }
                setOnline(moved, CoachClient(pairing: moved))
            case .unauthorized:
                link = .unauthorized
                showPairing = true
            case .none:
                link = .offline(message)
            }
        }
    }

    private func setOnline(_ p: Pairing?, _ c: CoachClient, usb: Bool = false) {
        let changed = client?.baseURL != c.baseURL
        pairing = p ?? pairing
        client = c
        viaUSB = usb
        link = .online
        #if DEBUG
        print("CoachCam[link] online via \(usb ? "USB cable" : c.baseURL.absoluteString)")
        #endif
        if changed || eventsTask == nil { startEvents(c) }
        sync.kick()
    }

    /// Saves a pairing after checking it against Core (or the same Core on another link).
    /// Returns an error message on failure.
    func pair(_ p: Pairing) async -> String? {
        var p = p
        var c = CoachClient(pairing: p)
        var result = await Self.check(c)
        if case .failed = result, case .found(let moved) = await CoreFinder.find(token: p.token, timeout: 4) {
            p = moved
            c = CoachClient(pairing: moved)
            result = .ok
        }
        switch result {
        case .ok:
            do { try store.save(p) } catch { return "Couldn't save the pairing: \(error.localizedDescription)" }
            coach.stop()
            setOnline(p, c)
            showPairing = false
            await startCoachIfReady()
            return nil
        case .unauthorized:
            return "Coach Core refused the code. Show a fresh QR on the Mac and scan again."
        case .failed(let m):
            return m
        }
    }

    func forgetPairing() {
        coach.stop()
        store.clear()
        eventsTask?.cancel()
        eventsTask = nil
        pairing = nil
        client = nil
        link = .unpaired
    }

    enum Check: Sendable { case ok, unauthorized, failed(String) }

    /// `GET /api/health` with a cap (an unreachable LAN address otherwise hangs for a minute).
    nonisolated static func check(_ c: CoachClient, timeout: Double = 4) async -> Check {
        await withTaskGroup(of: Check.self) { g in
            g.addTask {
                do { _ = try await c.health(); return .ok }
                catch CoachError.unauthorized { return .unauthorized }
                catch { return .failed(CoachSession.describe(error)) }
            }
            g.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .failed("Coach Core at \(c.baseURL.host() ?? "?") didn't answer. Same Wi-Fi, or the cable?")
            }
            let first = await g.next() ?? .failed("cancelled")
            g.cancelAll()
            return first
        }
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

    /// Pinch.
    func userZoom(_ z: Double) {
        let r = camera.snapshot.zoomRange
        let v = min(max(z, r.lowerBound), r.upperBound)
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
        }
    }

    // MARK: CoachHost

    var coachClient: CoachClient? { link == .online ? client : nil }

    var coachStateLine: String { camera.snapshot.stateLine }

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
        let snap = camera.snapshot
        let t0 = Date()
        do {
            let photo = try await camera.capture()
            let online = link == .online ? client : nil
            reveal.begin(jpeg: photo.jpeg, photoData: photo.fileData, client: online)
            let reviewID = online != nil ? InstantReview.newID() : nil
            let lines = Array(coach.lines.suffix(6))
            let keep = coach.subject.map { [$0] }
            let meta = ShotMeta(
                source: "iphone", device: Self.deviceModel, takenAt: Self.iso8601.string(from: Date()),
                iso: (photo.iso ?? snap.iso).rounded(), shutter: photo.shutter ?? snap.shutter,
                ev: snap.ev, wbKelvin: snap.wbKelvin.rounded(), tint: snap.tint.rounded(),
                lens: snap.lens.rawValue, zoom: (snap.zoom * 100).rounded() / 100, mode: snap.mode.rawValue,
                focus: (snap.focus * 100).rounded() / 100, facing: "back", intent: coach.intent?.rawValue,
                subject: coach.subject, keep: keep, scene: nil, coach: lines)
            if saveToPhotos {
                let file = photo.fileData
                Task.detached(priority: .utility) { await PhotoLibrarySaver.save(file) }
            }
            // Review first (a ≤1024 px copy): the full upload waits for its verdict (≤4 s) and
            // carries `review_id`, so Core saves the review into the shot.
            if let client = online, let reviewID {
                let hold = sync.hold(seconds: 4)
                let ctx = ReviewContext(
                    reviewID: reviewID, intent: coach.intent?.rawValue, subject: coach.subject, keep: keep,
                    scene: nil, heard: coach.lastHeard, coach: lines,
                    settings: .init(mode: snap.mode.rawValue, lens: snap.lens.rawValue, zoom: (snap.zoom * 100).rounded() / 100,
                                    iso: (photo.iso ?? snap.iso).rounded(), shutter: photo.shutter ?? snap.shutter,
                                    ev: snap.ev, flash: snap.flash.rawValue))
                review.start(client: client, jpeg: photo.jpeg, context: ctx, speak: voiceOn) { [weak self] in
                    self?.sync.release(hold)
                }
            }
            let entry = await sync.enqueue(jpeg: photo.jpeg, meta: meta, reviewID: reviewID, thumbnail: photo.thumbnail)
            if let entry { reveal.track(entry: entry) }
            if online != nil, let entry { beginScan(entry: entry) }
            coach.photoTaken(byCoach: byCoach)
            return ["ok": true, "capture_ms": Int(Date().timeIntervalSince(t0) * 1000),
                    "synced": online != nil, "depth": photo.hasDepth, "review": online != nil && voiceOn]
        } catch {
            return ["ok": false, "error": CoachSession.describe(error)]
        }
    }

    /// The review's line in the coach's Gemini voice: through the Live session when it's up,
    /// else Core's TTS (`/api/cam/say`, same voice) through the Live player. Voice off: silent.
    private func sayReview(_ line: String, verdict: ReviewVerdict?, reveal fromReveal: Bool = false) {
        guard voiceOn else { return }
        // The shot reveal (#34) speaks its own fix; the review's verdict stays quiet under it.
        if reveal.isShown, !fromReveal { return }
        if !fromReveal, coach.speakReview(line, verdict: verdict?.rawValue) { return }
        guard let client = coachClient else { return }
        Task { [weak self] in
            guard let wav = try? await CoreExtras.say(client: client, text: line), let pcm = CoreExtras.pcm(wav: wav) else { return }
            await self?.coach.playSpeech(pcm24k: pcm)
        }
    }

    // MARK: Depth scan: follow the shot through Core's pipeline

    /// Stages counted for the ring (CORE_API.md §3): depth, score, regions, masks, suggest.
    private static func finishedStages(_ s: Shot) -> Int {
        let a = s.assets
        let stages: [ShotAsset] = [a.depth, a.score, a.regions, a.masks, a.suggest]
        return stages.filter { (x: ShotAsset) -> Bool in x.status == .done || x.status == .error }.count
    }

    private func beginScan(entry: String) {
        scanEntry = entry
        scanShot = nil
        scanTarget = 0
        scan = .scanning(0.02)
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let t0 = Date()
            var lastPoll = Date()
            while !Task.isCancelled, let self {
                try? await Task.sleep(for: .milliseconds(66))
                guard case .scanning(let p) = self.scan else { return }
                // Ease toward the finished share; creep a little inside the running stage.
                let target = self.scanTarget
                let next = p < target ? min(target, p + max((target - p) * 0.22, 0.004)) : min(p + 0.0011, target + 0.15, 0.97)
                self.scan = .scanning(next)
                if target >= 1 {
                    self.scan = .scanning(1)
                    try? await Task.sleep(for: .milliseconds(260))
                    self.scan = .ready
                    try? await Task.sleep(for: .seconds(1.8))
                    if !Task.isCancelled, self.scan == .ready { self.scan = .idle }
                    return
                }
                // Fallback poll in case the events stream is reconnecting.
                if let id = self.scanShot, Date().timeIntervalSince(lastPoll) > 3, let c = self.client {
                    lastPoll = Date()
                    if let shot = try? await c.shot(id: id) { self.shotUpdated(shot) }
                }
                if Date().timeIntervalSince(t0) > 75 { self.scan = .idle; return }
            }
        }
    }

    private func uploaded(entry: String, shot: Shot) {
        guard entry == scanEntry else { return }
        scanShot = shot.id
        shotUpdated(shot)
    }

    private func shotUpdated(_ shot: Shot) {
        guard shot.id == scanShot, case .scanning = scan else { return }
        scanTarget = max(scanTarget, Double(Self.finishedStages(shot)) / 5)
        #if DEBUG
        print("CoachCam[scan] \(shot.id) \(Self.finishedStages(shot))/5")
        #endif
    }

    /// `GET /api/events` while online: shot updates drive the depth-scan ring.
    private func startEvents(_ c: CoachClient) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            do {
                for try await e in c.events() {
                    guard !Task.isCancelled else { return }
                    if case .shot(let shot) = e { self?.shotUpdated(shot) }
                }
            } catch {
                #if DEBUG
                print("CoachCam[events] ended: \(error)")
                #endif
            }
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
