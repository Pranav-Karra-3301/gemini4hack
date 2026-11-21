import CoachModels
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import os

/// Receives Gemini's speech straight from the network task (no main-thread hop), so playback
/// and barge-in flushes stay in order with the socket. `LiveAudio` conforms.
public protocol LiveAudioOutput: AnyObject, Sendable {
    /// 24 kHz mono PCM16 little-endian, in arrival order.
    func enqueue(pcm24k: Data)
    /// Drop everything queued (the user interrupted).
    func flush()
}

/// One Gemini Live conversation over an ephemeral token (docs/CORE_API.md §2).
///
/// Design: a thread-safe class rather than an actor. Media calls (`sendAudio`, `sendFrame`) are
/// synchronous and non-blocking so a capture thread can call them in order without spawning
/// tasks (unstructured tasks don't preserve order). Everything Gemini says comes back in order
/// on `events`, an `AsyncStream`. A session is single-use: `stop()` finishes the stream.
///
/// ```swift
/// let live = LiveSession()
/// audio.attach(to: live)                                   // mic in, speaker out
/// try await live.start(liveToken: { try await client.liveToken(.camera()) })
/// for await event in live.events {
///     if case .toolCall(let id, let name, let args) = event {
///         live.respond(to: id, name: name, result: ["ok": true])
///     }
/// }
/// ```
///
/// Reconnects: the session tracks `sessionResumptionUpdate.newHandle`. On `goAway` it waits for
/// a quiet moment (turn end, or ~1.5 s before the deadline), closes the socket and resumes with
/// `{"setup":{"sessionResumption":{"handle":…}}}` on the same `ws_url`. On a drop it does the
/// same with backoff (0, 0.25, 0.5, 1, 2, 4 s). If the server rejects the resume it mints a fresh
/// token via the provider; if that is rejected too it starts a fresh session (no context) and
/// emits `.reconnected(resumed: false)`.
///
/// Measured 2026-11-21 (gemini-3.8-live, see the integration test): with Core's tokens (fieldMask
/// leaves `sessionResumption` to the client, CORE_API §2) the first setup sends
/// `{"sessionResumption":{}}`, handles keep arriving, and a reconnect resumes on the SAME token
/// with the conversation intact (one mint, two drops, 0.36 s each). Tokens locked WITHOUT a
/// fieldMask ignore the client's setup: they refuse a second connection ("Token has been used too
/// many times", close 1011), so the session remembers that and mints before reconnecting, and
/// such a resume does not keep the conversation. After `.reconnected(resumed: false)`, re-send
/// what the model must know with `sendContext(_:)`.
public final class LiveSession: @unchecked Sendable {
    /// Tunables. Defaults follow docs/CORE_API.md.
    public struct Options: Sendable {
        /// Seconds to wait for `setupComplete`.
        public var setupTimeout: TimeInterval = 10
        /// Reconnect attempts per drop before giving up with `.status(.error)`.
        public var maxReconnectAttempts = 6
        /// Frame rate limit and change detection.
        public var frames = FrameThrottle()
        /// Long side of JPEGs made by `sendFrame(pixelBuffer:)` / `sendFrame(cgImage:)`.
        public var maxFrameDimension = 768
        public var jpegQuality = 0.6
        /// Unacknowledged socket writes above which video (resp. audio) is dropped instead of queued.
        public var maxPendingForVideo = 4
        public var maxPendingForAudio = 100 // 4 s of 40 ms chunks
        /// WebSocket ping period; a missing pong within `pingTimeout` counts as a drop.
        public var pingInterval: TimeInterval = 15
        public var pingTimeout: TimeInterval = 10
        public init() {}
    }

    enum Phase: Equatable { case idle, connecting, live, reconnecting, closed, failed }

    /// Everything that happens, in order. Finishes after `.status(.closed)` or `.status(.error)`.
    public let events: AsyncStream<LiveEvent>

    private let continuation: AsyncStream<LiveEvent>.Continuation
    private let options: Options
    private let urlSession: URLSession
    private let log = Logger(subsystem: "CoachLive", category: "session")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var phase: Phase = .idle
    private var socket: URLSessionWebSocketTask?       // set only while live
    private var connectingSocket: URLSessionWebSocketTask?
    private var queuedControl: [(text: String, isToolResponse: Bool)] = [] // sent while not live
    private var pendingWrites = 0
    private var throttle: FrameThrottle
    private var output: (any LiveAudioOutput)?
    private var handle: String?
    private var rotateNow: ObjectIdentifier?           // socket we closed on purpose for a goAway
    private var runTask: Task<Void, Never>?

    // Owned by the connection task (start(), then run()); never touched concurrently.
    private var tokenProvider: (@Sendable () async throws -> LiveCredential)?
    private var credential: LiveCredential?
    private var speaking = false
    private var goAwayPending = false
    /// Set after the server said "Token has been used too many times" on a resume: tokens locked
    /// without a fieldMask can't be reused (verified 2026-11-21), so later reconnects mint first.
    private var tokensAreSingleUse = false

    public init(options: Options = Options()) {
        self.options = options
        throttle = options.frames
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // Live sockets can be quiet on the receive side for minutes; our own setup timeout and
        // pings detect dead connections instead.
        config.timeoutIntervalForRequest = 3600
        urlSession = URLSession(configuration: config)
        (events, continuation) = AsyncStream.makeStream(of: LiveEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    // MARK: Public API

    /// Where Gemini's audio goes. When set, audio skips `events` and barge-ins flush it directly.
    public var audioOutput: (any LiveAudioOutput)? {
        get { lock.withLock { output } }
        set { lock.withLock { output = newValue } }
    }

    /// The latest resumption handle (persist it to resume after an app relaunch, ≤2 h old).
    public var resumptionHandle: String? { lock.withLock { handle } }

    /// True while connected and past `setupComplete`.
    public var isLive: Bool { lock.withLock { phase == .live && socket != nil } }

    /// Connects and returns once Gemini sent `setupComplete`; throws if that fails.
    /// - Parameters:
    ///   - resumeHandle: resume an earlier session (e.g. `resumptionHandle` saved before a relaunch).
    ///   - tokenProvider: mints a token, normally `POST /api/live/token` on Core. Called once now
    ///     and again only when a token expired or a resume was rejected.
    public func start(resumeHandle: String? = nil,
                      tokenProvider: @escaping @Sendable () async throws -> LiveCredential) async throws {
        try lock.withLock {
            guard phase == .idle else { throw LiveError.alreadyStarted }
            phase = .connecting
            handle = resumeHandle
        }
        self.tokenProvider = tokenProvider
        emit(.status(.connecting))
        do {
            let cred = try await tokenProvider()
            credential = cred
            let ws = try await connect(cred, resume: resumeHandle)
            guard install(ws) else {
                ws.cancel(with: .normalClosure, reason: nil)
                throw LiveError.closed
            }
            emit(.status(.live))
            let task = Task.detached { [self] in await run(first: ws) }
            lock.withLock { runTask = task }
        } catch {
            finish(.failed, status: .error(describe(error)))
            throw error
        }
    }

    /// `start` with the typed Core response, e.g.
    /// `try await live.start { try await client.liveToken(.camera()) }`.
    public func start(resumeHandle: String? = nil,
                      liveToken: @escaping @Sendable () async throws -> LiveTokenResponse) async throws {
        try await start(resumeHandle: resumeHandle) { try LiveCredential(try await liveToken()) }
    }

    /// Sends one chunk (~40 ms) of 16 kHz mono PCM16 from the mic. Thread-safe, non-blocking, keeps call
    /// order. Dropped while reconnecting or if the socket is backed up.
    @discardableResult
    public func sendAudio(pcm16k: Data) -> Bool {
        guard !pcm16k.isEmpty else { return false }
        return send(.audio(pcm16k), kind: .audio)
    }

    /// Tells the server the mic paused (mute), so its VAD can close the user's turn.
    public func sendAudioStreamEnd() {
        send(.audioStreamEnd, kind: .audio)
    }

    /// Sends a JPEG (≤768 px long side) if at least 1 s passed since the last sent frame and the
    /// picture changed (16×16 luma diff). Thread-safe; cheap when throttled.
    @discardableResult
    public func sendFrame(jpeg: Data) -> LiveFrameResult {
        let now = Self.uptime
        if let early = preFrameCheck(now) { return early }
        guard let thumb = LumaThumbnail(imageData: jpeg) else { return .invalid }
        return offerFrame(thumb, at: now) { jpeg }
    }

    /// Camera-frame variant: diffs the luma plane first and only JPEG-encodes frames that go out.
    /// - Parameter orientation: rotates the buffer upright before encoding (`.right` for a
    ///   portrait iPhone back camera delivering landscape buffers).
    @discardableResult
    public func sendFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> LiveFrameResult {
        let now = Self.uptime
        if let early = preFrameCheck(now) { return early }
        guard let thumb = LumaThumbnail(pixelBuffer: pixelBuffer) else { return .invalid }
        let (dim, q) = (options.maxFrameDimension, options.jpegQuality)
        return offerFrame(thumb, at: now) {
            LiveFrameEncoder.jpeg(from: pixelBuffer, orientation: orientation, maxDimension: dim, quality: q)
        }
    }

    /// `CGImage` variant (e.g. the Mac editor's current render).
    @discardableResult
    public func sendFrame(cgImage: CGImage) -> LiveFrameResult {
        let now = Self.uptime
        if let early = preFrameCheck(now) { return early }
        guard let thumb = LumaThumbnail(cgImage: cgImage) else { return .invalid }
        let (dim, q) = (options.maxFrameDimension, options.jpegQuality)
        return offerFrame(thumb, at: now) { LiveFrameEncoder.jpeg(from: cgImage, maxDimension: dim, quality: q) }
    }

    /// Sends a typed user turn. Queued (in order) while reconnecting.
    public func sendText(_ text: String) {
        send(.text(text), kind: .control)
    }

    /// Adds facts to the conversation without asking for a reply (`clientContent`,
    /// `turnComplete: false`), e.g. "[state] ISO 640, shutter 1/120" after the user turned a
    /// dial, or the current slider values after `.reconnected`. Queued while reconnecting.
    /// `clientContent` and realtime input are separate streams: a `sendText` or speech within
    /// ~0.3 s after this can be answered before the context lands (measured), so send context
    /// when state changes rather than right before a question.
    public func sendContext(_ text: String) {
        send(.context(text), kind: .control)
    }

    /// Answers a tool call. `result` must be JSON-compatible; non-dictionaries are wrapped as
    /// `{"result": value}`. Use `.silent` for UI tools and `.whenIdle` when Gemini should comment
    /// on the result. Queued while reconnecting.
    public func respond(to id: String, name: String, result: [String: Any], scheduling: LiveScheduling? = .silent) {
        send(.toolResponse([LiveFunctionResponse(id: id, name: name, response: result, scheduling: scheduling)]),
             kind: .control)
    }

    /// Answers a tool call with an `Encodable` value (e.g. the clamped camera settings applied).
    /// A separate label so dictionary literals keep using the non-throwing overload above.
    public func respond<T: Encodable>(to id: String, name: String, encoding value: T,
                                      scheduling: LiveScheduling? = .silent) throws {
        let obj = try LiveFunctionResponse.object(encoding: value)
        send(.toolResponse([LiveFunctionResponse(id: id, name: name, response: obj, scheduling: scheduling)]),
             kind: .control)
    }

    /// Closes the socket and finishes `events` with `.status(.closed)`. Idempotent.
    public func stop() {
        let (ws, connecting, task) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSessionWebSocketTask?, Task<Void, Never>?) in
            guard phase != .closed && phase != .failed else { return (nil, nil, nil) }
            phase = .closed
            defer { socket = nil; connectingSocket = nil; queuedControl = [] }
            return (socket, connectingSocket, runTask)
        }
        task?.cancel()
        ws?.cancel(with: .normalClosure, reason: nil)
        connecting?.cancel(with: .normalClosure, reason: nil)
        emit(.status(.closed))
        continuation.finish()
    }

    // MARK: Sending

    enum SendKind { case audio, video, control }

    @discardableResult
    func send(_ message: LiveClientMessage, kind: SendKind) -> Bool {
        let text: String
        do { text = try message.json() } catch {
            log.error("encode failed: \(String(describing: error), privacy: .public)")
            return false
        }
        var isToolResponse = false
        if case .toolResponse = message { isToolResponse = true }
        let ws: URLSessionWebSocketTask? = lock.withLock {
            guard phase == .live, let s = socket else {
                if kind == .control, phase == .connecting || phase == .reconnecting || phase == .idle {
                    queuedControl.append((text, isToolResponse))
                }
                return nil
            }
            switch kind {
            case .video where pendingWrites >= options.maxPendingForVideo: return nil
            case .audio where pendingWrites >= options.maxPendingForAudio: return nil
            default: break
            }
            pendingWrites += 1
            return s
        }
        guard let ws else { return false }
        write(text, on: ws, control: kind == .control ? (text, isToolResponse) : nil)
        return true
    }

    /// Writes one frame. Control messages (text, context, tool responses) that fail because the
    /// socket just died are re-sent on the next socket instead of being lost; media is not.
    private func write(_ text: String, on ws: URLSessionWebSocketTask, control: (text: String, isToolResponse: Bool)?) {
        ws.send(.string(text)) { [weak self, weak ws] error in
            guard let self else { return }
            var resendOn: URLSessionWebSocketTask?
            let drop = self.lock.withLock { () -> Bool in
                self.pendingWrites -= 1
                guard error != nil else { return false }
                if let control, self.phase != .closed && self.phase != .failed {
                    if self.phase == .live, let current = self.socket, current !== ws {
                        self.pendingWrites += 1
                        resendOn = current
                    } else {
                        self.queuedControl.append(control)
                    }
                }
                return ws != nil && self.socket === ws && self.phase == .live
            }
            if drop, let ws {
                // A failed write means the socket is dead; the receive loop will reconnect.
                ws.cancel(with: .goingAway, reason: nil)
            }
            if let resendOn { self.write(text, on: resendOn, control: control) }
        }
    }

    private func preFrameCheck(_ now: TimeInterval) -> LiveFrameResult? {
        lock.withLock {
            guard phase == .live, socket != nil else { return .notLive }
            guard pendingWrites < options.maxPendingForVideo else { return .notLive }
            return throttle.isDue(at: now) ? nil : .throttled
        }
    }

    private func offerFrame(_ thumb: LumaThumbnail, at now: TimeInterval, jpeg: () -> Data?) -> LiveFrameResult {
        let decision = lock.withLock { throttle.offer(thumb, at: now) }
        switch decision {
        case .tooSoon: return .throttled
        case .unchanged: return .unchanged
        case .send: break
        }
        guard let data = jpeg() else {
            lock.withLock { throttle.reset() }
            return .invalid
        }
        if send(.video(jpeg: data), kind: .video) { return .sent }
        lock.withLock { throttle.reset() }
        return .notLive
    }

    // MARK: Connection

    private enum LoopEnd { case stopped, goAway, dropped(code: Int, reason: String) }

    /// Opens a socket, sends `setup`, waits for `setupComplete`. Messages that arrive first
    /// (e.g. a resumption update) are handled normally.
    private func connect(_ cred: LiveCredential, resume: String?) async throws -> URLSessionWebSocketTask {
        let ws = urlSession.webSocketTask(with: cred.wsURL)
        ws.maximumMessageSize = 16 << 20
        let proceed = lock.withLock { () -> Bool in
            guard phase != .closed && phase != .failed else { return false }
            connectingSocket = ws
            return true
        }
        guard proceed else { throw LiveError.closed }
        defer { lock.withLock { if connectingSocket === ws { connectingSocket = nil } } }
        ws.resume()
        let started = Self.uptime
        let timeout = options.setupTimeout
        let timer = Task.detached { [weak ws] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            if !Task.isCancelled { ws?.cancel(with: .goingAway, reason: nil) }
        }
        defer { timer.cancel() }
        do {
            try await ws.send(.string(LiveClientMessage.setup(resumeHandle: resume).json()))
            while true {
                let msg = try await ws.receive()
                guard let parsed = parse(msg) else { continue }
                handle(parsed)
                if parsed.setupComplete { return ws }
            }
        } catch {
            let code = ws.closeCode
            let reason = Self.reason(ws)
            ws.cancel(with: .normalClosure, reason: nil)
            if lock.withLock({ phase == .closed || phase == .failed }) { throw LiveError.closed }
            if code != .invalid { throw LiveError.setupRejected(code: code.rawValue, reason: reason) }
            if let http = ws.response as? HTTPURLResponse, http.statusCode >= 400 {
                throw LiveError.setupRejected(code: http.statusCode, reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            }
            if Self.uptime - started >= timeout - 0.05 { throw LiveError.setupTimeout }
            throw error
        }
    }

    /// Makes `ws` the live socket and flushes queued control messages. False if stopped meanwhile.
    /// Tool responses queued during a reconnect are dropped when the session wasn't resumed
    /// (the new session never issued those calls).
    private func install(_ ws: URLSessionWebSocketTask, resumed: Bool = true) -> Bool {
        let queued: [(text: String, isToolResponse: Bool)]? = lock.withLock {
            guard phase != .closed && phase != .failed else { return nil }
            phase = .live
            socket = ws
            throttle.reset()
            let q = queuedControl.filter { resumed || !$0.isToolResponse }
            queuedControl = []
            pendingWrites += q.count
            return q
        }
        guard let queued else { return false }
        for entry in queued { write(entry.text, on: ws, control: entry) }
        return true
    }

    private func run(first: URLSessionWebSocketTask) async {
        var ws = first
        var shortLived = 0
        while true {
            let since = Self.uptime
            let pinger = Task.detached { [weak self, weak ws] in
                guard let ws else { return }
                await self?.keepAlive(ws)
            }
            let end = await receiveLoop(ws)
            pinger.cancel()
            let stillOurs = lock.withLock { () -> Bool in
                if socket === ws { socket = nil }
                if rotateNow == ObjectIdentifier(ws) { rotateNow = nil }
                guard phase == .live else { return false }
                phase = .reconnecting
                return true
            }
            ws.cancel(with: .normalClosure, reason: nil) // free the session before resuming it
            if speaking { speaking = false; emit(.speaking(false)) }
            goAwayPending = false
            guard stillOurs else { return }

            switch end {
            case .stopped:
                return
            case .goAway:
                log.info("goAway: rotating connection")
                shortLived = 0
            case .dropped(let code, let reason):
                log.warning("socket dropped (\(code, privacy: .public)) \(reason, privacy: .public)")
                if code == 1007 { // invalid payload: our bug, reconnecting would loop
                    finish(.failed, status: .error("closed by server (1007) \(reason)"))
                    return
                }
                shortLived = Self.uptime - since < 5 ? shortLived + 1 : 0
                if shortLived > 3 {
                    finish(.failed, status: .error("connection keeps dropping (\(code)) \(reason)"))
                    return
                }
            }

            guard let (next, resumed) = await reconnect() else {
                if lock.withLock({ phase == .reconnecting }) {
                    finish(.failed, status: .error("reconnect failed"))
                }
                return
            }
            guard install(next, resumed: resumed) else {
                next.cancel(with: .normalClosure, reason: nil)
                return
            }
            emit(.status(.live))
            emit(.reconnected(resumed: resumed))
            ws = next
        }
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask) async -> LoopEnd {
        var goAwayTimer: Task<Void, Never>?
        defer { goAwayTimer?.cancel() }
        while true {
            let msg: URLSessionWebSocketTask.Message
            do {
                msg = try await ws.receive()
            } catch {
                let (stopped, rotating) = lock.withLock {
                    (phase == .closed || phase == .failed, rotateNow == ObjectIdentifier(ws))
                }
                if stopped { return .stopped }
                if rotating { return .goAway }
                return .dropped(code: ws.closeCode.rawValue, reason: Self.reason(ws))
            }
            guard let parsed = parse(msg) else { continue }
            handle(parsed)
            if let left = parsed.goAwayTimeLeft {
                if !speaking { return .goAway }
                goAwayPending = true
                // Let the current answer finish, but rotate before the server cuts us off.
                let delay = max(0, left - 1.5)
                goAwayTimer?.cancel()
                goAwayTimer = Task.detached { [weak self, weak ws] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                    guard !Task.isCancelled, let self, let ws else { return }
                    self.lock.withLock { self.rotateNow = ObjectIdentifier(ws) }
                    ws.cancel(with: .goingAway, reason: nil)
                }
            }
            if goAwayPending && (parsed.turnComplete || parsed.interrupted) { return .goAway }
        }
    }

    /// Reconnect with escalation: same token + handle → fresh token + handle → fresh token, new session.
    /// Network failures back off; a rejection retries at once with the next escalation step.
    private func reconnect() async -> (URLSessionWebSocketTask, Bool)? {
        var needFreshToken = tokensAreSingleUse || (credential?.isExpired() ?? true)
        var mintedFresh = false
        var backoff = false
        for attempt in 1...max(1, options.maxReconnectAttempts) {
            if lock.withLock({ phase != .reconnecting }) { return nil }
            emit(.status(.reconnecting(attempt: attempt)))
            if backoff {
                let base = min(4.0, 0.25 * pow(2.0, Double(attempt - 2)))
                try? await Task.sleep(nanoseconds: UInt64(base * Double.random(in: 0.8...1.2) * 1e9))
                if lock.withLock({ phase != .reconnecting }) { return nil }
            }
            let resume = resumptionHandle
            do {
                if needFreshToken || credential == nil {
                    guard let provider = tokenProvider else { return nil }
                    credential = try await provider()
                    needFreshToken = false
                    mintedFresh = true
                }
                guard let cred = credential else { return nil }
                let ws = try await connect(cred, resume: resume)
                return (ws, resume != nil)
            } catch LiveError.setupRejected(let code, let reason) {
                log.warning("reconnect rejected (\(code, privacy: .public)) \(reason, privacy: .public)")
                if reason.localizedCaseInsensitiveContains("used too many times") { tokensAreSingleUse = true }
                backoff = false
                if !mintedFresh {
                    needFreshToken = true                // 1. same token refused: mint
                } else if resume != nil {
                    lock.withLock { handle = nil }       // 2. fresh token refused the handle: new session
                    needFreshToken = tokensAreSingleUse
                } else {
                    needFreshToken = true                // 3. nothing left to escalate: wait and retry
                    backoff = true
                }
            } catch LiveError.closed {
                return nil
            } catch {
                log.warning("reconnect failed: \(self.describe(error), privacy: .public)")
                backoff = true
                if attempt >= 2 && !mintedFresh { needFreshToken = true }
            }
        }
        return nil
    }

    private func keepAlive(_ ws: URLSessionWebSocketTask) async {
        let interval = options.pingInterval, timeout = options.pingTimeout
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            if Task.isCancelled { return }
            let ok = await Self.ping(ws, timeout: timeout)
            if !ok && !Task.isCancelled {
                log.warning("ping timed out; dropping socket")
                ws.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private static func ping(_ ws: URLSessionWebSocketTask, timeout: TimeInterval) async -> Bool {
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var cont: CheckedContinuation<Bool, Never>?
            func resume(_ v: Bool) {
                let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in defer { cont = nil }; return cont }
                c?.resume(returning: v)
            }
        }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            once.lock.withLock { once.cont = c }
            ws.sendPing { error in once.resume(error == nil) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                once.resume(false)
            }
        }
    }

    // MARK: Receiving

    private func parse(_ msg: URLSessionWebSocketTask.Message) -> LiveServerMessage? {
        let data: Data
        switch msg {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return nil
        }
        do { return try LiveServerMessage(json: data) } catch {
            log.error("unparseable server frame (\(data.count, privacy: .public) bytes)")
            return nil
        }
    }

    private func handle(_ m: LiveServerMessage) {
        if let h = m.resumeHandle { lock.withLock { handle = h } }
        if let e = m.error { log.error("server error: \(e, privacy: .public)") }
        let out = audioOutput
        if m.interrupted {
            out?.flush()
            if speaking { speaking = false; emit(.speaking(false)) }
            emit(.interrupted)
        }
        if !m.audio.isEmpty {
            if !speaking { speaking = true; emit(.speaking(true)) }
            for chunk in m.audio {
                if let out { out.enqueue(pcm24k: chunk) } else { emit(.audio(chunk)) }
            }
        }
        if let t = m.inputTranscript, !t.isEmpty { emit(.inputTranscript(t)) }
        if let t = m.outputTranscript, !t.isEmpty { emit(.outputTranscript(t)) }
        for call in m.toolCalls { emit(.toolCall(id: call.id, name: call.name, argsJSON: call.argsJSON)) }
        if !m.cancelledToolCallIDs.isEmpty { emit(.toolCallCancelled(ids: m.cancelledToolCallIDs)) }
        if m.turnComplete {
            if speaking { speaking = false; emit(.speaking(false)) }
            emit(.turnComplete)
        }
    }

    // MARK: Helpers

    private func emit(_ e: LiveEvent) { continuation.yield(e) }

    private func finish(_ terminal: Phase, status: LiveStatus) {
        let ws = lock.withLock { () -> URLSessionWebSocketTask? in
            guard phase != .closed && phase != .failed else { return nil }
            phase = terminal
            defer { socket = nil; queuedControl = [] }
            return socket
        }
        ws?.cancel(with: .normalClosure, reason: nil)
        emit(.status(status))
        continuation.finish()
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? LiveError { return e.description }
        if let e = error as? URLError { return "network error \(e.code.rawValue)" } // no URL: it holds the token
        return String(describing: type(of: error))
    }

    private static func reason(_ ws: URLSessionWebSocketTask) -> String {
        ws.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Test hooks

    /// Kills the socket as if the network dropped (exercises resume). Internal: tests only.
    func simulateDrop() {
        lock.withLock { socket }?.cancel(with: .goingAway, reason: nil)
    }
}
