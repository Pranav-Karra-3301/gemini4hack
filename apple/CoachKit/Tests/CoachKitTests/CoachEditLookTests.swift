import CoachModels
import CoreImage
import Metal
import XCTest
@testable import CoachEdit

/// Film looks (CORE_API.md §6): `.cube` parsing, identity, models, vignette rule, grain stability, timing.
final class CoachEditLookTests: XCTestCase {
    let r = EditRenderer()

    // MARK: - Models

    func testRecipeLookIsAdditive() throws {
        // Old JSON (no look) decodes and re-encodes without a `look` key.
        let old = #"{"version":1,"values":{"exposure":0.3},"subject":"r1"}"#
        let rec = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        XCTAssertNil(rec.look)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(rec), as: UTF8.self).contains("look"))
        // With a look: round trip, strength clamped, missing strength = 1, junk look ignored.
        var withLook = rec
        withLook.look = LookRef(id: "look-fit-1", strength: 0.6)
        let back = try JSONDecoder().decode(EditRecipe.self, from: try JSONEncoder().encode(withLook))
        XCTAssertEqual(back.look, LookRef(id: "look-fit-1", strength: 0.6))
        let j = #"{"values":{},"look":{"id":"a","strength":7}}"#
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: Data(j.utf8)).look?.strength, 1)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"look":{"id":"a"}}"#.utf8)).look?.strength, 1)
        XCTAssertNil(try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"look":"a"}"#.utf8)).look)
        XCTAssertTrue(EditRecipe().isIdentity)
        XCTAssertFalse(withLook.isIdentity)
        withLook.reset()
        XCTAssertNil(withLook.look)
    }

    func testEffectsDecodeBothShapes() throws {
        // film.py / effects.json shape.
        let url = LookFixtures.luts.appendingPathComponent("img-1016_fit.effects.json")
        let fx = try JSONDecoder().decode(LookEffects.self, from: Data(contentsOf: url))
        XCTAssertEqual(fx.grain.amount, 0.28); XCTAssertEqual(fx.halation.hue, 18); XCTAssertEqual(fx.bloom.threshold, 0.78)
        XCTAssertEqual(fx.vignette.midpoint, 0.55)
        // CORE_API §6 example shape: tint array, negative vignette, bloom without threshold.
        let doc = #"{"grain":{"amount":0.18,"size":1.2,"roughness":0.5},"halation":{"amount":0.2,"threshold":0.82,"radius":0.012,"tint":[1,0.45,0.25]},"bloom":{"amount":0.1,"radius":0.02},"vignette":{"amount":-0.15}}"#
        let d = try JSONDecoder().decode(LookEffects.self, from: Data(doc.utf8))
        XCTAssertEqual(EditRenderer.halationTint(d.halation), [1, 0.45, 0.25])
        XCTAssertEqual(d.bloom.threshold, 0.8); XCTAssertEqual(d.vignette.amount, -0.15)
        XCTAssertEqual(try JSONDecoder().decode(LookEffects.self, from: Data("{}".utf8)), .none)
        let hsv = EditRenderer.halationTint(fx.halation)
        XCTAssertEqual(hsv[0], 1, accuracy: 1e-9); XCTAssertEqual(hsv[1], 0.405, accuracy: 1e-3); XCTAssertEqual(hsv[2], 0.15, accuracy: 1e-9)
        // Look response.
        let look = try JSONDecoder().decode(Look.self, from: Data(#"{"id":"look-fit-1","name":"Coastal Gold","lut":"/x.cube","size":33,"effects":\#(doc),"spec":{"a":1}}"#.utf8))
        XCTAssertEqual(look.effects?.halation.tint, [1, 0.45, 0.25]); XCTAssertEqual(look.size, 33)
    }

    // MARK: - .cube

    func testParseEverySampleCube() throws {
        let cubes = try FileManager.default.contentsOfDirectory(atPath: LookFixtures.luts.path).filter { $0.hasSuffix(".cube") }
        XCTAssertGreaterThan(cubes.count, 10)
        for name in cubes {
            let lut = try CubeLUT(contentsOf: LookFixtures.luts.appendingPathComponent(name))
            XCTAssertEqual(lut.size, 33, name)
            XCTAssertEqual(lut.table.count, 33 * 33 * 33 * 3, name)
            XCTAssertNotNil(lut.title, name)
            XCTAssertTrue(lut.table.allSatisfy { $0 >= -0.01 && $0 <= 1.01 }, name)
        }
        XCTAssertThrowsError(try CubeLUT(cube: "0 0 0\n1 1 1\n")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .missingSize) }
        XCTAssertThrowsError(try CubeLUT(cube: "LUT_3D_SIZE 2\n0 0 0\n")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .wrongCount(expected: 8, got: 1))
        }
        XCTAssertThrowsError(try CubeLUT(cube: "LUT_1D_SIZE 4\n"))
        // Header variants, comments, red-fastest order.
        let t = "# c\nTITLE \"t\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n" +
            (0..<8).map { "\($0 & 1) \(($0 >> 1) & 1) \(($0 >> 2) & 1)" }.joined(separator: "\n")
        let small = try CubeLUT(cube: t)
        XCTAssertEqual(small.title, "t"); XCTAssertEqual(small.table, CubeLUT.identity(size: 2).table)
    }

    func testStrengthLerpAndCache() throws {
        let lut = try LookFixtures.lut("img-1016_fit")
        let half = lut.cubeData(strength: 0.5)
        XCTAssertEqual(half, lut.cubeData(strength: 0.501)) // same bucket
        let f = half.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let i = 1000, n = 33
        let idR = Float(i % n) / 32
        XCTAssertEqual(f[i * 4], idR + (lut.table[i * 3] - idR) * 0.5, accuracy: 1e-6)
        XCTAssertEqual(f[i * 4 + 3], 1)
    }

    func testIdentityLUTIsNoOp() async throws {
        let s = try await LookFixtures.source("img-1016")
        r.register(look: EditLook(id: "identity", lut: .identity()))
        var rec = EditRecipe()
        let base = r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 1024))
        rec.look = LookRef(id: "identity", strength: 1)
        let out = r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 1024))
        let (a, b) = (LookFixtures.rgb(r, base), LookFixtures.rgb(r, out))
        XCTAssertEqual(a.count, b.count)
        let d = LookFixtures.diff(a, b)
        print(String(format: "CoachEditLook identity LUT: max %.0f/255, mean %.3f/255", d.max, d.mean))
        XCTAssertLessThanOrEqual(d.max, 1)
        // Unregistered look ids render without a look.
        rec.look = LookRef(id: "missing", strength: 1)
        XCTAssertEqual(LookFixtures.diff(a, LookFixtures.rgb(r, r.render(source: s, depth: nil, subjectMask: nil, recipe: rec,
                                                                          quality: .preview(maxSide: 1024)))).max, 0)
    }

    // MARK: - Vignette rule, grain stability

    func testVignetteComposesWithSlider() async throws {
        let s = try await LookFixtures.source("img-1016")
        let lut = CubeLUT.identity()
        r.register(look: EditLook(id: "vig", lut: lut, effects: LookEffects(vignette: .init(amount: 0.3, midpoint: 0.5))))
        func corner(_ values: [Slider: Double], look: Bool) -> Float {
            var rec = EditRecipe(values: values)
            if look { rec.look = LookRef(id: "vig") }
            let img = r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 512))
            let px = LookFixtures.rgb(r, img, rect: CGRect(x: 0, y: 0, width: 24, height: 24))
            return Float(px.reduce(0) { $0 + Int($1) }) / Float(px.count)
        }
        let plain = corner([:], look: false), look = corner([:], look: true)
        let strong = corner([.vignette: -100], look: false), strongLook = corner([.vignette: -100], look: true)
        let weakLook = corner([.vignette: -10], look: true), lift = corner([.vignette: 40], look: true)
        print("CoachEditLook vignette corners: plain \(plain) look \(look) slider-100 \(strong) +look \(strongLook) slider-10+look \(weakLook) slider+40+look \(lift)")
        XCTAssertLessThan(look, plain - 3)                    // the look darkens the corners
        XCTAssertEqual(strongLook, strong, accuracy: 0.6)       // a darker slider: the look adds nothing
        XCTAssertEqual(weakLook, look, accuracy: 1.5)           // a lighter slider: the look's corners hold
        XCTAssertGreaterThan(lift, look + 2)                    // + lifts on top
    }

    func testGrainIsStableAcrossRenders() async throws {
        let s = try await LookFixtures.source("img-1016")
        r.register(look: try LookFixtures.look("img-1016_fit"))
        var rec = EditRecipe()
        rec.look = LookRef(id: "img-1016_fit", strength: 1)
        let a = LookFixtures.rgb(r, r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 640)))
        let b = LookFixtures.rgb(r, r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 640)))
        XCTAssertEqual(LookFixtures.diff(a, b).max, 0)
        // A different look id (another seed) changes the grain pattern.
        r.register(look: EditLook(id: "other", lut: try LookFixtures.lut("img-1016_fit"), effects: try LookFixtures.effects("img-1016_fit")))
        rec.look = LookRef(id: "other", strength: 1)
        let c = LookFixtures.rgb(r, r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 640)))
        XCTAssertGreaterThan(LookFixtures.diff(a, c).max, 0)
    }

    // MARK: - Timing

    /// Incremental cost of the look stage at 1280 px during a slider drag (warmth changes every
    /// frame), per component. Encode = CPU (recipe → CIImage → Metal commands); GPU = the command
    /// buffer's time; wall = encode + GPU + wait, serially (an MTKView overlaps encode and GPU).
    func testLookTiming() async throws {
        let s = try await LookFixtures.source("img-1216")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let fx = try LookFixtures.effects("img-1216_bold")
        var lutOnly = LookEffects.none, glow = fx
        glow.grain.amount = 0; glow.vignette.amount = 0
        lutOnly.vignette.amount = 0
        let variants: [(String, LookEffects?)] = [("none", nil), ("lut", lutOnly), ("lut+halation+bloom", glow), ("full", fx)]
        for (name, e) in variants { if let e { r.register(look: try LookFixtures.look("img-1216_bold", id: name, effects: e)) } }
        let values: [Slider: Double] = [.exposure: 0.2, .contrast: 15, .shadows: 20, .highlights: -20, .clarity: 20,
                                        .vibrance: 15, .vignette: -25]
        func once(_ rec: EditRecipe) throws -> (wall: Double, gpu: Double, encode: Double) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = r.render(source: s, depth: nil, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 1280))
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(img.extent.width),
                                                                height: Int(img.extent.height), mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            try r.render(img, to: tex, commandBuffer: cb)
            let encode = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            cb.commit(); cb.waitUntilCompleted()
            return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, (cb.gpuEndTime - cb.gpuStartTime) * 1000, encode)
        }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        // Every render gets its own warmth, so no variant reuses another's cached intermediates.
        var frame = 0
        func recipe(_ look: String, strength: Double = 0.8) -> EditRecipe {
            frame += 1
            var rec = EditRecipe(values: values.merging([.warmth: -45 + Double(frame) * 0.25]) { $1 })
            if look != "none" { rec.look = LookRef(id: look, strength: strength) }
            return rec
        }
        for _ in 0..<8 { for (name, _) in variants { _ = try once(recipe(name)) } } // warm up
        var t: [String: [(Double, Double, Double)]] = [:]
        for _ in 0..<60 { for (name, _) in variants { t[name, default: []].append(try once(recipe(name))) } }
        var strength: [(Double, Double, Double)] = [] // strength drag: a new LUT bucket every frame
        for i in 0..<30 { strength.append(try once(recipe("full", strength: 0.3 + Double(i) * 0.02))) }
        let wall = t.mapValues { median($0.map(\.0)) }, gpu = t.mapValues { median($0.map(\.1)) }
        let enc = t.mapValues { median($0.map(\.2)) }
        var line = String(format: "CoachEditLook timing @1280, sliders on, median of 60 (encode / GPU / wall ms): base %.2f / %.2f / %.2f",
                          enc["none"]!, gpu["none"]!, wall["none"]!)
        for (name, _) in variants.dropFirst() {
            line += String(format: "; %@ +%.2f / +%.2f / +%.2f", name, enc[name]! - enc["none"]!, gpu[name]! - gpu["none"]!,
                           wall[name]! - wall["none"]!)
        }
        line += String(format: "; full + strength drag (new LUT bucket each frame) +%.2f / +%.2f / +%.2f",
                       median(strength.map(\.2)) - enc["none"]!, median(strength.map(\.1)) - gpu["none"]!,
                       median(strength.map(\.0)) - wall["none"]!)
        print(line)
        try? line.write(toFile: "/tmp/lc_qa/look_timing.txt", atomically: true, encoding: .utf8)
        // Budget: < 4 ms incremental at 1280 px. Release: encode + GPU (the serial cost without the
        // wait latency). Debug (-Onone) inflates the CPU side ~2x, so only the GPU part is checked.
        #if DEBUG
        XCTAssertLessThan(gpu["full"]! - gpu["none"]!, 4, "look stage GPU cost at 1280 px")
        #else
        XCTAssertLessThan(enc["full"]! - enc["none"]! + gpu["full"]! - gpu["none"]!, 4, "look stage cost at 1280 px")
        #endif
    }
}

/// Paths and pixel helpers for the look tests.
enum LookFixtures {
    static let luts = CoachEditFixtures.repo.appendingPathComponent("experiments/film/out/luts")
    static let qa = URL(fileURLWithPath: "/tmp/lc_qa")

    static func source(_ name: String) async throws -> CIImage {
        let data = try Data(contentsOf: CoachEditFixtures.samplesDir.appendingPathComponent(name + ".jpg"))
        return try XCTUnwrap(EditRenderer.sourceImage(data: data))
    }

    static func lut(_ name: String) throws -> CubeLUT {
        try CubeLUT(contentsOf: luts.appendingPathComponent(name + ".cube"))
    }

    static func effects(_ name: String) throws -> LookEffects {
        try JSONDecoder().decode(LookEffects.self, from: Data(contentsOf: luts.appendingPathComponent(name + ".effects.json")))
    }

    static func look(_ name: String, id: String? = nil, effects fx: LookEffects? = nil) throws -> EditLook {
        EditLook(id: id ?? name, lut: try lut(name), effects: try fx ?? effects(name))
    }

    /// 8-bit sRGB RGB triples of a rendered image (rows top-first), optionally a sub-rect (CI coords).
    static func rgb(_ r: EditRenderer, _ img: CIImage, rect: CGRect? = nil) -> [UInt8] {
        let b = rect ?? img.extent
        let w = Int(b.width), h = Int(b.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        r.context.render(img, toBitmap: &px, rowBytes: w * 4, bounds: b, format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var out = [UInt8](); out.reserveCapacity(w * h * 3)
        for i in 0..<(w * h) { out.append(px[i * 4]); out.append(px[i * 4 + 1]); out.append(px[i * 4 + 2]) }
        return out
    }

    /// Raw RGB bytes of a PNG (no color matching: PIL writes untagged sRGB).
    static func pngRGB(_ url: URL) -> (w: Int, h: Int, rgb: [UInt8])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), cg.bitsPerComponent == 8,
              let data = cg.dataProvider?.data as Data? else { return nil }
        let bpp = cg.bitsPerPixel / 8, row = cg.bytesPerRow
        let first = [.first, .premultipliedFirst, .noneSkipFirst].contains(cg.alphaInfo) ? 1 : 0
        var out = [UInt8](); out.reserveCapacity(cg.width * cg.height * 3)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<cg.height { for x in 0..<cg.width {
                let o = y * row + x * bpp + first
                out.append(p[o]); out.append(p[o + 1]); out.append(p[o + 2])
            } }
        }
        return (cg.width, cg.height, out)
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, max: Double) {
        guard a.count == b.count, !a.isEmpty else { return (.infinity, .infinity) }
        var sum = 0, mx = 0
        for i in 0..<a.count { let d = abs(Int(a[i]) - Int(b[i])); sum += d; mx = max(mx, d) }
        return (Double(sum) / Double(a.count), Double(mx))
    }
}
