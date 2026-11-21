import CoreImage
import Foundation

/// CPU-side depth work for `depth_blur`: reads the depth map once, finds the subject's median
/// depth, and builds the blur-amount map (0 = sharp, 1 = full radius) at depth resolution.
/// Everything here is cached by the renderer, keyed by the input images' identity.
enum DepthFocus {
    /// Depth samples in meters at the depth map's own resolution (0 = unknown).
    struct Samples {
        let width: Int
        let height: Int
        let meters: [Float]
    }

    /// Depth-of-field tolerance: |1 - f/d| below this stays perfectly sharp.
    static let sharpBand = 0.04
    /// How quickly blur saturates with defocus (smaller = faster).
    static let falloff = 0.42

    /// Reads a 16-bit millimetre depth image (value = mm / 65535) into meters.
    static func readDepth(_ depth: CIImage, context: CIContext) -> Samples? {
        let e = depth.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0, w * h <= 4096 * 4096 else { return nil }
        let plane = readPlane(depth, extent: e, width: w, height: h, context: context)
        let scale: Float = 65.535 // (value * 65535 mm) / 1000
        return Samples(width: w, height: h, meters: plane.map { $0 * scale })
    }

    /// Renders `image` (scaled to `width x height` from `extent`) into a single float plane,
    /// top row first, without any color management.
    static func readPlane(_ image: CIImage, extent: CGRect, width: Int, height: Int, context: CIContext) -> [Float] {
        var img = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if Int(extent.width) != width || Int(extent.height) != height {
            img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                                        y: CGFloat(height) / extent.height))
        }
        img = img.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buf in
            context.render(img, toBitmap: buf.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: nil)
        }
        // CIContext.render(toBitmap:) writes the top row first.
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) { out[i] = rgba[i * 4] }
        return out
    }

    /// The depth range to keep sharp: the subject's 10th..90th percentile depth (clamped to
    /// 0.8x..1.35x of its median), or the central third's median without a mask.
    struct FocusRange: Hashable {
        var near: Double
        var median: Double
        var far: Double
    }

    /// Focus range of pixels where `weights > 0.5` (or the central third when `weights` is nil or
    /// the mask is nearly empty). Ignores unknown (0) depth. Nil if nothing qualifies.
    static func focusRange(_ s: Samples, weights: [Float]?) -> FocusRange? {
        var vals: [Float] = []
        vals.reserveCapacity(s.meters.count / 8)
        if let weights {
            for i in 0..<s.meters.count where weights[i] > 0.5 && s.meters[i] > 0 { vals.append(s.meters[i]) }
        }
        var fromMask = true
        if vals.count < 16 {
            fromMask = false
            vals.removeAll(keepingCapacity: true)
            let x0 = s.width / 3, x1 = s.width * 2 / 3, y0 = s.height / 3, y1 = s.height * 2 / 3
            for y in y0..<max(y1, y0 + 1) {
                for x in x0..<max(x1, x0 + 1) {
                    let d = s.meters[y * s.width + x]
                    if d > 0 { vals.append(d) }
                }
            }
        }
        guard !vals.isEmpty else { return nil }
        vals.sort() // <= 250k floats, once per (depth, mask): ~2 ms
        func q(_ f: Double) -> Double { Double(vals[min(vals.count - 1, Int(f * Double(vals.count)))]) }
        let med = q(0.5)
        guard fromMask else { return FocusRange(near: med, median: med, far: med) }
        return FocusRange(near: max(q(0.1), 0.8 * med), median: med, far: min(q(0.9), 1.35 * med))
    }

    /// Defocus amount per pixel (0 = sharp, 1 = full radius) from the thin-lens circle of
    /// confusion, which is proportional to |1 - f/d|: 0 at the focus plane, 1 at infinity and at
    /// half the focus distance. Everything inside `near...far` counts as the focus plane, plus a
    /// small depth-of-field band; blur then eases in and saturates smoothly.
    static func blurMap(_ s: Samples, near: Double, far: Double) -> [Float] {
        let band = sharpBand, k = falloff
        let norm = 1 - exp(-(1 - band) / k)
        let lo = Float(max(min(near, far), 0.05)), hi = Float(max(near, far, 0.05))
        var out = [Float](repeating: 0, count: s.meters.count)
        for i in 0..<s.meters.count {
            let d = s.meters[i]
            let c: Double
            if d <= 0 { c = 1 } // unknown depth = far (sky)
            else if d < lo { c = Double(lo / d - 1) }
            else if d > hi { c = Double(1 - hi / d) }
            else { c = 0 }
            let x = max(0, min(c, 2) - band)
            let ease = min(1, x / 0.12)
            out[i] = Float(min(1, (1 - exp(-x / k)) / norm * ease * ease * (3 - 2 * ease)))
        }
        return out
    }

    /// Wraps a single float plane (top row first) as a grayscale CIImage without color management.
    static func image(fromPlane plane: [Float], width: Int, height: Int) -> CIImage {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            // CIImage(bitmapData:) also treats the first row as the top.
            for x in 0..<width {
                let v = plane[y * width + x]
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v
            }
        }
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }
}
