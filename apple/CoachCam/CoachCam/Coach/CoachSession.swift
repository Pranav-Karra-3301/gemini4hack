import CoachAPI
import CoachLive
import CoachModels
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Observation

/// What the coach needs from the app: the camera, the shutter and Core.
@MainActor
protocol CoachHost: AnyObject {
    var coachClient: CoachClient? { get }
    /// `[state]` line: mode, lens, zoom, ISO, shutter, EV, focus, WB.
    var coachStateLine: String { get }
    /// Applies `set_camera` on the hardware, animates the dials, returns what was applied.
    func coachSetCamera(_ settings: CameraSettings) async -> CameraSettings
    /// Takes and syncs a photo; returns the tool result.
    func coachTakePhoto(reason: String?) async -> [String: Any]
}

/// One Gemini Live camera session (CORE_API.md §2): Core mints the token, audio and frames go
/// straight to Gemini, tool calls drive the viewfinder and the camera.
///
/// Token economy: frames go out at most once a second and only when the picture changed (the
/// session diffs a 16×16 luma thumbnail first). Gemini only answers when asked, so the app sends a
/// `[tick]` check-in every 4 s while nobody is talking, but only if a new frame went out since the
/// last tick (otherwise every 12 s). The user's own dial changes are added as silent context.
@MainActor
@Observable
final class CoachSession {
    enum Phase: Equatable {
        case off, connecting, live, reconnecting
        case failed(String)
    }

    private(set) var phase: Phase = .off
    /// The coach's current line (last few words, for the caption).
    private(set) var caption: String?
    /// What the user just said (reaction chip).
    private(set) var heard: String?
    private(set) var guide: GuideDirection?
    private(set) var guideStrength: GuideStrength = .medium
    private(set) var intent: ShotIntent?
    private(set) var subject: String?
    private(set) var reaction: UserReaction?
    /// Bumps on every `user_reaction` so the wash replays.
    private(set) var reactionID = 0
    private(set) var ready = false
    /// Mode last set by the coach (the mode selector shows it in safelight).
    private(set) var coachMode: CaptureMode?
    /// Finished coach lines, newest last (go into the shot's `coach` meta).
    private(set) var lines: [String] = []
    private(set) var audio: LiveAudio?
    /// Round-trip stats for the settings sheet: token mint → live, last tool latency.
    private(set) var connectMs: Int?
    /// The latest Director answer for the current view (subject / target boxes, level) for the
    /// viewfinder overlay; nil after a scene shift until a fresh answer, and when the session ends.
    private(set) var direction: Direction?

    var voiceOn = true {
        didSet { audio?.isOutputMuted = !voiceOn }
    }

    @ObservationIgnored weak var host: CoachHost?
    @ObservationIgnored let frames = LiveFrameSink()
    @ObservationIgnored private var live: LiveSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var guideClear: Task<Void, Never>?
    @ObservationIgnored private var captionClear: Task<Void, Never>?
    @ObservationIgnored private var heardClear: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNotes: [String: String] = [:]
    @ObservationIgnored private var toolChain: Task<Void, Never>?
    @ObservationIgnored private var lastCameraChange = Date.distantPast
    @ObservationIgnored private var lastCoachPhoto = Date.distantPast
    @ObservationIgnored private var turnText = ""
    @ObservationIgnored private var heardText = ""
    @ObservationIgnored private var modelTurn = false
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var lastUserSpeech = Date.distantPast
    @ObservationIgnored private var lastTick = Date.distantPast
    @ObservationIgnored private var framesAtLastTick = -1
    // Scene drift (#30): which view the subject and "ready" were set on, and what changed since.
    @ObservationIgnored private var drift = SceneDrift()
    @ObservationIgnored private var subjectSetAt: Date?
    @ObservationIgnored private var viewChangedSinceSubject = false
    @ObservationIgnored private var readySetAt: Date?
    @ObservationIgnored private var readyLostToMove = false
    @ObservationIgnored private var pendingScene = false
    @ObservationIgnored private var sceneShiftForDirector = false
    @ObservationIgnored private var heardForDirector = ""
    @ObservationIgnored private var heardForDirectorAt = Date.distantPast
    @ObservationIgnored private var lastShiftAt: Date?
    /// The Director's last non-empty tip for this subject (it answers "" when unchanged).
    @ObservationIgnored private var lastTip = ""
    @ObservationIgnored private let readyHaptic = ReadyHaptic()
    /// One ready haptic per subject / ready framing: re-armed by set_intent or a scene shift.
    @ObservationIgnored private var readyHapticArmed = true
    @ObservationIgnored private var director: Director?
    @ObservationIgnored private var directionAtLastTick = 0

    static let tickInterval: TimeInterval = 4
    static let idleTickInterval: TimeInterval = 12
    /// After a mode, lens or zoom change the picture jumps; drift ignores it this long.
    static let opticsSettle: TimeInterval = 2
    /// What the user said stays in the Director's state this long.
    static let heardForDirectorTTL: TimeInterval = 20

    var isActive: Bool { phase == .live || phase == .connecting || phase == .reconnecting }

    // MARK: Lifecycle

    func start() async {
        guard !isActive, let client = host?.coachClient else { return }
        phase = .connecting
        let t0 = Date()
        let live = LiveSession()
        self.live = live
        frames.session = live
        let audio = self.audio ?? LiveAudio()
        self.audio = audio
        audio.isOutputMuted = !voiceOn
        eventsTask = Task { [weak self] in
            for await e in live.events { self?.handle(e) }
        }
        let micOK = await LiveAudio.requestMicrophoneAccess()
        if micOK { audio.attach(to: live) } else { live.audioOutput = audio }
        // No mic and no voice: nothing for the audio engine to do (captions still arrive).
        let useAudio = micOK || voiceOn
        do {
            // Mint + connect and audio-engine start overlap (~0.5 s and ~0.2 s).
            async let mic: Void = useAudio ? startAudio(audio) : ()
            try await live.start(liveToken: { try await client.liveToken(.camera(facing: .back, voice: true)) })
            await mic
            // `start` returns after setupComplete; don't wait for the queued status event.
            if self.live === live, phase == .connecting {
                phase = .live
                lastTick = Date().addingTimeInterval(-Self.tickInterval + 1.5)
            }
            connectMs = Int(Date().timeIntervalSince(t0) * 1000)
            #if DEBUG
            print("CoachCam[live] connected (token + setup) in \(connectMs ?? 0) ms")
            #endif
            startTicks()
        } catch {
            if self.live === live {
                phase = .failed(Self.describe(error))
                teardown()
            }
        }
    }

    private func startAudio(_ audio: LiveAudio) async {
        do { try await audio.start() } catch {
            // No audio (e.g. simulator without input): the coach still sees, acts and captions.
            print("CoachCam: audio unavailable: \(error)")
        }
    }

    func stop() {
        live?.stop()
        teardown()
        phase = .off
    }

    private func teardown() {
        tickTask?.cancel(); tickTask = nil
        toolChain = nil
        eventsTask?.cancel(); eventsTask = nil
        frames.session = nil
        audio?.stop()
        live = nil
        modelTurn = false
        guide = nil
        ready = false
        director?.stop(); director = nil
        directionAtLastTick = 0
        direction = nil
        drift.reset()
        subjectSetAt = nil
        viewChangedSinceSubject = false
        readySetAt = nil
        readyLostToMove = false
        pendingScene = false
        sceneShiftForDirector = false
        heardText = ""
        heardForDirector = ""
        heardForDirectorAt = .distantPast
        lastShiftAt = nil
        lastTip = ""
        readyHapticArmed = true
    }

    // MARK: Events

    private func handle(_ e: LiveEvent) {
        let now = Date()
        #if DEBUG
        trace(e)
        #endif
        switch e {
        case .status(let s):
            switch s {
            case .connecting: if phase != .live { phase = .connecting }
            case .live:
                phase = .live
                lastTick = now.addingTimeInterval(-Self.tickInterval + 1.5)   // first check-in soon
            case .reconnecting: phase = .reconnecting
            case .closed: if phase != .off { phase = .off }
            case .error(let m): phase = .failed(m); teardown()
            }
        case .toolCall(let id, let name, let argsJSON):
            lastActivity = now
            let args = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(argsJSON.utf8))) ?? [:]
            // Run tools in arrival order: "set_camera, take_photo" must shoot with the new settings.
            let previous = toolChain
            toolChain = Task { [weak self] in
                await previous?.value
                await self?.runTool(FunctionCall(id: id, name: name, args: args))
            }
        case .toolCallCancelled:
            break
        case .inputTranscript(let t):
            lastUserSpeech = now
            heardText += t
            showHeard(heardText)
        case .outputTranscript(let t):
            lastActivity = now
            modelTurn = true
            turnText += t
            showCaption(turnText)
        case .speaking(let on):
            lastActivity = now
            if on { modelTurn = true }
        case .interrupted, .turnComplete:
            lastActivity = now
            modelTurn = false
            endTurn()
        case .audio:
            break
        case .reconnected:
            phase = .live
            // gemini-3.8-live resumes without the turns so far: restate what matters.
            live?.sendContext(contextLine())
        }
    }

    private func endTurn() {
        let line = Self.spoken(turnText).trimmingCharacters(in: .whitespacesAndNewlines)
        turnText = ""
        heardText = ""
        if Self.isSpeech(line) {
            lines.append(line)
            if lines.count > 12 { lines.removeFirst(lines.count - 12) }
        }
        captionClear?.cancel()
        captionClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.caption = nil
        }
    }

    private func showCaption(_ raw: String) {
        let text = Self.spoken(raw)
        guard Self.isSpeech(text) else { return }      // "...", "-", "<no speech>" on quiet ticks
        captionClear?.cancel()
        caption = Self.tail(text, words: 7)
    }

    /// Drops transcription markup like `<no speech>` and `{pause}` (also while half-received).
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]*(>|$)|\{[^}]*(\}|$)"#, with: " ", options: .regularExpression)
    }

    /// True if the text has at least one letter or digit.
    static func isSpeech(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private func showHeard(_ text: String) {
        heard = Self.tail(text, words: 8)
        heardClear?.cancel()
        heardClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.heard = nil
        }
    }

    static func tail(_ text: String, words n: Int) -> String? {
        let w = text.split(whereSeparator: \.isWhitespace)
        guard !w.isEmpty else { return nil }
        return (w.count > n ? "…" : "") + w.suffix(n).joined(separator: " ")
    }

    // MARK: Tools

    /// Runs one camera tool and answers Gemini (`SILENT` for UI tools, `WHEN_IDLE` for photos
    /// and errors so the coach can react). Also used by the DEBUG demo script without a session.
    func runTool(_ call: FunctionCall) async {
        guard let tool = CameraTool(call) else {
            respond(call, ["ok": false, "error": "unknown tool or missing arguments"], .whenIdle)
            return
        }
        switch tool {
        case .guide(let d, let s):
            showGuide(d, s)
            respond(call, ["ok": true])
        case .setCamera(let settings):
            guard let host else { return }
            let optics = settings.mode != nil || settings.lens != nil || settings.zoom != nil
            if optics { settleDrift() }
            let applied = await host.coachSetCamera(settings)
            if optics { settleDrift() }     // counted from when the new optics are on the sensor
            lastCameraChange = Date()
            if let m = applied.mode { coachMode = m }
            var body: [String: Any] = ["ok": true]
            if let obj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(applied)) { body["applied"] = obj }
            if !applied.ignored.isEmpty { body["ignored"] = applied.ignored }
            respond(call, body, applied.ignored.isEmpty ? .silent : .whenIdle)
        case .setIntent(let i, let s):
            intent = i
            subject = s
            subjectSetAt = Date()
            viewChangedSinceSubject = false
            pendingScene = false
            lastTip = ""
            // While optics settle, anchor on the first settled frame instead.
            drift.anchorSubject(drift.isSettling ? nil : live?.latestSentThumbnail)
            readyHapticArmed = true
            readyHaptic.prepare()
            respond(call, ["ok": true])
        case .userReaction(let r, let h):
            reaction = r
            reactionID += 1
            if let h, !h.isEmpty { showHeard(h) }
            respond(call, ["ok": true])
        case .shotReady(let r):
            let wasReady = ready
            ready = r
            readyLostToMove = false
            if r {
                readySetAt = Date()
                drift.anchorReady(drift.isSettling ? nil : live?.latestSentThumbnail)
                if !wasReady, readyHapticArmed {
                    readyHapticArmed = false
                    readyHaptic.fire()
                }
            } else {
                drift.clearReady()
            }
            respond(call, ["ok": true])
        case .takePhoto(let reason):
            // Gemini sometimes asks twice in one exchange: one photo per 2.5 s.
            let since = Date().timeIntervalSince(lastCoachPhoto)
            if since < 2.5 {
                respond(call, ["ok": true, "note": String(format: "photo already taken %.1f s ago", since)])
                return
            }
            // Let exposure / white balance land on the sensor (a few frames) after a set_camera.
            let settle = 0.35 - Date().timeIntervalSince(lastCameraChange)
            if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
            lastCoachPhoto = Date()
            let result = await host?.coachTakePhoto(reason: reason) ?? ["ok": false, "error": "no camera"]
            respond(call, result, .whenIdle)
        }
    }

    private func respond(_ call: FunctionCall, _ result: [String: Any], _ scheduling: LiveScheduling = .silent) {
        guard let live, let id = call.id else { return }
        live.respond(to: id, name: call.name, result: result, scheduling: scheduling)
    }

    private func showGuide(_ d: GuideDirection, _ s: GuideStrength) {
        guide = d
        guideStrength = s
        guideClear?.cancel()
        guideClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(d == .hold ? 2.2 : 3.2))
            guard !Task.isCancelled else { return }
            self?.guide = nil
        }
    }

    /// After any capture: clear the ready state and tell the coach (no reply requested).
    func photoTaken(byCoach: Bool) {
        ready = false
        guide = nil
        readyLostToMove = false
        drift.clearReady()      // keep the subject anchor: a retake of the same subject is common
        live?.sendContext(byCoach ? "[app] Photo taken and saved." : "[user] Took a photo.")
    }

    /// The user's own dial change, sent as silent context after they settle (1.2 s).
    func noteUserChange(key: String, text: String) {
        if ["zoom", "lens", "mode"].contains(key) { settleDrift() }
        pendingNotes[key] = text
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, let live = self.live, self.phase == .live else { return }
            let changes = self.pendingNotes.values.sorted().joined(separator: ", ")
            self.pendingNotes = [:]
            live.sendContext("[user] changed \(changes). Camera now: \(self.host?.coachStateLine ?? "").")
        }
    }

    // MARK: Ticks

    private func startTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tickIfQuiet()
            }
        }
    }

    private func tickIfQuiet() {
        guard phase == .live, let live else { return }
        let now = Date()
        if !heardText.isEmpty { heardForDirector = heardText; heardForDirectorAt = now }
        ensureDirector(live)
        checkScene(live, now)
        let playing = audio?.isPlaying ?? false
        guard !modelTurn, !playing else { return }
        let sent = frames.sentCount
        // A scene shift gets one turn of its own instead of the routine tick.
        if pendingScene, now.timeIntervalSince(lastUserSpeech) >= 1.2 {
            pendingScene = false
            live.sendText(Self.sceneText)
            #if DEBUG
            print("CoachCam[live] +\(Int(now.timeIntervalSince(traceT0) * 1000))ms scene turn sent")
            #endif
            lastTick = now              // the next routine tick is ≥ 3 s away (4 s, or 3 s for a fresh direction)
            lastActivity = now
            framesAtLastTick = sent
            return
        }
        // The user spoke and the model stayed silent (proactive audio): nudge it.
        let unanswered = lastUserSpeech > lastActivity && lastUserSpeech > lastTick
            && now.timeIntervalSince(lastUserSpeech) >= 1.2
        let freshDirection = (director?.count ?? 0) != directionAtLastTick
            && !startedBefore(director?.latestStartedAt, lastShiftAt)
        let due = (now.timeIntervalSince(lastTick) >= Self.tickInterval
            && (sent != framesAtLastTick || now.timeIntervalSince(lastTick) >= Self.idleTickInterval))
            || (freshDirection && now.timeIntervalSince(lastTick) >= 3)
        let routine = due && now.timeIntervalSince(lastUserSpeech) >= 2 && now.timeIntervalSince(lastActivity) >= 1.5
        guard unanswered || routine else { return }
        var text = "[tick] " + contextBody()
        viewChangedSinceSubject = false     // one-shot: this tick carried it
        if freshDirection, let d = director?.latest { text += directorBlock(d, startedAt: director?.latestStartedAt) }
        directionAtLastTick = director?.count ?? 0
        live.sendText(text)
        #if DEBUG
        print("CoachCam[live] +\(Int(now.timeIntervalSince(traceT0) * 1000))ms tick sent (frames \(sent)): \(text)")
        #endif
        lastTick = now
        lastActivity = now
        framesAtLastTick = sent
    }

    /// `Mode: portrait. Camera: lens wide, …. Subject you last set: object "soda can" (14 s ago); view
    /// steady since. Shot ready: no.` Mode first, and the subject as what the coach last set.
    private func contextBody() -> String {
        let now = Date()
        let (mode, camera) = Self.splitMode(host?.coachStateLine ?? "")
        var s = "Mode: \(mode ?? "unknown"). Camera: \(camera)."
        if let intent {
            let ago = Int(now.timeIntervalSince(subjectSetAt ?? now).rounded())
            s += " Subject you last set: \(intent.rawValue)" + (subject.map { " \"\($0)\"" } ?? "") + " (\(ago) s ago); "
            s += viewChangedSinceSubject
                ? "the view has changed a lot since, check it is still the subject."
                : "view steady since."
        } else {
            s += " Subject: not set yet."
        }
        if ready {
            s += " Shot ready: yes (you said so \(Int(now.timeIntervalSince(readySetAt ?? now).rounded())) s ago)."
        } else {
            s += readyLostToMove ? " Shot ready: no (the view moved after you said ready)." : " Shot ready: no."
        }
        return s
    }

    private func contextLine() -> String {
        var s = "[state] Reconnected. " + contextBody()
        if !lines.isEmpty { s += " You said recently: " + lines.suffix(3).map { "\"\($0)\"" }.joined(separator: " ") }
        return s
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }

    #if DEBUG
    /// Demo/QA: show a coach line as if Gemini said it.
    func debugSay(_ text: String) {
        turnText = text
        showCaption(text)
        endTurn()
    }

    /// QA: send a typed user turn (launch argument `-coachPrompt`).
    func debugSend(_ text: String) {
        traceT0 = Date()
        print("CoachCam[live] +0ms prompt sent: \(text)")
        live?.sendText(text)
        lastActivity = Date()
    }

    @ObservationIgnored private var traceT0 = Date()

    /// Stdout trace for QA (`simctl launch --stdout=…`): event kind and ms since the prompt.
    private func trace(_ e: LiveEvent) {
        let ms = Int(Date().timeIntervalSince(traceT0) * 1000)
        switch e {
        case .status(let s): print("CoachCam[live] +\(ms)ms status \(s)")
        case .toolCall(_, let name, let args): print("CoachCam[live] +\(ms)ms tool \(name) \(args)")
        case .outputTranscript(let t): print("CoachCam[live] +\(ms)ms says \(t)")
        case .turnComplete: print("CoachCam[live] +\(ms)ms turnComplete")
        case .reconnected(let r): print("CoachCam[live] +\(ms)ms reconnected resumed=\(r)")
        case .audio(let d): if d.count > 0, !sawAudio { sawAudio = true; print("CoachCam[live] +\(ms)ms first audio") }
        default: break
        }
    }

    @ObservationIgnored private var sawAudio = false
    #endif

    // MARK: Scene drift and director (#30)

    static let sceneText = "[scene] The view changed completely in the last few seconds. If the camera now points at "
        + "a different subject, this is a new shot: call set_intent for it and drop the old advice. If it is the "
        + "same subject reframed (closer, lower, new angle), keep going."

    /// Splits `mode portrait, lens wide, …` into ("portrait", "lens wide, …").
    static func splitMode(_ line: String) -> (mode: String?, rest: String) {
        guard line.hasPrefix("mode ") else { return (nil, line) }
        let after = line.dropFirst(5)
        let mode = after.prefix { $0 != "," }
        let rest = after.dropFirst(mode.count).drop { $0 == "," || $0 == " " }
        return (String(mode), String(rest))
    }

    /// Feeds the newest sent frame's thumbnail to the drift detector (cheap: two 256-cell diffs).
    private func checkScene(_ live: LiveSession, _ now: Date) {
        guard let thumb = live.latestSentThumbnail,
              let event = drift.observe(thumb, at: now.timeIntervalSinceReferenceDate) else { return }
        switch event {
        case .shift(let mean, let changed):
            if ready { readyLostToMove = true }
            ready = false
            guide = nil
            guideClear?.cancel()
            if intent != nil { viewChangedSinceSubject = true }
            pendingScene = true
            sceneShiftForDirector = true
            lastShiftAt = now
            lastTip = ""
            heardForDirector = ""
            direction = nil
            readyHapticArmed = true
            director?.runNow()
            #if DEBUG
            print(String(format: "CoachCam[live] +%dms scene shift (mean %.3f, changed %.2f)",
                         Int(now.timeIntervalSince(traceT0) * 1000), mean, changed))
            #endif
        case .moved(let mean, let changed):
            guard ready else { return }
            ready = false
            readyLostToMove = true
            #if DEBUG
            print(String(format: "CoachCam[live] +%dms moved off the ready framing (mean %.3f, changed %.2f)",
                         Int(now.timeIntervalSince(traceT0) * 1000), mean, changed))
            #endif
        }
    }

    /// Starts the director loop for this live session (it stops itself when the session ends).
    private func ensureDirector(_ live: LiveSession) {
        guard director?.live !== live, let client = host?.coachClient else { return }
        director?.stop()
        directionAtLastTick = 0
        let d = Director(live: live, client: client) { [weak self, weak live] in
            guard let self, let live, self.live === live, self.isActive else { return nil }
            return self.directorState()
        }
        d.onAnswer = { [weak self] answer, startedAt in self?.directorAnswered(answer, startedAt: startedAt) }
        director = d
        d.start()
    }

    /// True if a request that started at `start` predates `event` (its frame is from before it).
    private func startedBefore(_ start: Date?, _ event: Date?) -> Bool {
        guard let event else { return false }
        guard let start else { return true }
        return start < event
    }

    /// A Director answer arrived. Answers for frames from before the last shift are ignored here
    /// (the tick drops them too); the overlay and the tip memory follow the current view only.
    private func directorAnswered(_ d: Direction, startedAt: Date) {
        guard !startedBefore(startedAt, lastShiftAt) else { return }
        direction = d
        if lastShiftAt != nil, d.newShot == false { viewChangedSinceSubject = false }
        if let tip = d.tip?.trimmingCharacters(in: .whitespacesAndNewlines), !tip.isEmpty,
           !startedBefore(startedAt, subjectSetAt) {
            lastTip = tip
        }
    }

    /// Mode, lens or zoom changed: the picture jumps without a new scene. Drift re-anchors after.
    private func settleDrift() {
        drift.settle(until: Date().addingTimeInterval(Self.opticsSettle).timeIntervalSinceReferenceDate)
    }

    private func directorState() -> [String: Any] {
        let line = host?.coachStateLine ?? ""
        let shift = sceneShiftForDirector
        sceneShiftForDirector = false
        let heard = Date().timeIntervalSince(heardForDirectorAt) <= Self.heardForDirectorTTL ? heardForDirector : ""
        return [
            "mode": Self.splitMode(line).mode ?? "",
            "state_line": line,
            "intent": intent?.rawValue ?? "",
            "subject": subject ?? "",
            "last_move": director?.latest?.move ?? "",
            "last_tip": lastTip,
            "ready": ready,
            "scene_shift": shift,
            "heard": heard,
        ]
    }

    /// ` Director (Gemini 4, latest frame): shot object "soda can", score 6/10; issues: …; next move: …`
    /// "(NEW shot)" only when the request started after the subject was last set: an older answer
    /// compares against the previous subject and would trigger a second set_intent.
    private func directorBlock(_ d: Direction, startedAt: Date?) -> String {
        let current = Self.splitMode(host?.coachStateLine ?? "").mode
        var s = " Director (Gemini 4, latest frame): shot \(d.intent ?? "other") \"\(d.subject ?? "")\""
        if d.newShot == true, !startedBefore(startedAt, subjectSetAt) { s += " (NEW shot)" }
        s += ", score \(d.score.map(String.init) ?? "?")/10"
        s += "; issues: " + ((d.issues ?? []).isEmpty ? "none" : (d.issues ?? []).joined(separator: "; "))
        s += "; next move: \(d.move ?? "hold") (\(d.strength ?? "small"))"
        s += "; best mode: \(d.mode ?? current ?? "photo")"
        if let m = d.mode, let current, m != current { s += " (now \(current))" }
        s += "; ready: \(d.ready == true ? "yes" : "no"); tip: \"\(d.tip ?? "")\"."
        if d.ready == true { readyHaptic.prepare() }
        return s
    }
}

/// Hands camera frames to the Live session from the video queue. `LiveSession.sendFrame` is
/// thread-safe and returns immediately unless a frame is due (≥1 s) and the picture changed.
final class LiveFrameSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private weak var _session: LiveSession?
    private var _sent = 0

    var session: LiveSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    /// Frames actually sent to Gemini in this session.
    var sentCount: Int { lock.withLock { _sent } }

    func offer(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard let s = session else { return }
        if s.sendFrame(pixelBuffer: pixelBuffer, orientation: orientation) == .sent { lock.withLock { _sent += 1 } }
    }

    func offer(cgImage: CGImage) {
        guard let s = session else { return }
        if s.sendFrame(cgImage: cgImage) == .sent { lock.withLock { _sent += 1 } }
    }
}
