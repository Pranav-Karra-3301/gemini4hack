import Foundation
import Network
import os
#if canImport(UIKit)
import UIKit
#endif

/// USB cable link to Coach Core, no Wi-Fi needed.
///
/// usbmuxd only lets the Mac open TCP connections to a port on the phone, so this is a reverse
/// tunnel. The Mac runs `tools/usb_bridge.py` (`./dev.sh usb`), which keeps a pool of idle
/// connections open into this phone's port 2347. The app talks HTTP/SSE/WebSocket to
/// `baseURL` (127.0.0.1:8788); each local connection claims one pooled uplink and the bytes are
/// spliced both ways, bridge side to Core on the Mac's 127.0.0.1:8787. Core sees a loopback
/// peer, so no token is needed (sending it is harmless).
///
/// Uplink protocol before splicing (one byte each):
/// bridge → phone `K` keepalive (on connect, then every second); phone → bridge `k` keepalive;
/// phone → bridge `G` claim; bridge → phone `A` Core connected, raw bytes follow.
public final class USBUplink: @unchecked Sendable {
    public static let shared = USBUplink()

    /// Port the Mac bridge connects to through usbmuxd (any interface; usbmuxd arrives on loopback).
    public static let uplinkPort: UInt16 = 2347
    /// The app's local entry point.
    public static let localPort: UInt16 = 8788
    /// Posted on the main queue when `isLinked` flips.
    public static let linkDidChangeNotification = Notification.Name("USBUplink.linkDidChange")

    /// Point `CoachClient` here while `isLinked`: `http://127.0.0.1:8788`.
    public let baseURL = URL(string: "http://127.0.0.1:\(USBUplink.localPort)")!

    /// The Mac bridge has been heard from within the last 3 s.
    public var isLinked: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastHeard > 0 && Self.now() - lastHeard < Self.linkWindow
    }

    /// Starts both listeners (idempotent). Safe to call from any thread.
    public func start() {
        lock.withLock { if armedAt == 0 { armedAt = Self.now() } }  // before returning, for waitForLink
        q.async { [self] in
            guard !started else { return }
            started = true
            startListeners()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            #if canImport(UIKit)
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.q.async { self?.resumeAfterBackground() } }
            #endif
        }
    }

    /// Stops listening and drops every uplink and session.
    public func stop() {
        q.async { [self] in
            guard started else { return }
            started = false
            timer?.cancel(); timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            uplinkListener?.cancel(); uplinkListener = nil
            localListener?.cancel(); localListener = nil
            idle.forEach { $0.close() }; idle.removeAll()
            waiting.forEach { $0.conn.cancel() }; waiting.removeAll()
            lock.lock(); lastHeard = 0; armedAt = 0; lock.unlock()
            publishLink()
        }
    }

    /// Waits for the bridge while it could still be dialing in: until `timeout` seconds after
    /// `start()` or the last return to the foreground (it dials in within ~1 s). Later calls
    /// return `isLinked` at once, so a connect without the cable pays no delay.
    public func waitForLink(timeout: TimeInterval = 1.5) async -> Bool {
        let deadline = lock.withLock { armedAt } + timeout
        while !isLinked {
            if Self.now() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    // MARK: - Internals (everything below runs on `q`)

    static let linkWindow: TimeInterval = 3
    static let staleAfter: TimeInterval = 4  // drop an idle uplink silent this long
    static let claimWait: TimeInterval = 3  // a local connection waits this long for an uplink
    static let ackWait: TimeInterval = 2  // the bridge must answer `G` with `A` this fast
    static let chunk = 256 * 1024
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    let q = DispatchQueue(label: "coach.usb-uplink")
    let log = Logger(subsystem: "dev.coach", category: "usb-uplink")
    private let lock = NSLock()
    private var lastHeard: TimeInterval = 0  // guarded by `lock`
    private var armedAt: TimeInterval = 0  // start() or foreground; guarded by `lock`
    private var started = false
    private var reportedLink = false
    private var uplinkListener: NWListener?
    private var localListener: NWListener?
    private var idle: [Uplink] = []
    private var waiting: [Waiter] = []
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    fileprivate final class Waiter {
        let conn: NWConnection
        let deadline: TimeInterval
        init(_ conn: NWConnection, deadline: TimeInterval) { self.conn = conn; self.deadline = deadline }
    }

    private init() {}

    private func startListeners() {
        if uplinkListener == nil { uplinkListener = makeListener(uplink: true) }
        if localListener == nil { localListener = makeListener(uplink: false) }
    }

    private func makeListener(uplink: Bool) -> NWListener? {
        let port = NWEndpoint.Port(rawValue: uplink ? Self.uplinkPort : Self.localPort)!
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if !uplink {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            params.acceptLocalOnly = true
        }
        let listener: NWListener
        do {
            listener = uplink ? try NWListener(using: params, on: port) : try NWListener(using: params)
        } catch {
            log.error("listen \(port.rawValue) failed: \(error.localizedDescription, privacy: .public)")
            restartLater()
            return nil
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.log.info("listening on \(port.rawValue)")
            case .failed(let error):
                // iOS defuncts listening sockets while the app is suspended.
                self.log.error("listener \(port.rawValue) failed: \(error.localizedDescription, privacy: .public)")
                listener.cancel()
                if self.uplinkListener === listener { self.uplinkListener = nil }
                if self.localListener === listener { self.localListener = nil }
                self.restartLater()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            if uplink { self.acceptUplink(conn) } else { self.acceptLocal(conn) }
        }
        listener.start(queue: q)
        return listener
    }

    private func restartLater() {
        q.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.started else { return }
            self.startListeners()
        }
    }

    private func resumeAfterBackground() {
        guard started else { return }
        lock.lock(); armedAt = Self.now(); lock.unlock()
        for l in [uplinkListener, localListener].compactMap({ $0 }) {
            if case .ready = l.state { continue }
            l.cancel()
            if uplinkListener === l { uplinkListener = nil }
            if localListener === l { localListener = nil }
        }
        startListeners()
        tick()
    }

    private func acceptUplink(_ conn: NWConnection) {
        // usbmuxd connects from the device's loopback; never hand app traffic to a LAN peer.
        guard Self.isLoopback(conn.endpoint) else {
            log.error("rejected uplink from \(String(describing: conn.endpoint), privacy: .public)")
            conn.cancel()
            return
        }
        let up = Uplink(conn, owner: self)
        conn.stateUpdateHandler = { [self] state in  // retains `up` until the connection ends
            switch state {
            case .ready:
                idle.append(up)
                up.send(0x6B)  // 'k': the app is here
                serveWaiters()
            case .failed:
                up.close()
            case .cancelled:
                idle.removeAll { $0 === up }
                conn.stateUpdateHandler = nil
            default:
                break
            }
        }
        conn.start(queue: q)
        up.receiveIdle()
    }

    private func acceptLocal(_ conn: NWConnection) {
        conn.start(queue: q)
        let w = Waiter(conn, deadline: Self.now() + Self.claimWait)
        waiting.append(w)
        serveWaiters()
        q.asyncAfter(deadline: .now() + Self.claimWait) { [weak self, weak w] in
            guard let self, let w, self.waiting.contains(where: { $0 === w }) else { return }
            self.waiting.removeAll { $0 === w }
            self.log.error("no uplink within \(Self.claimWait) s; is usb_bridge.py running?")
            w.conn.cancel()
        }
    }

    /// Pairs waiting local connections with the freshest idle uplinks.
    private func serveWaiters() {
        while !waiting.isEmpty {
            let now = Self.now()
            idle.removeAll { up in
                let stale = now - up.heard > Self.linkWindow
                if stale { up.close() }
                return stale
            }
            guard let i = idle.indices.max(by: { idle[$0].heard < idle[$1].heard }) else { return }
            let up = idle.remove(at: i)
            claim(up, for: waiting.removeFirst())
        }
    }

    private func claim(_ up: Uplink, for w: Waiter) {
        up.state = .claimed(w)
        up.send(0x47)  // 'G'
        q.asyncAfter(deadline: .now() + Self.ackWait) { [weak up] in
            guard let up, case .claimed = up.state else { return }
            up.close()  // requeues `w`
        }
    }

    /// The uplink died before the bridge answered the claim: try another one while time remains.
    fileprivate func claimFailed(_ w: Waiter) {
        guard started, Self.now() < w.deadline else {
            log.error("couldn't reach Core through the bridge")
            w.conn.cancel()
            return
        }
        waiting.insert(w, at: 0)  // the timer from acceptLocal still enforces the deadline
        serveWaiters()
    }

    fileprivate func heard(_ up: Uplink) {
        up.heard = Self.now()
        lock.lock(); lastHeard = up.heard; lock.unlock()
        if !reportedLink { publishLink() }
    }

    private func tick() {
        let now = Self.now()
        idle.removeAll { up in
            let stale = now - up.heard > Self.staleAfter
            if stale { up.close() }
            return stale
        }
        for up in idle { up.send(0x6B) }  // 'k'
        publishLink()
    }

    private func publishLink() {
        let linked = isLinked
        guard linked != reportedLink else { return }
        reportedLink = linked
        log.info("\(linked ? "linked to the Mac bridge" : "link down", privacy: .public)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.linkDidChangeNotification, object: self)
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }
}

// MARK: - Uplink and session

/// One connection from the Mac bridge. All methods run on the owner's queue.
private final class Uplink {
    enum State { case idle, claimed(USBUplink.Waiter), spliced, closed }

    let conn: NWConnection
    unowned let owner: USBUplink
    var state: State = .idle
    var heard: TimeInterval = USBUplink.now()

    init(_ conn: NWConnection, owner: USBUplink) { self.conn = conn; self.owner = owner }

    func send(_ byte: UInt8) {
        conn.send(content: Data([byte]), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        let was = state
        state = .closed
        conn.cancel()
        if case .claimed(let w) = was { owner.claimFailed(w) }
    }

    /// Reads keepalives until a claim is answered with `A`, then hands the stream to a session.
    func receiveIdle() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
            if case .closed = state { return }
            if let data, !data.isEmpty {
                owner.heard(self)
                if case .claimed(let w) = state, let a = data.firstIndex(of: 0x41) {  // 'A'
                    state = .spliced
                    Session(local: w.conn, up: self).begin(first: data[data.index(after: a)...], upEOF: isComplete)
                    return
                }
            }
            if isComplete || error != nil { close(); return }
            receiveIdle()
        }
    }
}

/// Splices one local connection with one claimed uplink, with half-close and backpressure:
/// each direction reads its next chunk only after the previous one was handed to the other side.
/// Pending callbacks keep the session alive; cancelling both connections releases it.
private final class Session {
    let local: NWConnection
    let up: Uplink
    private var localEOF = false, upEOF = false, closed = false

    init(local: NWConnection, up: Uplink) { self.local = local; self.up = up }

    func begin(first: Data.SubSequence, upEOF: Bool) {
        pump(from: local, to: up.conn, isLocal: true)
        if !first.isEmpty || upEOF {
            forward(first.isEmpty ? nil : Data(first), isComplete: upEOF, error: nil, from: up.conn, to: local, isLocal: false)
        } else {
            pump(from: up.conn, to: local, isLocal: false)
        }
    }

    private func pump(from src: NWConnection, to dst: NWConnection, isLocal: Bool) {
        src.receive(minimumIncompleteLength: 1, maximumLength: USBUplink.chunk) { [self] data, _, isComplete, error in
            forward(data, isComplete: isComplete, error: error, from: src, to: dst, isLocal: isLocal)
        }
    }

    private func forward(_ data: Data?, isComplete: Bool, error: NWError?, from src: NWConnection, to dst: NWConnection, isLocal: Bool) {
        guard !closed else { return }
        let next = { [self] in
            guard !closed else { return }
            if isComplete {
                // Pass the FIN along and keep the other direction open.
                if isLocal { localEOF = true } else { upEOF = true }
                dst.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                    if localEOF && upEOF { close() }
                })
            } else if error != nil {
                close()
            } else {
                pump(from: src, to: dst, isLocal: isLocal)
            }
        }
        if let data, !data.isEmpty {
            dst.send(content: data, completion: .contentProcessed { [self] sendError in
                if sendError != nil { close() } else { next() }
            })
        } else {
            next()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        local.cancel()
        up.state = .closed
        up.conn.cancel()
    }
}
