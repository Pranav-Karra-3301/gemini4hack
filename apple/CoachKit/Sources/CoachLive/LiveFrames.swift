import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Video frames for Gemini Live: at most 1 fps, only when the picture changed, JPEG ≤768 px.
// Order of work per camera frame is cheapest-first: a clock check, then a 16×16 luma thumbnail
// (reads ~1/64 of the pixels), then the JPEG encode only for frames that will actually be sent.

/// A 16×16 grayscale thumbnail used to tell whether two frames differ.
public struct LumaThumbnail: Sendable, Equatable {
    public static let side = 16
    /// `side * side` luma values, row-major, 0...255.
    public var pixels: [UInt8]

    public init(pixels: [UInt8]) {
        precondition(pixels.count == Self.side * Self.side, "LumaThumbnail needs 256 pixels")
        self.pixels = pixels
    }

    /// Box-downsamples a `CGImage` (any size/format) through CoreGraphics.
    public init?(cgImage: CGImage) {
        let n = Self.side
        var buf = [UInt8](repeating: 0, count: n * n)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        pixels = buf
    }

    /// Decodes a JPEG/PNG at reduced size (ImageIO uses DCT scaling, so this is cheap).
    public init?(imageData: Data) {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        self.init(cgImage: img)
    }

    /// Reads the luma plane of a camera buffer directly (420 bi-planar, 8-bit) or BGRA/ARGB;
    /// other formats go through Core Image. Averages a sparse grid inside each cell.
    public init?(pixelBuffer pb: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(pb)
        let yuv: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let rgb: Set<OSType> = [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB]
        guard yuv.contains(format) || rgb.contains(format) else {
            guard let cg = LiveFrameEncoder.cgImage(from: pb, orientation: .up, maxDimension: 64) else { return nil }
            self.init(cgImage: cg)
            return
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let isYUV = yuv.contains(format)
        let base = isYUV ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)
        let w = isYUV ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = isYUV ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let rowBytes = isYUV ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        guard let base, w >= Self.side, h >= Self.side else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let n = Self.side
        // ~8×8 samples per cell regardless of resolution.
        let sx = max(1, w / n / 8), sy = max(1, h / n / 8)
        var out = [UInt8](repeating: 0, count: n * n)
        for cy in 0..<n {
            let y0 = cy * h / n, y1 = (cy + 1) * h / n
            for cx in 0..<n {
                let x0 = cx * w / n, x1 = (cx + 1) * w / n
                var sum = 0, count = 0
                var y = y0
                while y < y1 {
                    let row = p + y * rowBytes
                    var x = x0
                    while x < x1 {
                        if isYUV {
                            sum += Int(row[x])
                        } else {
                            let px = row + x * 4
                            // BGRA: b g r a; ARGB: a r g b. Rec. 709 weights (54, 183, 19)/256.
                            let (r, g, b) = format == kCVPixelFormatType_32BGRA
                                ? (Int(px[2]), Int(px[1]), Int(px[0]))
                                : (Int(px[1]), Int(px[2]), Int(px[3]))
                            sum += (54 * r + 183 * g + 19 * b) >> 8
                        }
                        count += 1
                        x += sx
                    }
                    y += sy
                }
                out[cy * n + cx] = UInt8(clamping: count > 0 ? sum / count : 0)
            }
        }
        self.init(pixels: out)
    }

    /// How different two thumbnails are: mean absolute luma difference (0...1) and the fraction
    /// of cells whose difference exceeds `cellThreshold` (0...1, in luma units / 255).
    public func difference(to other: LumaThumbnail, cellThreshold: Float = 0.08) -> (mean: Float, changedFraction: Float) {
        var total = 0, changed = 0
        let limit = Int(cellThreshold * 255)
        for i in 0..<pixels.count {
            let d = abs(Int(pixels[i]) - Int(other.pixels[i]))
            total += d
            if d > limit { changed += 1 }
        }
        let n = Float(pixels.count)
        return (Float(total) / n / 255, Float(changed) / n)
    }
}

/// Rate-limits and de-duplicates video frames. A plain value type so it can be unit-tested
/// with synthetic clocks; `LiveSession` keeps one behind its lock.
public struct FrameThrottle: Sendable {
    public enum Decision: Sendable, Equatable { case send, tooSoon, unchanged }

    /// Minimum seconds between sent frames (Gemini Live samples video at 1 fps).
    public var minInterval: TimeInterval
    /// After an unchanged frame, wait this long before diffing again (bounds work on static scenes).
    public var recheckInterval: TimeInterval
    /// A frame counts as changed if the mean luma difference exceeds this (0...1)…
    public var meanThreshold: Float
    /// …or if this fraction of the 256 cells changed by more than `cellThreshold`.
    public var changedFractionThreshold: Float
    public var cellThreshold: Float
    /// Re-send an unchanged scene after this long so the model's view never goes too stale. `nil` = never.
    public var maxStaleInterval: TimeInterval?

    public private(set) var lastSentAt: TimeInterval?
    public private(set) var lastCheckedAt: TimeInterval?
    public private(set) var lastSent: LumaThumbnail?

    public init(minInterval: TimeInterval = 1.0, recheckInterval: TimeInterval = 0.25,
                meanThreshold: Float = 0.02, changedFractionThreshold: Float = 0.04,
                cellThreshold: Float = 0.08, maxStaleInterval: TimeInterval? = nil) {
        self.minInterval = minInterval
        self.recheckInterval = recheckInterval
        self.meanThreshold = meanThreshold
        self.changedFractionThreshold = changedFractionThreshold
        self.cellThreshold = cellThreshold
        self.maxStaleInterval = maxStaleInterval
    }

    /// Cheap pre-check before computing a thumbnail: false if a frame at `now` would be throttled anyway.
    public func isDue(at now: TimeInterval) -> Bool {
        if let s = lastSentAt, now - s < minInterval { return false }
        if let c = lastCheckedAt, now - c < recheckInterval { return false }
        return true
    }

    /// Decides about a frame and records the decision (call only when you will act on `.send`).
    public mutating func offer(_ thumb: LumaThumbnail, at now: TimeInterval) -> Decision {
        guard isDue(at: now) else { return .tooSoon }
        if let prev = lastSent, let sentAt = lastSentAt {
            let stale = maxStaleInterval.map { now - sentAt >= $0 } ?? false
            let d = thumb.difference(to: prev, cellThreshold: cellThreshold)
            if !stale && d.mean <= meanThreshold && d.changedFraction <= changedFractionThreshold {
                lastCheckedAt = now
                return .unchanged
            }
        }
        lastSent = thumb
        lastSentAt = now
        lastCheckedAt = now
        return .send
    }

    /// Forget the last frame so the next one is sent (e.g. after a reconnect without context).
    public mutating func reset() {
        lastSent = nil
        lastSentAt = nil
        lastCheckedAt = nil
    }
}

/// JPEG encoding for Live frames (≤768 px long side by default, sRGB, quality 0.6).
public enum LiveFrameEncoder {
    /// Shared GPU-backed context; `CIContext` is thread-safe and expensive to create.
    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Encodes a camera buffer. `orientation` rotates sensor-native buffers upright
    /// (e.g. `.right` for a portrait iPhone back camera without a rotated connection).
    public static func jpeg(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up,
                            maxDimension: Int = 768, quality: Double = 0.6) -> Data? {
        let image = scaled(CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation), maxDimension: maxDimension)
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        return ciContext.jpegRepresentation(of: image, colorSpace: srgb, options: opts)
    }

    /// Encodes a `CGImage`, downscaling so the long side is at most `maxDimension`.
    public static func jpeg(from cgImage: CGImage, maxDimension: Int = 768, quality: Double = 0.6) -> Data? {
        let long = max(cgImage.width, cgImage.height)
        var img = cgImage
        if long > maxDimension {
            let s = Double(maxDimension) / Double(long)
            let w = max(1, Int((Double(cgImage.width) * s).rounded()))
            let h = max(1, Int((Double(cgImage.height) * s).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let small = ctx.makeImage() else { return nil }
            img = small
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Renders a camera buffer to a (downscaled) `CGImage`.
    public static func cgImage(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up,
                               maxDimension: Int = 768) -> CGImage? {
        let image = scaled(CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation), maxDimension: maxDimension)
        return ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb)
    }

    static func scaled(_ image: CIImage, maxDimension: Int) -> CIImage {
        let ext = image.extent
        let long = max(ext.width, ext.height)
        guard long > CGFloat(maxDimension) else { return image }
        let s = CGFloat(maxDimension) / long
        let out = image.applyingFilter("CILanczosScaleTransform",
                                       parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        // Lanczos can leave a fractional extent; crop to whole pixels at the origin.
        let e = out.extent
        return out.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .cropped(to: CGRect(x: 0, y: 0, width: floor(e.width), height: floor(e.height)))
    }
}
