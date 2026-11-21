import CoachModels
import CoreImage
import Metal
import XCTest
@testable import CoachEdit

/// Local layers (CORE_API.md §7): models, no-op rules, mask math (invert, subtract, feather,
/// edge-aware), the alpha cache and timing. No network; see CoachEditLayersVisualTests for Core data.
final class CoachEditLayersTests: XCTestCase {

    // MARK: - Models

    /// The `edit/local` example from CORE_API.md §7, verbatim.
    static let planExample = #"""
    {"summary": "Brighten the couple, calm the background",
     "why": "A light warm base so the subject layer reads",
     "values": {"warmth": 8, "exposure": 0.1, "contrast": 8},
     "layers": [{"id": "l1", "target": "background",
                 "mask": {"source": "background", "invert": false, "subtract": ["sky"], "feather": 30, "edge": "depth"},
                 "values": {"exposure": -0.25, "saturation": -12}, "why": "Darken the busy street so they stand out"},
                {"id": "l2", "target": "the couple",
                 "mask": {"source": "subject", "invert": false, "subtract": [], "feather": 5, "edge": "image"},
                 "values": {"exposure": 0.35, "clarity": 15, "vibrance": 15}, "why": "Lift and sharpen the couple"}],
     "subject": "r1", "model": "gemini-4-hydrogen", "ms": 6000, "semantic_ms": 3, "cached": false}
    """#

    func testDecodeSection7Example() throws {
        let plan = try JSONDecoder().decode(LocalEditPlan.self, from: Data(Self.planExample.utf8))
        XCTAssertEqual(plan.values, [.warmth: 8, .exposure: 0.1, .contrast: 8])
        XCTAssertEqual(plan.layers.count, 2)
        let l1 = plan.layers[0], l2 = plan.layers[1]
        XCTAssertEqual(l1.id, "l1"); XCTAssertEqual(l1.target, "background")
        XCTAssertEqual(l1.mask, LayerMask(source: "background", subtract: ["sky"], feather: 30, edge: .depth))
        XCTAssertEqual(l1.values, [.exposure: -0.25, .saturation: -12])
        XCTAssertEqual(l2.mask.edge, .image); XCTAssertEqual(l2.mask.feather, 5)
        XCTAssertEqual(l2[.clarity], 15); XCTAssertEqual(l2.why, "Lift and sharpen the couple")
        XCTAssertEqual(plan.subject, "r1"); XCTAssertEqual(plan.cached, false)

        // As a recipe: round trip through JSON, `layers` key present, same layers back.
        let rec = plan.recipe()
        XCTAssertEqual(rec.layers?.count, 2); XCTAssertEqual(rec.subject, "r1"); XCTAssertFalse(rec.isIdentity)
        let json = try JSONEncoder().encode(rec)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: json), rec)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let layers = try XCTUnwrap(obj["layers"] as? [[String: Any]])
        XCTAssertEqual((layers[0]["mask"] as? [String: Any])?["edge"] as? String, "depth")
        XCTAssertEqual(rec.layerMaskNames, ["background", "sky", "subject"])

        // The semantic.json example (§7 "Semantic masks").
        let sem = #"""
        {"version": 1, "created": "2026-11-21T19:03:18Z",
         "masks": {"sky": {"url": "/api/shots/x/semantic/sky.png", "width": 1024, "height": 768,
                           "area": 0.31, "source": "union", "label": "sky", "kind": "sky", "ids": ["t5"]},
                   "t1": {"url": "/api/shots/x/semantic/t1.png", "area": 0.08, "source": "sam2.1", "label": "man in red shirt",
                          "kind": "person", "ids": ["t1"]},
                   "t10": {"url": "u", "area": 0.01}, "t2": {"url": "u", "area": 0.01}},
         "targets": [{"id": "t1", "label": "man in red shirt", "kind": "person",
                      "box": {"x": 0.31, "y": 0.22, "w": 0.18, "h": 0.6},
                      "box_2d": [220, 310, 820, 490], "points": [[400, 400]], "neg_points": []}],
         "subject": ["t1"], "labels": ["people", "faces", "sky"],
         "model": "gemini-4-hydrogen", "segmenter": "facebook/sam2.1-hiera-large",
         "timing": {"gemini": 10500, "sam": 900}}
        """#
        let s = try JSONDecoder().decode(SemanticMasks.self, from: Data(sem.utf8))
        XCTAssertEqual(s.masks["sky"]?.width, 1024); XCTAssertEqual(s.masks["sky"]?.ids, ["t5"])
        XCTAssertEqual(s.targets?.first?.box?.w, 0.18); XCTAssertEqual(s.subject, ["t1"])
        XCTAssertEqual(s.names, ["sky", "t1", "t2", "t10"])
    }

    func testRecipeLayersAreAdditiveAndLenient() throws {
        // Old recipes decode without layers and encode byte-identically (no `layers` key).
        let old = #"{"version":1,"values":{"exposure":0.3},"subject":"r1","look":{"id":"a","strength":0.5}}"#
        let rec = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        XCTAssertNil(rec.layers)
        let enc = String(decoding: try JSONEncoder().encode(rec), as: UTF8.self)
        XCTAssertFalse(enc.contains("layers"))
        // Lenient: clamp values, drop layer-forbidden sliders and malformed layers, cap at 5, default fields.
        let messy = #"""
        {"values": {}, "layers": [
          {"id": "a", "mask": {"source": "sky", "feather": 250, "edge": "laser", "subtract": ["sky", "t1", null, "t1", "t2", "t3", "t4", "t5"]},
           "values": {"exposure": 9, "vignette": -50, "depth_blur": 20, "clarity": "12", "bogus": 1}},
          {"id": "b", "values": {"exposure": 1}},
          {"id": "a", "mask": {"source": "r1", "invert": true}, "values": {"shadows": 0}},
          {"mask": {"source": "t1"}}, {"mask": {"source": "t2"}}, {"mask": {"source": "t3"}}, {"mask": {"source": "t4"}}]}
        """#
        let m = try JSONDecoder().decode(EditRecipe.self, from: Data(messy.utf8))
        let ls = try XCTUnwrap(m.layers)
        XCTAssertEqual(ls.count, EditLayer.maxCount)
        XCTAssertEqual(ls[0].mask.feather, 100); XCTAssertEqual(ls[0].mask.edge, .image)
        XCTAssertEqual(ls[0].mask.subtract, ["t1", "t2", "t3", "t4"])
        XCTAssertEqual(ls[0].values, [.exposure: 3, .clarity: 12])
        XCTAssertEqual(ls[0].target, "sky")
        XCTAssertEqual(ls[1].id, "l2"); XCTAssertTrue(ls[1].mask.invert); XCTAssertTrue(ls[1].isIdentity)
        XCTAssertEqual(Set(ls.map(\.id)).count, ls.count)
        // Identity layers keep a recipe identity; reset drops layers.
        var r = EditRecipe()
        r.layers = [EditLayer(id: "l1", mask: LayerMask(source: "sky"), values: [.exposure: 0])]
        XCTAssertTrue(r.isIdentity)
        r.layers?[0][.exposure] = 0.5
        XCTAssertFalse(r.isIdentity)
        r.reset()
        XCTAssertNil(r.layers)
    }

    // MARK: - Rendering

    static let W = 1000, H = 500

    /// A raw mask (1 inside `rect`, CI coordinates) over W×H.
    static func box(_ rect: CGRect, w: Int = W, h: Int = H) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        return CIImage(color: .white).cropped(to: rect.intersection(full))
            .composited(over: CIImage(color: .black).cropped(to: full))
    }

    /// Alpha value at a CI-coordinate pixel.
    func value(_ r: EditRenderer, _ img: CIImage, _ x: Int, _ y: Int) -> Float {
        var px = [Float](repeating: 0, count: 4)
        r.rawContext.render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                            format: .RGBAf, colorSpace: nil)
        return px[1]
    }

    /// A photo-like test image: a gray ramp plus a hard vertical edge at x = W/2 in the bottom half.
    static func photo() -> CIImage {
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: CGFloat(H)),
            "inputColor0": CIColor(red: 0.35, green: 0.4, blue: 0.45), "inputColor1": CIColor(red: 0.45, green: 0.5, blue: 0.55),
        ])!.outputImage!.cropped(to: full)
        let dark = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.08))
            .cropped(to: CGRect(x: W / 2, y: 0, width: W / 2, height: H / 2))
        return dark.composited(over: ramp)
    }

    func testIdentityAndMissingMaskLayersAreNoOps() async throws {
        let r = EditRenderer()
        let names = CoachEditFixtures.sampleNames()
        let loaded = await CoachEditFixtures.load(names.first ?? "")
        let s = try XCTUnwrap(loaded)
        r.register(mask: Self.box(CGRect(x: 0, y: 0, width: 500, height: 500)), named: "subject")
        r.register(mask: Self.box(.zero), named: "empty")
        let base = EditRecipe(values: [.exposure: 0.2, .contrast: 12, .warmth: 10, .vignette: -20], subject: "r1")
        var rec = base
        rec.layers = [
            EditLayer(id: "l1", mask: LayerMask(source: "subject", feather: 30, edge: .image)), // no values
            EditLayer(id: "l2", mask: LayerMask(source: "subject"), values: [.exposure: 0, .clarity: 0]),
            EditLayer(id: "l3", mask: LayerMask(source: "missing", feather: 10), values: [.exposure: 1]),
            EditLayer(id: "l4", mask: LayerMask(source: "empty", feather: 0), values: [.exposure: 1]),
        ]
        func px(_ recipe: EditRecipe) -> [UInt8] {
            LookFixtures.rgb(r, r.render(source: s.source, depth: s.depth, subjectMask: s.mask, recipe: recipe,
                                         quality: .preview(maxSide: 512)))
        }
        let a = px(base), b = px(rec)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(LookFixtures.diff(a, b).max, 0, "identity / missing / empty-mask layers must not change a pixel")
        // An empty layer list too.
        var empty = base; empty.layers = []
        XCTAssertEqual(LookFixtures.diff(a, px(empty)).max, 0)
        // A real layer does change pixels, only inside its mask (left half; feather 0).
        var live = base
        live.layers = [EditLayer(id: "l1", mask: LayerMask(source: "subject"), values: [.exposure: 0.5])]
        let img = r.render(source: s.source, depth: s.depth, subjectMask: s.mask, recipe: live, quality: .preview(maxSide: 512))
        let ref = r.render(source: s.source, depth: s.depth, subjectMask: s.mask, recipe: base, quality: .preview(maxSide: 512))
        let e = img.extent
        let left = CGRect(x: 0, y: 0, width: e.width * 0.45, height: e.height)
        let right = CGRect(x: e.width * 0.55, y: 0, width: e.width * 0.45, height: e.height).integral
        XCTAssertGreaterThan(LookFixtures.diff(LookFixtures.rgb(r, img, rect: left.integral), LookFixtures.rgb(r, ref, rect: left.integral)).mean, 5)
        XCTAssertEqual(LookFixtures.diff(LookFixtures.rgb(r, img, rect: right), LookFixtures.rgb(r, ref, rect: right)).max, 0)
    }

    func testInvertAndSubtract() throws {
        let r = EditRenderer()
        let size = CGSize(width: Self.W, height: Self.H)
        r.register(mask: Self.box(CGRect(x: 0, y: 0, width: 500, height: 500)), named: "left")
        r.register(mask: Self.box(CGRect(x: 0, y: 250, width: 1000, height: 250)), named: "top")
        r.register(mask: Self.box(CGRect(x: 0, y: 0, width: 250, height: 500)), named: "strip")
        let photo = Self.photo()
        // Quadrant centers (CI coords): top-left, top-right, bottom-left, bottom-right.
        let pts = [(250, 375), (750, 375), (250, 125), (750, 125)]
        func alpha(_ m: LayerMask) throws -> [Float] {
            let a = try XCTUnwrap(r.layerAlpha(m, source: photo, depth: nil, size: size))
            return pts.map { value(r, a, $0.0 + 60, $0.1) } // +60: clear of the 250 px strip edge
        }
        XCTAssertEqual(try alpha(LayerMask(source: "left")), [1, 0, 1, 0])
        XCTAssertEqual(try alpha(LayerMask(source: "left", invert: true)), [0, 1, 0, 1])
        XCTAssertEqual(try alpha(LayerMask(source: "left", subtract: ["top"])), [0, 0, 1, 0])
        XCTAssertEqual(try alpha(LayerMask(source: "left", invert: true, subtract: ["top"])), [0, 0, 0, 1])
        // Several subtracts multiply; a missing one is skipped.
        let a = try XCTUnwrap(r.layerAlpha(LayerMask(source: "left", subtract: ["top", "strip", "nope"]), source: photo, depth: nil, size: size))
        XCTAssertEqual(value(r, a, 100, 125), 0); XCTAssertEqual(value(r, a, 400, 125), 1)
        XCTAssertNil(r.layerAlpha(LayerMask(source: "nope"), source: photo, depth: nil, size: size))
        // Provider: asked only for unregistered names.
        let asked = LockedNames()
        r.maskProvider = { name in asked.add(name); return name == "p" ? Self.box(CGRect(x: 0, y: 0, width: 10, height: 10)) : nil }
        XCTAssertNotNil(r.layerAlpha(LayerMask(source: "p"), source: photo, depth: nil, size: size))
        XCTAssertNotNil(r.layerAlpha(LayerMask(source: "left"), source: photo, depth: nil, size: size))
        XCTAssertEqual(asked.names, ["p"])
    }

    func testFeatherScaleAndEdgeAwareness() throws {
        let r = EditRenderer()
        let size = CGSize(width: Self.W, height: Self.H)
        r.register(mask: Self.box(CGRect(x: 0, y: 0, width: 500, height: 500)), named: "left")
        let photo = Self.photo()
        // feather 50 on a 1000 px long side: r = 2% = 20 px, Gaussian σ = 10 px.
        let none = try XCTUnwrap(r.layerAlpha(LayerMask(source: "left", feather: 50, edge: .none), source: photo, depth: nil, size: size))
        XCTAssertEqual(value(r, none, 499, 400) + value(r, none, 500, 400), 1, accuracy: 0.02)
        XCTAssertEqual(value(r, none, 490, 400), 0.82, accuracy: 0.04) // Φ(0.95) at 9.5 px from the edge
        XCTAssertEqual(value(r, none, 510, 400), 0.18, accuracy: 0.04)
        XCTAssertEqual(value(r, none, 300, 400), 1, accuracy: 1e-3)
        // feather 0: the mask as is.
        let hard = try XCTUnwrap(r.layerAlpha(LayerMask(source: "left", feather: 0, edge: .image), source: photo, depth: nil, size: size))
        XCTAssertEqual(value(r, hard, 499, 100), 1); XCTAssertEqual(value(r, hard, 500, 100), 0)
        // Edge-aware: crisp where the mask edge sits on the photo's edge (bottom half), soft where the
        // photo is smooth (top half), like render.py's `near_edge` mix.
        let img = try XCTUnwrap(r.layerAlpha(LayerMask(source: "left", feather: 50, edge: .image), source: photo, depth: nil, size: size))
        XCTAssertGreaterThan(value(r, none, 506, 100), 0.2)
        XCTAssertLessThan(value(r, img, 506, 100), 0.05, "should stay crisp at the photo edge")
        XCTAssertGreaterThan(value(r, img, 494, 100), 0.95)
        XCTAssertEqual(value(r, img, 506, 450), value(r, none, 506, 450), accuracy: 0.03, "soft over smooth photo")
        // Depth edge without depth falls back to the plain blur.
        let depthless = try XCTUnwrap(r.layerAlpha(LayerMask(source: "left", feather: 50, edge: .depth), source: photo, depth: nil, size: size))
        XCTAssertEqual(value(r, depthless, 506, 100), value(r, none, 506, 100), accuracy: 1e-3)
        // Depth guide: a depth step at x = W/2 everywhere keeps the edge crisp top to bottom.
        var meters = [Float](repeating: 2, count: 100 * 50)
        for y in 0..<50 { for x in 50..<100 { meters[y * 100 + x] = 30 } }
        let depth = try XCTUnwrap(EditRenderer.depthImage(meters: meters, width: 100, height: 50))
        let dep = try XCTUnwrap(r.layerAlpha(LayerMask(source: "left", feather: 50, edge: .depth), source: photo, depth: depth, size: size))
        XCTAssertLessThan(value(r, dep, 508, 450), 0.08)
    }

    func testAlphaCache() throws {
        let r = EditRenderer()
        let size = CGSize(width: 400, height: 200)
        let photo = Self.photo()
        r.register(mask: Self.box(CGRect(x: 0, y: 0, width: 200, height: 200), w: 400, h: 200), named: "m")
        let spec = LayerMask(source: "m", feather: 40, edge: .image)
        let a = r.layerAlpha(spec, source: photo, depth: nil, size: size)
        XCTAssertTrue(a === r.layerAlpha(spec, source: photo, depth: nil, size: size), "same spec, size, guide: cached")
        // Feathers that round to the same pixel radius share the entry; a new radius, size or mask doesn't.
        var close = spec; close.feather = 40.4
        XCTAssertTrue(a === r.layerAlpha(close, source: photo, depth: nil, size: size))
        var far = spec; far.feather = 60
        XCTAssertFalse(a === r.layerAlpha(far, source: photo, depth: nil, size: size))
        XCTAssertFalse(a === r.layerAlpha(spec, source: photo, depth: nil, size: CGSize(width: 300, height: 150)))
        r.register(mask: Self.box(CGRect(x: 0, y: 0, width: 100, height: 200), w: 400, h: 200), named: "m")
        XCTAssertFalse(a === r.layerAlpha(spec, source: photo, depth: nil, size: size))
    }

    // MARK: - Timing

    /// Incremental cost per layer at a 1280 px preview, alphas cached (a slider drag): median of 40.
    func testLayerTiming() async throws {
        let r = EditRenderer()
        let data = try Data(contentsOf: CoachEditFixtures.samplesDir.appendingPathComponent("img-2178.jpg"))
        let src = try XCTUnwrap(EditRenderer.sourceImage(data: data))
        let e = CGRect(origin: .zero, size: CGSize(width: 1024, height: (1024 * src.extent.height / src.extent.width).rounded()))
        // Masks at the Core size (1024 long side): a soft subject ellipse, its inverse, a sky band, a small item.
        let ellipse = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: e.midX, y: e.midY * 0.8), "inputRadius0": e.height * 0.3, "inputRadius1": e.height * 0.32,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: e)
        r.register(mask: ellipse, named: "subject")
        r.register(mask: ellipse.applyingFilter("CIColorInvert"), named: "background")
        r.register(mask: CIImage(color: .white).cropped(to: CGRect(x: 0, y: e.height * 0.7, width: e.width, height: e.height * 0.3))
            .composited(over: CIImage(color: .black).cropped(to: e)), named: "sky")
        r.register(mask: CIImage(color: .white).cropped(to: CGRect(x: e.width * 0.1, y: e.height * 0.1, width: 80, height: 60))
            .composited(over: CIImage(color: .black).cropped(to: e)), named: "distraction")
        let layers = Self.timingLayers
        let stats = try Self.measure(r, source: src, depth: nil, layers: layers, globals: [.contrast: 10, .vibrance: 10, .vignette: -15])
        print(stats.line)
        try? stats.line.write(toFile: "/tmp/lc_qa/layers_timing_synthetic.txt", atomically: true, encoding: .utf8)
        #if DEBUG
        XCTAssertLessThan(stats.gpuPerLayer, 3, "layer GPU cost at 1280 px")
        #else
        XCTAssertLessThan(stats.gpuPerLayer + stats.encodePerLayer, 3, "layer cost at 1280 px")
        #endif
    }

    /// The `make them pop` plan's layer shapes (sky, background − sky by depth, subject, faces, distraction).
    static let timingLayers: [EditLayer] = [
        EditLayer(id: "l1", mask: LayerMask(source: "sky", feather: 30, edge: .image), values: [.exposure: -0.25, .highlights: -30, .clarity: 10]),
        EditLayer(id: "l2", mask: LayerMask(source: "background", subtract: ["sky"], feather: 25, edge: .depth),
                  values: [.exposure: -0.25, .contrast: -10, .saturation: -15, .clarity: -15]),
        EditLayer(id: "l3", mask: LayerMask(source: "subject", feather: 5, edge: .image), values: [.exposure: 0.25, .contrast: 15, .vibrance: 18, .clarity: 18]),
        EditLayer(id: "l4", mask: LayerMask(source: "subject", feather: 5, edge: .image), values: [.exposure: 0.2, .shadows: 15, .warmth: 6, .clarity: 5]),
        EditLayer(id: "l5", mask: LayerMask(source: "distraction", feather: 15, edge: .image), values: [.exposure: -0.35, .saturation: -30, .clarity: -25]),
    ]

    struct Timing {
        var line: String
        var gpuPerLayer: Double
        var encodePerLayer: Double
    }

    /// Renders to a Metal texture with 0 and all layers; each frame changes `warmth` (globally and in
    /// layer 1, a global slider drag: the worst case) so nothing is reused from the previous frame
    /// except the baked alphas.
    static func measure(_ r: EditRenderer, source: CIImage, depth: CIImage?, layers: [EditLayer],
                        globals: [Slider: Double], layerDrag: Bool = false) throws -> Timing {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func once(_ rec: EditRecipe) throws -> (wall: Double, gpu: Double, encode: Double) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = r.render(source: source, depth: depth, subjectMask: nil, recipe: rec, quality: .preview(maxSide: 1280))
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
        var frame = 0
        func recipe(_ n: Int) -> EditRecipe {
            frame += 1
            let w = -40 + Double(frame % 160) * 0.5
            var rec = EditRecipe(values: layerDrag ? globals : globals.merging([.warmth: w]) { $1 })
            if n > 0 {
                var ls = Array(layers.prefix(n))
                ls[0][.warmth] = w / 4
                rec.layers = ls
            }
            return rec
        }
        // First render with layers bakes the alphas (cache miss); time it separately.
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try once(recipe(layers.count))
        let miss = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        // Blocks of consecutive frames, like a slider drag (alternating graphs every frame would
        // measure Core Image's texture-pool churn instead), twice each.
        var t0s: [(Double, Double, Double)] = [], tNs: [(Double, Double, Double)] = []
        for _ in 0..<3 {
            for i in 0..<25 { let t = try once(recipe(0)); if i >= 5 { t0s.append(t) } }
            for i in 0..<25 { let t = try once(recipe(layers.count)); if i >= 5 { tNs.append(t) } }
        }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        let n = Double(layers.count)
        let gpu = (median(tNs.map(\.1)) - median(t0s.map(\.1))) / n
        let enc = (median(tNs.map(\.2)) - median(t0s.map(\.2))) / n
        let wall = (median(tNs.map(\.0)) - median(t0s.map(\.0))) / n
        let size = r.render(source: source, depth: nil, subjectMask: nil, recipe: EditRecipe(), quality: .preview(maxSide: 1280)).extent.size
        let line = String(format: "CoachEditLayers timing @%dx%d, median of 60 frames (encode / GPU / wall ms): base %.2f / %.2f / %.2f; %d layers %.2f / %.2f / %.2f; per layer +%.2f / +%.2f / +%.2f; first render with %d new alphas (bake) %.0f ms",
                          Int(size.width), Int(size.height), median(t0s.map(\.2)), median(t0s.map(\.1)), median(t0s.map(\.0)),
                          layers.count, median(tNs.map(\.2)), median(tNs.map(\.1)), median(tNs.map(\.0)), enc, gpu, wall, layers.count, miss)
        return Timing(line: line, gpuPerLayer: gpu, encodePerLayer: enc)
    }
}

/// Thread-safe name log for the provider test.
final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    func add(_ n: String) { lock.lock(); _names.append(n); lock.unlock() }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return _names }
}
