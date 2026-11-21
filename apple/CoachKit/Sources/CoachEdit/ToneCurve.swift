import Foundation

/// The global tone curve built from exposure headroom plus the five tone sliders
/// (contrast, highlights, shadows, whites, blacks).
///
/// The curve works in a perceptual (sRGB-encoded) space. Input runs over `0...domainMax`, where
/// `domainMax > 1` when exposure or local light pushed values past white; that headroom is rolled
/// off with a smooth shoulder instead of clipping. Output is `0...1`. All slider values are
/// normalized to `-1...1` (slider / 100).
struct ToneCurve: Hashable, Sendable {
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    /// Largest input value (perceptual) the curve must map; `1` means no headroom.
    var domainMax = 1.0

    /// Mid-grey pivot for contrast (18% grey in sRGB encoding).
    static let pivot = 0.46
    /// Where the highlight shoulder starts when there is headroom.
    static let knee = 0.78

    var isIdentity: Bool {
        contrast == 0 && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0 && domainMax <= 1
    }

    /// Maps one perceptual input value.
    func value(_ x: Double) -> Double {
        var u = shoulder(max(0, x))
        u = applyContrast(u)
        // Shadows and highlights: smooth bumps peaking at 0.25 and 0.75 (Lightroom-like regions).
        // The global part is gentle; the renderer adds a local (edge-aware) part on top.
        let bump = 0.10546875 // max of u(1-u)^3
        let sw = u <= 0 ? 0 : (u >= 1 ? 0 : u * pow(1 - u, 3) / bump)
        let hw = u <= 0 ? 0 : (u >= 1 ? 0 : pow(u, 3) * (1 - u) / bump)
        u += (shadows > 0 ? 0.11 : 0.09) * shadows * sw
        u += (highlights > 0 ? 0.10 : 0.12) * highlights * hw
        // Whites and blacks move the ends of the range: whites + pushes toward clipping,
        // blacks - crushes, blacks + gives a matte lift.
        let uc = min(max(u, 0), 1)
        u += 0.085 * whites * pow(uc, 4)
        u += 0.07 * blacks * pow(1 - uc, 4)
        return min(max(u, 0), 1)
    }

    /// `count` samples over `0...domainMax`, forced monotonic (no tone reversals, no banding spikes).
    func samples(count: Int = 1024) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var last: Float = 0
        for i in 0..<count {
            let x = Double(i) / Double(count - 1) * domainMax
            let v = max(Float(value(x)), last)
            out[i] = v
            last = v
        }
        return out
    }

    // MARK: - Pieces

    /// Identity below the knee; above it, compresses `knee...domainMax` into `knee...1`
    /// with slope 1 at the knee (C1-continuous), so pushed highlights roll off softly.
    private func shoulder(_ x: Double) -> Double {
        let k = Self.knee
        guard domainMax > 1.0001, x > k else { return min(x, max(domainMax, 1)) }
        let t = (x - k) / (1 - k)
        let tmax = (domainMax - k) / (1 - k)
        let a = (tmax - 1) / tmax
        return k + (1 - k) * t / (1 + a * t)
    }

    /// Positive: normalized logistic S-curve around the pivot (endpoints fixed).
    /// Negative: the inverse of that curve (flattens midtones toward the pivot).
    private func applyContrast(_ u: Double) -> Double {
        guard contrast != 0 else { return u }
        let p = Self.pivot
        func sig(_ v: Double) -> Double { 1 / (1 + exp(-v)) }
        if contrast > 0 {
            let k = 6.5 * contrast
            let lo = sig(-k * p), hi = sig(k * (1 - p))
            return (sig(k * (u - p)) - lo) / (hi - lo)
        } else {
            let k = 4.5 * -contrast
            let lo = sig(-k * p), hi = sig(k * (1 - p))
            let z = lo + min(max(u, 0), 1) * (hi - lo)
            return p + log(z / (1 - z)) / k
        }
    }
}

/// sRGB transfer helpers (extended: mirrored for negatives, unbounded above 1).
enum SRGB {
    static func encode(_ x: Double) -> Double {
        let a = abs(x)
        let e = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1 / 2.4) - 0.055
        return x < 0 ? -e : e
    }

    static func decode(_ x: Double) -> Double {
        let a = abs(x)
        let d = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return x < 0 ? -d : d
    }
}
