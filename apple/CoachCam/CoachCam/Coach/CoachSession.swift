import AVFoundation
import CoachAPI
import CoachLive
import CoachModels
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Observation
import os
import UIKit

/// What the coach needs from the app: the camera and the shutter.
@MainActor
protocol CoachHost: AnyObject {
    /// `[state]` line: mode, lens, zoom, ISO, shutter, EV, focus, WB.
    var coachStateLine: String { get }
    /// Applies `set_camera` on the hardware, animates the dials, returns what was applied.
    func coachSetCamera(_ settings: CameraSettings) async -> CameraSettings
    /// Takes and syncs a photo; returns the tool result.
    func coachTakePhoto(reason: String?) async -> [String: Any]
}

/// The live camera coach, entirely on the phone: an agent loop on Gemini 4 (`GeminiDirect`,
/// function calling). While it runs it takes the newest viewfinder frame plus the camera state,
/// asks `GeminiDirect.fastModel` what to do, runs the tool calls it returns (glow the border,
/// roll the dials, set the shot, mark it ready), answers with the results and lets it continue
/// for at most `maxSteps` model calls. Then it waits for the next frame. One request in flight,
/// a short history (system prompt + the last 2 exchanges), no cycle while the picture is still,
/// quiet once the shot is ready until the scene changes or the user speaks.
@MainActor
@Observable
final class CoachSession {
    enum Phase: Equatable {
        case off, connecting, live, reconnecting
        case failed(String)
    }

    private(set) var phase: Phase = .off
    /// Always nil: the coach is heard, never read (kept for the UI's existing hooks).
    private(set) var caption: String?
    /// Always nil (no on-screen transcript).
    private(set) var heard: String?
    /// The user's last utterance (kept; goes into the instant review's context).
    private(set) var lastHeard: String?
    private(set) var guide: GuideDirection?
    private(set) var guideStrength: GuideStrength = .medium
    private(set) var intent: ShotIntent?
    private(set) var subject: String?
    private(set) var reaction: UserReaction?
    /// Bumps on every `user_reaction` so the wash replays.
    private(set) var reactionID = 0
    private(set) var ready = false
    /// Mode last set by the coach (the mode selector shows it in safelight).
    private(set) var coachMode: CoachModels.CaptureMode?
    /// Finished coach lines, newest last (go into the shot's `coach` meta).
    private(set) var lines: [String] = []
    /// The mic (on-device speech recognition) while the coach runs with voice on.
    private(set) var audio: Listener?
    /// Latency of the last model call (settings sheet).
    private(set) var connectMs: Int?

    /// Voice mode (the mic key): the mic listens and the coach speaks. Off: both quiet.
    var voiceOn = true {
        didSet { applyVoice() }
    }

    @ObservationIgnored weak var host: CoachHost?
    @ObservationIgnored let frames = AgentFrameSink()

    @ObservationIgnored private let log = Logger(subsystem: "app.heliocam.CoachCam", category: "Coach")
    @ObservationIgnored private var gemini: GeminiDirect?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var fastLoop: Task<Void, Never>?
    // Fast inner loop (Gemini Decision 1): edge glow from `move`, "that's it" from `ready`.
    @ObservationIgnored private var lastMove: String?
    @ObservationIgnored private var readyStreak = 0
    @ObservationIgnored private var saidReady = false
    @ObservationIgnored private var pendingClip: Data?
    @ObservationIgnored private var decideBackoffUntil = Date.distantPast
    @ObservationIgnored private var guideClear: Task<Void, Never>?
    @ObservationIgnored private var history: [[JSONValue]] = []
    @ObservationIgnored private var pendingUser: String?
    @ObservationIgnored private var pendingNotes: [String] = []
    @ObservationIgnored private var lastSentThumb: LumaThumbnail?
    @ObservationIgnored private var lastSentCount = 0
    @ObservationIgnored private var lastCycleEnd = Date.distantPast
    @ObservationIgnored private var backoffUntil = Date.distantPast
    @ObservationIgnored private var lastCameraChange = Date.distantPast
    @ObservationIgnored private var lastCoachPhoto = Date.distantPast
    @ObservationIgnored private var lastSpoken = ""
    // Scene drift (#30): which view the subject and "ready" were set on, and what changed since.
    @ObservationIgnored private var drift = SceneDrift()
    @ObservationIgnored private var subjectSetAt: Date?
    @ObservationIgnored private var viewChangedSinceSubject = false
    @ObservationIgnored private var readySetAt: Date?
    @ObservationIgnored private var readyLostToMove = false
    @ObservationIgnored private var sceneChanged = false
    @ObservationIgnored private let readyHaptic = ReadyHaptic()
    @ObservationIgnored private var readyHapticArmed = true

    /// Model calls per frame (the first answer plus up to two follow-ups after tool results).
    static let maxSteps = 3
    /// Exchanges kept in the history besides the current one.
    static let keptExchanges = 2
    static let errorBackoff: TimeInterval = 5
    /// Fast loop: one Decision call about every second.
    static let decideInterval: Duration = .milliseconds(1000)
    /// `move` drives the glow at p ≥ this when the top answer repeats; `ready` counts at p ≥ readyP.
    static let moveP = 0.4
    static let readyP = 0.7
    /// Minimum gap between cycles, and the re-check while nothing moves (not ready yet).
    static let minGap: TimeInterval = 0.8
    static let stillRecheck: TimeInterval = 10
    /// After a mode, lens or zoom change the picture jumps; drift ignores it this long.
    static let opticsSettle: TimeInterval = 2

    var isActive: Bool { phase == .live || phase == .connecting || phase == .reconnecting }

    // MARK: Lifecycle

    func start() async {
        guard !isActive else { return }
        guard let key = GeminiDirect.keyFromBundle() else {
            log.error("coach can't start: \(GeminiDirect.Failure.noKey.localizedDescription, privacy: .public)")
            phase = .failed(GeminiDirect.Failure.noKey.localizedDescription)
            return
        }
        gemini = GeminiDirect(apiKey: key)
        frames.enabled = true
        phase = .live
        log.info("coach on: \(GeminiDirect.fastModel, privacy: .public), agent loop")
        applyVoice()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
        fastLoop = Task { [weak self] in
            while !Task.isCancelled {
                let t0 = ContinuousClock.now
                guard let self, !Task.isCancelled else { return }
                await self.decideTick()
                let left = Self.decideInterval - (ContinuousClock.now - t0)
                if left > .zero { try? await Task.sleep(for: left) }
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        fastLoop?.cancel(); fastLoop = nil
        lastMove = nil
        readyStreak = 0
        saidReady = false
        pendingClip = nil
        frames.enabled = false
        audio?.stop()
        Speaker.shared.stop()
        gemini = nil
        history = []
        pendingUser = nil
        pendingNotes = []
        lastSentThumb = nil
        guide = nil
        ready = false
        drift.reset()
        subjectSetAt = nil
        viewChangedSinceSubject = false
        readySetAt = nil
        readyLostToMove = false
        sceneChanged = false
        readyHapticArmed = true
        phase = .off
    }

    /// The mic: listens (on-device) while voice is on and the coach runs.
    private func applyVoice() {
        if voiceOn, phase == .live {
            let listener = audio ?? Listener()
            listener.onUtterance = { [weak self] text, clip in
                self?.pendingClip = clip
                self?.userSaid(text)
            }
            audio = listener
            if !listener.isRunning { Task { await listener.start() } }
        } else {
            audio?.stop()
            Speaker.shared.stop()
        }
    }

    /// The mic key while live but the engine is down: start it again.
    func restartAudio() async {
        guard let audio, phase == .live else { return }
        audio.stop()
        await audio.start()
    }

    /// The instant review's line, spoken by the coach's voice. False when voice is off.
    func speakReview(_ line: String, verdict: String?) -> Bool {
        guard voiceOn else { return false }
        Speaker.shared.say(line)
        return true
    }

    /// Core's TTS PCM is no longer used on the phone; the review speaks through `Speaker`.
    func playSpeech(pcm24k: Data) async {
        log.notice("playSpeech(pcm24k:) ignored (\(pcm24k.count) bytes): the coach speaks through Speaker")
    }

    private func userSaid(_ text: String) {
        lastHeard = String(text.suffix(200))
        pendingUser = text
        Speaker.shared.stop()
        log.info("heard: \(text, privacy: .public)")
    }

    // MARK: Loop

    private func tick() async {
        guard phase == .live, let gemini else { return }
        let now = Date()
        guard let frame = frames.latest else { return }
        checkScene(frame.thumb, now)
        guard now >= backoffUntil, now.timeIntervalSince(lastCycleEnd) >= Self.minGap else { return }

        let user = pendingUser
        let changed = lastSentThumb.map { Self.changed($0, frame.thumb) } ?? true
        let due: Bool
        if user != nil || sceneChanged {
            due = true
        } else if ready {
            due = false                 // "that's it": quiet until the view moves or the user speaks
        } else {
            due = (changed && frame.count != lastSentCount)
                || now.timeIntervalSince(lastCycleEnd) >= Self.stillRecheck
        }
        guard due else { return }

        pendingUser = nil
        let scene = sceneChanged
        sceneChanged = false
        lastSentThumb = frame.thumb
        lastSentCount = frame.count
        do {
            try await cycle(gemini, frame: frame, user: user, scene: scene)
        } catch is CancellationError {
            return
        } catch {
            log.error("coach turn failed, backing off \(Self.errorBackoff)s: \(Self.describe(error), privacy: .public)")
            backoffUntil = Date().addingTimeInterval(Self.errorBackoff)
            history = []        // a broken exchange must not poison the next request
        }
        lastCycleEnd = Date()
    }

    /// One frame: up to `maxSteps` model calls, running every tool call in between.
    private func cycle(_ gemini: GeminiDirect, frame: AgentFrameSink.Frame, user: String?, scene: Bool) async throws {
        let started = Date()
        var turn: [JSONValue] = [GeminiDirect.user([
            GeminiDirect.text(stateText(user: user, scene: scene)),
            GeminiDirect.image(frame.jpeg, resolution: "MEDIA_RESOLUTION_LOW"),
        ])]
        let options = GeminiDirect.Options(system: CoachBrain.system, functions: CoachBrain.tools, thinking: "low")
        var calls: [String] = []
        var spoke = false
        let wasReady = ready
        for step in 0..<Self.maxSteps {
            let reply = try await gemini.generate(model: GeminiDirect.fastModel,
                                                  contents: Self.flatten(history) + turn, options: options)
            try Task.checkCancellation()
            guard phase == .live else { return }
            if step == 0 { connectMs = reply.milliseconds }
            turn.append(reply.content)      // unchanged: keeps the thought signatures
            if speak(reply.text) { spoke = true }
            guard !reply.calls.isEmpty else { break }
            var responses: [JSONValue] = []
            for c in reply.calls {
                calls.append(c.name)
                let result = await runTool(FunctionCall(id: c.id, name: c.name, args: c.args))
                responses.append(GeminiDirect.functionResponse(name: c.name, id: c.id, response: Self.json(result)))
            }
            turn.append(GeminiDirect.user(responses))
            // Done when it only did UI moves; set_camera/take_photo results may need a follow-up.
            // Only a spoken request earns a follow-up call; otherwise the next frame continues (keeps turns ~3 s).
            if user == nil || !reply.calls.contains(where: { $0.name == "set_camera" || $0.name == "take_photo" }) { break }
        }
        // Converged: always say "that's it" once, even if the model only called the tools.
        if ready, !wasReady, !spoke, !saidReady { speak("That's it. Take it.") }
        if ready { saidReady = true }
        history.append(Self.strippingImages(turn))
        if history.count > Self.keptExchanges { history.removeFirst(history.count - Self.keptExchanges) }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("coach turn \(ms) ms (first call \(self.connectMs ?? 0) ms): \(calls.joined(separator: ", "), privacy: .public)")
    }

    // MARK: Fast loop (Gemini Decision 1, ~0.8 s)

    /// One Decision call on the newest frame: `move` → edge glow (p ≥ 0.5, same top answer twice),
    /// `ready` high twice → "that's it" once and quiet, `reaction` only with a fresh voice clip.
    private func decideTick() async {
        guard phase == .live, let gemini, Date() >= decideBackoffUntil, let frame = frames.latest else { return }
        let clip = pendingClip
        // Quiet once ready: nothing to glow or say until the view moves (drift) or the user speaks.
        guard !ready || clip != nil else { return }
        pendingClip = nil
        var input: [JSONValue] = [
            GeminiDirect.decisionText(decisionContext()),
            GeminiDirect.decisionImage(frame.jpeg, resolution: "low"),
        ]
        var questions = ["move": CoachBrain.move, "ready": CoachBrain.ready]
        if let clip {
            input.append(GeminiDirect.decisionText("The last few seconds of the user's voice:"))
            input.append(GeminiDirect.decisionAudio(clip))
            questions["reaction"] = CoachBrain.reaction
        }
        let d: GeminiDirect.Decision
        do {
            d = try await gemini.decide(input: input, questions: questions)
        } catch is CancellationError {
            return
        } catch {
            log.error("decision failed, backing off \(Self.errorBackoff)s: \(Self.describe(error), privacy: .public)")
            decideBackoffUntil = Date().addingTimeInterval(Self.errorBackoff)
            return
        }
        guard phase == .live, !Task.isCancelled else { return }
        decided(d)
    }

    private func decided(_ d: GeminiDirect.Decision) {
        let move = d.top("move")
        let readyP = d.probabilities["ready"]?["yes"] ?? 0
        log.info("decision \(d.milliseconds) ms: move \(move?.option ?? "-", privacy: .public) \(move?.p ?? 0) ready \(readyP)")
        if let r = d.top("reaction"), r.p >= Self.moveP, r.option != "neutral",
           let reaction = UserReaction(rawValue: r.option) {
            self.reaction = reaction
            reactionID += 1
        }
        // Ready twice in a row: "that's it" once, then quiet.
        readyStreak = readyP >= Self.readyP ? readyStreak + 1 : 0
        if readyStreak >= 2, !ready {
            ready = true
            readyLostToMove = false
            readySetAt = Date()
            drift.anchorReady(drift.isSettling ? nil : frames.latest?.thumb)
            showGuide(.hold, .small)
            if readyHapticArmed {
                readyHapticArmed = false
                readyHaptic.fire()
            }
            if !saidReady {
                saidReady = true
                speak("That's it.")
            }
            lastMove = nil
            return
        }
        if readyStreak == 1 { readyHaptic.prepare() }
        // The glow follows `move` once the top answer is stable across two answers.
        guard let move, move.p >= Self.moveP else { lastMove = nil; return }
        if move.option == lastMove, let dir = GuideDirection(rawValue: move.option) {
            showGuide(dir, move.p >= 0.8 ? .large : .medium)
        }
        lastMove = move.option
    }

    /// The state line for the Decision call (no side effects on the agent's one-shot flags).
    private func decisionContext() -> String {
        let (mode, camera) = Self.splitMode(host?.coachStateLine ?? "")
        var s = "Capture mode: \(mode ?? "unknown"). Camera: \(camera)."
        if let intent { s += " Subject: \(intent.rawValue)" + (subject.map { " \"\($0)\"" } ?? "") + "." }
        if let heard = lastHeard { s += " The user last said: \"\(heard)\"." }
        return s
    }

    @discardableResult
    private func speak(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSpeech(text), text != lastSpoken else { return false }
        lastSpoken = text
        lines.append(text)
        if lines.count > 12 { lines.removeFirst(lines.count - 12) }
        if voiceOn { Speaker.shared.say(text) }
        return true
    }

    /// The text part of the turn: the camera state, what changed, what the user said.
    private func stateText(user: String?, scene: Bool) -> String {
        let now = Date()
        let (mode, camera) = Self.splitMode(host?.coachStateLine ?? "")
        var s = "Capture mode: \(mode ?? "unknown"). Camera: \(camera)."
        if let intent {
            let ago = Int(now.timeIntervalSince(subjectSetAt ?? now).rounded())
            s += " Subject you last set: \(intent.rawValue)" + (subject.map { " \"\($0)\"" } ?? "") + " (\(ago) s ago); "
            s += viewChangedSinceSubject
                ? "the view has changed a lot since: check it is still the subject."
                : "view steady since."
        } else {
            s += " Subject: not set yet (call set_intent)."
        }
        if ready {
            s += " Shot ready: yes."
        } else {
            s += readyLostToMove ? " Shot ready: no (the view moved off the ready framing)." : " Shot ready: no."
        }
        if scene {
            s += " The view changed completely: if it is a different subject, this is a NEW shot (set_intent, drop the old advice)."
        }
        if !pendingNotes.isEmpty {
            s += " Since last turn: " + pendingNotes.joined(separator: "; ") + "."
            pendingNotes = []
        }
        if let user {
            s += " The user said: \"\(user)\". Answer with tools and a few spoken words."
        }
        viewChangedSinceSubject = false     // one-shot: this turn carried it
        return s
    }

    static func flatten(_ history: [[JSONValue]]) -> [JSONValue] {
        var out: [JSONValue] = []
        for exchange in history {
            for turn in exchange {
                // A trailing functionResponse turn followed by the next user turn: merge them so
                // the roles keep alternating.
                if case .object(let t) = turn, t["role"]?.stringValue == "user",
                   case .object(var last)? = out.last, last["role"]?.stringValue == "user",
                   case .array(let a)? = last["parts"], case .array(let b)? = t["parts"] {
                    last["parts"] = .array(a + b)
                    out[out.count - 1] = .object(last)
                } else {
                    out.append(turn)
                }
            }
        }
        return out
    }

    /// History keeps the text, calls and signatures but not old frames (latency).
    static func strippingImages(_ turns: [JSONValue]) -> [JSONValue] {
        turns.map { turn in
            guard case .object(var t) = turn, t["role"]?.stringValue == "user",
                  case .array(let parts)? = t["parts"] else { return turn }
            t["parts"] = .array(parts.map { p in
                if case .object(let o) = p, o["inlineData"] != nil { return GeminiDirect.text("[earlier frame]") }
                return p
            })
            return .object(t)
        }
    }

    static func json(_ dict: [String: Any]) -> JSONValue {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object(["ok": .bool(dict["ok"] as? Bool ?? true)])
        }
        return v
    }

    /// True when the picture moved enough to be worth a new look.
    static func changed(_ a: LumaThumbnail, _ b: LumaThumbnail) -> Bool {
        let d = a.difference(to: b)
        return d.mean > 0.035 || d.changedFraction > 0.12
    }

    /// Drops transcription markup like `<no speech>` and `{pause}` (also while half-received).
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]*(>|$)|\{[^}]*(\}|$)"#, with: " ", options: .regularExpression)
    }

    /// True if the text has at least one letter or digit.
    static func isSpeech(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }

    /// Splits `mode portrait, lens wide, …` into ("portrait", "lens wide, …").
    static func splitMode(_ line: String) -> (mode: String?, rest: String) {
        guard line.hasPrefix("mode ") else { return (nil, line) }
        let after = line.dropFirst(5)
        let mode = after.prefix { $0 != "," }
        let rest = after.dropFirst(mode.count).drop { $0 == "," || $0 == " " }
        return (String(mode), String(rest))
    }

    // MARK: Tools

    /// Runs one camera tool and returns its result for the model. Also used by the DEBUG demo
    /// script without a session.
    @discardableResult
    func runTool(_ call: FunctionCall) async -> [String: Any] {
        guard let tool = CameraTool(call) else {
            log.error("unknown tool or bad arguments: \(call.name, privacy: .public)")
            return ["ok": false, "error": "unknown tool or missing arguments"]
        }
        switch tool {
        case .guide(let d, let s):
            showGuide(d, s)
            return ["ok": true]
        case .setCamera(let settings):
            guard let host else { return ["ok": false, "error": "no camera"] }
            let optics = settings.mode != nil || settings.lens != nil || settings.zoom != nil
            if optics { settleDrift() }
            let applied = await host.coachSetCamera(settings)
            if optics { settleDrift() }     // counted from when the new optics are on the sensor
            lastCameraChange = Date()
            if let m = applied.mode { coachMode = m }
            var body: [String: Any] = ["ok": true]
            if let obj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(applied)) { body["applied"] = obj }
            if !applied.ignored.isEmpty { body["ignored"] = applied.ignored }
            return body
        case .setIntent(let i, let s):
            intent = i
            subject = s
            subjectSetAt = Date()
            viewChangedSinceSubject = false
            // While optics settle, anchor on the first settled frame instead.
            drift.anchorSubject(drift.isSettling ? nil : frames.latest?.thumb)
            readyHapticArmed = true
            readyHaptic.prepare()
            return ["ok": true]
        case .userReaction(let r, _):
            reaction = r
            reactionID += 1
            return ["ok": true]
        case .shotReady(let r):
            let wasReady = ready
            ready = r
            readyLostToMove = false
            if r {
                readySetAt = Date()
                drift.anchorReady(drift.isSettling ? nil : frames.latest?.thumb)
                if !wasReady, readyHapticArmed {
                    readyHapticArmed = false
                    readyHaptic.fire()
                }
            } else {
                drift.clearReady()
                saidReady = false
                readyStreak = 0
            }
            return ["ok": true]
        case .takePhoto(let reason):
            // One photo per 2.5 s.
            let since = Date().timeIntervalSince(lastCoachPhoto)
            if since < 2.5 { return ["ok": true, "note": String(format: "photo already taken %.1f s ago", since)] }
            // Let exposure / white balance land on the sensor after a set_camera.
            let settle = 0.35 - Date().timeIntervalSince(lastCameraChange)
            if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
            lastCoachPhoto = Date()
            return await host?.coachTakePhoto(reason: reason) ?? ["ok": false, "error": "no camera"]
        }
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

    /// After any capture: clear the ready state and tell the coach next turn.
    func photoTaken(byCoach: Bool) {
        ready = false
        saidReady = false
        readyStreak = 0
        guide = nil
        readyLostToMove = false
        drift.clearReady()      // keep the subject anchor: a retake of the same subject is common
        pendingNotes.append(byCoach ? "photo taken and saved" : "the user took a photo")
    }

    /// The user's own dial change, noted for the next turn.
    func noteUserChange(key: String, text: String) {
        if ["zoom", "lens", "mode"].contains(key) { settleDrift() }
        pendingNotes.removeAll { $0.hasPrefix("user changed \(key)") }
        pendingNotes.append("user changed \(key): \(text)")
    }

    // MARK: Scene drift (#30)

    private func checkScene(_ thumb: LumaThumbnail, _ now: Date) {
        guard let event = drift.observe(thumb, at: now.timeIntervalSinceReferenceDate) else { return }
        switch event {
        case .shift(let mean, let changed):
            if ready { readyLostToMove = true }
            ready = false
            saidReady = false
            readyStreak = 0
            lastMove = nil
            guide = nil
            guideClear?.cancel()
            if intent != nil { viewChangedSinceSubject = true }
            sceneChanged = true
            readyHapticArmed = true
            log.info("scene shift (mean \(mean), changed \(changed))")
        case .moved:
            guard ready else { return }
            ready = false
            saidReady = false
            readyStreak = 0
            readyLostToMove = true
            sceneChanged = true
        }
    }

    private func settleDrift() {
        drift.settle(until: Date().addingTimeInterval(Self.opticsSettle).timeIntervalSinceReferenceDate)
    }

    #if DEBUG
    /// Demo/QA: speak a coach line as if Gemini said it.
    func debugSay(_ text: String) { speak(text) }

    /// Demo/QA: treat text as the user's words.
    func debugHeard(_ text: String) { userSaid(text) }

    /// QA: send a typed user turn (launch argument `-coachPrompt`).
    func debugSend(_ text: String) { userSaid(text) }
    #endif
}

/// The "shot ready" moment: a success haptic, at most once per 3 s. Kept prepared so it lands on time.
/// `CoachSession` also fires it only once per subject (re-armed by set_intent or a scene shift).
@MainActor
final class ReadyHaptic {
    private let generator = UINotificationFeedbackGenerator()
    private var last = Date.distantPast

    func prepare() { generator.prepare() }

    func fire() {
        let now = Date()
        guard now.timeIntervalSince(last) >= 3 else { return }
        last = now
        generator.notificationOccurred(.success)
        generator.prepare()
    }
}
