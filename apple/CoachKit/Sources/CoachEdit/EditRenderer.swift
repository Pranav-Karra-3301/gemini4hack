import CoachModels
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal

/// How big and how carefully to render.
public enum EditQuality: Hashable, Sendable {
    /// Interactive preview: the output's long side is at most `maxSide` px (after crop).
    case preview(maxSide: Int)
    /// Full resolution of the source.
    case export
}

/// Renders an `EditRecipe` (docs/CORE_API.md §4) with Core Image on the GPU. The same code runs
/// on the iPhone and the Mac, so a recipe looks the same everywhere.
///
/// Pipeline (linear light unless noted): preview downscale (cached) → depth blur (cached) →
/// white balance → local highlights/shadows → subject/background light → exposure →
/// tone curve (perceptual, with a highlight shoulder) → clarity (perceptual, luminance only) →
/// vibrance → saturation → local layers → film look → straighten + crop → post-crop vignette → grain.
///
/// All radii are relative to the image size, so a preview and its export match.
/// Thread-safe: render from any thread. Pass the same `CIImage` instances across renders so the
/// depth caches (subject depth, blur map) are reused; slider drags then cost one GPU pass chain.
public final class EditRenderer: @unchecked Sendable {
    /// Metal-backed context (half-float working format, linear extended sRGB). Use it to draw
    /// previews into an `MTKView` or call `render(_:to:commandBuffer:)`.
    public let context: CIContext
    /// No color management, float: used to read depth and masks back as raw numbers.
    let rawContext: CIContext

    private let lock = NSLock()
    private var depthCache: [(image: CIImage, samples: DepthFocus.Samples)] = []
    private var maskCache: [(depth: CIImage, mask: CIImage, range: DepthFocus.FocusRange?)] = []
    private var mapCache: [(key: MapKey, map: CIImage)] = []
    private static let cacheLimit = 4
    /// Film looks by id (`register(look:)`, EditLook.swift).
    let looks = LookLibrary()
    /// Layer masks by name and their feathered alphas (`register(mask:named:)`, EditLayers.swift).
    let layerMasks = LayerMaskStore()

    /// - Parameter device: the GPU to use; `nil` falls back to Core Image's default.
    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        let opts: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: true,
            .name: "CoachEdit",
        ]
        if let device {
            context = CIContext(mtlDevice: device, options: opts)
        } else {
            context = CIContext(options: opts)
        }
        var raw: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false, .name: "CoachEdit.raw",
        ]
        if device == nil { raw[.useSoftwareRenderer] = false }
        rawContext = device.map { CIContext(mtlDevice: $0, options: raw) } ?? CIContext(options: raw)
    }

    /// Builds the edited image. Cheap: returns a lazy `CIImage`; pixels are computed when you draw
    /// or export it (the first call with new depth/mask inputs also reads them back once).
    ///
    /// - Parameters:
    ///   - source: the photo, already upright (apply EXIF orientation first).
    ///   - depth: `depth.png` from Core: 16-bit depth in millimetres (0 = unknown), any size, same
    ///     aspect as `source`. Load it with `EditRenderer.depthImage(pngData:)` so values stay raw.
    ///   - subjectMask: the mask PNG of `recipe.subject` (8-bit, 255 = subject), any size.
    ///   - recipe: slider values and crop. Missing values are defaults.
    ///   - quality: `.preview(maxSide:)` while editing, `.export` for the full-size file.
    /// - Returns: an opaque image with origin (0, 0), in the context's working space.
    public func render(source: CIImage, depth: CIImage?, subjectMask: CIImage?,
                       recipe: EditRecipe, quality: EditQuality) -> CIImage {
        let p = Params(recipe)
        var img = source
        if img.extent.origin != .zero {
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        let full = img.extent.size
        guard full.width >= 1, full.height >= 1, full.width.isFinite else { return source }

        // 1. Preview scale: fit the *cropped* output in maxSide, so zoomed crops stay sharp.
        var scale: CGFloat = 1
        if case .preview(let maxSide) = quality {
            let side = max(full.width * p.crop.w, full.height * p.crop.h)
            scale = min(1, CGFloat(max(maxSide, 16)) / side)
        }
        let extent = CGRect(x: 0, y: 0, width: max(1, (full.width * scale).rounded()),
                            height: max(1, (full.height * scale).rounded()))
        if scale < 0.999 {
            img = img.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
                ])
                .cropped(to: extent)
                .insertingIntermediate(cache: true)
        } else {
            img = img.cropped(to: extent)
        }
        let L = max(extent.width, extent.height)
        let mask = subjectMask.map { Self.fit($0, to: extent) }

        // 2. Depth blur (lens blur), cached: later slider changes reuse this intermediate.
        if p.depthBlur > 0.001, let blurred = depthBlur(img, extent: extent, L: L, p: p,
                                                         depth: depth, subjectMask: subjectMask, fittedMask: mask) {
            img = blurred.insertingIntermediate(cache: true)
        }

        // 3. White balance around a D65 neutral, in mireds (perceptually even steps).
        if p.warmth != 0 || p.tint != 0 {
            let mired = 1e6 / 6500 + 42 * p.warmth
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 1e6 / mired, y: -36 * p.tint),
            ])
        }

        // 4. Local (edge-aware) part of shadows + / highlights -.
        if p.shadows > 0 || p.highlights < 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputRadius": 0.012 * L,
                "inputShadowAmount": 0.55 * max(0, p.shadows),
                "inputHighlightAmount": 1 + 0.45 * min(0, p.highlights),
            ]).cropped(to: extent)
        }

        // 5. Subject / background light: exposure through the feathered mask and its inverse.
        var headroomEV = max(0, p.exposure)
        if let mask, p.subjectLight != 0 || p.backgroundLight != 0 {
            // Pull the edge in a little before feathering so the light change never glows outward.
            let soft = Self.feather(Self.erode(mask, radius: 0.002 * L, extent: extent), sigma: 0.003 * L, extent: extent)
                .insertingIntermediate(cache: true)
            let inside = Self.exposure(img, ev: 1.5 * p.subjectLight)
            let outside = Self.exposure(img, ev: 1.5 * p.backgroundLight)
            img = inside.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: outside, kCIInputMaskImageKey: soft,
            ])
            headroomEV += max(0, 1.5 * max(p.subjectLight, p.backgroundLight))
        }

        // 6. Exposure (linear gain).
        if p.exposure != 0 { img = Self.exposure(img, ev: p.exposure) }

        // 7. Tone curve in sRGB-encoded space; rolls off any headroom instead of clipping.
        var curve = ToneCurve(contrast: p.contrast, highlights: p.highlights, shadows: p.shadows,
                              whites: p.whites, blacks: p.blacks)
        if headroomEV > 0.01 { curve.domainMax = min(SRGB.encode(pow(2, headroomEV)), 4) }
        if !curve.isIdentity {
            // Per-channel curves shift hue/saturation (a bright orange sky turns red when the
            // highlights come down). Take the luminance from the curve and the color from before,
            // keeping a little of the per-channel result for natural contrast "punch".
            let perChannel = Self.apply(curve, to: img)
            let lumOnly = perChannel.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: img])
            img = Self.colorPreserve <= 0 ? perChannel : perChannel.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: lumOnly, kCIInputTimeKey: Self.colorPreserve,
            ])
        }

        // 8. Clarity: local contrast on luminance only, in perceptual space.
        if p.clarity != 0 { img = clarity(img, amount: p.clarity, L: L, extent: extent) }

        // 9. Color.
        if p.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": p.vibrance])
        }
        if p.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + p.saturation, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
            ])
        }

        // 9a. Local layers (§7, EditLayers.swift): each layer's sliders through its feathered mask, in order.
        if let layers = recipe.layers, !layers.isEmpty {
            img = applyLayers(layers, to: img, source: source, depth: depth, L: L, extent: extent)
        }

        // 9b. Film look (§6, EditLookEffects.swift): LUT, halation, bloom; vignette + grain after the crop.
        let look = looks.resolve(recipe.look)
        if let look { img = Self.lookColor(img, look, L: L, extent: extent) }

        // 10. Straighten + crop, then the post-crop vignette (centered on what you see).
        img = Self.straightenAndCrop(img, crop: p.crop, extent: extent)
        if let look { img = Self.lookVignette(img, look, slider: p.vignette) }
        if p.vignette != 0 { img = Self.vignette(img, amount: p.vignette) }
        if let look { img = Self.lookGrain(img, look, seed: Self.grainSeed(source: source, lookID: look.look.id)) }

        let out = img.extent.integral
        return img.cropped(to: out).settingAlphaOne(in: out)
    }

    /// The subject's median depth in meters (what `focus_depth = null` focuses on), or the
    /// central third's median without a mask. Nil without depth. Cached.
    public func subjectDepth(depth: CIImage, subjectMask: CIImage?) -> Double? {
        guard let s = samples(for: depth) else { return nil }
        return focusRange(depth: depth, samples: s, mask: subjectMask)?.median
    }

    /// Drops cached depth samples, blur maps and Core Image intermediates.
    public func purgeCaches() {
        lock.lock()
        depthCache.removeAll(); maskCache.removeAll(); mapCache.removeAll()
        lock.unlock()
        layerMasks.purge()
        context.clearCaches()
    }

    // MARK: - Depth blur

    private struct MapKey: Equatable {
        let depth: ObjectIdentifier
        let nearMM: Int
        let farMM: Int
    }

    private func depthBlur(_ img: CIImage, extent: CGRect, L: CGFloat, p: Params,
                           depth: CIImage?, subjectMask: CIImage?, fittedMask: CIImage?) -> CIImage? {
        var radius = p.depthBlur * 0.022 * L
        var map: CIImage
        var protect = fittedMask != nil
        if let depth, let s = samples(for: depth) {
            let subject = focusRange(depth: depth, samples: s, mask: subjectMask)
            var range: DepthFocus.FocusRange
            if let f = p.focusDepth {
                range = DepthFocus.FocusRange(near: f, median: f, far: f)
                if let m = subject?.median, abs(1 - f / m) > 0.12 {
                    protect = false // focusing elsewhere: the subject is allowed to go soft
                }
            } else if let subject {
                range = subject // keep the whole subject (e.g. a group) in the focal plane
            } else {
                return nil
            }
            // A real lens's blur shrinks roughly as 1/focus distance: a close portrait gets creamy
            // bokeh, a far subject only a gentle softening (no fake "miniature" look).
            radius *= Self.focusScale(range.median)
            let small = blurMap(depth: depth, samples: s, near: range.near, far: range.far)
            // Upsample guided by the photo, so blur boundaries follow real edges (thin figures,
            // railings) instead of the depth map's coarse pixels.
            map = Self.fit(small, to: extent)
            if extent.width > CGFloat(s.width) * 1.5 {
                map = img.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
                    "inputSmallImage": small, "inputSpatialSigma": 2.0, "inputLumaSigma": 0.1,
                ]).cropped(to: extent)
            }
        } else if let fittedMask {
            // No depth: a uniform background blur behind the subject ("portrait mode").
            map = Self.feather(fittedMask, sigma: 0.012 * L, extent: extent).applyingFilter("CIColorInvert")
            radius *= 0.7
        } else {
            return nil
        }
        map = map.clampedToExtent()

        guard protect, let fittedMask else {
            return img.clampedToExtent()
                .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": map, kCIInputRadiusKey: radius])
                .cropped(to: extent)
        }
        // Blur only background pixels: the subject (grown by a few px, so its edge colors can't
        // leak) is made transparent and the blur fills the hole from the surroundings. Where the
        // blur is too small to fill it (near the focal plane), the original pixels show through.
        // Then the sharp subject (shrunk a hair, so no ring of sharp background rides along) goes
        // on top.
        let grown = Self.feather(Self.dilate(fittedMask, radius: 0.004 * L, extent: extent), sigma: 0.0015 * L, extent: extent)
        let edge = Self.feather(Self.erode(fittedMask, radius: 0.0012 * L, extent: extent), sigma: 0.0012 * L, extent: extent)
        let background = img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: grown.applyingFilter("CIColorInvert"),
        ])
        let premult = background.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": map, kCIInputRadiusKey: radius])
            .cropped(to: extent)
        // Normalize by coverage (= average of background pixels only); fall back to the original
        // where the blur saw almost no background (coverage < ~25%).
        let coverage = premult.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 4), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 4),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 4), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp")
        let blurred = premult.unpremultiplyingAlpha().settingAlphaOne(in: extent)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: coverage,
            ])
        return img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: edge,
        ])
    }

    private func samples(for depth: CIImage) -> DepthFocus.Samples? {
        lock.lock()
        if let hit = depthCache.first(where: { $0.image === depth }) { lock.unlock(); return hit.samples }
        lock.unlock()
        guard let s = DepthFocus.readDepth(depth, context: rawContext) else { return nil }
        lock.lock()
        depthCache.insert((depth, s), at: 0)
        if depthCache.count > Self.cacheLimit { depthCache.removeLast() }
        lock.unlock()
        return s
    }

    private func focusRange(depth: CIImage, samples s: DepthFocus.Samples, mask: CIImage?) -> DepthFocus.FocusRange? {
        guard let mask else { return DepthFocus.focusRange(s, weights: nil) }
        lock.lock()
        if let hit = maskCache.first(where: { $0.depth === depth && $0.mask === mask }) {
            lock.unlock(); return hit.range
        }
        lock.unlock()
        let weights = DepthFocus.readPlane(mask, extent: mask.extent, width: s.width, height: s.height,
                                           context: rawContext)
        let range = DepthFocus.focusRange(s, weights: weights)
        lock.lock()
        maskCache.insert((depth, mask, range), at: 0)
        if maskCache.count > Self.cacheLimit { maskCache.removeLast() }
        lock.unlock()
        return range
    }

    private func blurMap(depth: CIImage, samples s: DepthFocus.Samples, near: Double, far: Double) -> CIImage {
        let key = MapKey(depth: ObjectIdentifier(depth), nearMM: Int((near * 1000).rounded()),
                         farMM: Int((far * 1000).rounded()))
        lock.lock()
        if let hit = mapCache.first(where: { $0.key == key }) { lock.unlock(); return hit.map }
        lock.unlock()
        let plane = DepthFocus.blurMap(s, near: near, far: far)
        // Smooth the map a little at depth resolution so blur changes gradually across edges.
        let raw = DepthFocus.image(fromPlane: plane, width: s.width, height: s.height)
        let map = raw.clampedToExtent().applyingGaussianBlur(sigma: 0.8).cropped(to: raw.extent)
        lock.lock()
        mapCache.insert((key, map), at: 0)
        if mapCache.count > Self.cacheLimit * 2 { mapCache.removeLast() }
        lock.unlock()
        return map
    }

    // MARK: - Stages

    private func clarity(_ img: CIImage, amount: Double, L: CGFloat, extent: CGRect) -> CIImage {
        let base = img.applyingFilter("CILinearToSRGBToneCurve")
        let smooth = Self.clarityBase(base, sigma: 0.012 * L, extent: extent)
        let detail: CIImage
        if amount > 0 {
            // base + a * (base - smooth), unclamped.
            let a = 0.9 * amount
            detail = Self.scaled(smooth, by: -a)
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: Self.scaled(base, by: 1 + a)])
                .settingAlphaOne(in: extent)
        } else {
            detail = base.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: smooth, kCIInputTimeKey: 0.65 * -amount,
            ])
        }
        // Keep the original hue/saturation; take only the new luminance.
        let lum = detail.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: base])
        // Fade the effect out in deep shadows and bright highlights (no clipping, fewer halos).
        let mid = base.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0.15), "inputPoint1": CIVector(x: 0.2, y: 0.85),
                "inputPoint2": CIVector(x: 0.5, y: 1), "inputPoint3": CIVector(x: 0.82, y: 0.85),
                "inputPoint4": CIVector(x: 1, y: 0.2),
            ])
        return lum.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mid,
        ]).applyingFilter("CISRGBToneCurveToLinear")
    }

    /// Large-radius, edge-aware smoothing: blur at 1/4 size, then upsample guided by the full image
    /// (joint bilateral), so strong edges (hair against sky) don't produce clarity halos.
    /// How much of the tone curve is applied hue/saturation-preserving (0 = plain RGB curves).
    static let colorPreserve = 0.7
    static func clarityBase(_ base: CIImage, sigma: CGFloat, extent: CGRect) -> CIImage {
        guard extent.width >= 64, extent.height >= 64 else {
            return base.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: extent)
        }
        let k: CGFloat = 0.25
        let smallExtent = CGRect(x: 0, y: 0, width: (extent.width * k).rounded(.down), height: (extent.height * k).rounded(.down))
        let small = base.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: k, y: k), highQualityDownsample: true)
            .applyingGaussianBlur(sigma: Double(sigma * k))
            .cropped(to: smallExtent)
        return base.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
            "inputSmallImage": small, "inputSpatialSigma": 2.0, "inputLumaSigma": 0.12,
        ]).cropped(to: extent)
    }

    /// Multiplies RGB by `k` (may be negative), alpha stays 1.
    static func scaled(_ img: CIImage, by k: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    static func apply(_ curve: ToneCurve, to img: CIImage) -> CIImage {
        let ys = curve.samples()
        var rgb = [Float](repeating: 0, count: ys.count * 3)
        for (i, y) in ys.enumerated() { rgb[i * 3] = y; rgb[i * 3 + 1] = y; rgb[i * 3 + 2] = y }
        let f = CIFilter.colorCurves()
        f.inputImage = img
        f.curvesData = rgb.withUnsafeBytes { Data($0) }
        f.curvesDomain = CIVector(x: 0, y: CGFloat(curve.domainMax))
        f.colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        return f.outputImage ?? img
    }

    static func exposure(_ img: CIImage, ev: Double) -> CIImage {
        ev == 0 ? img : img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    }

    /// Scales `image` (any size/origin) onto `extent`, edge-clamped, bilinear.
    static func fit(_ image: CIImage, to extent: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, !e.isInfinite else { return image.cropped(to: extent) }
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / e.width, y: extent.height / e.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return image.transformed(by: t).clampedToExtent().cropped(to: extent)
    }

    /// Blur-radius factor for a focus distance in meters: 1 up to 1.2 m, then ~(1.2/f)^0.6, min 0.25.
    static func focusScale(_ f: Double) -> Double {
        max(0.25, pow(min(1, 1.2 / max(f, 0.05)), 0.6))
    }

    /// Shrinks a mask by `radius` px (morphological minimum).
    static func erode(_ mask: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        guard radius >= 0.75 else { return mask }
        return mask.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    /// Grows a mask by `radius` px (morphological maximum).
    static func dilate(_ mask: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        guard radius >= 0.75 else { return mask }
        return mask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    static func feather(_ mask: CIImage, sigma: CGFloat, extent: CGRect) -> CIImage {
        guard sigma >= 0.5 else { return mask }
        return mask.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: extent)
    }

    /// Rotates by `crop.angle` degrees (positive = clockwise, like Lightroom's Angle), zooms just
    /// enough that no empty corners show, then crops the normalized rect (origin top-left).
    static func straightenAndCrop(_ img: CIImage, crop: Crop, extent: CGRect) -> CIImage {
        guard !crop.isIdentity else { return img }
        let W = extent.width, H = extent.height
        var out = img
        if abs(crop.angle) > 0.001 {
            let t = straightenTransform(angle: crop.angle, size: extent.size)
            out = img.clampedToExtent().transformed(by: t, highQualityDownsample: true).cropped(to: extent)
        }
        let r = CGRect(x: crop.x * W, y: (1 - crop.y - crop.h) * H, width: crop.w * W, height: crop.h * H)
            .integral.intersection(extent)
        guard r.width >= 1, r.height >= 1 else { return out }
        return out.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    /// Rotation about the center by `angle` degrees (positive = clockwise on screen) plus the
    /// smallest zoom that keeps the rotated photo covering the whole `size` frame.
    static func straightenTransform(angle: Double, size: CGSize) -> CGAffineTransform {
        let W = size.width, H = size.height
        let theta = -angle * .pi / 180 // Core Image is y-up: negative = clockwise
        let c = abs(cos(theta)), s = abs(sin(theta))
        let zoom = max((W * c + H * s) / W, (W * s + H * c) / H)
        return CGAffineTransform(translationX: -W / 2, y: -H / 2)
            .concatenating(CGAffineTransform(rotationAngle: theta))
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))
    }

    /// Post-crop vignette with a lens-like radial profile: untouched inside 45% of the half
    /// diagonal, then a smoothstep falloff to the corners. -100 takes the corners down 1.6 EV
    /// (the long-side edge centers ~0.9 EV); +100 lifts them 0.8 EV.
    static func vignette(_ img: CIImage, amount: Double) -> CIImage {
        let e = img.extent
        let hd = hypot(e.width, e.height) / 2
        let ramp = CIFilter.radialGradient()
        ramp.center = CGPoint(x: e.midX, y: e.midY)
        ramp.radius0 = Float(0.45 * hd)
        ramp.radius1 = Float(hd)
        ramp.color0 = CIColor(red: 0, green: 0, blue: 0)
        ramp.color1 = CIColor(red: 1, green: 1, blue: 1)
        guard let linear = ramp.outputImage?.cropped(to: e) else { return img }
        let shape = CIFilter.colorCurves()
        shape.inputImage = linear
        shape.curvesData = vignetteCurve
        shape.curvesDomain = CIVector(x: 0, y: 1)
        shape.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let weight = shape.outputImage else { return img }
        let ev = amount < 0 ? 1.6 * amount : 0.8 * amount
        return exposure(img, ev: ev).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: weight,
        ]).cropped(to: e)
    }

    /// smoothstep(t) as RGB float triples, 256 samples.
    static let vignetteCurve: Data = {
        var rgb = [Float](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let t = Float(i) / 255
            let v = t * t * (3 - 2 * t)
            rgb[i * 3] = v; rgb[i * 3 + 1] = v; rgb[i * 3 + 2] = v
        }
        return rgb.withUnsafeBytes { Data($0) }
    }()
}

/// Recipe values normalized for the pipeline (tone/color sliders as -1...1).
struct Params {
    var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    var warmth = 0.0, tint = 0.0, vibrance = 0.0, saturation = 0.0, clarity = 0.0, vignette = 0.0
    var subjectLight = 0.0, backgroundLight = 0.0, depthBlur = 0.0
    var focusDepth: Double?
    var crop = Crop.full

    init(_ r: EditRecipe) {
        func n(_ s: Slider) -> Double { (r.value(s) ?? 0) / 100 }
        exposure = r.value(.exposure) ?? 0
        contrast = n(.contrast); highlights = n(.highlights); shadows = n(.shadows)
        whites = n(.whites); blacks = n(.blacks)
        warmth = n(.warmth); tint = n(.tint); vibrance = n(.vibrance); saturation = n(.saturation)
        clarity = n(.clarity); vignette = n(.vignette)
        subjectLight = n(.subjectLight); backgroundLight = n(.backgroundLight); depthBlur = n(.depthBlur)
        focusDepth = r.value(.focusDepth)
        if var c = r.crop {
            c.x = min(max(c.x, 0), 1); c.y = min(max(c.y, 0), 1)
            c.w = min(max(c.w, 0.02), 1 - c.x); c.h = min(max(c.h, 0.02), 1 - c.y)
            c.angle = c.angle.isFinite ? min(max(c.angle, -45), 45) : 0
            crop = c
        }
    }
}
