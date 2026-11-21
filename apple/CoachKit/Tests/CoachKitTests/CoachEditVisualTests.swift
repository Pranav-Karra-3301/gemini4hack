import CoachModels
import CoreImage
import XCTest
@testable import CoachEdit

/// Renders every sample photo with six looks to /tmp/lc_qa/edit_<sample>_<recipe>.png for eyeballing.
/// COACH_IT=1 uses real depth and masks from Core (see CoachEditFixtures).
final class CoachEditVisualTests: XCTestCase {
    static let recipes: [(String, EditRecipe)] = [
        ("neutral", EditRecipe()),
        ("warm_sunset", EditRecipe(values: [.warmth: 35, .tint: 6, .exposure: 0.15, .highlights: -30,
                                            .shadows: 15, .vibrance: 25, .vignette: -20])),
        ("moody", EditRecipe(values: [.exposure: -0.3, .contrast: 30, .highlights: -40, .shadows: -15,
                                      .blacks: -20, .saturation: -25, .warmth: -10, .clarity: 15, .vignette: -35])),
        ("subject_pop", EditRecipe(values: [.subjectLight: 25, .backgroundLight: -25, .depthBlur: 60,
                                            .vibrance: 15, .clarity: 10])),
        ("bw_clarity", EditRecipe(values: [.saturation: -100, .clarity: 60, .contrast: 20, .whites: 15, .blacks: -15])),
        ("vignette", EditRecipe(values: [.vignette: -80])),
    ]

    func testRenderSamples() async throws {
        let renderer = EditRenderer()
        let names = CoachEditFixtures.sampleNames()
        XCTAssertFalse(names.isEmpty)
        try FileManager.default.createDirectory(at: CoachEditFixtures.outDir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["COACH_EDIT_ONLY"]
        var real = 0
        for name in names where only == nil || only == name {
            guard let s = await CoachEditFixtures.load(name) else { XCTFail("load \(name)"); continue }
            if s.real { real += 1 }
            for (rname, recipe) in Self.recipes {
                let img = renderer.render(source: s.source, depth: s.depth, subjectMask: s.mask,
                                          recipe: recipe, quality: .preview(maxSide: 1280))
                let data = try XCTUnwrap(renderer.pngData(img))
                try data.write(to: CoachEditFixtures.outDir.appendingPathComponent("edit_\(name)_\(rname).png"))
            }
            if let d = s.depth {
                let f = renderer.subjectDepth(depth: d, subjectMask: s.mask) ?? -1
                print(String(format: "CoachEdit sample %@: %@ depth, subject at %.2f m, mask %@", name,
                             s.real ? "Core" : "synthetic", f, s.mask == nil ? "none" : "yes"))
            }
        }
        print("CoachEdit rendered \(names.count) samples x \(Self.recipes.count) recipes (\(real) with Core depth)")
    }
}
