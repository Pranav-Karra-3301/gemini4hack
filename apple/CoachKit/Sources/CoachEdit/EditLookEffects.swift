import CoachModels
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Film look stages (CORE_API.md §6), a Core Image port of `experiments/film/film.py` `render`.
/// `EditRenderer.render` calls them in this order:
///
///   global sliders → **look color** (LUT at strength, halation, bloom) → straighten + crop →
///   **look vignette** → slider vignette → **grain**.
///
/// (Depth blur already ran at the start of the chain on the cached preview, so "before depth blur"
/// in §6 holds trivially: the LUT is per pixel.)
///
/// `strength` scales the LUT (mixed with identity) and every effect amount, like film.py, so
/// strength 0 is the untouched image. Radii are relative to the image size (preview = export).
///
/// Vignette rule (look + `vignette` slider never stack): per corner, the darker of the two wins.
/// - slider ≥ 0: the look's vignette applies in full, then a positive slider lifts on top.
/// - slider < 0: the look's vignette is reduced by what the slider already darkens at the
///   corners (both measured in EV at the corner); once the slider is darker, only the slider acts.
/// So dragging the slider darker never lightens the corners, and the two never double-darken.
extension EditRenderer {
    // MARK: - Color: LUT, halation, bloom (before the crop, linear working space)

    static func lookColor(_ img: CIImage, _ a: ActiveLook, L: CGFloat, extent: CGRect) -> CIImage {
        let s = a.strength
        var lin = a.look.lut.apply(to: img, strength: s).cropped(to: extent)
        let fx = a.look.effects
        let ha = fx.halation, bl = fx.bloom
        let haAmount = clamp(ha.amount, 0, 0.6) * s, blAmount = clamp(bl.amount, 0, 0.5) * s
        guard haAmount > 0.004 || blAmount > 0.004 else { return lin }
        // The glow sources and the final pass all read the graded image: render it once.
        lin = lin.insertingIntermediate(cache: false)

        // film.py thresholds on the luma of the sRGB-encoded graded image.
        let encoded = lin.applyingFilter("CILinearToSRGBToneCurve")
        func highlightMask(from e0: Double, to e1: Double) -> CIImage {
            let w = max(e1 - e0, 1e-3)
            let row = CIVector(x: 0.2126 / w, y: 0.7152 / w, z: 0.0722 / w, w: 0)
            let t = encoded.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": row, "inputGVector": row, "inputBVector": row,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -e0 / w, y: -e0 / w, z: -e0 / w, w: 0),
            ]).applyingFilter("CIColorClamp")
            return smoothstep01(t)
        }

        // Halation: bright areas bleed a red-orange glow (light scattering back through the base).
        if haAmount > 0.004 {
            let th = clamp(ha.threshold, 0.6, 1)
            let mask = highlightMask(from: th, to: min(1, th + 0.15))
            let source = lin.applyingFilter("CIMaximumComponent")
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                .applyingFilter("CIColorClamp")
            let glow = lookBlur(source, sigma: clamp(ha.radius, 0.002, 0.03) * L, extent: extent)
            let tint = halationTint(ha), k = 0.9 * haAmount
            let tinted = glow.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: tint[0] * k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: tint[1] * k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: tint[2] * k, w: 0),
            ])
            // Weaker inside the highlight itself (it would only clip there).
            let falloff = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -0.6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -0.6, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -0.6, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
            lin = tinted.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: falloff])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: lin])
                .settingAlphaOne(in: extent)
        }

        // Bloom: soft neutral diffusion of the highlights, screened on.
        if blAmount > 0.004 {
            let mask = highlightMask(from: clamp(bl.threshold, 0.6, 1), to: 1)
            let source = lin.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                .applyingFilter("CIColorClamp")
            let glow = lookBlur(source, sigma: clamp(bl.radius, 0.005, 0.06) * L, extent: extent)
            // Screen, written out as lin + g·(1 − lin): CIScreenBlendMode clamps to 1 and would eat
            // the halation's headroom before the vignette (−3/255 red around the sun in img-1016).
            let headroom = lin.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
            lin = scaled(glow, by: 0.6 * blAmount)
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: headroom])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: lin])
                .settingAlphaOne(in: extent)
        }
        return lin.cropped(to: extent)
    }

    /// Gaussian blur (sigma in px) done at 1/k size, k = sigma/6 like film.py: same look, a
    /// fraction of the cost for the big halation/bloom radii.
    static func lookBlur(_ img: CIImage, sigma: CGFloat, extent: CGRect) -> CIImage {
        let k = max(1, (sigma / 6).rounded(.down))
        guard k > 1 else {
            return img.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: extent)
        }
        let small = CGRect(x: 0, y: 0, width: max(1, (extent.width / k).rounded()), height: max(1, (extent.height / k).rounded()))
        let down = img.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: small.width / extent.width, y: small.height / extent.height),
                         highQualityDownsample: true)
            .cropped(to: small)
        let blurred = down.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma / k)).cropped(to: small)
        return fit(blurred, to: extent)
    }

    /// Linear RGB tint: `tint` if given, else HSV(hue, 0.85, 1) as in film.py.
    static func halationTint(_ h: LookEffects.Halation) -> [Double] {
        if let t = h.tint, t.count == 3, t.allSatisfy({ $0.isFinite }) { return t.map { clamp($0, 0, 2) } }
        let hue = ((h.hue ?? 15).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let sat = 0.85, f = hue / 60, i = Int(f) % 6, fr = f - Double(Int(f))
        let p = 1 - sat, q = 1 - sat * fr, t = 1 - sat * (1 - fr)
        switch i {
        case 0: return [1, t, p]
        case 1: return [q, 1, p]
        case 2: return [p, 1, t]
        case 3: return [p, q, 1]
        case 4: return [t, p, 1]
        default: return [1, p, q]
        }
    }

    // MARK: - Vignette (after the crop)

    /// The look's vignette as film.py draws it (sRGB values × `1 − 0.7·amount·fall`, `fall` a
    /// smoothstep from `midpoint` to 1.15 of the half diagonal), composed with the slider (see the
    /// rule at the top of this file). The slider's own vignette is applied by the caller.
    static func lookVignette(_ img: CIImage, _ a: ActiveLook, slider: Double) -> CIImage {
        let v = a.look.effects.vignette
        let mid = clamp(v.midpoint, 0.3, 1)
        var c = 0.7 * min(abs(v.amount.isFinite ? v.amount : 0), 0.45) * a.strength // corner loss at fall = 1
        guard c > 0.002 else { return img }
        let cornerFall = smoothstep(mid, 1.15, 1)
        if slider < 0 {
            let lookEV = 2.2 * log2(1 - c * cornerFall) // sRGB gain → ≈ EV in linear light
            let sliderEV = 1.6 * slider                 // EditRenderer.vignette at the corners
            let residual = min(0, lookEV - sliderEV)
            guard residual < -0.003 else { return img }
            c = (1 - pow(2, residual / 2.2)) / cornerFall
        }
        let e = img.extent
        let hd = hypot(e.width, e.height) / 2
        let ramp = CIFilter.radialGradient()
        ramp.center = CGPoint(x: e.midX, y: e.midY)
        ramp.radius0 = Float(mid * hd)
        ramp.radius1 = Float(1.15 * hd)
        ramp.color0 = CIColor(red: 0, green: 0, blue: 0)
        ramp.color1 = CIColor(red: 1, green: 1, blue: 1)
        guard let t = ramp.outputImage?.cropped(to: e) else { return img }
        let gain = smoothstep01(t).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -c, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -c, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -c, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        return img.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: e)
    }

    // MARK: - Grain (last)

    /// Gain from `amount` to the soft-light offset, tuned so midtone grain matches film.py's
    /// additive `n · amount · 0.055 · (0.35 + 2.6·L(1−L))` (soft light moves a midtone by ~0.46·d).
    static let grainSoftLightGain = 2.2

    /// Film grain from `CIRandomGenerator`: mostly luminance noise (a little color with roughness),
    /// size ∝ the output (px at 2048 long side), a finer and a coarser octave, soft-light blended
    /// in sRGB so it is strongest in the midtones. Seeded per image: the pattern is stable across
    /// preview renders unless `grain.animated` (re-seeded at 24 fps).
    static func lookGrain(_ img: CIImage, _ a: ActiveLook, seed: UInt64) -> CIImage {
        let g = a.look.effects.grain
        let amount = clamp(g.amount, 0, 0.6) * a.strength
        guard amount > 0.004 else { return img }
        let size = clamp(g.size, 0.5, 3), r = clamp(g.roughness, 0, 1)
        let e = img.extent
        let s = max(1, size * max(e.width, e.height) / 2048)
        var seed = seed
        if g.animated { seed = seed &+ UInt64(max(0, Date().timeIntervalSinceReferenceDate * 24)) }

        let (o1, sd1) = noiseOctave(scale: s, seed: seed, extent: e)
        let (o2, sd2) = noiseOctave(scale: 2.2 * s, seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ 1, extent: e)
        // S = o1 + w·o2, each octave normalized to unit std first (w = 0.6·r relative weight).
        let w = 0.6 * r * sd1 / sd2
        let sum = scaled(o2, by: w)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: o1])
            .settingAlphaOne(in: e)
        let mean = 0.5 * (1 + w)
        // Unit-std noise per channel, then film.py's mono/chroma mix:
        // out_c = 0.35r·n_c + (1 − 0.7r)/3 · Σ n_j. Stored as 0.5 + 0.1·n so the cached texture
        // doesn't depend on amount or strength (a strength drag reuses it).
        let k = 0.1 / (sd1 * (1 + 0.36 * r * r).squareRoot())
        let diag = 0.35 * r, off = (1 - 0.7 * r) / 3
        let rowSum = diag + 3 * off
        func row(_ c: Int) -> CIVector {
            CIVector(x: k * (off + (c == 0 ? diag : 0)), y: k * (off + (c == 1 ? diag : 0)),
                     z: k * (off + (c == 2 ? diag : 0)), w: 0)
        }
        let bias = 0.5 - k * mean * rowSum
        let unit = sum.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).insertingIntermediate(cache: max(e.width, e.height) <= 2560) // preview: reused every frame
        // Soft-light layer: 0.5 + d, d = n · amount · 0.055 · gain.
        let a = 10 * amount * 0.055 * grainSoftLightGain
        let noise = unit.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - 0.5 * a, y: 0.5 - 0.5 * a, z: 0.5 - 0.5 * a, w: 0),
        ])
        return noise
            .applyingFilter("CISoftLightBlendMode", parameters: [
                kCIInputBackgroundImageKey: img.applyingFilter("CILinearToSRGBToneCurve"),
            ])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: e)
    }

    /// Uniform [0, 1] noise on `extent` with feature size `scale` px (Gaussian-smoothed white noise,
    /// sigma 0.45·scale), and its standard deviation.
    static func noiseOctave(scale: Double, seed: UInt64, extent e: CGRect) -> (CIImage, Double) {
        let dx = CGFloat(seed % 4096), dy = CGFloat((seed >> 12) % 4096)
        let white = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: e)
            .settingAlphaOne(in: e) // raw RGB; alpha from the generator is random
        let sigma = 0.45 * scale
        guard sigma >= 0.5 else { return (white, 0.2887) }
        // Measured for CIGaussianBlur on white noise: std ≈ 1 / (2·sqrt(pi)·sqrt(sigma² + 0.06)).
        let sd = 0.2887 / (2 * Double.pi.squareRoot() * (sigma * sigma + 0.06).squareRoot())
        return (white.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e), min(0.2887, sd))
    }

    /// Stable per-image grain seed: FNV-1a of the source size, the look id and the capture time.
    static func grainSeed(source: CIImage, lookID: String) -> UInt64 {
        var key = "\(Int(source.extent.width))x\(Int(source.extent.height))|\(lookID)"
        if let exif = source.properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            key += "|\(exif[kCGImagePropertyExifDateTimeOriginal as String] ?? "")"
            key += "|\(exif[kCGImagePropertyExifSubsecTimeOriginal as String] ?? "")"
        }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    // MARK: - Helpers

    /// smoothstep(t) of a [0, 1] gray image (values taken as-is in the linear working space).
    static func smoothstep01(_ t: CIImage) -> CIImage {
        let f = CIFilter.colorCurves()
        f.inputImage = t
        f.curvesData = vignetteCurve
        f.curvesDomain = CIVector(x: 0, y: 1)
        f.colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return f.outputImage ?? t
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isFinite ? min(max(v, lo), hi) : lo
    }
}
