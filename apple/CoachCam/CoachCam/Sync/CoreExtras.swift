import CoachAPI
import CoachModels
import Foundation
import Network

// Calls the app makes on Coach Core beyond CoachKit's `CoachClient`: the instant review stream
// (CORE_API.md §5), the shot upload with extra meta keys (`review_id`), and finding a reachable
// Core over every network path Bonjour sees (Wi-Fi or the USB Personal Hotspot link).

// MARK: - Instant review models

enum ReviewVerdict: String, Sendable, Hashable {
    case keeper, almost, retake
    init(_ raw: String?) { self = ReviewVerdict(rawValue: raw ?? "") ?? .almost }
}

/// One suggestion card: `action` ≤8 words, `why` ≤10 words, `direction` a camera move or `none`.
struct ReviewCard: Decodable, Hashable, Sendable {
    var action: String
    var why: String?
    var kind: String?
    var direction: String?
    var priority: Int?
    var speak: String?

    /// The card's camera move as a guide direction (nil for `none`).
    var guide: GuideDirection? { direction.flatMap { GuideDirection(rawValue: $0) } }
}

enum ReviewEvent: Sendable {
    /// ~0.6 s: the calibrated verdict, maybe a templated card.
    case decision(verdict: ReviewVerdict, card: ReviewCard?, working: String?)
    /// ~1.1 s: the first worded card.
    case suggestion(ReviewCard)
    /// ~1.2 s: verdict, 1–3 cards, what works, and the line to speak.
    case final(verdict: ReviewVerdict, cards: [ReviewCard], working: String?, speak: String?)
    case done(reviewID: String?)
}

/// `context` for `POST /api/review`: the live session's state at the shutter.
struct ReviewContext: Encodable, Sendable {
    struct Settings: Encodable, Sendable {
        var mode: String?
        var lens: String?
        var zoom: Double?
        var iso: Double?
        var shutter: Double?
        var ev: Double?
        var flash: String?
    }

    var reviewID: String
    var facing = "back"
    var intent: String?
    var subject: String?
    var keep: [String]?
    var scene: String?
    var heard: String?
    var coach: [String]?
    var settings: Settings?

    enum CodingKeys: String, CodingKey {
        case facing, intent, subject, keep, scene, heard, coach, settings
        case reviewID = "review_id"
    }
}

// MARK: - Core calls

enum CoreExtras {
    /// `POST /api/review` (multipart `image` + `context`) as a stream of review events. Ends after
    /// `done`, or with an error (status, transport, or the 10 s overall deadline).
    static func review(client: CoachClient, jpeg: Data, context: ReviewContext) -> AsyncThrowingStream<ReviewEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var form = Multipart()
                    form.addFile(name: "image", filename: "review.jpg", contentType: "image/jpeg", data: jpeg)
                    form.addField(name: "context", value: String(decoding: try JSONEncoder().encode(context), as: UTF8.self))
                    var req = try request(client, "/api/review", method: "POST", timeout: 10)
                    req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = form.body
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 2048 { break } }
                        throw error(status: http.statusCode, body: body, path: "/api/review")
                    }
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        line.append(byte)
                        guard byte == 0x0A else { continue }
                        for item in parser.feed(line) {
                            guard case .event(let e) = item, let event = Self.event(e) else { continue }
                            continuation.yield(event)
                            if case .done = event { continuation.finish(); return }
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(10))
                task.cancel()
            }
            continuation.onTermination = { _ in task.cancel(); deadline.cancel() }
        }
    }

    private static func event(_ e: SSEEvent) -> ReviewEvent? {
        let data = Data(e.data.utf8)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        func card(_ v: JSONValue?) -> ReviewCard? {
            guard let v, let d = try? JSONEncoder().encode(v) else { return nil }
            return try? JSONDecoder().decode(ReviewCard.self, from: d)
        }
        func text(_ key: String) -> String? {
            guard let s = json[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        switch e.event {
        case "decision":
            return .decision(verdict: ReviewVerdict(text("verdict")), card: card(json["card"]), working: text("working"))
        case "suggestion":
            return card(json).map(ReviewEvent.suggestion)
        case "final":
            let cards = (json["suggestions"]?.arrayValue ?? []).compactMap { card($0) }
            return .final(verdict: ReviewVerdict(text("verdict")), cards: cards, working: text("working"), speak: text("speak"))
        case "done":
            return .done(reviewID: text("review_id"))
        default:
            return nil
        }
    }

    /// `POST /api/shots` with `meta` plus `extra` top-level keys (e.g. `review_id`, which
    /// `ShotMeta` doesn't model). Errors map to `CoachError` like `CoachClient.uploadShot`.
    static func uploadShot(client: CoachClient, jpeg: Data, meta: ShotMeta, extra: [String: String]) async throws -> Shot {
        var object = (try JSONSerialization.jsonObject(with: CoachJSON.encoder.encode(meta)) as? [String: Any]) ?? [:]
        for (k, v) in extra { object[k] = v }
        var form = Multipart()
        form.addFile(name: "image", filename: "shot.jpg", contentType: "image/jpeg", data: jpeg)
        form.addField(name: "meta", value: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        var req = try request(client, "/api/shots", method: "POST", timeout: 120)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let host = client.baseURL.host() ?? client.baseURL.absoluteString
        let body: Data, response: URLResponse
        do {
            (body, response) = try await URLSession.shared.upload(for: req, from: form.body)
        } catch {
            throw transportError(error, host: host)
        }
        guard let http = response as? HTTPURLResponse else { throw CoachError.decoding("not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, body: body, path: "/api/shots") }
        do { return try JSONDecoder().decode(Shot.self, from: body) } catch { throw CoachError.decoding("Shot: \(error)") }
    }

    /// `POST /api/cam/say {text}` → WAV (Gemini TTS in the coach's voice, cached by Core).
    static func say(client: CoachClient, text: String) async throws -> Data {
        var req = try request(client, "/api/cam/say", method: "POST", timeout: 20)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (body, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw error(status: http.statusCode, body: body, path: "/api/cam/say")
        }
        return body
    }

    /// The PCM16 samples of a WAV (the `data` chunk). Core's TTS is 24 kHz mono.
    static func pcm(wav: Data) -> Data? {
        let b = [UInt8](wav)
        guard b.count > 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF" else { return nil }
        var i = 12
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self)
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            if id == "data" { return Data(b[(i + 8)..<min(b.count, i + 8 + size)]) }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    // MARK: Plumbing

    static func request(_ client: CoachClient, _ path: String, method: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: client.baseURL)?.absoluteURL else { throw CoachError.invalidURL(path) }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        if let token = client.token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    static func error(status: Int, body: Data, path: String) -> CoachError {
        let msg = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401, 403: return .unauthorized(msg.isEmpty ? "HTTP \(status)" : msg)
        case 404: return .notFound(path)
        default: return .server(status: status, message: msg.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : msg)
        }
    }

    static func transportError(_ error: Error, host: String) -> CoachError {
        if let e = error as? CoachError { return e }
        if error is CancellationError { return .cancelled }
        guard let u = error as? URLError else { return .transport(error.localizedDescription) }
        switch u.code {
        case .cancelled: return .cancelled
        case .timedOut: return .transport("Coach Core at \(host) took too long to answer.")
        default: return .transport("Can't reach Coach Core at \(host): \(u.localizedDescription)")
        }
    }
}

/// Minimal multipart/form-data body.
struct Multipart {
    let boundary = "CoachCam-\(UUID().uuidString)"
    private var parts = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    var body: Data { parts + Data("--\(boundary)--\r\n".utf8) }

    mutating func addField(name: String, value: String) {
        parts.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        parts.append(Data(value.utf8))
        parts.append(Data("\r\n".utf8))
    }

    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        parts.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                           + "Content-Type: \(contentType)\r\n\r\n").utf8))
        parts.append(data)
        parts.append(Data("\r\n".utf8))
    }
}

// MARK: - Finding a reachable Core

/// Finds Coach Core on whichever link works now. The Mac advertises `_coachcore._tcp` on every
/// interface, so one service can resolve to several IPv4 addresses (Wi-Fi `192.168.x.y`, the
/// iPhone's USB Personal Hotspot link `172.20.10.x`, ...). Every resolved address is probed with
/// `GET /api/health` (same token) and the first that answers wins, so a pairing made on Wi-Fi
/// keeps working over the cable and back.
@MainActor
enum CoreFinder {
    enum Result: Sendable {
        case found(Pairing)
        /// A Core answered but refused the token.
        case unauthorized
        case none
    }

    static func find(token: String?, timeout: TimeInterval = 6) async -> Result {
        let t0 = Date()
        let resolver = BonjourAddresses()
        resolver.start()
        defer { resolver.stop() }
        let box = ProbeResults()
        var probes: [Task<Void, Never>] = []
        defer { probes.forEach { $0.cancel() } }
        var started: Set<String> = []
        while Date().timeIntervalSince(t0) < timeout, !Task.isCancelled {
            // Probe each address as soon as it resolves (all in parallel).
            for (host, port) in resolver.addresses where started.insert("\(host):\(port)").inserted {
                let p = Pairing(host: host, port: port, token: token)
                probes.append(Task { @MainActor in
                    let r = await AppModel.check(CoachClient(pairing: p), timeout: 2.5)
                    box.results.append((p, r))
                })
            }
            // The first address that answered wins.
            for (p, r) in box.results {
                if case .ok = r {
                    #if DEBUG
                    print("CoachCam[pair] reachable at \(p.host):\(p.port) (resolved \(started.sorted()))")
                    #endif
                    return .found(p)
                }
            }
            // Everything resolved so far failed, and nothing new for a while: give up early.
            if !started.isEmpty, box.results.count == started.count, Date().timeIntervalSince(t0) > 3 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let refused = box.results.contains { if case .unauthorized = $0.1 { return true } else { return false } }
        return refused ? .unauthorized : .none
    }
}

@MainActor
private final class ProbeResults {
    var results: [(Pairing, AppModel.Check)] = []
}

/// Browses `_coachcore._tcp` and resolves every IPv4 address of every service (all interfaces).
@MainActor
final class BonjourAddresses: NSObject, NetServiceDelegate {
    private(set) var addresses: [(String, Int)] = []
    private var browser: NWBrowser?
    private var services: [String: NetService] = [:]

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: CoachDiscovery.serviceType, domain: "local."), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.resolve(names) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        services.values.forEach { $0.stop() }
        services.removeAll()
    }

    private func resolve(_ names: [String]) {
        for name in names where services[name] == nil {
            let s = NetService(domain: "local.", type: CoachDiscovery.serviceType + ".", name: name)
            s.delegate = self
            services[name] = s
            s.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let port = sender.port
        let found = (sender.addresses ?? []).compactMap(Self.ipv4)
        Task { @MainActor in
            for host in found where !self.addresses.contains(where: { $0.0 == host && $0.1 == port }) {
                // Prefer the USB hotspot link (172.20.10.x) when it is there: it is the cable.
                if host.hasPrefix("172.20.10.") { self.addresses.insert((host, port), at: 0) }
                else { self.addresses.append((host, port)) }
            }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}

    /// `sockaddr_in` → "a.b.c.d" (IPv6 is skipped: Core binds IPv4 and the URL stays plain).
    nonisolated static func ipv4(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr_in>.size,
                  let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == sa_family_t(AF_INET)
            else { return nil }
            var addr = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            let s = String(cString: buf)
            return s.hasPrefix("169.254.") ? nil : s
        }
    }
}
