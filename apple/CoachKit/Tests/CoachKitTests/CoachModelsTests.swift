import XCTest
@testable import CoachModels

/// Fixtures are copied from docs/CORE_API.md and CONTRACT.md.
final class CoachModelsTests: XCTestCase {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Shot records

    static let shotJSON = """
    {"id": "20261121-143005-a1b2", "created": "2026-11-21T14:30:05.123456+00:00", "updated": "2026-11-21T17:42:28.959Z", "width": 4032, "height": 3024,
     "meta": {"source": "iphone", "device": "iPhone 17 Pro", "taken_at": "2026-11-21T14:30:01Z", "iso": 64, "shutter": 0.004,
       "ev": 0.0, "wb_kelvin": 5200, "tint": 0, "lens": "wide", "zoom": 1.0, "mode": "portrait",
       "focus": 0.42, "facing": "back", "intent": "portrait", "subject": "friend by the window",
       "keep": ["friend"], "scene": "", "coach": ["Turn her toward the window"]},
     "assets": {
       "image":   {"status": "done", "url": "/api/shots/20261121-143005-a1b2/image.jpg"},
       "original":{"status": "done", "url": "/api/shots/20261121-143005-a1b2/original.jpg"},
       "thumb":   {"status": "done", "url": "/api/shots/20261121-143005-a1b2/thumb.jpg"},
       "depth":   {"status": "done", "url": "/api/shots/20261121-143005-a1b2/depth.png",
                   "meta": {"width": 512, "height": 384, "p02": 0.8, "p98": 14.2, "focal_px": 1100.0, "units": "mm"}},
       "regions": {"status": "done", "url": "/api/shots/20261121-143005-a1b2/regions.json"},
       "masks":   {"status": "done", "urls": {"r1": "/api/shots/20261121-143005-a1b2/masks/r1.png"}},
       "score":   {"status": "done", "url": "/api/shots/20261121-143005-a1b2/score.json", "ms": 1040,
                   "summary": {"lighting": 3.17, "composition": 3.18}},
       "suggest": {"status": "running", "summary": null},
       "splat":   {"status": "error", "error": "out of memory"}
     },
     "edit": null}
    """

    func testShotRecordDecodes() throws {
        let shot = try decode(Shot.self, Self.shotJSON)
        XCTAssertEqual(shot.id, "20261121-143005-a1b2")
        XCTAssertEqual(shot.width, 4032)
        XCTAssertNotNil(shot.createdDate)
        XCTAssertEqual(shot.meta?.wbKelvin, 5200)
        XCTAssertEqual(shot.meta?.takenDate, ISO8601DateFormatter().date(from: "2026-11-21T14:30:01Z"))
        XCTAssertEqual(shot.meta?.keep, ["friend"])
        XCTAssertEqual(shot.assets.depth.meta?.focalPx, 1100)
        XCTAssertEqual(shot.assets.depth.meta?.units, "mm")
        XCTAssertEqual(shot.assets.masks.urls?["r1"], "/api/shots/20261121-143005-a1b2/masks/r1.png")
        XCTAssertEqual(shot.assets.score.status, .done)
        XCTAssertEqual(shot.assets.score.summaryScores, ["lighting": 3.17, "composition": 3.18])
        XCTAssertEqual(shot.assets.score.ms, 1040)
        XCTAssertNil(shot.assets.score.summaryText)
        XCTAssertNotNil(shot.updatedDate)
        XCTAssertEqual(shot.assets.suggest.status, .running)
        XCTAssertEqual(shot.assets.splat.status, .error)
        XCTAssertEqual(shot.assets.splat.error, "out of memory")
        XCTAssertTrue(shot.assets.thumb.isReady)
        XCTAssertTrue(shot.assets.isProcessing)
        XCTAssertNil(shot.edit)
    }

    func testShotToleratesMissingAndUnknownFields() throws {
        let shot = try decode(Shot.self, #"{"id": "x", "assets": {"depth": {"status": "warming"}, "future": {"status": "done"}}, "extra": 1}"#)
        XCTAssertEqual(shot.assets.depth.status, .none)
        XCTAssertEqual(shot.assets.splat, .missing)
        XCTAssertNil(shot.meta)
        let bare = try decode(Shot.self, #"{"id": "y"}"#)
        XCTAssertEqual(bare.assets, ShotAssets())
    }

    func testShotRoundTripsAndMetaUsesSnakeCase() throws {
        let shot = try decode(Shot.self, Self.shotJSON)
        let data = try CoachJSON.encoder.encode(shot)
        XCTAssertEqual(try JSONDecoder().decode(Shot.self, from: data), shot)
        let meta = String(decoding: try CoachJSON.encoder.encode(ShotMeta(takenAt: "t", wbKelvin: 5000)), as: UTF8.self)
        XCTAssertEqual(meta, #"{"taken_at":"t","wb_kelvin":5000}"#)
    }

    func testShotListAndEditInRecord() throws {
        let list = try decode(ShotList.self, """
        {"shots": [\(Self.shotJSON.replacingOccurrences(of: "\"edit\": null", with: #""edit": {"version": 1, "values": {"exposure": 0.3}, "subject": "r1"}"#))]}
        """)
        XCTAssertEqual(list.shots.first?.edit?.values[.exposure], 0.3)
        XCTAssertEqual(list.shots.first?.edit?.subject, "r1")
    }

    // MARK: Recipe and sliders

    func testRecipeFixture() throws {
        let r = try decode(EditRecipe.self, """
        {"version": 1, "values": {"exposure": 0.3, "warmth": 12, "depth_blur": 35},
         "subject": "r1", "crop": {"x": 0, "y": 0, "w": 1, "h": 1, "angle": 0}}
        """)
        XCTAssertEqual(r.values, [.exposure: 0.3, .warmth: 12, .depthBlur: 35])
        XCTAssertEqual(r.subject, "r1")
        XCTAssertEqual(r.crop, .full)
        XCTAssertEqual(r.value(.contrast), 0)
        XCTAssertNil(r.value(.focusDepth))
        let again = try JSONDecoder().decode(EditRecipe.self, from: CoachJSON.encoder.encode(r))
        XCTAssertEqual(again, r)
        let text = String(decoding: try CoachJSON.encoder.encode(r), as: UTF8.self)
        XCTAssertTrue(text.contains(#""depth_blur":35"#), text)
    }

    func testRecipeDecodingClampsAndDropsUnknown() throws {
        let r = try decode(EditRecipe.self, #"{"values": {"exposure": 9, "contrast": -400, "sparkle": 5, "focus_depth": null, "warmth": "15"}}"#)
        XCTAssertEqual(r.values, [.exposure: 3, .contrast: -100, .warmth: 15])
        XCTAssertEqual(r.version, 1)
    }

    func testSliderTableMatchesDoc() {
        XCTAssertEqual(Slider.allCases.count, 16)
        XCTAssertEqual(SliderSpec.table.count, 16)
        XCTAssertEqual(Slider.exposure.spec.range, -3...3)
        XCTAssertEqual(Slider.exposure.spec.unit, "EV")
        XCTAssertEqual(Slider.depthBlur.spec.range, 0...100)
        XCTAssertNil(Slider.focusDepth.spec.defaultValue)
        XCTAssertEqual(Slider.focusDepth.spec.unit, "m")
        for s in Slider.allCases where ![.exposure, .depthBlur, .focusDepth].contains(s) {
            XCTAssertEqual(s.spec.range, -100...100, s.rawValue)
            XCTAssertEqual(s.spec.defaultValue, 0, s.rawValue)
            XCTAssertTrue(s.spec.isBipolar)
        }
        XCTAssertEqual(SliderGroup.allCases.flatMap(\.sliders), Slider.allCases)
        XCTAssertEqual(Slider(name: "subjectLight"), .subjectLight)
        XCTAssertEqual(Slider(name: "Background Light"), .backgroundLight)
        XCTAssertNil(Slider(name: "sparkle"))
    }

    func testSliderClampSnapAndFormat() {
        let ex = Slider.exposure.spec
        XCTAssertEqual(ex.clamp(5), 3)
        XCTAssertEqual(ex.clamp(-5), -3)
        XCTAssertEqual(ex.clamp(.nan), 0)
        XCTAssertEqual(ex.snap(0.312), 0.3, accuracy: 1e-12)
        XCTAssertEqual(Slider.warmth.spec.snap(12.6), 13)
        XCTAssertEqual(Slider.depthBlur.spec.clamp(-10), 0)
        XCTAssertEqual(ex.format(0.3), "+0.30 EV")
        XCTAssertEqual(Slider.warmth.spec.format(12), "+12")
        XCTAssertEqual(Slider.warmth.spec.format(-12), "-12")
        XCTAssertEqual(Slider.depthBlur.spec.format(35), "35")
        XCTAssertEqual(Slider.focusDepth.spec.format(nil), "Auto")
        XCTAssertEqual(Slider.focusDepth.spec.format(2.4), "2.4 m")
    }

    func testRecipeSetClampsAndRemovesDefaults() {
        var r = EditRecipe()
        r.set(.exposure, 4)
        XCTAssertEqual(r.values[.exposure], 3)
        r[.shadows] = -250
        XCTAssertEqual(r[.shadows], -100)
        r.set(.exposure, 0)
        XCTAssertNil(r.values[.exposure])
        r.set(.focusDepth, 2.5)
        XCTAssertEqual(r.value(.focusDepth), 2.5)
        r.set(.focusDepth, nil)
        XCTAssertNil(r.value(.focusDepth))
        r.set(.shadows, nil)
        XCTAssertTrue(r.isIdentity)
        let applied = EditRecipe.identity.applying([.vignette: -500, .clarity: 20])
        XCTAssertEqual(applied.values, [.vignette: -100, .clarity: 20])
    }

    // MARK: Suggest, live token, pairing, health, scores

    func testSuggestionFixture() throws {
        let s = try decode(EditSuggestion.self, """
        {"summary": "Warm it up and let the subject glow",
         "steps": [{"slider": "exposure", "value": 0.3, "why": "Lift the underexposed faces", "region": null},
                   {"slider": "warmth", "value": 15, "why": "Bring back the sunset color", "region": null},
                   {"slider": "subject_light", "value": 20, "why": "Make the group the brightest thing", "region": "r1"},
                   {"slider": "sparkle", "value": 20, "why": "unknown slider is skipped"}],
         "values": {"exposure": 0.3, "warmth": 15, "subject_light": 20}, "subject": "r1",
         "model": "gemini-4-hydrogen", "ms": 4200}
        """)
        XCTAssertEqual(s.steps.count, 3)
        XCTAssertEqual(s.steps[2], EditStep(slider: .subjectLight, value: 20, why: "Make the group the brightest thing", region: "r1"))
        XCTAssertEqual(s.values, [.exposure: 0.3, .warmth: 15, .subjectLight: 20])
        XCTAssertEqual(s.ms, 4200)
        let recipe = s.recipe()
        XCTAssertEqual(recipe.subject, "r1")
        XCTAssertEqual(recipe.values[.warmth], 15)
        // values missing → derived from steps
        let derived = try decode(EditSuggestion.self, #"{"summary": "", "steps": [{"slider": "contrast", "value": 300, "why": ""}]}"#)
        XCTAssertEqual(derived.values, [.contrast: 100])
        let req = String(decoding: try CoachJSON.encoder.encode(EditSuggestRequest(values: [.warmth: 5], goal: "warmer")), as: UTF8.self)
        XCTAssertEqual(req, #"{"goal":"warmer","values":{"warmth":5}}"#)
    }

    func testLiveTokenFixtures() throws {
        let body = String(decoding: try CoachJSON.encoder.encode(LiveTokenRequest.camera()), as: UTF8.self)
        XCTAssertEqual(body, #"{"context":"","facing":"back","mode":"camera","voice":true}"#)
        let edit = String(decoding: try CoachJSON.encoder.encode(LiveTokenRequest.edit(shotId: "s1")), as: UTF8.self)
        XCTAssertEqual(edit, #"{"context":"","mode":"edit","shot_id":"s1","voice":true}"#)
        let r = try decode(LiveTokenResponse.self, """
        {"token": "auth_tokens/abc", "model": "gemini-3.8-live",
         "ws_url": "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token=auth_tokens/abc",
         "expire_time": "2026-11-21T15:00:00Z", "new_session_expire_time": "2026-11-21T14:31:00.000Z"}
        """)
        XCTAssertEqual(r.wsURL?.host, "generativelanguage.googleapis.com")
        XCTAssertNotNil(r.expiresAt)
        XCTAssertTrue(r.canStartSession(at: ISO8601DateFormatter().date(from: "2026-11-21T14:30:00Z")!))
        XCTAssertFalse(r.canStartSession(at: ISO8601DateFormatter().date(from: "2026-11-21T14:30:58Z")!))
    }

    func testPairingURLRoundTrip() throws {
        let p = Pairing(host: "192.168.1.20", port: 8787, token: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(p.url.absoluteString, "coach://pair?host=192.168.1.20&port=8787&token=0123456789abcdef0123456789abcdef")
        XCTAssertEqual(Pairing(url: p.url), p)
        XCTAssertEqual(Pairing(string: "  coach://pair?host=mac.local&token=a%2Bb%26c\n"),
                       Pairing(host: "mac.local", port: 8787, token: "a+b&c"))
        let odd = Pairing(host: "fe80::1", port: 9000, token: "t&=?")
        XCTAssertEqual(Pairing(url: odd.url), odd)
        XCTAssertEqual(odd.baseURL.absoluteString, "http://[fe80::1]:9000")
        XCTAssertEqual(p.baseURL.absoluteString, "http://192.168.1.20:8787")
        XCTAssertNil(Pairing(string: "https://pair?host=x"))
        XCTAssertNil(Pairing(string: "coach://other?host=x"))
        XCTAssertNil(Pairing(string: "coach://pair?port=8787"))
        XCTAssertNil(Pairing(string: "coach://pair?host=x&port=99999"))
        XCTAssertEqual(Pairing(address: "192.168.1.20:9000", token: " abc "), Pairing(host: "192.168.1.20", port: 9000, token: "abc"))
        XCTAssertEqual(Pairing(address: "mac.local", token: ""), Pairing(host: "mac.local"))
        // GET /api/pair
        let api = try decode(Pairing.self, #"{"host": "192.168.1.20", "port": 8787, "token": "abc", "url": "coach://pair?host=192.168.1.20&port=8787&token=abc"}"#)
        XCTAssertEqual(api, Pairing(host: "192.168.1.20", token: "abc"))
        XCTAssertTrue(Pairing.local.isLoopback)
    }

    func testHealthScoreRegions() throws {
        let h = try decode(Health.self, #"{"ok": true, "version": 1, "lan": true, "models": {"depth": "warm", "sam": {"state": "cold"}}}"#)
        XCTAssertEqual(h.models?["depth"], "warm")
        XCTAssertTrue(try decode(Health.self, #"{"ok": true}"#).ok)
        let s = try decode(ScoreReport.self, """
        {"provider": "emulated:x", "scores": {
          "lighting": {"score": 3.6, "scale": [1, 5], "confidence": 0.81,
                       "distribution": {"1": 0.01, "2": 0.05, "3": 0.30, "4": 0.55, "5": 0.09},
                       "label": "Soft window light, slightly underexposed"},
          "composition": {"score": 4.1, "scale": [1, 5], "confidence": 0.74,
                       "distribution": {"1": 0.0, "2": 0.02, "3": 0.15, "4": 0.52, "5": 0.31},
                       "label": "Strong leading line, subject a little centered"}}, "ms": 1800}
        """)
        XCTAssertEqual(s.lighting?.bins.map(\.bucket), [1, 2, 3, 4, 5])
        XCTAssertEqual(s.lighting?.bins[3].p, 0.55)
        XCTAssertEqual(s.composition?.normalized ?? 0, 0.775, accuracy: 1e-9)
        let r = try decode(RegionsResponse.self, """
        {"regions": [{"id": "r1", "box": {"x": 0.12, "y": 0.30, "w": 0.25, "h": 0.40}, "tag": "focus", "note": "One short line."}],
         "model": "google/gemini-4-argon", "ms": 2300}
        """)
        XCTAssertEqual(r.regions.first?.box.midX ?? 0, 0.245, accuracy: 1e-9)
        XCTAssertTrue(r.regions.first?.isFocus ?? false)
    }

    // MARK: Tool calls

    func call(_ json: String) throws -> FunctionCall { try decode(FunctionCall.self, json) }

    func testSetCameraEveryField() throws {
        let c = try call("""
        {"id": "fc1", "name": "set_camera", "args": {"mode": "night", "lens": "Ultra-Wide", "zoom": 12, "iso": "auto",
         "shutter": "1/125", "ev": -4, "focus": 0.3, "focus_x": 0.5, "focus_y": 1.4, "wb_kelvin": 12000, "tint": -60,
         "flash": "auto", "torch": "true", "why": "Brighter, steadier", "sparkle": 1}}
        """)
        guard case .camera(.setCamera(let s)) = CoachTool(c) else { return XCTFail("\(CoachTool(c))") }
        XCTAssertEqual(s.mode, .night)
        XCTAssertEqual(s.lens, .ultrawide)
        XCTAssertEqual(s.iso, .auto)
        XCTAssertEqual(s.shutter?.number ?? 0, 0.008, accuracy: 1e-12)
        XCTAssertEqual(s.flash, .auto)
        XCTAssertEqual(s.torch, true)
        XCTAssertEqual(s.ignored, ["sparkle"])
        let k = s.clamped(iso: 32...6400, shutter: 1.0 / 8000...1)
        XCTAssertEqual(k.zoom, 10)
        XCTAssertEqual(k.ev, -3)
        XCTAssertEqual(k.focusY, 1)
        XCTAssertEqual(k.wbKelvin, .value(9000))
        XCTAssertEqual(k.tint, -50)
        XCTAssertEqual(k.iso, .auto)
        // Encodes back with snake_case and "auto" strings, ignoring `ignored`.
        let applied = try JSONValue(encoding: k)
        XCTAssertEqual(applied["iso"], "auto")
        XCTAssertEqual(applied["wb_kelvin"], 9000)
        XCTAssertNil(applied["ignored"])
        let resp = String(decoding: try CoachJSON.encoder.encode(FunctionResponse.ok(c, applied: applied)), as: UTF8.self)
        XCTAssertTrue(resp.hasPrefix(#"{"id":"fc1","name":"set_camera","response":{"applied":{"#), resp)
        XCTAssertTrue(resp.hasSuffix(#""ok":true},"scheduling":"SILENT"}"#), resp)
    }

    func testSetCameraBadValuesAreIgnoredNotFatal() throws {
        let c = try call(#"{"name": "set_camera", "args": {"iso": "bright", "focus": "auto", "lens": "fisheye", "torch": null}}"#)
        guard case .camera(.setCamera(let s)) = CoachTool(c) else { return XCTFail() }
        XCTAssertEqual(s.focus, .auto)
        XCTAssertNil(s.iso)
        XCTAssertNil(s.torch)
        XCTAssertEqual(Set(s.ignored), ["iso", "lens"])
        XCTAssertFalse(s.isEmpty)
    }

    func testOtherCameraTools() throws {
        XCTAssertEqual(CoachTool(try call(#"{"name": "guide", "args": {"direction": "rotate_left", "strength": "large"}}"#)),
                       .camera(.guide(direction: .rotateLeft, strength: .large)))
        XCTAssertEqual(CoachTool(try call(#"{"name": "guide", "args": {"direction": "forward"}}"#)),
                       .camera(.guide(direction: .closer, strength: .medium)))
        XCTAssertEqual(CoachTool(try call(#"{"name": "set_intent", "args": {"intent": "food", "subject": "ramen bowl"}}"#)),
                       .camera(.setIntent(intent: .food, subject: "ramen bowl")))
        XCTAssertEqual(CoachTool(try call(#"{"name": "user_reaction", "args": {"reaction": "pleased", "heard": "oh that's good"}}"#)),
                       .camera(.userReaction(reaction: .pleased, heard: "oh that's good")))
        XCTAssertEqual(CoachTool(try call(#"{"name": "shot_ready", "args": {"ready": false}}"#)), .camera(.shotReady(false)))
        XCTAssertEqual(CoachTool(try call(#"{"name": "take_photo", "args": {"reason": "Light is perfect"}}"#)),
                       .camera(.takePhoto(reason: "Light is perfect")))
        XCTAssertEqual(CoachTool(try call(#"{"name": "take_photo"}"#)), .camera(.takePhoto(reason: nil)))
        let bad = try call(#"{"name": "guide", "args": {"direction": "sideways"}}"#)
        XCTAssertEqual(CoachTool(bad), .unknown(bad))
    }

    func testEditTools() throws {
        XCTAssertEqual(CoachTool(try call(#"{"name": "edit_step", "args": {"slider": "warmth", "value": 250, "why": "Sunset", "region": null}}"#)),
                       .edit(.editStep(EditStep(slider: .warmth, value: 100, why: "Sunset", region: nil))))
        XCTAssertEqual(CoachTool(try call(#"{"name": "edit_step", "args": {"slider": "focus_depth", "value": null, "region": "r1"}}"#)),
                       .edit(.editStep(EditStep(slider: .focusDepth, value: nil, why: "", region: "r1"))))
        let noValue = try call(#"{"name": "edit_step", "args": {"slider": "warmth"}}"#)
        XCTAssertEqual(CoachTool(noValue), .unknown(noValue))
        XCTAssertEqual(CoachTool(try call(#"{"name": "set_sliders", "args": {"values": {"exposure": 0.5, "shadows": -300, "glow": 4}, "why": "Lift"}}"#)),
                       .edit(.setSliders(values: [.exposure: 0.5, .shadows: -100], why: "Lift")))
        XCTAssertEqual(CoachTool(try call(#"{"name": "set_sliders", "args": {"values": "{\"vibrance\": 20}"}}"#)),
                       .edit(.setSliders(values: [.vibrance: 20], why: nil)))
        XCTAssertEqual(CoachTool(try call(#"{"name": "select_region", "args": {"region": "none"}}"#)), .edit(.selectRegion(nil)))
        XCTAssertEqual(CoachTool(try call(#"{"name": "select_region", "args": {"region": "r2"}}"#)), .edit(.selectRegion("r2")))
        XCTAssertEqual(CoachTool(try call(#"{"name": "compare", "args": {"show": "after"}}"#)), .edit(.compare(.after)))
        XCTAssertEqual(CoachTool(try call(#"{"name": "reset", "args": {}}"#)), .edit(.reset))
        XCTAssertEqual(CoachTool(try call(#"{"name": "save_edit"}"#)), .edit(.saveEdit))
        let unknown = try call(#"{"id": "z", "name": "make_coffee", "args": {"size": "large"}}"#)
        XCTAssertEqual(CoachTool(unknown), .unknown(unknown))
        let fail = String(decoding: try CoachJSON.encoder.encode(FunctionResponse.failure(unknown, error: "unknown tool")), as: UTF8.self)
        XCTAssertEqual(fail, #"{"id":"z","name":"make_coffee","response":{"error":"unknown tool","ok":false},"scheduling":"WHEN_IDLE"}"#)
    }

    func testJSONValueHelpers() throws {
        XCTAssertEqual(JSONValue.string("1/250").doubleValue ?? 0, 0.004, accuracy: 1e-12)
        XCTAssertEqual(JSONValue.string("0.5s").doubleValue, 0.5)
        XCTAssertNil(JSONValue.string("fast").doubleValue)
        XCTAssertEqual(JSONValue.number(64).stringValue, "64")
        XCTAssertEqual(try decode(JSONValue.self, #"{"a": [1, true, null, "x"]}"#), ["a": [1, true, nil, "x"]])
    }
}
