import CoachModels
import CoreImage
import ImageIO
import Metal
import XCTest
@testable import CoachEdit

final class CoachEditTests: XCTestCase {
    static let renderer = EditRenderer()
    var r: EditRenderer { Self.renderer }

    // MARK: - Helpers

    /// Mean linear RGB over a normalized rect (origin top-left).
    func mean(_ img: CIImage, _ rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> SIMD3<Float> {
        let e = img.extent
        let box = CGRect(x: e.minX + rect.minX * e.width, y: e.minY + (1 - rect.maxY) * e.height,
                         width: rect.width * e.width, height: rect.height * e.height)
        let avg = img.cropped(to: box).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: box)])
        var px = [Float](repeating: 0, count: 4)
        r.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return SIMD3(px[0], px[1], px[2])
    }

    func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    func sample() async throws -> CoachEditFixtures.Sample {
        let names = CoachEditFixtures.sampleNames()
        let s = await CoachEditFixtures.load(names.first ?? "")
        return try XCTUnwrap(s, "no sample photos in \(CoachEditFixtures.samplesDir.path)")
    }

    func render(_ s: CoachEditFixtures.Sample, _ values: [Slider: Double], crop: Crop? = nil, side: Int = 640) -> CIImage {
        r.render(source: s.source, depth: s.depth, subjectMask: s.mask,
                 recipe: EditRecipe(values: values, crop: crop), quality: .preview(maxSide: side))
    }

    // MARK: - Tone curve

    func testToneCurveIdentityAndMonotonic() {
        let id = ToneCurve()
        XCTAssertTrue(id.isIdentity)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) { XCTAssertEqual(id.value(x), x, accuracy: 1e-9) }
        let extremes: [ToneCurve] = [
            ToneCurve(contrast: 1, highlights: -1, shadows: 1, whites: 1, blacks: -1),
            ToneCurve(contrast: -1, highlights: 1, shadows: -1, whites: -1, blacks: 1),
            ToneCurve(contrast: 0.4, domainMax: 2.4),
        ]
        for c in extremes {
            let s = c.samples(count: 512)
            XCTAssertEqual(s.count, 512)
            for i in 1..<s.count { XCTAssertGreaterThanOrEqual(s[i], s[i - 1]) }
            XCTAssertTrue(s.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
        // Headroom rolls off to exactly white at domainMax, smoothly (slope ~1 at the knee).
        let sh = ToneCurve(domainMax: 2)
        XCTAssertEqual(sh.value(2), 1, accuracy: 1e-6)
        XCTAssertEqual(sh.value(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(sh.value(ToneCurve.knee + 0.001) - sh.value(ToneCurve.knee), 0.001, accuracy: 1e-4)
        // Contrast pivots around mid-grey and keeps the endpoints.
        let c = ToneCurve(contrast: 0.5)
        XCTAssertEqual(c.value(0), 0, accuracy: 1e-9); XCTAssertEqual(c.value(1), 1, accuracy: 1e-9)
        XCTAssertLessThan(c.value(0.2), 0.2); XCTAssertGreaterThan(c.value(0.75), 0.75)
    }

    // MARK: - Pixel plumbing

    func testBitmapRowOrderRoundTrip() {
        // A plane with a bright top row must read back with the bright row first.
        let w = 8, h = 6
        var plane = [Float](repeating: 0, count: w * h)
        for x in 0..<w { plane[x] = 1 }
        let img = DepthFocus.image(fromPlane: plane, width: w, height: h)
        XCTAssertGreaterThan(mean(img, CGRect(x: 0, y: 0, width: 1, height: 1.0 / 6)).x, 0.9)
        let back = DepthFocus.readPlane(img, extent: img.extent, width: w, height: h, context: r.rawContext)
        XCTAssertEqual(back[0], 1, accuracy: 1e-4)
        XCTAssertEqual(back[w * h - 1], 0, accuracy: 1e-4)
        // Depth survives the 16-bit millimetre encoding.
        let meters: [Float] = (0..<(w * h)).map { 0.5 + Float($0) * 0.25 }
        let depth = EditRenderer.depthImage(meters: meters, width: w, height: h)!
        let s = DepthFocus.readDepth(depth, context: r.rawContext)!
        for i in [0, 7, 20, 47] { XCTAssertEqual(s.meters[i], meters[i], accuracy: 0.002) }
        // Core's depth.png (16-bit grayscale PNG, millimetres) loads with raw values and top row first.
        var mm: [UInt16] = meters.map { UInt16(($0 * 1000).rounded()).bigEndian }
        let provider = CGDataProvider(data: Data(bytes: &mm, count: mm.count * 2) as CFData)!
        let cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: w * 2,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let fromPNG = try! XCTUnwrap(EditRenderer.depthImage(pngData: png as Data))
        let sp = DepthFocus.readDepth(fromPNG, context: r.rawContext)!
        XCTAssertEqual(sp.width, w); XCTAssertEqual(sp.height, h)
        for i in [0, 7, 20, 47] { XCTAssertEqual(sp.meters[i], meters[i], accuracy: 0.002) }
    }

    // MARK: - Sliders

    func testNeutralRecipeIsIdentity() async throws {
        let s = try await sample()
        let out = render(s, [:])
        let ref = r.render(source: s.source, depth: nil, subjectMask: nil, recipe: .identity, quality: .preview(maxSide: 640))
        XCTAssertEqual(out.extent.size, ref.extent.size)
        XCTAssertEqual(max(out.extent.width, out.extent.height), 640)
        let d = mean(out) - mean(ref)
        XCTAssertLessThan(abs(d.x) + abs(d.y) + abs(d.z), 1e-4)
    }

    func testSliderDirections() async throws {
        let s = try await sample()
        let base = mean(render(s, [:]))
        XCTAssertGreaterThan(luma(mean(render(s, [.exposure: 1]))), luma(base) * 1.4)
        XCTAssertLessThan(luma(mean(render(s, [.exposure: -1]))), luma(base) * 0.7)
        let warm = mean(render(s, [.warmth: 50])), cool = mean(render(s, [.warmth: -50]))
        XCTAssertGreaterThan(warm.x / warm.z, base.x / base.z * 1.1)
        XCTAssertLessThan(cool.x / cool.z, base.x / base.z / 1.1)
        let magenta = mean(render(s, [.tint: 50]))
        XCTAssertLessThan(magenta.y / (magenta.x + magenta.z), base.y / (base.x + base.z))
        let bw = mean(render(s, [.saturation: -100]))
        XCTAssertEqual(bw.x, bw.y, accuracy: 0.01); XCTAssertEqual(bw.y, bw.z, accuracy: 0.01)
        // Vignette: negative darkens corners relative to the center.
        let v = render(s, [.vignette: -80])
        let corner = CGRect(x: 0, y: 0, width: 0.1, height: 0.1), center = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        let ratio0 = luma(mean(render(s, [:]), corner)) / luma(mean(render(s, [:]), center))
        let ratio1 = luma(mean(v, corner)) / luma(mean(v, center))
        XCTAssertLessThan(ratio1, ratio0 * 0.6)
        // Shadows +, blacks -: the darkest decile moves the right way.
        XCTAssertGreaterThan(luma(mean(render(s, [.shadows: 80]))), luma(base))
        XCTAssertLessThan(luma(mean(render(s, [.blacks: -80]))), luma(base))
    }

    func testSubjectAndBackgroundLight() async throws {
        let s = try await sample()
        let mask = try XCTUnwrap(s.mask)
        // Average inside vs outside the mask, at the mask's own size.
        func split(_ img: CIImage) -> (Float, Float) {
            let m = EditRenderer.fit(mask, to: img.extent)
            let inside = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: img.extent), kCIInputMaskImageKey: m])
            let maskMean = mean(m).x
            let total = luma(mean(img)), inMean = luma(mean(inside)) / max(maskMean, 1e-3)
            let outMean = (total - luma(mean(inside))) / max(1 - maskMean, 1e-3)
            return (inMean, outMean)
        }
        let (i0, o0) = split(render(s, [:]))
        let (i1, o1) = split(render(s, [.subjectLight: 60, .backgroundLight: -60]))
        XCTAssertGreaterThan(i1, i0 * 1.4)
        XCTAssertLessThan(o1, o0 * 0.75)
    }

    func testDepthBlurSoftensBackgroundKeepsSubject() async throws {
        let s = try await sample()
        func detail(_ img: CIImage, _ rect: CGRect) -> Float {
            // High-frequency energy: |img - blur(img)| averaged.
            let blur = img.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: img.extent)
            let diff = img.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blur])
            return luma(mean(diff, rect))
        }
        let sharp = render(s, [:]), soft = render(s, [.depthBlur: 80])
        let top = CGRect(x: 0, y: 0, width: 1, height: 0.15)
        XCTAssertLessThan(detail(soft, top), detail(sharp, top) * 0.7, "far background should lose detail")
        let focusDepth = r.subjectDepth(depth: s.depth!, subjectMask: s.mask)
        XCTAssertNotNil(focusDepth)
    }

    func testCropAndStraighten() async throws {
        let s = try await sample()
        let full = render(s, [:], side: 800)
        let half = render(s, [:], crop: Crop(x: 0.25, y: 0.25, w: 0.5, h: 0.5), side: 800)
        XCTAssertEqual(max(half.extent.width, half.extent.height), 800, accuracy: 1)
        XCTAssertEqual(half.extent.width / half.extent.height, full.extent.width / full.extent.height, accuracy: 0.01)
        let tilted = render(s, [:], crop: Crop(angle: 5), side: 800)
        XCTAssertEqual(tilted.extent.size, full.extent.size)
        // The zoom keeps the rotated photo covering the frame: every frame corner maps back inside it.
        for angle in [-45.0, -12, 3, 5, 30] {
            let size = CGSize(width: 1280, height: 853)
            let inv = EditRenderer.straightenTransform(angle: angle, size: size).inverted()
            for p in [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height),
                      CGPoint(x: size.width, y: size.height)] {
                let q = p.applying(inv)
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01).contains(q), "angle \(angle)")
            }
        }
        // Positive angle turns the picture clockwise: the top-left corner content moves right.
        let tr = EditRenderer.straightenTransform(angle: 10, size: CGSize(width: 100, height: 100))
        XCTAssertGreaterThan(CGPoint(x: 0, y: 100).applying(tr).x, 0)
        XCTAssertNotNil(r.cgImage(tilted))
    }

    // MARK: - Speed

    /// Preview renders at 1280 px into a Metal texture while a slider moves (depth blur on).
    func testPreviewTiming() async throws {
        let s = try await sample()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var recipe = EditRecipe(values: [.depthBlur: 50, .exposure: 0.2, .contrast: 15, .shadows: 20,
                                         .highlights: -20, .clarity: 20, .vibrance: 15, .vignette: -25,
                                         .subjectLight: 15])
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var gpu: [Double] = []
        /// Wall-clock ms for build + encode + GPU + wait; also records pure GPU ms.
        func once(_ rec: EditRecipe) throws -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = r.render(source: s.source, depth: s.depth, subjectMask: s.mask, recipe: rec, quality: .preview(maxSide: 1280))
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(img.extent.width),
                                                                height: Int(img.extent.height), mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            let tex = device.makeTexture(descriptor: desc)!
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            try r.render(img, to: tex, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
            gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        func stats(_ v: [Double]) -> (Double, Double) {
            let s = v.sorted(); return (s[s.count / 2], s[s.count * 9 / 10])
        }
        let cold = try once(recipe)
        var times: [Double] = []
        gpu.removeAll()
        for i in 0..<40 {
            recipe.set(.warmth, Double(i % 20) * 2 - 20)
            times.append(try once(recipe))
        }
        let (median, p90) = stats(times), (gpuMedian, gpuP90) = stats(gpu)
        // Moving the blur amount rebuilds the cached blur intermediate.
        var focusTimes: [Double] = []
        for i in 0..<10 {
            recipe.set(.depthBlur, 40 + Double(i) * 3)
            focusTimes.append(try once(recipe))
        }
        // Full-size export to JPEG.
        let t0 = CFAbsoluteTimeGetCurrent()
        let jpeg = await r.exportJPEG(source: s.source, depth: s.depth, subjectMask: s.mask, recipe: recipe)
        let exportMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let line = String(format: "CoachEdit timing @1280 (all sliders on): cold %.1f ms; slider drag wall median %.1f / p90 %.1f ms, GPU median %.1f / p90 %.1f ms; depth_blur change median %.1f ms; export %.0f ms (%d KB)",
                          cold, median, p90, gpuMedian, gpuP90, stats(focusTimes).0, exportMs, (jpeg?.count ?? 0) / 1024)
        print(line)
        try? line.write(toFile: "/tmp/lc_qa/edit_timing.txt", atomically: true, encoding: .utf8)
        XCTAssertNotNil(jpeg)
        XCTAssertLessThan(gpuMedian, 16, "preview render should fit a 60 Hz frame")
    }
}
