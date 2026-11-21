import XCTest
import CoachAPI
import CoachModels

/// Hits a running Core. Opt in: `COACH_IT=1 swift test --filter CoachAPIIntegrationTests`.
/// `COACH_URL` (default http://127.0.0.1:8787), `COACH_TOKEN` for a non-loopback Core.
/// Read-only unless `COACH_IT_WRITE=1` (then it uploads and deletes one shot).
/// Endpoints that Core doesn't have yet (404) are skipped, not failed.
final class CoachAPIIntegrationTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }
    var client: CoachClient!

    override func setUpWithError() throws {
        try XCTSkipUnless(env["COACH_IT"] == "1", "set COACH_IT=1 to run against a live Core")
        client = CoachClient(baseURL: URL(string: env["COACH_URL"] ?? "http://127.0.0.1:8787")!, token: env["COACH_TOKEN"])
    }

    /// Runs `op`, turning a 404 into a skip.
    func orSkip<T>(_ what: String, _ op: () async throws -> T) async throws -> T {
        do { return try await op() } catch CoachError.notFound(let p) {
            throw XCTSkip("\(what): \(p) not on this Core yet")
        }
    }

    /// `COACH_SAMPLE`, or the repo's `web/public/samples/img-1216.jpg` found by walking up from this file.
    static var sampleJPEG: Data {
        get throws {
            if let p = ProcessInfo.processInfo.environment["COACH_SAMPLE"] { return try Data(contentsOf: URL(fileURLWithPath: p)) }
            var dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            while dir.path != "/" {
                let f = dir.appendingPathComponent("web/public/samples/img-1216.jpg")
                if FileManager.default.fileExists(atPath: f.path) { return try Data(contentsOf: f) }
                dir.deleteLastPathComponent()
            }
            throw XCTSkip("no sample JPEG found; set COACH_SAMPLE")
        }
    }

    func testHealth() async throws {
        let t0 = Date()
        let h = try await client.health()
        XCTAssertTrue(h.ok)
        print("[IT] health ok in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, version=\(h.version.map(String.init) ?? "-") lan=\(h.lan.map(String.init) ?? "-")")
    }

    func testScoreShape() async throws {
        let t0 = Date()
        let report = try await client.score(jpeg: Self.sampleJPEG)
        let l = try XCTUnwrap(report.lighting), c = try XCTUnwrap(report.composition)
        for s in [l, c] {
            XCTAssertEqual(s.scale, [1, 5])
            XCTAssertTrue((1...5).contains(s.score))
            XCTAssertFalse(s.distribution.isEmpty)
            XCTAssertEqual(s.bins.reduce(0) { $0 + $1.p }, 1, accuracy: 0.05)
        }
        print("[IT] score lighting=\(l.score) composition=\(c.score) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms via \(report.provider ?? "?")")
    }

    func testShotsList() async throws {
        let shots = try await orSkip("shots") { try await client.shots(limit: 5) }
        XCTAssertLessThanOrEqual(shots.count, 5)
        XCTAssertEqual(shots.map(\.id), shots.map(\.id).sorted(by: >), "newest first")
        if let first = shots.first, let thumb = first.assets.thumb.url, first.assets.thumb.status == .done {
            let data = try await client.assetData(thumb)
            XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "thumb is a JPEG")
        }
        print("[IT] shots: \(shots.count)")
    }

    func testEventsHello() async throws {
        let stream = client.events()
        let first = try await withThrowingTaskGroup(of: ShotEvent?.self) { group in
            group.addTask { for try await e in stream { return e }; return nil }
            group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); return nil }
            defer { group.cancelAll() }
            do { return try await group.next() ?? nil } catch CoachError.notFound { throw XCTSkip("/api/events not on this Core yet") }
        }
        guard case .hello? = first else { return XCTFail("expected hello, got \(String(describing: first))") }
    }

    func testLiveTokenMint() async throws {
        let t0 = Date()
        let tok = try await orSkip("live token") { try await client.liveToken(.camera()) }
        XCTAssertTrue(tok.token.hasPrefix("auth_tokens/"))
        XCTAssertEqual(tok.wsURL?.scheme, "wss")
        XCTAssertTrue(tok.canStartSession())
        print("[IT] live token for \(tok.model) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    func testUploadAndDelete() async throws {
        try XCTSkipUnless(env["COACH_IT_WRITE"] == "1", "set COACH_IT_WRITE=1 to upload a test shot")
        let shot = try await orSkip("upload") {
            try await client.uploadShot(jpeg: Self.sampleJPEG, meta: ShotMeta(source: "coachkit-test", lens: "wide"))
        }
        XCTAssertFalse(shot.id.isEmpty)
        let again = try await client.shot(id: shot.id)
        XCTAssertEqual(again.id, shot.id)
        try await client.deleteShot(id: shot.id)
        do { _ = try await client.shot(id: shot.id); XCTFail("deleted shot still there") } catch CoachError.notFound {}
    }

    /// Uploads a shot, follows `events()` through depth → score/regions → masks → suggest, and decodes
    /// every JSON asset with the CoachModels types. `COACH_IT_WRITE=1` only (runs the models).
    func testPipelineEventsDecode() async throws {
        try XCTSkipUnless(env["COACH_IT_WRITE"] == "1", "set COACH_IT_WRITE=1 to upload a test shot")
        let client = self.client!
        let t0 = Date()
        let events = client.events()
        let shot = try await orSkip("upload") {
            try await client.uploadShot(jpeg: Self.sampleJPEG, meta: ShotMeta(source: "coachkit-test", intent: "portrait"))
        }
        let final = try await withThrowingTaskGroup(of: Shot?.self) { group in
            group.addTask {
                var undecoded = 0
                for try await e in events {
                    switch e {
                    case .shot(let s) where s.id == shot.id:
                        let a = s.assets
                        print("[IT] +\(Int(Date().timeIntervalSince(t0) * 1000)) ms depth=\(a.depth.status) score=\(a.score.status) regions=\(a.regions.status) masks=\(a.masks.status) suggest=\(a.suggest.status)")
                        let stages = [a.depth, a.score, a.regions, a.masks, a.suggest]
                        if stages.allSatisfy({ $0.status == .done || $0.status == .error }) { return s }
                    case .other(let name, let data) where name == "shot":
                        undecoded += 1
                        XCTFail("shot event didn't decode: \(data.prefix(300))")
                    default: break
                    }
                }
                return nil
            }
            group.addTask { try await Task.sleep(nanoseconds: 150_000_000_000); return nil }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let s = final else {
            try? await client.deleteShot(id: shot.id)
            return XCTFail("pipeline didn't finish in 150 s")
        }
        XCTAssertNotNil(s.assets.depth.meta?.p98)
        if s.assets.regions.status == .done, let u = s.assets.regions.url {
            let r: RegionsResponse = try await client.assetJSON(u)
            XCTAssertFalse(r.regions.isEmpty)
        }
        if s.assets.score.status == .done, let u = s.assets.score.url {
            let r: ScoreReport = try await client.assetJSON(u)
            XCTAssertNotNil(r.lighting)
        }
        if s.assets.suggest.status == .done, let u = s.assets.suggest.url {
            let r: EditSuggestion = try await client.assetJSON(u)
            XCTAssertFalse(r.steps.isEmpty)
            print("[IT] suggest: \(r.summary) (\(r.steps.count) steps, \(r.values.count) sliders)")
        }
        if let m = s.assets.masks.urls?.values.first {
            let png = try await client.assetData(m)
            XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        }
        for (name, a) in [("depth", s.assets.depth), ("score", s.assets.score), ("regions", s.assets.regions),
                          ("masks", s.assets.masks), ("suggest", s.assets.suggest)] where a.status == .error {
            print("[IT] \(name) error: \(a.error ?? "?")")
        }
        try await client.deleteShot(id: shot.id)
    }
}
