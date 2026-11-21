// Offline tests of LiveSession's connection logic against a local WebSocket server (Network.framework):
// setup handshake, goAway rotation (idle and mid-speech), resume escalation after a 1011
// "Token has been used too many times" rejection, queued control messages and event mapping.
// Needs "CoachLive" in the CoachKitTests target's dependencies; compiled out until then.
#if canImport(CoachLive)
import Foundation
import Network
import Testing
@testable import CoachLive

/// A scripted Live API stand-in. Each accepted socket gets an index; `onMessage` decides replies.
final class MockLiveServer: @unchecked Sendable {
    struct Conn: @unchecked Sendable { let index: Int; let nw: NWConnection }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-live")
    private let lock = NSLock()
    private var conns: [NWConnection] = []
    private var log: [(conn: Int, json: [String: Any])] = []
    var onMessage: (@Sendable (MockLiveServer, Conn, [String: Any]) -> Void)?

    init() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let p = listener.port?.rawValue, p != 0 { return p }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LiveError.protocolError("mock listener didn't start")
    }

    func stop() {
        listener.cancel()
        lock.withLock { conns }.forEach { $0.cancel() }
    }

    var connectionCount: Int { lock.withLock { conns.count } }
    func messages(conn: Int) -> [[String: Any]] { lock.withLock { log.filter { $0.conn == conn }.map(\.json) } }

    func send(_ c: Conn, _ json: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.nw.send(content: Data(json.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close(_ c: Conn, code: NWProtocolWebSocket.CloseCode, reason: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = code
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        c.nw.send(content: Data(reason.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in
            c.nw.cancel()
        })
    }

    private func accept(_ nw: NWConnection) {
        let index: Int = lock.withLock { conns.append(nw); return conns.count - 1 }
        nw.start(queue: queue)
        receive(Conn(index: index, nw: nw))
    }

    private func receive(_ c: Conn) {
        c.nw.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.lock.withLock { self.log.append((c.index, obj)) }
                self.onMessage?(self, c, obj)
            }
            self.receive(c)
        }
    }
}

@Suite(.serialized) struct CoachLiveSessionTests {
    /// Collects events; `wait` polls for a condition.
    actor Events {
        var all: [LiveEvent] = []
        func add(_ e: LiveEvent) { all.append(e) }
        func count(_ match: (LiveEvent) -> Bool) -> Int { all.filter(match).count }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
        var value: Int { lock.withLock { n } }
    }

    static func wait(_ seconds: TimeInterval = 5, _ check: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await check() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw LiveError.protocolError("timed out")
    }

    static func setup(_ m: [String: Any]) -> [String: Any]? { m["setup"] as? [String: Any] }
    static func handle(_ m: [String: Any]) -> String? {
        ((setup(m)?["sessionResumption"]) as? [String: Any])?["handle"] as? String
    }

    /// A session wired to the mock; `mints` counts token-provider calls.
    static func make(_ port: UInt16, mints: Counter) -> (LiveSession, @Sendable () async throws -> LiveCredential) {
        var opts = LiveSession.Options()
        opts.setupTimeout = 3
        let provider: @Sendable () async throws -> LiveCredential = {
            let n = mints.next()
            return LiveCredential(wsURL: URL(string: "ws://127.0.0.1:\(port)/?token=\(n)")!,
                                  expireTime: Date().addingTimeInterval(1800))
        }
        return (LiveSession(options: opts), provider)
    }

    @Test func eventsAndGoAwayWhenIdle() async throws {
        let server = try MockLiveServer()
        server.onMessage = { s, c, m in
            if Self.setup(m) != nil {
                s.send(c, #"{"setupComplete":{}}"#)
                s.send(c, #"{"sessionResumptionUpdate":{"newHandle":"H\#(c.index)","resumable":true}}"#)
            } else if let t = (m["realtimeInput"] as? [String: Any])?["text"] as? String, t == "hello" {
                let pcm = Data(repeating: 1, count: 480).base64EncodedString()
                s.send(c, #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\#(pcm)"}}]},"outputTranscription":{"text":"Hi"}}}"#)
                s.send(c, #"{"toolCall":{"functionCalls":[{"id":"t1","name":"guide","args":{"direction":"left"}}]}}"#)
                s.send(c, #"{"serverContent":{"turnComplete":true}}"#)
                s.send(c, #"{"toolCallCancellation":{"ids":["t1"]}}"#)
            } else if (m["realtimeInput"] as? [String: Any])?["text"] as? String == "bye" {
                s.send(c, #"{"goAway":{"timeLeft":"5s"}}"#)
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let mints = Counter()
        let (session, provider) = Self.make(port, mints: mints)
        let ev = Events()
        let pump = Task { for await e in session.events { await ev.add(e) } }
        defer { session.stop(); pump.cancel() }

        try await session.start(tokenProvider: provider)
        #expect(session.isLive)
        // {"setup":{"sessionResumption":{}}}: asks for handles, resumes nothing
        #expect(Self.setup(server.messages(conn: 0)[0]).map { $0.count == 1 && Self.handle(server.messages(conn: 0)[0]) == nil
            && ($0["sessionResumption"] as? [String: Any])?.isEmpty == true } == true)
        session.sendText("hello")
        try await Self.wait { await ev.count { if case .turnComplete = $0 { return true }; return false } == 1 }
        try await Self.wait { await ev.count { if case .toolCallCancelled = $0 { return true }; return false } == 1 }
        let all = await ev.all
        #expect(all.contains { if case .speaking(true) = $0 { return true }; return false })
        #expect(all.contains { if case .speaking(false) = $0 { return true }; return false })
        #expect(all.contains { if case .outputTranscript("Hi") = $0 { return true }; return false })
        #expect(all.contains { if case .audio(let d) = $0 { return d.count == 480 }; return false })
        #expect(all.contains { if case .toolCall("t1", "guide", let a) = $0 { return a.contains("left") }; return false })
        #expect(session.resumptionHandle == "H0")

        session.sendText("bye") // → goAway while idle: rotate now, resume with H0
        try await Self.wait { await ev.count { if case .reconnected(true) = $0 { return true }; return false } == 1 }
        #expect(server.connectionCount == 2)
        #expect(Self.handle(server.messages(conn: 1)[0]) == "H0")
        #expect(mints.value == 1) // same token reused (expiry far away, not known single-use)
        #expect(session.isLive)
    }

    @Test func goAwayMidSpeechWaitsForTurnEnd() async throws {
        let server = try MockLiveServer()
        let turnEndSent = Counter()
        server.onMessage = { s, c, m in
            if Self.setup(m) != nil {
                s.send(c, #"{"setupComplete":{}}"#)
                s.send(c, #"{"sessionResumptionUpdate":{"newHandle":"S\#(c.index)","resumable":true}}"#)
            } else if (m["realtimeInput"] as? [String: Any])?["text"] as? String == "talk" {
                let pcm = Data(repeating: 2, count: 960).base64EncodedString()
                s.send(c, #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"\#(pcm)"}}]}}}"#)
                s.send(c, #"{"goAway":{"timeLeft":"10s"}}"#)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    _ = turnEndSent.next()
                    s.send(c, #"{"serverContent":{"turnComplete":true}}"#)
                }
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (session, provider) = Self.make(port, mints: Counter())
        let ev = Events()
        let pump = Task { for await e in session.events { await ev.add(e) } }
        defer { session.stop(); pump.cancel() }
        try await session.start(tokenProvider: provider)
        session.sendText("talk")
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(server.connectionCount == 1, "must not rotate while the model is speaking")
        try await Self.wait { await ev.count { if case .reconnected = $0 { return true }; return false } == 1 }
        #expect(turnEndSent.value == 1)
        #expect(server.connectionCount == 2)
        #expect(Self.handle(server.messages(conn: 1)[0]) == "S0")
    }

    @Test func singleUseTokenEscalationAndQueuedControl() async throws {
        let server = try MockLiveServer()
        server.onMessage = { s, c, m in
            guard let setup = Self.setup(m) else { return }
            // Token 1 may be used once: a second connection with it is refused like Gemini does.
            let isFirstToken = c.index == 1
            if isFirstToken {
                s.close(c, code: .protocolCode(.internalServerError), reason: "Token has been used too many times")
                return
            }
            _ = setup
            s.send(c, #"{"setupComplete":{}}"#)
            s.send(c, #"{"sessionResumptionUpdate":{"newHandle":"R\#(c.index)","resumable":true}}"#)
        }
        let port = try await server.start()
        defer { server.stop() }
        let mints = Counter()
        let (session, provider) = Self.make(port, mints: mints)
        let ev = Events()
        let pump = Task { for await e in session.events { await ev.add(e) } }
        defer { session.stop(); pump.cancel() }
        try await session.start(tokenProvider: provider)

        // Drop 1: conn 1 (same token) is refused with 1011 → mint → conn 2 resumes with R0.
        try await Self.wait { session.resumptionHandle == "R0" }
        session.simulateDrop()
        session.sendText("queued while reconnecting")
        session.respond(to: "old", name: "guide", result: ["ok": true])
        try await Self.wait { await ev.count { if case .reconnected(true) = $0 { return true }; return false } == 1 }
        #expect(server.connectionCount == 3)
        #expect(mints.value == 2)
        #expect(Self.handle(server.messages(conn: 2)[0]) == "R0")
        try await Self.wait {
            server.messages(conn: 2).contains { ($0["realtimeInput"] as? [String: Any])?["text"] as? String == "queued while reconnecting" }
        }
        try await Self.wait { server.messages(conn: 2).contains { $0["toolResponse"] != nil } } // resumed: kept

        // Drop 2: the session learned tokens are single-use, so it mints first: no refused attempt.
        try await Self.wait { session.resumptionHandle == "R2" }
        session.simulateDrop()
        try await Self.wait { await ev.count { if case .reconnected(true) = $0 { return true }; return false } == 2 }
        #expect(server.connectionCount == 4)
        #expect(mints.value == 3)
        #expect(Self.handle(server.messages(conn: 3)[0]) == "R2")
        let attempts = await ev.count { if case .status(.reconnecting) = $0 { return true }; return false }
        #expect(attempts == 3) // 2 for drop 1 (refused + ok), 1 for drop 2

        session.stop()
        try await Self.wait { await ev.count { if case .status(.closed) = $0 { return true }; return false } == 1 }
        #expect(!session.isLive)
        #expect(session.sendAudio(pcm16k: Data(count: 3200)) == false)
    }

    @Test func setupRejectedFailsStart() async throws {
        let server = try MockLiveServer()
        server.onMessage = { s, c, m in
            if Self.setup(m) != nil { s.close(c, code: .protocolCode(.policyViolation), reason: "bad token") }
        }
        let port = try await server.start()
        defer { server.stop() }
        let (session, provider) = Self.make(port, mints: Counter())
        do {
            try await session.start(tokenProvider: provider)
            Issue.record("start should throw")
        } catch let LiveError.setupRejected(code, reason) {
            #expect(code == 1008)
            #expect(reason == "bad token")
        }
        var last: LiveEvent?
        for await e in session.events { last = e }
        if case .status(.error(let msg)) = last { #expect(msg.contains("1008")) } else { Issue.record("expected error status") }
    }
}
#endif
