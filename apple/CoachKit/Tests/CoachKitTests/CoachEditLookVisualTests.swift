import CoachModels
import CoreImage
import XCTest
@testable import CoachEdit

/// Renders 3 samples with their designed looks at strengths 0, 0.6 and 1 to
/// /tmp/lc_qa/look_<sample>_<strength>.png and compares them with the numpy reference
/// (`experiments/film/film.py` `render`). References: /tmp/lc_qa/ref_<sample>_<strength>[_nograin|_lutonly].png
/// from `make_refs.py` (same 1024 px input); without them only the committed strength-1 JPEGs
/// in experiments/film/out/ are compared.
final class CoachEditLookVisualTests: XCTestCase {
    static let samples = [("img-1016", "img-1016_fit"), ("img-1216", "img-1216_bold"), ("img-1931", "img-1931_fit")]

    func testRenderLooksAgainstNumpy() async throws {
        let r = EditRenderer()
        var report: [String] = []
        for (sample, lookName) in Self.samples {
            let sampleSource = try await LookFixtures.source(sample)
            // Parity input: the exact 1024 px image numpy rendered (PIL LANCZOS thumbnail), if present,
            // so the numbers measure the look, not two resamplers. The look_*.png files use the sample.
            let refInput = LookFixtures.qa.appendingPathComponent("in_\(sample).png")
            let parity = FileManager.default.fileExists(atPath: refInput.path) ? CIImage(contentsOf: refInput) : nil
            let fx = try LookFixtures.effects(lookName)
            var noGrain = fx; noGrain.grain.amount = 0
            r.register(look: try LookFixtures.look(lookName))
            r.register(look: try LookFixtures.look(lookName, id: lookName + "-nograin", effects: noGrain))
            r.register(look: try LookFixtures.look(lookName, id: lookName + "-lutonly", effects: LookEffects.none))
            func render(_ id: String, _ strength: Double, from src: CIImage? = nil) -> CIImage {
                var rec = EditRecipe()
                rec.look = LookRef(id: id, strength: strength)
                return r.render(source: src ?? parity ?? sampleSource, depth: nil, subjectMask: nil, recipe: rec,
                                quality: .preview(maxSide: 1024))
            }
            for st in [0.0, 0.6, 1.0] {
                let tag = st == 0 ? "0" : st == 1 ? "1" : "0.6"
                try XCTUnwrap(r.pngData(render(lookName, st, from: sampleSource)))
                    .write(to: LookFixtures.qa.appendingPathComponent("look_\(sample)_\(tag).png"))
                let img = render(lookName, st)
                let ours = LookFixtures.rgb(r, img)
                var line = String(format: "%@ s=%.1f", sample, st)
                if let ref = LookFixtures.pngRGB(LookFixtures.qa.appendingPathComponent("ref_\(sample)_\(st).png")) {
                    let d = LookFixtures.diff(ours, ref.rgb)
                    line += String(format: " | full mean %.2f", d.mean)
                    XCTAssertLessThan(d.mean, 4, "\(sample) \(st)")
                }
                if st > 0, let ref = LookFixtures.pngRGB(LookFixtures.qa.appendingPathComponent("ref_\(sample)_\(st)_nograin.png")) {
                    let ngImage = render(lookName + "-nograin", st)
                    try XCTUnwrap(r.pngData(ngImage)).write(to: LookFixtures.qa.appendingPathComponent("look_\(sample)_\(tag)_nograin.png"))
                    let ng = LookFixtures.rgb(r, ngImage)
                    let d = LookFixtures.diff(ng, ref.rgb)
                    line += String(format: " | no-grain mean %.2f max %.0f", d.mean, d.max)
                    XCTAssertLessThan(d.mean, 1.5, "\(sample) \(st) no grain")
                    // Grain strength by luminance band: std of (full − no grain), ours / numpy.
                    if let full = LookFixtures.pngRGB(LookFixtures.qa.appendingPathComponent("ref_\(sample)_\(st).png")) {
                        line += " | grain std ours/np by L " + Self.grainBands(oursFull: ours, oursBase: ng, npFull: full.rgb, npBase: ref.rgb)
                    }
                }
                if st == 1 {
                    if let ref = LookFixtures.pngRGB(LookFixtures.qa.appendingPathComponent("ref_\(sample)_1.0_lutonly.png")) {
                        let d = LookFixtures.diff(LookFixtures.rgb(r, render(lookName + "-lutonly", 1)), ref.rgb)
                        line += String(format: " | LUT only mean %.2f max %.0f", d.mean, d.max)
                        XCTAssertLessThan(d.mean, 1, "\(sample) LUT")
                    }
                    let committed = CoachEditFixtures.repo.appendingPathComponent("experiments/film/out/\(lookName).jpg")
                    if let jpg = LookFixtures.pngRGB(committed) {
                        line += String(format: " | vs committed jpg %.2f", LookFixtures.diff(ours, jpg.rgb).mean)
                    }
                }
                report.append(line)
            }
        }
        let text = "CoachEditLook parity vs numpy (mean |Δ| in /255):\n" + report.joined(separator: "\n")
        print(text)
        try? text.write(toFile: "/tmp/lc_qa/look_parity.txt", atomically: true, encoding: .utf8)
    }

    /// "a/b/c/d/e": ours ÷ numpy grain std in luminance bands [0,.15) [.15,.4) [.4,.6) [.6,.85) [.85,1].
    static func grainBands(oursFull: [UInt8], oursBase: [UInt8], npFull: [UInt8], npBase: [UInt8]) -> String {
        let edges: [Double] = [0, 0.15, 0.4, 0.6, 0.85, 1.01]
        func stds(_ full: [UInt8], _ base: [UInt8]) -> [Double] {
            var s = [Double](repeating: 0, count: 5), s2 = s, n = s
            for i in stride(from: 0, to: min(full.count, base.count), by: 3) {
                let l = (0.2126 * Double(base[i]) + 0.7152 * Double(base[i + 1]) + 0.0722 * Double(base[i + 2])) / 255
                guard let b = edges.indices.dropLast().first(where: { l < edges[$0 + 1] }) else { continue }
                for c in 0..<3 {
                    let d = Double(full[i + c]) - Double(base[i + c])
                    s[b] += d; s2[b] += d * d; n[b] += 1
                }
            }
            return (0..<5).map { n[$0] > 100 ? (s2[$0] / n[$0] - pow(s[$0] / n[$0], 2)).squareRoot() : .nan }
        }
        let a = stds(oursFull, oursBase), b = stds(npFull, npBase)
        return (0..<5).map { String(format: "%.2f", a[$0] / b[$0]) }.joined(separator: "/")
            + String(format: " (np %.1f at mid)", b[2])
    }
}
