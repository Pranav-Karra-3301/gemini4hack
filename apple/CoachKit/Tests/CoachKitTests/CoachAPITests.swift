import XCTest
@testable import CoachAPI
@testable import CoachModels

final class CoachAPITests: XCTestCase {
    override func tearDown() { StubProtocol.reset() }

    // MARK: SSE parser

    static let canned = "\u{FEFF}event: hello\ndata: {\"version\": 1}\n\n"
        + ": ping\r\n\r\n"
        + "event: shot\r\ndata: {\"id\": \"20261121-143005-a1b2\",\r\ndata:  \"assets\": {\"thumb\": {\"status\": \"done\", \"url\": \"/t.jpg\"}}, \"meta\": {\"subject\": \"café ☕️\"}}\r\n\r\n"
        + "id: 7\rretry: 250\revent: shot_deleted\rdata: {\"id\": \"old\"}\r\r"
        + "data: no event name\n\n"
        + "event: shot\ndata: {not json}\n\n"
        + "event: ignored-no-data\n\n"
        + "event: hello\ndata: partial-at-end-is-not-dispatched"

    func expectCanned(_ items: [SSEItem], file: StaticString = #filePath, line: UInt = #line) {
        let events = items.compactMap(ShotEvent.init)
        XCTAssertEqual(events.count, 6, "\(events)", file: file, line: line)
        guard events.count == 6 else { return }
        XCTAssertEqual(events[0], .hello(["version": 1]), file: file, line: line)
        XCTAssertEqual(events[1], .ping, file: file, line: line)
        if case .shot(let s) = events[2] {
            XCTAssertEqual(s.id, "20261121-143005-a1b2", file: file, line: line)
            XCTAssertEqual(s.assets.thumb.url, "/t.jpg", file: file, line: line)
            XCTAssertEqual(s.meta?.subject, "café ☕️", file: file, line: line)
        } else { XCTFail("expected shot, got \(events[2])", file: file, line: line) }
        XCTAssertEqual(events[3], .shotDeleted(id: "old"), file: file, line: line)
        XCTAssertEqual(events[4], .other(event: "message", data: "no event name"), file: file, line: line)
        XCTAssertEqual(events[5], .other(event: "shot", data: "{not json}"), file: file, line: line)
    }

    func testSSEWholeStream() {
        var p = SSEParser()
        expectCanned(p.feed(Self.canned))
        XCTAssertEqual(p.retryMs, 250)
    }

    func testSSEEveryChunkSize() {
        let bytes = Array(Self.canned.utf8)
        for size in [1, 2, 3, 5, 7, 13, 64] {
            var p = SSEParser()
            var items: [SSEItem] = []
            var i = 0
            while i < bytes.count {
                items += p.feed(bytes[i..<min(i + size, bytes.count)])
                i += size
            }
            expectCanned(items)
        }
    }

    func testSSEEverySplitPoint() {
        // Two chunks, split at every byte (inside UTF-8 sequences and between \r and \n).
        let bytes = Array(Self.canned.utf8)
        for cut in 0...bytes.count {
            var p = SSEParser()
            let items = p.feed(bytes[..<cut]) + p.feed(bytes[cut...])
            XCTAssertEqual(items.compactMap(ShotEvent.init).count, 6, "cut at \(cut)")
        }
    }

    func testSSEMultilineDataAndId() {
        var p = SSEParser()
        let items = p.feed("id: 42\nevent: x\ndata:a\ndata: b\ndata\n\n")
        XCTAssertEqual(items, [.event(SSEEvent(event: "x", data: "a\nb\n", id: "42"))])
    }

    // MARK: Requests

    func testRequestsCarryTokenOnlyToCore() throws {
        let client = CoachClient(pairing: Pairing(host: "192.168.1.20", token: "secret"))
        let r = try client.assetRequest("/api/shots/a/thumb.jpg")
        XCTAssertEqual(r.url?.absoluteString, "http://192.168.1.20:8787/api/shots/a/thumb.jpg")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let foreign = try client.assetRequest("https://example.com/api/shots/a/thumb.jpg")
        XCTAssertNil(foreign.value(forHTTPHeaderField: "Authorization"))
        let local = try CoachClient.local.assetRequest("/api/health")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(CoachClient.shotPath("a b/c"), "/api/shots/a%20b%2Fc")
        let q = try client.request("/api/shots", query: [URLQueryItem(name: "limit", value: "5")])
        XCTAssertEqual(q.url?.absoluteString, "http://192.168.1.20:8787/api/shots?limit=5")
    }

    func testUploadSendsMultipartAndDecodesShot() async throws {
        StubProtocol.handler = { req, body in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/shots")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let ct = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(ct.hasPrefix("multipart/form-data; boundary="))
            let boundary = String(ct.split(separator: "=").last ?? "")
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"image\"; filename=\"shot.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nJPEGDATA\r\n"))
            XCTAssertTrue(text.contains("name=\"meta\"\r\n\r\n{\"iso\":64,\"lens\":\"wide\",\"source\":\"iphone\"}\r\n"))
            XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
            return .init(status: 201, body: Data(#"{"id": "new", "assets": {"depth": {"status": "pending"}}}"#.utf8))
        }
        let client = CoachClient(baseURL: URL(string: "http://core.test:8787")!, token: "tok", session: StubProtocol.session)
        let shot = try await client.uploadShot(jpeg: Data("JPEGDATA".utf8), meta: ShotMeta(source: "iphone", iso: 64, lens: "wide"))
        XCTAssertEqual(shot.id, "new")
        XCTAssertEqual(shot.assets.depth.status, .pending)
    }

    func testErrorsAreTypedAndReadable() async throws {
        StubProtocol.handler = { req, _ in
            switch req.url?.path {
            case "/api/shots/missing": return .init(status: 404, body: Data(#"{"error": "no such shot"}"#.utf8))
            case "/api/shots/boom": return .init(status: 500, body: Data(#"{"error": "depth failed"}"#.utf8))
            case "/api/live/token": return .init(status: 401, body: Data(#"{"error": "missing or wrong coach token"}"#.utf8))
            default: return .init(status: 200, body: Data(#"{"shots": [{"nope": 1}]}"#.utf8))
            }
        }
        let client = CoachClient(baseURL: URL(string: "http://core.test:8787")!, session: StubProtocol.session)
        await assertThrows(try await client.shot(id: "missing"), .notFound("/api/shots/missing"))
        await assertThrows(try await client.shot(id: "boom"), .server(status: 500, message: "depth failed"))
        await assertThrows(try await client.liveToken(.camera()), .unauthorized("missing or wrong coach token"))
        do { _ = try await client.shots(); XCTFail() } catch let e as CoachError {
            guard case .decoding(let m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("shots.0"), m)
        }
        // Nothing listens on port 9: readable transport error.
        do { _ = try await CoachClient(baseURL: URL(string: "http://127.0.0.1:9")!).health(); XCTFail() } catch let e as CoachError {
            guard case .transport(let m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("Can't reach Coach Core at 127.0.0.1:9"), m)
        }
    }

    func assertThrows<T>(_ op: @autoclosure () async throws -> T, _ expected: CoachError,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await op(); XCTFail("no error", file: file, line: line) }
        catch let e as CoachError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testEditEndpoints() async throws {
        StubProtocol.handler = { req, body in
            switch (req.httpMethod, req.url?.path) {
            case ("PUT", "/api/shots/s1/edit"):
                let recipe = try? JSONDecoder().decode(EditRecipe.self, from: body)
                XCTAssertEqual(recipe?.values[.warmth], 12)
                return .init(status: 200, body: Data(#"{"id": "s1", "edit": {"version": 1, "values": {"warmth": 12}}}"#.utf8))
            case ("POST", "/api/shots/s1/edit/suggest"):
                XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"goal":"warmer","values":{"warmth":12}}"#)
                return .init(status: 200, body: Data(#"{"summary": "s", "steps": [{"slider": "warmth", "value": 20, "why": "w", "region": null}]}"#.utf8))
            case ("DELETE", "/api/shots/s1"):
                return .init(status: 204, body: Data())
            default:
                return .init(status: 418, body: Data())
            }
        }
        let client = CoachClient(baseURL: URL(string: "http://core.test:8787")!, session: StubProtocol.session)
        let recipe = EditRecipe(values: [.warmth: 12])
        let saved = try await client.putEdit(shotID: "s1", recipe: recipe)
        XCTAssertEqual(saved.edit, recipe)
        let s = try await client.suggestEdit(shotID: "s1", current: recipe, goal: "warmer")
        XCTAssertEqual(s.values, [.warmth: 20])
        try await client.deleteShot(id: "s1")
    }

    // MARK: Events stream

    func testEventsReconnectAfterDrop() async throws {
        StubProtocol.handler = { req, _ in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            let n = StubProtocol.requestCount
            return .init(status: 200, chunks: [
                "retry: 50\nevent: hello\ndata: {\"n\": \(n)}\n\n",
                ": ping\n\n",
                "event: shot\ndata: {\"id\": \"s\(n)\"}\n",
                "\n",
            ].map { Data($0.utf8) })
        }
        let client = CoachClient(baseURL: URL(string: "http://core.test:8787")!, session: StubProtocol.session)
        var seen: [ShotEvent] = []
        let start = Date()
        for try await e in client.events() {
            seen.append(e)
            if seen.count == 6 { break }
        }
        XCTAssertEqual(seen, [.hello(["n": 1]), .ping, .shot(Shot(id: "s1")), .hello(["n": 2]), .ping, .shot(Shot(id: "s2"))])
        XCTAssertGreaterThanOrEqual(StubProtocol.requestCount, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "retry: 50 should make the reconnect fast")
    }

    func testEventsStopOnUnauthorized() async {
        StubProtocol.handler = { _, _ in .init(status: 401, body: Data(#"{"error": "nope"}"#.utf8)) }
        let client = CoachClient(baseURL: URL(string: "http://core.test:8787")!, session: StubProtocol.session)
        do {
            for try await _ in client.events() {}
            XCTFail("expected an error")
        } catch {
            guard case .unauthorized? = error as? CoachError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(StubProtocol.requestCount, 1)
    }
}

/// URLProtocol stub: one handler for all requests, records the count, streams chunked bodies.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var chunks: [Data]
        init(status: Int, body: Data) { self.status = status; chunks = [body] }
        init(status: Int, chunks: [Data]) { self.status = status; self.chunks = chunks }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest, Data) -> Reply)?
    nonisolated(unsafe) private static var _count = 0

    static var handler: ((URLRequest, Data) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
    static func reset() { lock.lock(); _handler = nil; _count = 0; lock.unlock() }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._count += 1; Self.lock.unlock()
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        guard let reply = Self.handler?(request, body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks where !chunk.isEmpty { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
