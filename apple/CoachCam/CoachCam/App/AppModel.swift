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

/// App state: pairing with Core, the camera, the dials, the coach and sync.
@MainActor
@Observable
final class AppModel: CoachHost {
    enum Link: Equatable {
        case unpaired, checking, online
        case offline(String)
        case unauthorized
    }

    let camera: CameraController
    let controls = CameraControlsModel(parameters: CameraParameter.stripDefault)
    let coach = CoachSession()
    let sync = SyncModel()

    private(set) var pairing: Pairing?
    private(set) var link: Link = .unpaired
    private(set) var capturing = false
    /// Bumps on each capture (viewfinder blink).
    private(set) var shutterCount = 0
    /// Readout values the coach just changed (shown in safelight for 600 ms).
    private(set) var coachTouched: Set<CameraParameter> = []
    var showPairing = false
    var showSettings = false

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
    @ObservationIgnored private var lastRanges: [CameraParameter: ClosedRange<Double>] = [:]
    @ObservationIgnored private var touchClear: Task<Void, Never>?
    @ObservationIgnored private var connecting = false

    init() {
        defaults.register(defaults: ["coach.enabled": true, "coach.voice": true, "photos.save": true])
        coachEnabled = defaults.bool(forKey: "coach.enabled")
        voiceOn = defaults.bool(forKey: "coach.voice")
        saveToPhotos = defaults.bool(forKey: "photos.save")
        camera = CameraController(mock: LaunchOptions.mockCamera)
        coach.voiceOn = voiceOn
        coach.host = self
        camera.engine.frameSink = coach.frames
        camera.onSnapshot = { [weak self] s in self?.syncDials(s) }
        controls.onUserChange = { [weak self] p, s in self?.userChanged(p, s) }
        sync.clientProvider = { [weak self] in self?.link == .online ? self?.client : nil }
        sync.onUnauthorized = { [weak self] in
            self?.link = .unauthorized
            self?.showPairing = true
        }
        sync.onNetworkBack = { [weak self] in
            guard let self, case .offline = self.link else { return }
            Task { await self.connect() }
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
        await coach.start()
        #if DEBUG
        if let p = LaunchOptions.coachPrompt, coach.phase == .live {
            try? await Task.sleep(for: .seconds(2.5))   // let a frame or two arrive first
            coach.debugSend(p)
        }
        #endif
    }

    /// Status pill tap: pair, reconnect, or pause/resume the coach.
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

    // MARK: Pairing

    /// Checks the saved pairing; if the Mac moved to a new IP, finds it again over Bonjour.
    func connect() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        var saved = store.load()
        #if DEBUG
        if let url = LaunchOptions.coreURL, let p = Pairing(address: url, token: LaunchOptions.coreToken) { saved = p }
        #endif
        guard let p = saved else {
            link = .unpaired
            #if DEBUG
            if LaunchOptions.demoCoach { return }
            #endif
            showPairing = true
            return
        }
        pairing = p
        link = .checking
        let c = CoachClient(pairing: p)
        client = c
        switch await Self.check(c) {
        case .ok:
            link = .online
            sync.kick()
        case .unauthorized:
            link = .unauthorized
            showPairing = true
        case .failed(let message):
            if let found = await CoachDiscovery().first(timeout: 4), found.host != p.host || found.port != p.port {
                let moved = found.pairing(token: p.token)
                let mc = CoachClient(pairing: moved)
                if case .ok = await Self.check(mc) {
                    store.updateAddress(host: moved.host, port: moved.port)
                    pairing = moved
                    client = mc
                    link = .online
                    sync.kick()
                    return
                }
            }
            link = .offline(message)
        }
    }

    /// Saves a pairing after checking it against Core. Returns an error message on failure.
    func pair(_ p: Pairing) async -> String? {
        let c = CoachClient(pairing: p)
        switch await Self.check(c) {
        case .ok:
            do { try store.save(p) } catch { return "Couldn't save the pairing: \(error.localizedDescription)" }
            coach.stop()
            pairing = p
            client = c
            link = .online
            showPairing = false
            sync.kick()
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
        pairing = nil
        client = nil
        link = .unpaired
    }

    enum Check { case ok, unauthorized, failed(String) }

    /// `GET /api/health` with a 4 s cap (an unreachable LAN address otherwise hangs for a minute).
    static func check(_ c: CoachClient) async -> Check {
        await withTaskGroup(of: Check.self) { g in
            g.addTask {
                do { _ = try await c.health(); return .ok }
                catch CoachError.unauthorized { return .unauthorized }
                catch { return .failed(CoachSession.describe(error)) }
            }
            g.addTask {
                try? await Task.sleep(for: .seconds(4))
                return .failed("Coach Core at \(c.baseURL.host() ?? "?") didn't answer. Same Wi-Fi?")
            }
            let first = await g.next() ?? .failed("cancelled")
            g.cancelAll()
            return first
        }
    }

    // MARK: Camera ↔ dials

    /// Device truth → dials: device ranges, and the metered value for dials in AUTO.
    private func syncDials(_ s: CameraSnapshot) {
        for (p, r) in [(CameraParameter.iso, s.isoRange), (.shutter, s.shutterRange), (.zoom, s.zoomRange), (.ev, s.evRange)]
        where lastRanges[p] != r {
            lastRanges[p] = r
            controls.setRange(r, for: p)
        }
        if s.isoAuto { controls.updateMetered(.iso, value: s.iso) }
        if s.shutterAuto { controls.updateMetered(.shutter, value: s.shutter) }
        if s.focusAuto { controls.updateMetered(.focus, value: s.focus) }
        if s.wbAuto { controls.updateMetered(.whiteBalance, value: s.wbKelvin) }
    }

    private func userChanged(_ p: CameraParameter, _ s: DialSetting) {
        var c = CameraSettings()
        let auto: (DialSetting) -> AutoNumber = { $0.isAuto ? .auto : .value($0.value ?? p.defaultValue) }
        switch p {
        case .iso: c.iso = auto(s)
        case .shutter: c.shutter = auto(s)
        case .focus: c.focus = auto(s)
        case .whiteBalance: c.wbKelvin = auto(s)
        case .ev: c.ev = s.value
        case .tint: c.tint = s.value
        case .zoom: c.zoom = s.value
        }
        camera.applyUser(c)
        coach.noteUserChange(key: p.rawValue, text: "\(p.title) to \(p.format(s))")
    }

    /// Pinch / lens buttons.
    func userZoom(_ z: Double) {
        let r = controls.range(.zoom)
        let v = min(max(z, r.lowerBound), r.upperBound)
        controls.set(.zoom, to: .manual(v), animated: false)
        camera.applyUser(CameraSettings(zoom: v))
        coach.noteUserChange(key: "zoom", text: String(format: "zoom to %.1fx", v))
    }

    func userMode(_ m: CaptureMode) {
        Task {
            let applied = await camera.apply(CameraSettings(mode: m))
            showOnDials(applied)   // presets move dials too (in the user's colour, not the coach's)
            coach.noteUserChange(key: "mode", text: "mode to \(m.rawValue)")
        }
    }

    private func showOnDials(_ s: CameraSettings) {
        func put(_ p: CameraParameter, _ n: AutoNumber?) {
            guard let n else { return }
            controls.set(p, to: n.isAuto ? .auto(metered: controls.setting(p).value) : .manual(n.number ?? p.defaultValue))
        }
        put(.iso, s.iso)
        put(.shutter, s.shutter)
        put(.focus, s.focus)
        put(.whiteBalance, s.wbKelvin)
        if let v = s.ev { controls.set(.ev, to: .manual(v)) }
        if let v = s.zoom { controls.set(.zoom, to: .manual(v)) }
    }

    func userFocus(atUpright p: CGPoint) {
        camera.focus(atUpright: p)
        if case .manual = controls.setting(.focus) { controls.set(.focus, to: .auto(metered: nil)) }
    }

    // MARK: CoachHost

    var coachClient: CoachClient? { link == .online ? client : nil }

    var coachStateLine: String { camera.snapshot.stateLine }

    func coachSetCamera(_ settings: CameraSettings) async -> CameraSettings {
        let applied = await camera.apply(settings)
        controls.coachApply(applied)
        var touched: Set<CameraParameter> = []
        if applied.iso != nil { touched.insert(.iso) }
        if applied.ev != nil { touched.insert(.ev) }
        if applied.zoom != nil { touched.insert(.zoom) }
        coachTouched = touched
        touchClear?.cancel()
        touchClear = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600 + 620 * max(0, touched.count - 1)))
            guard !Task.isCancelled else { return }
            self?.coachTouched = []
        }
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
            let meta = ShotMeta(
                source: "iphone", device: Self.deviceModel, takenAt: Self.iso8601.string(from: Date()),
                iso: (photo.iso ?? snap.iso).rounded(), shutter: photo.shutter ?? snap.shutter,
                ev: snap.ev, wbKelvin: snap.wbKelvin.rounded(), tint: snap.tint.rounded(),
                lens: snap.lens.rawValue, zoom: (snap.zoom * 100).rounded() / 100, mode: snap.mode.rawValue,
                focus: (snap.focus * 100).rounded() / 100, facing: "back", intent: coach.intent?.rawValue,
                subject: coach.subject, keep: coach.subject.map { [$0] }, scene: nil,
                coach: Array(coach.lines.suffix(6)))
            if saveToPhotos {
                let file = photo.fileData
                Task.detached(priority: .utility) { await PhotoLibrarySaver.save(file) }
            }
            await sync.enqueue(jpeg: photo.jpeg, meta: meta, thumbnail: photo.thumbnail)
            coach.photoTaken(byCoach: byCoach)
            return ["ok": true, "capture_ms": Int(Date().timeIntervalSince(t0) * 1000),
                    "synced": link == .online, "depth": photo.hasDepth]
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
