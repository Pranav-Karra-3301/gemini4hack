import CoachModels
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CoachEdit

/// Local layers on a real shot (COACH_IT=1): Core's semantic masks + two `edit/local` plans for the
/// shot in /tmp/lc_qa/last_sid. Writes /tmp/lc_qa/layers_<plan>.png (1280 px), _global.png (without
/// layers), _alphas.png (every layer's feathered alpha) and _zoom2x.png (mask edges at 2x:
/// global | layers | |diff|×4), and compares with experiments/masks/render.py run on the same
/// inputs (references in /tmp/lc_qa/layers_ref from /tmp/lc_qa/scratch/make_layer_refs.py: in.png, ref_<plan>[_global].png,
/// alpha_<plan>_<id>.png). Plans are cached in /tmp/lc_qa/layers_data/plan_<plan>.json, so Gemini is
/// called at most once per plan.
final class CoachEditLayersVisualTests: XCTestCase {
    static let plans = [("pop", "make them pop"),
                        ("moody", "moody evening: darken the sky and the hills, keep their faces warm and bright")]
    static let data = URL(fileURLWithPath: "/tmp/lc_qa/layers_data")
    static let refs = URL(fileURLWithPath: "/tmp/lc_qa/layers_ref")
    static let qa = URL(fileURLWithPath: "/tmp/lc_qa")
    /// Mask-edge crops (normalized, origin top-left): heads against sky and hills, the ridge, the roadside.
    static let zooms: [CGRect] = [CGRect(x: 0.62, y: 0.17, width: 0.18, height: 0.23), CGRect(x: 0.31, y: 0.33, width: 0.16, height: 0.22),
                                  CGRect(x: 0.80, y: 0.26, width: 0.19, height: 0.16), CGRect(x: 0.22, y: 0.58, width: 0.12, height: 0.22)]

    func get(_ path: String) async throws -> Data {
        let (d, resp) = try await URLSession.shared.data(from: CoachEditFixtures.core.appendingPathComponent(path))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200, path)
        return d
    }

    func plan(_ sid: String, tag: String, goal: String) async throws -> LocalEditPlan {
        let file = Self.data.appendingPathComponent("plan_\(tag).json")
        if !FileManager.default.fileExists(atPath: file.path) {
            var req = URLRequest(url: CoachEditFixtures.core.appendingPathComponent("api/shots/\(sid)/edit/local"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(LocalEditRequest(goal: goal))
            req.timeoutInterval = 90
            let (d, _) = try await URLSession.shared.data(for: req)
            try FileManager.default.createDirectory(at: Self.data, withIntermediateDirectories: true)
            try d.write(to: file)
        }
        return try JSONDecoder().decode(LocalEditPlan.self, from: Data(contentsOf: file))
    }

    func testRenderSemanticLayers() async throws {
        guard CoachEditFixtures.integration else { throw XCTSkip("set COACH_IT=1 (needs Core with a semantic shot)") }
        let sid = try String(contentsOfFile: "/tmp/lc_qa/last_sid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let r = EditRenderer()
        let sem = try JSONDecoder().decode(SemanticMasks.self, from: try await get("api/shots/\(sid)/semantic/semantic.json"))
        let imageData = try await get("api/shots/\(sid)/image.jpg"), depthData = try await get("api/shots/\(sid)/depth.png")
        let source = try XCTUnwrap(EditRenderer.sourceImage(data: imageData))
        let depth = try XCTUnwrap(EditRenderer.depthImage(pngData: depthData))
        var plans: [(String, LocalEditPlan)] = []
        for (tag, goal) in Self.plans { plans.append((tag, try await plan(sid, tag: tag, goal: goal))) }
        // Register every mask the plans read: semantic names from semantic.json, region ids from /masks.
        for name in Set(plans.flatMap { $0.1.recipe().layerMaskNames }) {
            let path = sem.masks[name]?.url.map { String($0.dropFirst()) } ?? "api/shots/\(sid)/masks/\(name).png"
            let png = try await get(path)
            r.register(mask: try XCTUnwrap(EditRenderer.maskImage(pngData: png)), named: name)
        }
        let parityIn = CIImage(contentsOf: Self.refs.appendingPathComponent("in.png"))
        var report: [String] = ["CoachEditLayers on \(sid) (\(sem.masks.count) semantic masks); mean |Δ| in /255"]
        for (tag, plan) in plans {
            XCTAssertGreaterThan(plan.layers.count, 0)
            let rec = plan.recipe(), global = EditRecipe(values: plan.values, subject: plan.subject)
            func render(_ recipe: EditRecipe, _ src: CIImage = source, side: Int = 1280) -> CIImage {
                r.render(source: src, depth: depth, subjectMask: nil, recipe: recipe, quality: .preview(maxSide: side))
            }
            let with = render(rec), without = render(global)
            try XCTUnwrap(r.pngData(with)).write(to: Self.qa.appendingPathComponent("layers_\(tag).png"))
            try XCTUnwrap(r.pngData(without)).write(to: Self.qa.appendingPathComponent("layers_\(tag)_global.png"))
            try Self.writeAlphas(r, plan.layers, source: source, depth: depth, size: with.extent.size,
                                 to: Self.qa.appendingPathComponent("layers_\(tag)_alphas.png"))
            try XCTUnwrap(r.pngData(Self.zoomSheet(without, with)))
                .write(to: Self.qa.appendingPathComponent("layers_\(tag)_zoom2x.png"))
            let changed = LookFixtures.diff(LookFixtures.rgb(r, with), LookFixtures.rgb(r, without)).mean
            XCTAssertGreaterThan(changed, 1, "\(tag): layers should visibly change the photo")
            var line = String(format: "%@ (%d layers): layers vs global-only %.2f", tag, plan.layers.count, changed)

            // Parity with render.py on its exact 1024 px input.
            if let parityIn, let ref = LookFixtures.pngRGB(Self.refs.appendingPathComponent("ref_\(tag).png")),
               let refG = LookFixtures.pngRGB(Self.refs.appendingPathComponent("ref_\(tag)_global.png")) {
                let ours = LookFixtures.rgb(r, render(rec, parityIn, side: 1024))
                let oursG = LookFixtures.rgb(r, render(global, parityIn, side: 1024))
                let full = LookFixtures.diff(ours, ref.rgb), glob = LookFixtures.diff(oursG, refG.rgb)
                // The layers' own contribution: (with − without) here vs in numpy.
                var dsum = 0.0, ourMag = 0.0, refMag = 0.0
                for i in 0..<min(ours.count, ref.rgb.count) {
                    let o = Double(ours[i]) - Double(oursG[i]), n = Double(ref.rgb[i]) - Double(refG.rgb[i])
                    dsum += abs(o - n); ourMag += abs(o); refMag += abs(n)
                }
                let count = Double(max(1, ours.count)), delta = dsum / count
                line += String(format: " | vs numpy: full %.2f, global-only %.2f, layer delta %.2f (|delta| ours %.2f, numpy %.2f)",
                               full.mean, glob.mean, delta, ourMag / count, refMag / count)
                // The masks match closely (alphas below); what remains is Core Image's slider math vs
                // render.py's numpy approximation of it, inside the layers.
                XCTAssertLessThan(delta, 5, "\(tag) layer contribution vs render.py")
                XCTAssertLessThan(full.mean, 6, "\(tag) full render vs render.py")
                var alphaLine: [String] = []
                for l in plan.layers {
                    guard let refA = Self.gray8(Self.refs.appendingPathComponent("alpha_\(tag)_\(l.id).png")) else { continue }
                    let a = try XCTUnwrap(r.layerAlpha(l.mask, source: parityIn, depth: depth, size: parityIn.extent.size))
                    let d = LookFixtures.diff(Self.alpha8(r, a), refA)
                    alphaLine.append(String(format: "%@ %@/%@ f%.0f %.2f (max %.0f)", l.id, l.mask.source, l.mask.edge.rawValue,
                                            l.mask.feather, d.mean, d.max))
                    XCTAssertLessThan(d.mean, 2, "\(tag) \(l.id) alpha vs render.py")
                }
                line += " | alphas: " + alphaLine.joined(separator: ", ")
            }
            report.append(line)
        }
        // Timing with the real masks and the first plan.
        let t = try CoachEditLayersTests.measure(r, source: source, depth: depth, layers: plans[0].1.layers, globals: plans[0].1.values)
        report.append(t.line)
        let text = report.joined(separator: "\n")
        print(text)
        try? text.write(toFile: "/tmp/lc_qa/layers_parity.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// One raw byte per pixel (rows top-first) of a single-value image.
    static func alpha8(_ r: EditRenderer, _ img: CIImage) -> [UInt8] {
        let w = Int(img.extent.width), h = Int(img.extent.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        r.rawContext.render(img, toBitmap: &px, rowBytes: w * 4, bounds: img.extent, format: .RGBA8, colorSpace: nil)
        return (0..<(w * h)).map { px[$0 * 4 + 1] }
    }

    /// Raw bytes of an 8-bit grayscale PNG.
    static func gray8(_ url: URL) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), cg.bitsPerPixel == 8,
              let data = cg.dataProvider?.data as Data? else { return nil }
        var out = [UInt8](); out.reserveCapacity(cg.width * cg.height)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<cg.height { for x in 0..<cg.width { out.append(p[y * cg.bytesPerRow + x]) } }
        }
        return out
    }

    /// Every layer's alpha side by side (half size), as an 8-bit gray PNG.
    static func writeAlphas(_ r: EditRenderer, _ layers: [EditLayer], source: CIImage, depth: CIImage?, size: CGSize, to url: URL) throws {
        var tiles: [CIImage] = []
        for l in layers { if let a = r.layerAlpha(l.mask, source: source, depth: depth, size: size) { tiles.append(a) } }
        guard !tiles.isEmpty else { return }
        let s: CGFloat = 0.5, tw = (size.width * s).rounded(), th = (size.height * s).rounded()
        var sheet = CIImage(color: CIColor(red: 0.5, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: (tw + 8) * CGFloat(tiles.count), height: th))
        for (i, t) in tiles.enumerated() {
            sheet = t.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: CGFloat(i) * (tw + 8), y: 0)))
                .cropped(to: CGRect(x: CGFloat(i) * (tw + 8), y: 0, width: tw, height: th)).composited(over: sheet)
        }
        let bytes = alpha8(r, sheet)
        let w = Int(sheet.extent.width), h = Int(sheet.extent.height)
        let cg = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bytes.withUnsafeBytes { b in cg.data!.copyMemory(from: b.baseAddress!, byteCount: w * h) }
        let img = try XCTUnwrap(cg.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Rows of 2x nearest-neighbor crops: global only | with layers | |difference| × 4.
    static func zoomSheet(_ before: CIImage, _ after: CIImage) -> CIImage {
        let e = after.extent
        let diff = after.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: before])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 4, w: 0),
            ])
        var rows: [CIImage] = []
        for z in zooms {
            let box = CGRect(x: z.minX * e.width, y: (1 - z.maxY) * e.height, width: z.width * e.width, height: z.height * e.height).integral
            var row = CIImage.empty()
            for (i, img) in [before, after, diff].enumerated() {
                let t = CGAffineTransform(translationX: -box.minX, y: -box.minY).concatenating(CGAffineTransform(scaleX: 2, y: 2))
                    .concatenating(CGAffineTransform(translationX: CGFloat(i) * (box.width * 2 + 6), y: 0))
                row = img.cropped(to: box).samplingNearest().transformed(by: t).composited(over: row)
            }
            rows.append(row)
        }
        var sheet = CIImage.empty(), y: CGFloat = 0
        for row in rows.reversed() {
            sheet = row.transformed(by: CGAffineTransform(translationX: 0, y: y)).composited(over: sheet)
            y += row.extent.height + 6
        }
        return sheet.composited(over: CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: sheet.extent))
    }
}
