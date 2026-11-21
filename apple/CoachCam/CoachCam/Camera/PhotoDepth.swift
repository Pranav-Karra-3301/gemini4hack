import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The depth that rides along with a capture (LiDAR-fused on Pro iPhones, dual-camera disparity
/// otherwise), upright like the photo and in Core's `depth.png` format: 16-bit grayscale
/// millimetres, 0 = unknown. Load the PNG with `EditRenderer.depthImage(pngData:)`.
enum PhotoDepth {
    /// The depth (or disparity) embedded in a HEIC/JPEG, plus the photo's EXIF orientation.
    static func depthData(fromPhotoData data: Data) -> (AVDepthData, CGImagePropertyOrientation)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let info = (CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDepth)
                  ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDisparity))
                  as? [AnyHashable: Any],
              let depth = try? AVDepthData(fromDictionaryRepresentation: info) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (depth, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    /// Depth in metres (`DepthFloat32`, disparity converted), rotated upright the way the photo
    /// is shown. NaN or ≤ 0 = unknown.
    static func metres(from depth: AVDepthData, orientation: CGImagePropertyOrientation) -> CVPixelBuffer {
        depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            .applyingExifOrientation(orientation)
            .depthDataMap
    }

    /// `metres(from:orientation:)` as a Core Image image (one Float32 channel, metres).
    static func metresImage(from depth: AVDepthData, orientation: CGImagePropertyOrientation) -> CIImage {
        CIImage(cvPixelBuffer: metres(from: depth, orientation: orientation))
    }

    /// The photo's embedded depth as Core's `depth.png`; nil when the photo carries none.
    static func depthPNGmm(fromPhotoData data: Data) -> Data? {
        guard let found = depthData(fromPhotoData: data) else { return nil }
        return depthPNGmm(from: found.0, orientation: found.1)
    }

    /// `depth` (e.g. `AVCapturePhoto.depthData`, sensor-native) as Core's `depth.png`, upright
    /// for `orientation` (the photo's EXIF orientation).
    static func depthPNGmm(from depth: AVDepthData, orientation: CGImagePropertyOrientation) -> Data? {
        let pb = metres(from: depth, orientation: orientation)
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var m = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { m[y * w + x] = row[x] }
        }
        return pngMM(metres: m, width: w, height: h)
    }

    // MARK: Pure conversion (no AVFoundation; unit-testable)

    /// Metres → millimetres for `depth.png`: 0 = unknown (NaN, ±inf, ≤ 0), clamped to 65535.
    static func millimetres(_ m: Float) -> UInt16 {
        guard m.isFinite, m > 0 else { return 0 }
        return UInt16(min(65535, (m * 1000).rounded()))
    }

    /// Row-major metres (top row first) → 16-bit grayscale PNG in millimetres.
    static func pngMM(metres: [Float], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, metres.count >= width * height else { return nil }
        let mm = metres.prefix(width * height).map(millimetres)
        let bytes = mm.withUnsafeBytes { Data($0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                                  bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}
