import CoachModels
import CoreImage
import Foundation

// Masked local adjustment layers (docs/CORE_API.md §7), the Core Image port of
// experiments/masks/render.py.
//
// Render order (EditRenderer.render): preview scale → depth blur → global sliders (white balance,
// local highlights/shadows, subject/background light, exposure, tone curve, clarity, vibrance,
// saturation) → **layers, in recipe order** → look (LUT, halation, bloom) → straighten + crop →
// vignette → grain. That is §7's order ("global sliders, then each layer, then the look, vignette,
// depth blur and grain"), except that depth blur keeps its place at the start of the chain, where
// it always ran.
//
// Each layer: alpha = feather(mask(source) [inverted] × Π(1 − subtract)), then
// `out = out·(1 − α) + adjust(out, layer.values)·α`, blended in linear light (render.py blends
// sRGB-encoded values; the difference is confined to the feather and is < 1/255 on average).
// `adjust` is the global stages' slider math with the layer's values, except that the neighborhood
// terms (clarity's detail, CIHighlightShadowAdjust's change) are computed once per render from the
// image before the layers, as luminance gains each layer scales (`localGains`): one blur pyramid
// instead of one per layer, and no halos from an earlier layer's mask edge in a later layer's
// local contrast.
//
// Masks come from the caller (`register(mask:named:)` or `maskProvider`), so CoachEdit stays
// network-free. A layer whose source mask is missing renders as a no-op; a missing `subtract`
// mask is skipped (render.py does the same).
//
// Feather (render.py `layer_alpha`): r = max(1, ⌊feather/100 · 4% · long side⌋) px.
// - `none` (or `depth` without a depth map): Gaussian, σ = r/2.
// - `image` / `depth`: edge-aware. A guided filter (He et al.; gray guide, box radius 3 px at
//   1024 px, ε = 1e-3) snaps the mask to the guide's edges; a "near an edge" weight
//   (smoothstep(0.01, 0.04, |∇ guide|), dilated by r, blurred by r/3) picks the snapped mask near real
//   edges and the plain Gaussian elsewhere. Guide: the photo's mean RGB (`image`) or the min-max
//   normalized log depth (`depth`). render.py uses a color guided filter for `image`; the gray
//   guide here is the approximation (it only differs right at edges between equally bright colors).
// Pixel constants are defined at 1024 px (the mask size) and scale with the long side, so a 1280 px
// preview and a full-size export match. Feathered alphas are baked once per (mask spec, radius,
// edge, guide, size) into a half-float bitmap and cached, so a slider drag costs only the layer's
// adjustment passes and one blend.

/// Returns the mask for a name (`sky`, `subject`, `t3`, `r1`, ...), or nil if there is none.
/// Return the same `CIImage` instance for the same name, so feathered masks stay cached.
public typealias LayerMaskProvider = @Sendable (String) -> CIImage?

extension EditRenderer {
    // MARK: - Masks (public API)

    /// Registers a mask for layers by name: a semantic mask (`/api/shots/{id}/semantic/<name>.png`)
    /// or a region mask (`/api/shots/{id}/masks/r1.png`). Load PNGs with
    /// `EditRenderer.maskImage(pngData:)` so values stay raw (255 = fully inside). Any size with the
    /// photo's aspect. Registering a new image under a name drops the old one's cached alphas.
    public func register(mask: CIImage, named name: String) { layerMasks.register(mask, name) }

    /// Forgets one registered mask.
    public func removeMask(named name: String) { layerMasks.register(nil, name) }

    /// Forgets every registered mask, the provider's memoized answers and the feathered alphas
    /// (call it when switching photos).
    public func removeAllMasks() { layerMasks.removeAll() }

    /// Names of the registered masks.
    public var registeredMaskNames: [String] { layerMasks.names }

    /// Asked for masks that were not registered (e.g. backed by a download cache). Non-nil answers
    /// are memoized per name until `removeAllMasks()` or a new provider.
    public var maskProvider: LayerMaskProvider? {
        get { layerMasks.provider }
        set { layerMasks.setProvider(newValue) }
    }

    /// The feathered alpha a layer mask resolves to over a `size` image (the pre-crop size the
    /// renderer works at: `EditRenderer.workingSize`), e.g. for a UI overlay. Raw values 0...1 in
    /// every color channel, origin (0, 0). Nil when the source mask is missing.
    public func layerAlpha(_ mask: LayerMask, source: CIImage, depth: CIImage?, size: CGSize) -> CIImage? {
        let extent = CGRect(origin: .zero, size: CGSize(width: size.width.rounded(), height: size.height.rounded()))
        return bakedAlpha(mask, source: source, depth: depth, extent: extent)?.image
    }

    /// The pre-crop size `render` works at for `source` (what `layerAlpha(size:)` expects).
    public static func workingSize(source: CGSize, crop: Crop?, quality: EditQuality) -> CGSize {
        var p = Params(EditRecipe())
        if let crop { p = Params(EditRecipe(crop: crop)) }
        var scale: CGFloat = 1
        if case .preview(let maxSide) = quality {
            let side = max(source.width * p.crop.w, source.height * p.crop.h)
            scale = min(1, CGFloat(max(maxSide, 16)) / side)
        }
        return CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
    }

    // MARK: - Render stage

    /// Applies `layers` in order to `img` (linear working space, `extent` at origin 0).
    func applyLayers(_ layers: [EditLayer], to img: CIImage, source: CIImage, depth: CIImage?,
                     L: CGFloat, extent: CGRect) -> CIImage {
        let live: [(EditLayer, LayerMaskStore.Baked)] = layers.prefix(EditLayer.maxCount).compactMap { l in
            guard !l.isIdentity, let a = bakedAlpha(l.mask, source: source, depth: depth, extent: extent),
                  !a.bbox.isEmpty else { return nil }
            return (l, a)
        }
        guard !live.isEmpty else { return img }
        let gains = Self.localGains(img, highlights: live.contains { $0.0[.highlights] < 0 },
                                    shadows: live.contains { $0.0[.shadows] > 0 },
                                    clarity: live.contains { $0.0[.clarity] != 0 }, L: L, extent: extent)
        var out = img
        for (layer, a) in live {
            let adjusted = Self.layerAdjust(out, Params(EditRecipe(values: layer.values)), gains: gains)
            // out·(1 − α) + adjusted·α, in linear light.
            out = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: a.image,
            ]).cropped(to: extent)
        }
        return out
    }

    /// The neighborhood parts of local highlights/shadows and clarity, computed once per render
    /// from the image before the layers, as relative luminance changes packed in one image:
    /// R = highlights −100 (`CIHighlightShadowAdjust`, as the global stage), G = shadows +100,
    /// B = clarity +100 (the global clarity's perceptual detail boost, mid-tone weighted).
    /// A layer scales them by its own amounts and multiplies its pixels by `1 + Σ amount·gain`:
    /// one blur pyramid per render instead of one per layer, and an earlier layer's mask edge never
    /// enters a later layer's local contrast (no halos where layers meet). Nil if nothing needs them.
    static func localGains(_ img: CIImage, highlights: Bool, shadows: Bool, clarity: Bool,
                           L: CGFloat, extent: CGRect) -> CIImage? {
        guard highlights || shadows || clarity else { return nil }
        typealias F = LayerFeather
        let y = F.luma(img)
        let invY = F.affine(y, 1, 1e-4).applyingFilter("CIGammaAdjust", parameters: ["inputPower": -1.0])
        func rel(_ changedLuma: CIImage) -> CIImage { F.mul(F.sub(changedLuma, y), invY) }
        func hs(shadow: Double, highlight: Double) -> CIImage {
            rel(F.luma(img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputRadius": 0.012 * L, "inputShadowAmount": shadow, "inputHighlightAmount": highlight,
            ]).cropped(to: extent)))
        }
        var channels: [(CIImage, Int)] = []
        if highlights { channels.append((hs(shadow: 0, highlight: 1 - 0.45), 0)) }
        if shadows { channels.append((hs(shadow: 0.55, highlight: 1), 1)) }
        if clarity {
            let p = y.applyingFilter("CILinearToSRGBToneCurve")
            let smooth = clarityBase(p, sigma: 0.012 * L, extent: extent)
            let detail = F.sub(p, smooth)
            let mid = p.applyingFilter("CIToneCurve", parameters: [ // fades out in deep shadows and highlights
                "inputPoint0": CIVector(x: 0, y: 0.15), "inputPoint1": CIVector(x: 0.2, y: 0.85),
                "inputPoint2": CIVector(x: 0.5, y: 1), "inputPoint3": CIVector(x: 0.82, y: 0.85),
                "inputPoint4": CIVector(x: 1, y: 0.2),
            ])
            let boosted = F.add(p, F.affine(F.mul(detail, mid), 0.9)).applyingFilter("CISRGBToneCurveToLinear")
            channels.append((rel(boosted), 2))
        }
        var packed: CIImage?
        for (c, ch) in channels {
            let one = F.channel(c, ch)
            packed = packed.map { F.add($0, one) } ?? one
        }
        // One intermediate: Core Image would otherwise re-evaluate this graph for every layer that reads it.
        return packed?.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: -0.9, y: -0.9, z: -0.9, w: 1), "inputMaxComponents": CIVector(x: 4, y: 4, z: 4, w: 1),
        ]).cropped(to: extent).insertingIntermediate(cache: false)
    }

    /// The global slider stages 3–9 of `render` (white balance, local highlights/shadows, exposure,
    /// tone curve, clarity, vibrance, saturation) with a layer's values. Local highlights/shadows
    /// and clarity are gains from `localGains`, applied together before exposure (gains and exposure
    /// commute). Keep in sync with `render`.
    static func layerAdjust(_ input: CIImage, _ p: Params, gains: CIImage?) -> CIImage {
        var img = input
        if p.warmth != 0 || p.tint != 0 {
            let mired = 1e6 / 6500 + 42 * p.warmth
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 1e6 / mired, y: -36 * p.tint),
            ])
        }
        // Clarity's smoothing side is ~0.72× its boost (0.65 vs 0.9 detail weight in `clarity`).
        let k = SIMD3(-min(0, p.highlights), max(0, p.shadows), p.clarity > 0 ? p.clarity : p.clarity * 0.65 / 0.9)
        if let gains, k != .zero {
            let v = CIVector(x: k.x, y: k.y, z: k.z, w: 0)
            let gain = gains.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
            img = LayerFeather.mul(img, gain)
        }
        if p.exposure != 0 { img = exposure(img, ev: p.exposure) }
        var curve = ToneCurve(contrast: p.contrast, highlights: p.highlights, shadows: p.shadows,
                              whites: p.whites, blacks: p.blacks)
        if p.exposure > 0.01 { curve.domainMax = min(SRGB.encode(pow(2, p.exposure)), 4) }
        if !curve.isIdentity {
            let perChannel = apply(curve, to: img)
            let lumOnly = perChannel.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: img])
            img = colorPreserve <= 0 ? perChannel : perChannel.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: lumOnly, kCIInputTimeKey: colorPreserve,
            ])
        }
        if p.vibrance != 0 { img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": p.vibrance]) }
        if p.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + p.saturation, kCIInputBrightnessKey: 0, kCIInputContrastKey: 1,
            ])
        }
        return img
    }

    // MARK: - Alpha (cached)

    /// The layer's feathered alpha over `extent`, baked to a bitmap, plus its bounding box
    /// (alpha > 1/512). Nil when the source mask is missing.
    func bakedAlpha(_ spec: LayerMask, source: CIImage, depth: CIImage?, extent: CGRect) -> LayerMaskStore.Baked? {
        guard let src = layerMasks.mask(spec.source) else { return nil }
        let subs = spec.subtract.compactMap { layerMasks.mask($0) }
        let L = max(extent.width, extent.height)
        let r = spec.feather > 0 ? max(1, Int(spec.feather / 100 * 0.04 * L)) : 0
        var edge = spec.edge
        if r == 0 || (edge == .depth && depth == nil) { edge = .none }
        let guideRef: CIImage? = edge == .image ? source : edge == .depth ? depth : nil
        let key = LayerMaskStore.Key(source: spec.source, invert: spec.invert, subtract: spec.subtract, radius: r,
                                     edge: edge, width: Int(extent.width), height: Int(extent.height))
        let refs = [src] + subs + (guideRef.map { [$0] } ?? [])
        if let hit = layerMasks.cached(key, refs: refs) { return hit }

        var m = Self.fit(src, to: extent)
        if spec.invert { m = m.applyingFilter("CIColorInvert") }
        for s in subs {
            m = m.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: Self.fit(s, to: extent).applyingFilter("CIColorInvert"),
            ])
        }
        var alpha = m
        if r > 0 {
            let soft = LayerFeather.gaussian(m, sigma: CGFloat(r) / 2, extent: extent)
            switch edge {
            case .none:
                alpha = soft
            case .image, .depth:
                let guide: CIImage
                if edge == .image {
                    guide = LayerFeather.gray(Self.scaledSource(source, to: extent))
                } else if let depth, let g = layerMasks.depthGuide(depth, context: rawContext) {
                    guide = Self.fit(g, to: extent)
                } else {
                    guide = LayerFeather.gray(Self.scaledSource(source, to: extent))
                }
                alpha = LayerFeather.edgeAware(mask: m, soft: soft, guide: guide, radius: r, L: L, extent: extent)
            }
        }
        alpha = alpha.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]).cropped(to: extent)
        let baked = LayerMaskStore.bake(alpha, extent: extent, context: rawContext)
        layerMasks.insert(key, refs: refs, baked)
        return baked
    }

    /// The photo at `extent`'s size (Lanczos, like the preview downscale), origin 0.
    static func scaledSource(_ source: CIImage, to extent: CGRect) -> CIImage {
        var img = source
        if img.extent.origin != .zero {
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        let s = extent.width / max(1, img.extent.width)
        if abs(s - 1) < 0.001 && abs(img.extent.height - extent.height) < 0.5 { return img.cropped(to: extent) }
        return img.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: s, kCIInputAspectRatioKey: (extent.height / max(1, img.extent.height)) / s,
        ]).cropped(to: extent)
    }
}

/// Feather building blocks on raw single-value images (r = g = b), meant for the float raw context.
enum LayerFeather {
    /// Pixel constants are defined at this long side (the mask size) and scale with the image.
    static let referenceSide: CGFloat = 1024
    static let guidedRadius: CGFloat = 3
    static let guidedEps = 1e-3
    static let gradientSigma: CGFloat = 1
    static let edgeLow = 0.01, edgeHigh = 0.04

    static func gaussian(_ img: CIImage, sigma: CGFloat, extent: CGRect) -> CIImage {
        guard sigma >= 0.3 else { return img }
        return img.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: extent)
    }

    /// (r + g + b) / 3 in every channel.
    static func gray(_ img: CIImage) -> CIImage {
        let v = CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// k·x + bias per color channel; alpha 1.
    static func affine(_ img: CIImage, _ k: Double, _ bias: Double = 0) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }

    /// Linear Rec. 709 luminance in every color channel.
    static func luma(_ img: CIImage) -> CIImage {
        let v = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Keeps one color channel (0 R, 1 G, 2 B) of a gray image; the other two become 0.
    static func channel(_ img: CIImage, _ c: Int) -> CIImage {
        func v(_ i: Int) -> CIVector { CIVector(x: i == c ? 1 : 0, y: 0, z: 0, w: 0) }
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v(0), "inputGVector": v(1), "inputBVector": v(2), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    static func mul(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    /// a + b. Addition also adds the alphas (1 + 1 = 2), so alpha goes back to 1 (rgb kept as is).
    static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
            .settingAlphaOne(in: a.extent.intersection(b.extent))
    }

    static func sub(_ a: CIImage, _ b: CIImage) -> CIImage { add(a, affine(b, -1)) }

    /// Mean over a (2r+1)² box: exact 9-tap separable convolutions up to r = 4, else a Gaussian of
    /// the same variance.
    static func box(_ img: CIImage, radius r: Int, extent: CGRect) -> CIImage {
        guard r > 4 else {
            var w = [CGFloat](repeating: 0, count: 9)
            for i in (4 - r)...(4 + r) { w[i] = 1 / CGFloat(2 * r + 1) }
            let v = CIVector(values: w, count: 9)
            return img.clampedToExtent()
                .applyingFilter("CIConvolution9Horizontal", parameters: ["inputWeights": v, "inputBias": 0])
                .applyingFilter("CIConvolution9Vertical", parameters: ["inputWeights": v, "inputBias": 0])
                .cropped(to: extent)
        }
        return gaussian(img, sigma: sqrt(CGFloat(r * (r + 1)) / 3), extent: extent)
    }

    /// Gray guided filter: the output follows `p` but takes its edges from `guide`.
    static func guided(guide I: CIImage, p: CIImage, radius r: Int, eps: Double, extent: CGRect) -> CIImage {
        let mI = box(I, radius: r, extent: extent), mp = box(p, radius: r, extent: extent)
        let mIp = box(mul(I, p), radius: r, extent: extent), mII = box(mul(I, I), radius: r, extent: extent)
        let cov = sub(mIp, mul(mI, mp))
        let varI = sub(mII, mul(mI, mI))
        let inv = affine(varI, 1, eps).applyingFilter("CIGammaAdjust", parameters: ["inputPower": -1.0])
        let a = mul(cov, inv)
        let b = sub(mp, mul(a, mI))
        return add(mul(box(a, radius: r, extent: extent), I), box(b, radius: r, extent: extent)).cropped(to: extent)
    }

    /// 0...1: how close each pixel is to a real edge in `guide` (render.py `near_edge`).
    static func nearEdge(guide: CIImage, radius r: Int, L: CGFloat, extent: CGRect) -> CIImage {
        let k = L / referenceSide
        let g = gaussian(guide, sigma: gradientSigma * k, extent: extent).clampedToExtent()
        func shifted(_ dx: CGFloat, _ dy: CGFloat) -> CIImage { g.transformed(by: CGAffineTransform(translationX: dx, y: dy)) }
        let dx = sub(shifted(-1, 0), shifted(1, 0)), dy = sub(shifted(0, -1), shifted(0, 1))
        // Central difference (÷2), in units of the 1024 px reference: × k.
        let g2 = affine(add(mul(dx, dx), mul(dy, dy)), Double(k * k / 4)).cropped(to: extent)
        let grad = g2.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.5])
        let t = affine(grad, 1 / (edgeHigh - edgeLow), -edgeLow / (edgeHigh - edgeLow))
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        let smooth = mul(mul(t, t), affine(t, -2, 3)) // t²(3 − 2t)
        let side = 2 * r + 1
        let grown = smooth.clampedToExtent()
            .applyingFilter("CIMorphologyRectangleMaximum", parameters: ["inputWidth": side, "inputHeight": side])
            .cropped(to: extent)
        return gaussian(grown, sigma: CGFloat(r) / 3, extent: extent)
    }

    /// near·guided(mask) + (1 − near)·soft.
    static func edgeAware(mask: CIImage, soft: CIImage, guide: CIImage, radius r: Int, L: CGFloat, extent: CGRect) -> CIImage {
        let k = L / referenceSide
        let snapped = guided(guide: guide, p: mask, radius: max(1, Int((guidedRadius * k).rounded())), eps: guidedEps,
                             extent: extent)
        let near = nearEdge(guide: guide, radius: r, L: L, extent: extent)
        return snapped.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: soft, kCIInputMaskImageKey: near,
        ]).cropped(to: extent)
    }
}

/// Registered masks, the provider, depth guides and baked alphas for one renderer. Thread-safe.
final class LayerMaskStore: @unchecked Sendable {
    struct Key: Hashable {
        let source: String
        let invert: Bool
        let subtract: [String]
        let radius: Int
        let edge: LayerEdge
        let width: Int
        let height: Int
    }

    /// A baked alpha: half-float luminance bitmap as a CIImage (origin 0), and where it is > 1/512.
    struct Baked {
        let image: CIImage
        let bbox: CGRect
    }

    private let lock = NSLock()
    private var named: [String: CIImage] = [:]
    private var provided: [String: CIImage] = [:]
    private var _provider: LayerMaskProvider?
    private var alphas: [(key: Key, refs: [CIImage], baked: Baked)] = []
    private var guides: [(depth: CIImage, guide: CIImage)] = []
    static let alphaLimit = 16

    var names: [String] { lock.lock(); defer { lock.unlock() }; return named.keys.sorted() }

    var provider: LayerMaskProvider? { lock.lock(); defer { lock.unlock() }; return _provider }

    func setProvider(_ p: LayerMaskProvider?) {
        lock.lock(); _provider = p; provided.removeAll(); lock.unlock()
    }

    func register(_ image: CIImage?, _ name: String) {
        lock.lock()
        if let old = named[name] { alphas.removeAll { $0.refs.contains { $0 === old } } }
        named[name] = image
        lock.unlock()
    }

    func removeAll() {
        lock.lock(); named.removeAll(); provided.removeAll(); alphas.removeAll(); guides.removeAll(); lock.unlock()
    }

    func purge() {
        lock.lock(); alphas.removeAll(); guides.removeAll(); lock.unlock()
    }

    func mask(_ name: String) -> CIImage? {
        lock.lock()
        if let m = named[name] ?? provided[name] { lock.unlock(); return m }
        let p = _provider
        lock.unlock()
        guard let m = p?(name) else { return nil }
        lock.lock(); provided[name] = m; lock.unlock()
        return m
    }

    func cached(_ key: Key, refs: [CIImage]) -> Baked? {
        lock.lock(); defer { lock.unlock() }
        guard let i = alphas.firstIndex(where: { $0.key == key && $0.refs.count == refs.count
            && zip($0.refs, refs).allSatisfy { $0 === $1 } }) else { return nil }
        let hit = alphas.remove(at: i)
        alphas.insert(hit, at: 0)
        return hit.baked
    }

    func insert(_ key: Key, refs: [CIImage], _ baked: Baked) {
        lock.lock()
        alphas.insert((key, refs, baked), at: 0)
        if alphas.count > Self.alphaLimit { alphas.removeLast() }
        lock.unlock()
    }

    /// Min-max normalized log depth (render.py's `Ln`) at the depth map's resolution. Cached.
    func depthGuide(_ depth: CIImage, context: CIContext) -> CIImage? {
        lock.lock()
        if let hit = guides.first(where: { $0.depth === depth }) { lock.unlock(); return hit.guide }
        lock.unlock()
        guard let s = DepthFocus.readDepth(depth, context: context) else { return nil }
        var plane = s.meters.map { log(min(max($0, 0.05), 1e5)) }
        guard let lo = plane.min(), let hi = plane.max() else { return nil }
        let span = max(1e-6, hi - lo)
        for i in plane.indices { plane[i] = (plane[i] - lo) / span }
        let guide = DepthFocus.image(fromPlane: plane, width: s.width, height: s.height)
        lock.lock()
        guides.insert((depth, guide), at: 0)
        if guides.count > 4 { guides.removeLast() }
        lock.unlock()
        return guide
    }

    /// Renders `alpha` once into a half-float bitmap (no color management) and finds its bounding box.
    static func bake(_ alpha: CIImage, extent: CGRect, context: CIContext) -> Baked {
        let w = Int(extent.width), h = Int(extent.height)
        var px = [UInt16](repeating: 0, count: w * h)
        context.render(alpha, toBitmap: &px, rowBytes: w * 2, bounds: extent, format: .Lh, colorSpace: nil)
        // Non-negative halves order like their bit patterns: > 0x1800 (2^-9) and no sign bit.
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        px.withUnsafeBufferPointer { b in
            for row in 0..<h {
                let o = row * w
                var first = -1, last = -1
                for x in 0..<w {
                    let v = b[o + x]
                    if v > 0x1800 && v < 0x8000 { if first < 0 { first = x }; last = x }
                }
                if first >= 0 { x0 = min(x0, first); x1 = max(x1, last); y0 = min(y0, row); y1 = max(y1, row) }
            }
        }
        let image = CIImage(bitmapData: px.withUnsafeBytes { Data($0) }, bytesPerRow: w * 2,
                            size: CGSize(width: w, height: h), format: .Lh, colorSpace: nil)
        guard x1 >= 0 else { return Baked(image: image, bbox: .null) }
        // Bitmap rows run top-down; Core Image's y runs up. Pad 2 px for the edge filters.
        let bbox = CGRect(x: x0 - 2, y: h - 1 - y1 - 2, width: x1 - x0 + 5, height: y1 - y0 + 5).intersection(extent)
        return Baked(image: image, bbox: bbox)
    }
}
