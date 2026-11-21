import CoreGraphics
import CoreML
import Foundation
import ImageIO

/// On-device metric depth with Apple's Depth Pro 2 S (Core ML package `depthpro2-s_w4` from
/// `apple/DepthPro2-coreml`, bundled as `DepthPro2S.mlpackage`; see tools/depthpro2_coreml).
///
/// The model takes a fixed 854x480 RGB frame in [0, 1] (ImageNet normalization is inside the
/// model) and returns focal-normalized inverse depth. A photo is scaled to fit the frame, keeping
/// its aspect, and replicate-padded right and bottom, as the PyTorch model pads its input. Depth in
/// metres is `f_px / (854 * inverse_depth)`, `f_px` being in pixels of the fitted photo, from its
/// 35mm-equivalent EXIF focal length (iPhone main camera, 24 mm, when the photo has none).
enum DepthPro2 {
    static let frameWidth = 854, frameHeight = 480
    /// The iPhone 15 Pro main camera's 35mm-equivalent focal length, used when EXIF has none.
    static let fallbackFocal35mm = 24.0

    /// The compiled model Xcode puts in the app bundle; nil when the package wasn't fetched.
    static let modelURL = Bundle.main.url(forResource: "DepthPro2S", withExtension: "mlmodelc")
    static var isAvailable: Bool { modelURL != nil }
    static var isLoaded: Bool { lock.withLock { model != nil } }

    private static let lock = NSLock()
    private static var model: MLModel?
    private static var warming = false

    /// Loads the model and runs one prediction, off the main thread, once. Call after launch.
    static func warmUp() {
        guard isAvailable else { return }
        let start = lock.withLock { () -> Bool in
            guard model == nil, !warming else { return false }
            warming = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            defer { lock.withLock { warming = false } }
            do {
                let t0 = Date()
                let m = try loadedModel()
                _ = try m.prediction(from: try input(rgba: [128, 128, 128, 255], width: 1, height: 1),
                                     using: m.makeState())
                print("DepthPro2: warmed in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            } catch {
                print("DepthPro2: warm-up failed: \(error)")
            }
        }
    }

    /// The model, loaded on first use (compute units .all). Blocks while it loads.
    static func loadedModel() throws -> MLModel {
        try lock.withLock {
            if let model { return model }
            guard let url = modelURL else { throw DepthPro2Error.missingModel }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            config.functionName = "res_854x480"
            let m = try MLModel(contentsOf: url, configuration: config)
            model = m
            return m
        }
    }

    /// Upright metric depth (metres, row-major, top row first; ≤ 0 or non-finite = unknown) for a
    /// HEIC/JPEG, at the photo's aspect with the long side ≤ 854 (640x480 for a 4:3 landscape).
    static func metres(fromPhotoData data: Data) throws -> (metres: [Float], width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: frameWidth,
              ] as CFDictionary) else { throw DepthPro2Error.unreadablePhoto }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let f35 = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
        return try metres(for: image, focal35mm: f35)
    }

    /// Upright metric depth for an upright image; see `metres(fromPhotoData:)`.
    static func metres(for image: CGImage, focal35mm: Double?) throws
        -> (metres: [Float], width: Int, height: Int) {
        let s = min(Double(frameWidth) / Double(image.width), Double(frameHeight) / Double(image.height))
        let w = max(1, min(frameWidth, Int((Double(image.width) * s).rounded())))
        let h = max(1, min(frameHeight, Int((Double(image.height) * s).rounded())))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw DepthPro2Error.unreadablePhoto }

        let m = try loadedModel()
        let out = try m.prediction(from: try input(rgba: rgba, width: w, height: h), using: m.makeState())
        guard let inv = out.featureValue(for: "inverse_depth")?.multiArrayValue else {
            throw DepthPro2Error.badOutput
        }
        let f35 = (focal35mm ?? 0) > 0 ? focal35mm! : fallbackFocal35mm
        let fPx = f35 * (Double(w * w + h * h)).squareRoot() / (36.0 * 36.0 + 24.0 * 24.0).squareRoot()
        // The model normalizes by the width it sees (854, padding included), not the photo's w.
        let scale = Float(fPx / Double(frameWidth))
        var metres = [Float](repeating: 0, count: w * h)
        inv.withUnsafeBufferPointer(ofType: Float16.self) { p in
            let st = inv.strides.map(\.intValue)   // (1, 480, 854)
            for y in 0..<h {
                for x in 0..<w {
                    let v = Float(p[y * st[1] + x * st[2]])
                    metres[y * w + x] = v > 0 ? scale / v : 0
                }
            }
        }
        return (metres, w, h)
    }

    /// The model's `frame` input: the w x h RGBA pixels at the top left of an 854x480 float16
    /// frame in [0, 1], the rest replicating the last column and row.
    private static func input(rgba: [UInt8], width w: Int, height h: Int) throws -> MLFeatureProvider {
        let frame = try MLMultiArray(shape: [1, 3, NSNumber(value: frameHeight), NSNumber(value: frameWidth)],
                                     dataType: .float16)
        let st = frame.strides.map(\.intValue)
        frame.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in
            for c in 0..<3 {
                for y in 0..<frameHeight {
                    let row = min(y, h - 1) * w
                    let base = c * st[1] + y * st[2]
                    for x in 0..<frameWidth {
                        p[base + x * st[3]] = Float16(Float(rgba[(row + min(x, w - 1)) * 4 + c]) / 255)
                    }
                }
            }
        }
        return try MLDictionaryFeatureProvider(dictionary: ["frame": MLFeatureValue(multiArray: frame)])
    }
}

enum DepthPro2Error: Error {
    case missingModel, unreadablePhoto, badOutput
}
