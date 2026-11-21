// SceneDrift (#30): a new subject is a "shift", moving off the ready framing is "moved"; shaking,
// exposure changes and a quick swing away and back are neither. Uses web/public/samples/*.jpg.
#if canImport(CoachLive)
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CoachAPI
@testable import CoachLive

@Suite struct CoachSceneDriftTests {
    static let samples = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web/public/samples")

    static func load(_ name: String) throws -> CGImage {
        let src = try #require(CGImageSourceCreateWithURL(samples.appendingPathComponent(name) as CFURL, nil))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 640,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return try #require(CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary))
    }

    /// A centred window `size` of each side, offset by (dx, dy) fractions: a camera view of the photo.
    static func view(_ img: CGImage, size: Double = 0.8, dx: Double = 0, dy: Double = 0, gain: Double = 1) throws -> LumaThumbnail {
        let w = Double(img.width), h = Double(img.height)
        let rect = CGRect(x: (w - w * size) / 2 + dx * w, y: (h - h * size) / 2 + dy * h, width: w * size, height: h * size)
        let crop = try #require(img.cropping(to: rect.integral))
        var t = try #require(LumaThumbnail(cgImage: crop))
        if gain != 1 { t.pixels = t.pixels.map { UInt8(clamping: Int((Double($0) * gain).rounded())) } }
        return t
    }

    static func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: samples.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
    }

    @Test func thresholdsSeparateScenesFromReframes() throws {
        let names = Self.names()
        #expect(names.count >= 4)
        let drift = SceneDrift()
        let imgs = try names.map(Self.load)
        let views = try imgs.map { try Self.view($0) }
        for i in views.indices {
            for j in views.indices where i != j {
                let d = SceneDrift.compare(views[i], views[j])
                #expect(d.mean >= drift.shiftMean && d.changedFraction >= drift.shiftChanged,
                        "\(names[i]) vs \(names[j]) should be a new scene: \(d)")
            }
            // Same photo: shaken 2 %, brighter, darker. Not a shift and not "moved".
            for (label, other) in [("shake", try Self.view(imgs[i], dx: 0.02)),
                                   ("bright", try Self.view(imgs[i], gain: 1.3)),
                                   ("dark", try Self.view(imgs[i], gain: 0.7))] {
                let d = SceneDrift.compare(views[i], other)
                #expect(d.mean < drift.movedMean && d.changedFraction < drift.movedChanged, "\(names[i]) \(label): \(d)")
            }
        }
    }

    @Test func sustainedNewSceneIsOneShift() throws {
        let names = Self.names()
        let a = try Self.view(Self.load(names[0])), b = try Self.view(Self.load(names[3]))
        var drift = SceneDrift()
        drift.anchorSubject(a)
        #expect(drift.observe(a, at: 0) == nil)
        #expect(drift.observe(b, at: 1) == nil)
        #expect(drift.observe(b, at: 2) == nil)            // 1.0 s changed: not yet
        guard case .shift(let mean, let changed)? = drift.observe(b, at: 2.5) else {
            Issue.record("expected a shift after 1.5 s"); return
        }
        #expect(mean >= 0.10 && changed >= 0.5)
        #expect(drift.subjectAnchor == b)                  // re-anchored on the new view
        #expect(drift.observe(b, at: 3) == nil)
        #expect(drift.observe(b, at: 10) == nil)           // once per anchor
    }

    @Test func quickSwingAwayAndBackIsNotAShift() throws {
        let names = Self.names()
        let a = try Self.view(Self.load(names[1])), b = try Self.view(Self.load(names[2]))
        var drift = SceneDrift()
        drift.anchorSubject(a)
        // Frames go out ≥1 s apart, so the "away" frame is the newest sent one for ~1.0–1.25 s.
        #expect(drift.observe(b, at: 0) == nil)
        #expect(drift.observe(b, at: 0.5) == nil)
        #expect(drift.observe(b, at: 1.0) == nil)
        #expect(drift.observe(try Self.view(Self.load(names[1]), dx: 0.01), at: 1.25) == nil)
        #expect(drift.observe(a, at: 5) == nil)
        #expect(drift.subjectAnchor == a)
    }

    @Test func sameSceneShiftedOrBrightenedIsNotAShift() throws {
        let img = try Self.load(Self.names()[4])
        let a = try Self.view(img)
        var drift = SceneDrift()
        drift.anchorSubject(a)
        let variants = [try Self.view(img, dx: 0.02), try Self.view(img, dy: -0.02),
                        try Self.view(img, gain: 1.3), try Self.view(img, gain: 0.7), try Self.view(img, size: 0.75)]
        var t = 0.0
        for v in variants {
            for _ in 0..<6 { #expect(drift.observe(v, at: t) == nil); t += 0.5 }
        }
    }

    @Test func movedOffTheReadyFraming() throws {
        let img = try Self.load(Self.names()[5])
        let a = try Self.view(img), moved = try Self.view(img, dx: 0.08)
        var drift = SceneDrift()
        drift.anchorSubject(a)
        drift.anchorReady(a)
        #expect(drift.observe(try Self.view(img, dx: 0.01), at: 0) == nil)   // shake
        #expect(drift.observe(try Self.view(img, gain: 1.2), at: 0.5) == nil) // exposure
        #expect(drift.observe(moved, at: 1) == nil)
        guard case .moved? = drift.observe(moved, at: 1.6) else { Issue.record("expected moved after 0.6 s"); return }
        #expect(drift.readyAnchor == nil)
        #expect(drift.observe(moved, at: 3) == nil)        // once per ready anchor
        #expect(drift.subjectAnchor == a)                  // moved doesn't touch the subject
    }

    @Test func reanchorResetsAndPendingAnchorTakesNextSample() throws {
        let names = Self.names()
        let a = try Self.view(Self.load(names[0])), b = try Self.view(Self.load(names[6]))
        var drift = SceneDrift()
        drift.anchorSubject(a)
        #expect(drift.observe(b, at: 0) == nil)
        #expect(drift.observe(b, at: 1) == nil)
        drift.anchorSubject(b)                             // set_intent on the new view
        #expect(drift.observe(b, at: 2) == nil)
        #expect(drift.observe(b, at: 5) == nil)

        var pending = SceneDrift()
        pending.anchorSubject(nil)                         // set_intent before any frame went out
        pending.anchorReady(nil)
        #expect(pending.observe(a, at: 0) == nil)
        #expect(pending.subjectAnchor == a && pending.readyAnchor == a)
        #expect(pending.observe(b, at: 1) == nil)
        // Both thresholds cross; a shift wins and clears the ready anchor too.
        guard case .shift? = pending.observe(b, at: 2.5) else { Issue.record("expected a shift"); return }
        #expect(pending.readyAnchor == nil)
    }

    @Test func directionDecodesLeniently() throws {
        let json = #"{"subject":"soda can","intent":"object","new_shot":true,"score":6.4,"issues":["tilted"],"move":"closer","strength":"small","mode":"macro","ready":false,"tip":"get low","model":"g4","ms":812,"extra":1}"#
        let d = try JSONDecoder().decode(Direction.self, from: Data(json.utf8))
        #expect(d.subject == "soda can" && d.newShot == true && d.score == 6 && d.issues == ["tilted"])
        #expect(d.move == "closer" && d.mode == "macro" && d.ready == false && d.ms == 812)
        let partial = try JSONDecoder().decode(Direction.self, from: Data(#"{"score":"high","tip":"hold still"}"#.utf8))
        #expect(partial.score == nil && partial.tip == "hold still" && partial.subject == nil)
    }
}
#endif
