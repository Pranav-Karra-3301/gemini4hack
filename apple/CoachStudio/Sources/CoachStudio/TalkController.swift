import Foundation
import Observation
import CoachAPI
import CoachLive
import CoachModels
import CoachUI

/// "Talk": an edit-mode Gemini Live session for the open shot. Core mints the token with the
/// shot's regions, scores, depth summary, plan and current sliders baked into the prompt; audio
/// goes straight to Google. Gemini drives the sliders through `edit_step` / `set_sliders` /
/// `select_region` / `compare` / `reset` / `save_edit`, and each tool is answered with the values
/// actually applied once the slider has landed.
@MainActor
@Observable
final class TalkController {
    enum State: Equatable {
        case idle, connecting, live, reconnecting, failed(String)
    }

    private(set) var state: State = .idle
    /// What the user said / typed, and what the coach said, in the current exchange.
    private(set) var userLine = ""
    private(set) var coachLine = ""
    private(set) var coachSpeaking = false
    private(set) var micAllowed = true
    /// Tool calls handled this session, and the last one (for the HUD).
    private(set) var toolCount = 0
    private(set) var lastTool: String?
    /// ms from start() to setupComplete.
    private(set) var connectMs: Int?

    private(set) var audio: LiveAudio?
    @ObservationIgnored private var session: LiveSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// Tool calls run one after another (each waits for its glide), in arrival order.
    @ObservationIgnored private var toolChain: Task<Void, Never>?
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var lineDone = false
    @ObservationIgnored private weak var editor: EditorModel?
    @ObservationIgnored private var lastContext = ""

    var isActive: Bool { state != .idle && !isFailed }
    var isFailed: Bool { if case .failed = state { return true } else { return false } }

    func toggle(editor: EditorModel) {
        if isActive { stop() } else { start(editor: editor) }
    }

    func start(editor: EditorModel) {
        guard !isActive else { return }
        self.editor = editor
        state = .connecting
        userLine = ""; coachLine = ""; toolCount = 0; lastTool = nil
        let session = LiveSession()
        self.session = session
        let useAudio = StudioAutomation.talkMic
        let audio: LiveAudio? = useAudio ? LiveAudio() : nil
        self.audio = audio
        audio?.attach(to: session)
        let client = editor.client
        let shotID = editor.shotID
        let t0 = Date()
        // Reads the editor's state at mint time (also on re-mints after a reconnect).
        let mintToken: @Sendable () async throws -> LiveTokenResponse = { [weak editor] in
            let current = editor
            let (values, subject) = await MainActor.run { () -> ([String: Double]?, String?) in
                guard let e = current else { return (nil, nil) }
                return (SliderValues.named(e.sliders.values), e.subject)
            }
            return try await client.liveToken(.edit(shotId: shotID, values: values, subject: subject))
        }
        eventsTask = Task { [weak self] in
            for await ev in session.events { self?.handle(ev) }
        }
        Task {
            micAllowed = useAudio ? await LiveAudio.requestMicrophoneAccess() : false
            do {
                try await session.start(liveToken: mintToken)
                connectMs = Int(Date().timeIntervalSince(t0) * 1000)
                if micAllowed, let audio {
                    do { try await audio.start() } catch {
                        micAllowed = false
                    }
                }
                lastContext = editor.stateSummary()
                if let text = StudioAutomation.talkText, !text.isEmpty {
                    send(text: text)
                }
            } catch {
                state = .failed(describe(error))
                cleanup()
            }
        }
    }

    func stop() {
        session?.stop()
        cleanup()
        state = .idle
        coachSpeaking = false
    }

    private func cleanup() {
        audio?.stop()
        audio = nil
        session = nil
        contextTask?.cancel()
        // eventsTask ends when the stream finishes.
    }

    /// A typed request ("make it warmer"), for quiet rooms or no mic.
    func send(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let session else { return }
        newExchangeIfNeeded()
        userLine = t
        session.sendText(t)
    }

    /// The user moved a slider while talking: tell the coach (debounced) so it can react to it.
    func userEdited() {
        guard state == .live, let editor else { return }
        contextTask?.cancel()
        contextTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self, let session = self.session else { return }
            let s = editor.stateSummary()
            guard s != self.lastContext else { return }
            self.lastContext = s
            session.sendContext("[sliders] " + s)
        }
    }

    // MARK: Events

    private func handle(_ ev: LiveEvent) {
        if StudioAutomation.snapshotDir != nil {  // QA trace: event kinds and timing only
            let kind = String(String(describing: ev).prefix(60)).replacingOccurrences(of: "\n", with: " ")
            let line = String(format: "[talk %.2f] ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + kind + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        switch ev {
        case .status(let s):
            switch s {
            case .connecting: state = .connecting
            case .live: state = .live
            case .reconnecting: state = .reconnecting
            case .closed: if !isFailed { state = .idle }
            case .error(let m): state = .failed(m); cleanup()
            }
        case .toolCall(let id, let name, let argsJSON):
            toolCount += 1
            lastTool = name
            let prev = toolChain
            toolChain = Task { [weak self] in
                await prev?.value
                await self?.run(id: id, name: name, argsJSON: argsJSON)
            }
        case .toolCallCancelled:
            break  // slider moves are cheap to keep; the coach will correct itself
        case .inputTranscript(let t):
            newExchangeIfNeeded()
            userLine += t
        case .outputTranscript(let t):
            if lineDone { coachLine = ""; lineDone = false }
            coachLine += t
        case .speaking(let on):
            coachSpeaking = on
        case .interrupted:
            coachSpeaking = false
        case .turnComplete:
            lineDone = true
            coachSpeaking = false
        case .audio:
            break
        case .reconnected:
            state = .live
            if let editor { session?.sendContext("[sliders] " + editor.stateSummary()) }
        }
    }

    private func newExchangeIfNeeded() {
        if lineDone { userLine = ""; coachLine = ""; lineDone = false }
    }

    private func run(id: String, name: String, argsJSON: String) async {
        guard let session else { return }
        let args = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(argsJSON.utf8))) ?? [:]
        let call = FunctionCall(id: id, name: name, args: args)
        guard let editor, let tool = EditTool(call) else {
            session.respond(to: id, name: name, result: ["ok": false, "error": "unknown tool or bad arguments: \(argsJSON.prefix(200))"],
                            scheduling: .whenIdle)
            return
        }
        // A spoken edit takes over from a running guide.
        if editor.guide != nil { editor.pauseGuide() }
        switch tool {
        case .editStep(let step):
            editor.selectedRegion = nil
            if editor.showBefore { editor.showBefore = false }
            let applied = await editor.sliders.coachStep(step)
            var out: [String: Any] = ["ok": true, "slider": step.slider.rawValue]
            out["applied"] = [step.slider.rawValue: applied.map { $0 as Any } ?? NSNull()]
            if let r = step.region { out["region"] = r }
            // WHEN_IDLE: the prompt has the coach wait for each step's answer before the next one,
            // so the answer must give it a turn (SILENT would end the lesson after one step).
            session.respond(to: id, name: name, result: out, scheduling: .whenIdle)
        case .setSliders(let values, let why):
            if editor.showBefore { editor.showBefore = false }
            let applied = await editor.sliders.coachSet(values, why: why)
            session.respond(to: id, name: name, result: ["ok": true, "applied": SliderValues.named(applied)],
                            scheduling: .whenIdle)
        case .selectRegion(let r):
            editor.selectedRegion = r
            let known = r == nil || editor.region(r) != nil
            session.respond(to: id, name: name, result: known ? ["ok": true, "region": r.map { $0 as Any } ?? NSNull()]
                                                              : ["ok": false, "error": "no region \(r ?? "")"])
        case .compare(let side):
            editor.showBefore = side == .before
            session.respond(to: id, name: name, result: ["ok": true, "show": side.rawValue])
        case .reset:
            editor.resetAll()
            session.respond(to: id, name: name, result: ["ok": true])
        case .saveEdit:
            let ok = await editor.save()
            session.respond(to: id, name: name, result: ok ? ["ok": true] : ["ok": false, "error": "save failed"],
                            scheduling: ok ? .silent : .whenIdle)
        }
        lastContext = editor.stateSummary()
    }
}
