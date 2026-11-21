import Foundation
import CoachModels

/// HTTP client for Coach Core (docs/CORE_API.md). Immutable configuration, safe to share.
///
/// ```swift
/// let core = CoachClient(pairing: pairing)        // or CoachClient.local on the Mac
/// let shot = try await core.uploadShot(jpeg: data, meta: meta)
/// for try await event in core.events() { ... }
/// ```
public actor CoachClient {
    /// e.g. `http://192.168.1.20:8787`.
    public nonisolated let baseURL: URL
    /// Bearer token; nil for loopback.
    public nonisolated let token: String?
    private nonisolated let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token?.isEmpty == true ? nil : token
        self.session = session
    }

    public init(pairing: Pairing, session: URLSession = .shared) {
        self.init(baseURL: pairing.baseURL, token: pairing.token, session: session)
    }

    /// The Mac's own Core at `http://127.0.0.1:8787`.
    public static var local: CoachClient { CoachClient(pairing: .local) }

    // MARK: Health and pairing

    /// `GET /api/health` (5 s timeout).
    public func health() async throws -> Health {
        try await send(request("/api/health", timeout: 5))
    }

    /// `GET /api/pair` (loopback only): the QR payload for the iPhone.
    public func pair() async throws -> Pairing {
        try await send(request("/api/pair", timeout: 5))
    }

    // MARK: Live

    /// `POST /api/live/token`: an ephemeral Gemini Live token with the session setup locked in.
    public func liveToken(_ body: LiveTokenRequest) async throws -> LiveTokenResponse {
        try await send(request("/api/live/token", method: "POST", json: body, timeout: 15))
    }

    // MARK: Shots

    /// `GET /api/shots`, newest first. Page with `before: lastShot.id`.
    public func shots(limit: Int = 50, before: String? = nil) async throws -> [Shot] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        let list: ShotList = try await send(request("/api/shots", query: q))
        return list.shots
    }

    /// `GET /api/shots/{id}`.
    public func shot(id: String) async throws -> Shot {
        try await send(request(Self.shotPath(id)))
    }

    /// `POST /api/shots` (multipart `image` + `meta`). Returns the new record; processing continues
    /// in the background and arrives through `events()`.
    public func uploadShot(jpeg: Data, meta: ShotMeta = ShotMeta()) async throws -> Shot {
        var form = MultipartForm()
        form.addFile(name: "image", filename: "shot.jpg", contentType: "image/jpeg", data: jpeg)
        form.addField(name: "meta", value: String(decoding: try encode(meta), as: UTF8.self))
        var req = try request("/api/shots", method: "POST", timeout: 120)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        return try await send(req, upload: form.body)
    }

    /// `DELETE /api/shots/{id}`.
    public func deleteShot(id: String) async throws {
        _ = try await data(for: request(Self.shotPath(id), method: "DELETE"))
    }

    /// `PUT /api/shots/{id}/edit`: saves the recipe, returns the updated record.
    public func putEdit(shotID: String, recipe: EditRecipe) async throws -> Shot {
        try await send(request(Self.shotPath(shotID) + "/edit", method: "PUT", json: recipe))
    }

    /// `POST /api/shots/{id}/edit/suggest`: a guided edit from the current values toward `goal`.
    public func suggestEdit(shotID: String, current: EditRecipe = .identity, goal: String? = nil) async throws -> EditSuggestion {
        let body = EditSuggestRequest(values: current.values, goal: goal?.isEmpty == true ? nil : goal)
        return try await send(request(Self.shotPath(shotID) + "/edit/suggest", method: "POST", json: body, timeout: 60))
    }

    /// `POST /api/shots/{id}/splat`: queues SHARP (~7 s, one at a time). Returns the record if Core sends one;
    /// progress arrives through `events()` either way.
    @discardableResult
    public func requestSplat(shotID: String) async throws -> Shot? {
        let body = try await data(for: request(Self.shotPath(shotID) + "/splat", method: "POST", timeout: 30))
        return try? JSONDecoder().decode(Shot.self, from: body)
    }

    // MARK: Assets

    /// A request for an asset URL from a shot record (relative like `/api/shots/<id>/thumb.jpg`, or absolute).
    /// Carries the bearer token only when the URL is on this Core.
    public nonisolated func assetRequest(_ path: String) throws -> URLRequest {
        try request(path, timeout: 60)
    }

    /// Downloads an asset (image, thumb, depth.png, mask, regions.json, splat.spz).
    public func assetData(_ path: String) async throws -> Data {
        try await data(for: assetRequest(path))
    }

    /// Fetches and decodes a JSON asset (`regions.json` → `RegionsResponse`, `score.json` → `ScoreReport`,
    /// `suggest.json` → `EditSuggestion`).
    public func assetJSON<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try await send(assetRequest(path))
    }

    // MARK: One-shot analysis (CONTRACT.md)

    /// `POST /api/score` with a JPEG: lighting and composition scores.
    public func score(jpeg: Data) async throws -> ScoreReport {
        try await multipartImage("/api/score", jpeg: jpeg)
    }

    /// `POST /api/regions` with a JPEG: three focus/remove regions.
    public func regions(jpeg: Data) async throws -> RegionsResponse {
        try await multipartImage("/api/regions", jpeg: jpeg)
    }

    // MARK: Events

    /// `GET /api/events` as typed events. Reconnects with exponential backoff (0.5 s → `maxBackoff`,
    /// with jitter; reset by each `hello`). After a reconnect, expect a fresh `hello`: refetch
    /// `shots()` then to catch anything missed. Finishes with an error only on 401/403 or 404
    /// (no events endpoint); cancel the consuming task to stop.
    public nonisolated func events(maxBackoff: TimeInterval = 15) -> AsyncThrowingStream<ShotEvent, Error> {
        let session = self.session
        let host = baseURL.host ?? baseURL.absoluteString
        let built = Result { () throws -> URLRequest in
            var r = try self.request("/api/events", timeout: 45)  // idle timeout; Core pings every 15 s
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            return r
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let req: URLRequest
                do { req = try built.get() } catch { continuation.finish(throwing: error); return }
                var delay = 0.5
                var parser = SSEParser()
                while !Task.isCancelled {
                    do {
                        let (bytes, response) = try await session.bytes(for: req)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            let err = CoachError.from(status: http.statusCode, body: Data(), path: "/api/events")
                            switch err {
                            case .unauthorized, .notFound: continuation.finish(throwing: err); return
                            default: throw err
                            }
                        }
                        parser.reset()
                        var chunk: [UInt8] = []
                        chunk.reserveCapacity(4096)
                        for try await byte in bytes {
                            chunk.append(byte)
                            guard byte == 0x0A || chunk.count >= 4096 else { continue }
                            for item in parser.feed(chunk) {
                                guard let event = ShotEvent(item) else { continue }
                                if case .hello = event { delay = Double(parser.retryMs ?? 500) / 1000 }
                                continuation.yield(event)
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    } catch {
                        if Task.isCancelled || CoachError.from(error, host: host) == .cancelled { break }
                    }
                    let jitter = Double.random(in: 0.8...1.2)
                    try? await Task.sleep(nanoseconds: UInt64(delay * jitter * 1_000_000_000))
                    delay = min(delay * 2, maxBackoff)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    static func shotPath(_ id: String) -> String {
        "/api/shots/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id)
    }

    nonisolated func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                             timeout: TimeInterval = 30) throws -> URLRequest {
        guard let resolved = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              var comps = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            throw CoachError.invalidURL(path)
        }
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query }
        guard let url = comps.url else { throw CoachError.invalidURL(path) }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only send the token to this Core, never to a foreign absolute URL.
        if let token, url.host == baseURL.host, url.port == baseURL.port {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    nonisolated func request<B: Encodable>(_ path: String, method: String, json body: B,
                                           timeout: TimeInterval = 30) throws -> URLRequest {
        var r = try request(path, method: method, timeout: timeout)
        r.httpBody = try encode(body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    private nonisolated func encode<B: Encodable>(_ body: B) throws -> Data {
        do { return try CoachJSON.encoder.encode(body) } catch { throw CoachError.decoding("encode \(B.self): \(error)") }
    }

    private func multipartImage<T: Decodable>(_ path: String, jpeg: Data) async throws -> T {
        var form = MultipartForm()
        form.addFile(name: "image", filename: "image.jpg", contentType: "image/jpeg", data: jpeg)
        var req = try request(path, method: "POST", timeout: 120)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        return try await send(req, upload: form.body)
    }

    private func data(for req: URLRequest, upload: Data? = nil) async throws -> Data {
        let host = baseURL.host.map { "\($0):\(baseURL.port ?? 80)" } ?? baseURL.absoluteString
        let body: Data, response: URLResponse
        do {
            if let upload { (body, response) = try await session.upload(for: req, from: upload) }
            else { (body, response) = try await session.data(for: req) }
        } catch {
            throw CoachError.from(error, host: host)
        }
        guard let http = response as? HTTPURLResponse else { throw CoachError.decoding("not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CoachError.from(status: http.statusCode, body: body, path: req.url?.path ?? "")
        }
        return body
    }

    private func send<T: Decodable>(_ req: URLRequest, upload: Data? = nil) async throws -> T {
        let body = try await data(for: req, upload: upload)
        do {
            return try JSONDecoder().decode(T.self, from: body)
        } catch {
            throw CoachError.decoding("\(T.self) from \(req.url?.path ?? ""): \(Self.describe(error))")
        }
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ c: DecodingError.Context) -> String {
            c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let k, let c): return "missing \(path(c)).\(k.stringValue)"
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            return "\(path(c)): \(c.debugDescription)"
        @unknown default: return "\(e)"
        }
    }
}

/// Minimal multipart/form-data body builder.
struct MultipartForm {
    let boundary = "CoachKit-\(UUID().uuidString)"
    private var parts = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    /// All parts plus the closing delimiter.
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
