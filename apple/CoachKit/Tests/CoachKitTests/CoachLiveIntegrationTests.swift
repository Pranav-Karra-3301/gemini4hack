// End-to-end test of LiveSession against the real Gemini Live API.
// Gated: runs only with COACH_LIVE_IT=1 and GEMINI_API_KEY in the environment (test-only; the
// apps never see the key, Core mints their tokens). Mints its own ephemeral token with a
// camera-mode-like setup, connects, sends a text turn + a JPEG frame, expects a tool call and
// audio back, then forces a socket drop and expects a resumed session. Prints timings.
// Needs "CoachLive" in the CoachKitTests target's dependencies; compiled out until then.
#if canImport(CoachLive)
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CoachLive

@Suite struct CoachLiveIntegrationTests {
    static let sample = "/Users/pranav/developer/gemini4hack/web/public/samples/img-1216.jpg"

    /// Collects events with arrival times (seconds since `t0`).
    actor Recorder {
        let t0 = Date()
        var events: [(TimeInterval, LiveEvent)] = []
        var mintTimes: [TimeInterval] = []
        func addMint(_ t: TimeInterval) { mintTimes.append(t) }
        func add(_ e: LiveEvent) { events.append((Date().timeIntervalSince(t0), e)) }
        func first(after: TimeInterval = 0, _ match: (LiveEvent) -> Bool) -> TimeInterval? {
            events.first { $0.0 >= after && match($0.1) }?.0
        }
        func audioBytes(after: TimeInterval = 0) -> Int {
            events.reduce(0) { n, e in
                if e.0 >= after, case .audio(let d) = e.1 { return n + d.count }
                return n
            }
        }
        func toolCalls() -> [(TimeInterval, String, String, String)] {
            events.compactMap { e in
                if case .toolCall(let id, let name, let args) = e.1 { return (e.0, id, name, args) }
                return nil
            }
        }
        func transcript(after: TimeInterval = 0) -> String {
            events.compactMap { e in
                if e.0 >= after, case .outputTranscript(let t) = e.1 { return t }
                return nil
            }.joined()
        }
        func now() -> TimeInterval { Date().timeIntervalSince(t0) }
        /// Compact event log (audio collapsed into byte counts).
        func timeline() -> String {
            var out: [String] = []
            var audio = 0
            for (t, e) in events {
                if case .audio(let d) = e { audio += d.count; continue }
                if audio > 0 { out.append("audio×\(audio)"); audio = 0 }
                let name: String
                switch e {
                case .status(let s): name = "status(\(s))"
                case .toolCall(_, let n, _): name = "toolCall(\(n))"
                case .toolCallCancelled(let ids): name = "cancelled(\(ids.count))"
                case .inputTranscript(let t): name = "in(\(t))"
                case .outputTranscript(let t): name = "out(\(t))"
                case .speaking(let b): name = "speaking(\(b))"
                case .interrupted: name = "interrupted"
                case .turnComplete: name = "turnComplete"
                case .audio: name = "audio"
                case .reconnected(let r): name = "reconnected(\(r))"
                }
                out.append(String(format: "%.2f ", t) + name)
            }
            if audio > 0 { out.append("audio×\(audio)") }
            return out.joined(separator: " | ")
        }
    }

    /// Counts audio delivered through the direct `audioOutput` path.
    final class CountingOutput: LiveAudioOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0, flushes = 0
        func enqueue(pcm24k: Data) { lock.withLock { bytes += pcm24k.count } }
        func flush() { lock.withLock { flushes += 1 } }
        var total: Int { lock.withLock { bytes } }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COACH_LIVE_IT"] == "1", "set COACH_LIVE_IT=1"),
          .timeLimit(.minutes(2)))
    func liveSessionEndToEnd() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["GEMINI_API_KEY"], "GEMINI_API_KEY not set")

        let rec = Recorder()
        let provider: @Sendable () async throws -> LiveCredential = {
            let t = Date()
            let c = try await Self.mint(key: key)
            await rec.addMint(Date().timeIntervalSince(t))
            return c
        }

        let session = LiveSession()
        let pump = Task { for await e in session.events { await rec.add(e) } }
        defer { session.stop(); pump.cancel() }

        let tStart = await rec.now()
        try await session.start(tokenProvider: provider)
        let tLive = await rec.now()

        // A text turn plus the frame it refers to.
        let image = try #require(Self.loadImage(Self.sample))
        #expect(session.sendFrame(cgImage: image) == .sent)
        #expect(session.sendFrame(cgImage: image) == .throttled) // < 1 s later
        session.sendText("Remember the code word PELICAN. This is my camera frame. Pretend the main subject is cut off at the left edge. "
                         + "Call the guide tool with the direction to move the camera, then tell me in one short sentence.")
        let tAsk = await rec.now()

        let call = try await Self.wait(25) { await rec.toolCalls().first }
        session.respond(to: call.1, name: call.2, result: ["ok": true, "shown": true], scheduling: .whenIdle)
        _ = try await Self.wait(25) { await rec.audioBytes() > 24_000 ? true : nil } // ≥0.5 s of speech
        let tAudio = await rec.first { if case .audio = $0 { return true }; return false } ?? -1
        let tSpeaking = await rec.first { if case .speaking(true) = $0 { return true }; return false } ?? -1
        // The tool call ends a turn; the spoken answer is a second turn. Let it finish.
        _ = try? await Self.wait(20) { await rec.first(after: tAudio) { if case .turnComplete = $0 { return true }; return false } }

        // Resumption: wait for a handle, kill the socket, expect a resumed reconnect.
        _ = try await Self.wait(15) { session.resumptionHandle }
        let output = CountingOutput()
        session.audioOutput = output
        let drop1 = try await Self.dropAndWait(session, rec)
        session.sendContext("[state] The camera ISO is now 640 and the shutter 1/120 s.")
        try await Task.sleep(nanoseconds: 500_000_000) // context and realtime text are separate streams
        session.sendText("What ISO is the camera at now? Answer with just the number.")
        let tAsk2 = await rec.now()
        _ = try await Self.wait(25) { output.total > 0 ? true : nil }
        let tAudio2 = await rec.now()
        _ = try? await Self.wait(20) { await rec.first(after: tAsk2) { if case .turnComplete = $0 { return true }; return false } }
        let answer2 = await rec.transcript(after: tAsk2)

        // A second drop. Core-style tokens (fieldMask without sessionResumption) resume on the same
        // token; tokens locked without a mask are single-use and the session mints first.
        _ = try await Self.wait(15) { session.resumptionHandle }
        let drop2 = try await Self.dropAndWait(session, rec)
        // The conversation itself must survive the drops (no sendContext for this one).
        try await Task.sleep(nanoseconds: 500_000_000)
        session.sendText("What code word did I ask you to remember at the start? Answer with just the word.")
        let tAsk3 = await rec.now()
        _ = try? await Self.wait(25) { await rec.first(after: tAsk3) { if case .turnComplete = $0 { return true }; return false } }
        let answer3 = await rec.transcript(after: tAsk3)

        let mintTimes = await rec.mintTimes
        print("CoachLive IT events: " + (await rec.timeline()))
        let calls = await rec.toolCalls()
        let bytes = await rec.audioBytes()
        print(String(format: """
            CoachLive IT timings (s): mint %@, start→live %.2f, ask→toolCall %.2f, ask→first audio %.2f, \
            ask→speaking %.2f, drop1→reconnected %.2f (resumed=%@), ask2→audio via output %.2f, \
            drop2→reconnected %.2f (resumed=%@)
            """,
            mintTimes.map { String(format: "%.2f", $0) }.joined(separator: "/"),
            tLive - tStart, call.0 - tAsk, tAudio - tAsk, tSpeaking - tAsk, drop1.seconds,
            drop1.resumed ? "true" : "false", tAudio2 - tAsk2, drop2.seconds, drop2.resumed ? "true" : "false"))
        print("CoachLive IT: tool calls \(calls.map { "\($0.2)\($0.3)" }), audio bytes \(bytes) "
              + "(\(String(format: "%.1f", Double(bytes) / 48_000)) s), output-path bytes \(output.total), "
              + "after resume + sendContext asked the ISO, heard: \"\(answer2)\"; code word after 2 drops: \"\(answer3)\"")

        #expect(call.2 == "guide")
        #expect(bytes > 0)
        #expect(drop1.resumed && drop2.resumed, "expected the session to resume with its handle")
        #expect(answer2.contains("640"), "sendContext should reach the model")
        #expect(answer3.lowercased().contains("pelican"), "the resumed session should keep the conversation")
        #expect(output.total > 0)
    }

    // MARK: helpers

    /// Kills the socket and waits for `.reconnected`; returns how long it took.
    static func dropAndWait(_ session: LiveSession, _ rec: Recorder) async throws -> (seconds: TimeInterval, resumed: Bool) {
        let t = await rec.now()
        session.simulateDrop()
        let resumed: Bool = try await wait(20) {
            for (te, e) in await rec.events where te >= t {
                if case .reconnected(let r) = e { return r }
            }
            return nil
        }
        return (await rec.now() - t, resumed)
    }

    /// Polls `check` every 50 ms until it returns non-nil.
    static func wait<T>(_ seconds: TimeInterval, _ check: () async -> T?) async throws -> T {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let v = await check() { return v }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LiveError.protocolError("timed out after \(seconds) s")
    }

    static func loadImage(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Mints an ephemeral token like Core's camera mode (trimmed tool set).
    static func mint(key: String) async throws -> LiveCredential {
        let f = ISO8601DateFormatter()
        let now = Date()
        let tools: [[String: Any]] = [
            ["name": "guide",
             "description": "Show an arrow telling the user how to move the CAMERA. Use 'hold' when framing is right.",
             "parameters": ["type": "OBJECT", "properties": [
                "direction": ["type": "STRING", "enum": ["left", "right", "up", "down", "closer", "back", "hold"]],
                "strength": ["type": "STRING", "enum": ["small", "medium", "large"]]],
                "required": ["direction"]]],
            ["name": "set_camera",
             "description": "Change camera settings. Pass only what should change.",
             "parameters": ["type": "OBJECT", "properties": [
                "iso": ["type": "NUMBER"], "shutter": ["type": "NUMBER"], "ev": ["type": "NUMBER"],
                "why": ["type": "STRING"]]]],
        ]
        let setup: [String: Any] = [
            "model": "models/gemini-3.8-live",
            "generationConfig": ["responseModalities": ["AUDIO"], "mediaResolution": "MEDIA_RESOLUTION_LOW"],
            "systemInstruction": ["parts": [["text":
                "You are a friendly camera coach. Use the guide tool for framing directions and set_camera for settings. "
                + "After a tool call, say at most one short sentence."]]],
            "tools": [["functionDeclarations": tools]],
            "inputAudioTranscription": [:] as [String: Any],
            "outputAudioTranscription": [:] as [String: Any],
            "realtimeInputConfig": ["automaticActivityDetection": [
                "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH", "silenceDurationMs": 600]],
            "contextWindowCompression": ["triggerTokens": 16000, "slidingWindow": ["targetTokens": 8000]],
        ]
        // Minted the way Core does (live_setup.token_constraints): every field is locked except
        // sessionResumption, which the client's {"setup":{"sessionResumption":{...}}} supplies.
        let body: [String: Any] = [
            "fieldMask": setup.keys.sorted().joined(separator: ","),
            "uses": 1,
            "expireTime": f.string(from: now.addingTimeInterval(30 * 60)),
            "newSessionExpireTime": f.string(from: now.addingTimeInterval(5 * 60)),
            "bidiGenerateContentSetup": setup,
        ]
        var lastError = "no response"
        for version in ["v1beta", "v1alpha"] {
            var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/\(version)/auth_tokens")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let name = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
            else { lastError = "mint \(version) HTTP \(status)"; continue }
            var comps = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.\(version).GenerativeService.BidiGenerateContentConstrained")!
            comps.queryItems = [URLQueryItem(name: "access_token", value: name)]
            return LiveCredential(wsURL: comps.url!, expireTime: now.addingTimeInterval(30 * 60),
                                  model: "gemini-3.8-live", newSessionExpireTime: now.addingTimeInterval(5 * 60))
        }
        throw LiveError.badToken(lastError)
    }
}
#endif
