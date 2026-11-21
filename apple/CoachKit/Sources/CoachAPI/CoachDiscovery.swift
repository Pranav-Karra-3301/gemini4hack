import Foundation
import Network
import CoachModels

/// A Coach Core found on the local network.
public struct DiscoveredCore: Hashable, Sendable, Identifiable {
    /// Bonjour service name, e.g. `Coach Core (Pranav's MacBook Pro)`.
    public let name: String
    /// Resolved IPv4 address (or hostname).
    public let host: String
    public let port: Int
    /// TXT record (Core sends `v=1`).
    public let txt: [String: String]

    public var id: String { name }

    public init(name: String, host: String, port: Int, txt: [String: String] = [:]) {
        self.name = name; self.host = host; self.port = port; self.txt = txt
    }

    /// Pairing for this Core; the token still comes from the QR code or the user.
    public func pairing(token: String?) -> Pairing { Pairing(host: host, port: port, token: token) }
}

/// Browses Bonjour for `_coachcore._tcp` and resolves each service to a host and port.
///
/// iOS apps need `NSLocalNetworkUsageDescription` and `NSBonjourServices = ["_coachcore._tcp"]`
/// in Info.plist.
public final class CoachDiscovery: Sendable {
    public static let serviceType = "_coachcore._tcp"

    public let type: String
    public let domain: String
    /// How long to wait for one service to resolve before giving up on it (it's retried on the next change).
    public let resolveTimeout: TimeInterval

    public init(type: String = CoachDiscovery.serviceType, domain: String = "local.", resolveTimeout: TimeInterval = 5) {
        self.type = type; self.domain = domain; self.resolveTimeout = resolveTimeout
    }

    /// The current set of resolved Cores, re-emitted whenever it changes (starts empty).
    /// Browsing stops when the consumer stops iterating.
    public func cores() -> AsyncStream<[DiscoveredCore]> {
        AsyncStream { continuation in
            let session = BrowseSession(type: type, domain: domain, timeout: resolveTimeout) { list in
                continuation.yield(list)
            }
            continuation.onTermination = { _ in session.cancel() }
            session.start()
        }
    }

    /// Waits for the first resolved Core (or nil after `timeout` seconds).
    public func first(timeout: TimeInterval = 5) async -> DiscoveredCore? {
        await withTaskGroup(of: DiscoveredCore?.self) { group in
            group.addTask {
                for await list in self.cores() { if let c = list.first { return c } }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

/// One browse: an NWBrowser plus a short NWConnection per service to learn its address.
/// All state is confined to `queue`.
private final class BrowseSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "coach.discovery")
    private let browser: NWBrowser
    private let timeout: TimeInterval
    private let emit: @Sendable ([DiscoveredCore]) -> Void
    private var resolved: [String: DiscoveredCore] = [:]
    private var resolving: [String: NWConnection] = [:]
    private var lastEmitted: [DiscoveredCore]?

    init(type: String, domain: String, timeout: TimeInterval, emit: @escaping @Sendable ([DiscoveredCore]) -> Void) {
        let params = NWParameters()
        params.includePeerToPeer = false
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: domain), using: params)
        self.timeout = timeout
        self.emit = emit
    }

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.publish(force: true) }
        }
        browser.start(queue: queue)
        queue.async { self.publish(force: true) }
    }

    func cancel() {
        queue.async {
            self.browser.cancel()
            self.resolving.values.forEach { $0.cancel() }
            self.resolving.removeAll()
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var present: Set<String> = []
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            present.insert(name)
            var txt: [String: String] = [:]
            if case .bonjour(let record) = r.metadata { txt = record.dictionary }
            if resolved[name] == nil && resolving[name] == nil { resolve(name: name, endpoint: r.endpoint, txt: txt) }
        }
        for name in resolved.keys where !present.contains(name) { resolved[name] = nil }
        for (name, c) in resolving where !present.contains(name) { c.cancel(); resolving[name] = nil }
        publish()
    }

    private func resolve(name: String, endpoint: NWEndpoint, txt: [String: String]) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4  // an IPv4 address makes a plain http:// URL
        }
        let conn = NWConnection(to: endpoint, using: params)
        resolving[name] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint {
                    self.resolved[name] = DiscoveredCore(name: name, host: Self.format(host),
                                                         port: Int(port.rawValue), txt: txt)
                }
                conn.cancel()
                self.resolving[name] = nil
                self.publish()
            case .failed, .waiting:
                conn.cancel()
                self.resolving[name] = nil
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak conn] in
            guard let self, let conn, self.resolving[name] === conn else { return }
            conn.cancel()
            self.resolving[name] = nil
        }
    }

    private func publish(force: Bool = false) {
        let list = resolved.values.sorted { $0.name < $1.name }
        guard force || list != lastEmitted else { return }
        lastEmitted = list
        emit(list)
    }

    static func format(_ host: NWEndpoint.Host) -> String {
        let raw: String
        switch host {
        case .ipv4(let a): raw = "\(a)"
        case .ipv6(let a): raw = "\(a)"
        case .name(let n, _): raw = n
        @unknown default: raw = "\(host)"
        }
        // Drop the interface scope ("192.168.1.20%en0").
        return raw.split(separator: "%").first.map(String.init) ?? raw
    }
}
