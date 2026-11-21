import CoachModels
import CoreImage
import Foundation
import ImageIO
import Metal

extension EditRenderer {
    // MARK: - Loading inputs

    /// Loads a photo upright (EXIF orientation applied), color-managed.
    public static func sourceImage(data: Data) -> CIImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    /// Loads Core's `depth.png` (16-bit grayscale, millimetres) with raw values preserved
    /// (no gamma decoding), as `render(source:depth:...)` expects.
    public static func depthImage(pngData: Data) -> CIImage? {
        CIImage(data: pngData, options: [.colorSpace: NSNull()])
    }

    /// Builds a depth image from `/api/depth` output: Float32 meters, row-major, top row first.
    /// Stored like `depth.png`: 16-bit millimetres, 0 = unknown.
    public static func depthImage(meters: [Float], width: Int, height: Int) -> CIImage? {
        guard width > 0, height > 0, meters.count >= width * height else { return nil }
        var mm = [UInt16](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let v = meters[i]
            mm[i] = v.isFinite && v > 0 ? UInt16(min(65535, (v * 1000).rounded())) : 0
        }
        let data = mm.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 2, size: CGSize(width: width, height: height),
                       format: .L16, colorSpace: nil)
    }

    /// Loads a subject mask PNG (8-bit, 255 = subject) with raw values preserved.
    public static func maskImage(pngData: Data) -> CIImage? {
        CIImage(data: pngData, options: [.colorSpace: NSNull()])
    }

    // MARK: - Output

    /// Renders to a `CGImage` (8-bit, `colorSpace`, default sRGB). Pass `source.colorSpace`
    /// to keep a wide-gamut (Display P3) photo wide.
    public func cgImage(_ image: CIImage, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let cs = Self.outputSpace(colorSpace)
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: cs)
    }

    /// JPEG bytes (default quality 0.92, sRGB) with the color profile embedded.
    public func jpegData(_ image: CIImage, quality: Double = 0.92, colorSpace: CGColorSpace? = nil) -> Data? {
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: image, colorSpace: Self.outputSpace(colorSpace),
                                          options: [key: quality])
    }

    /// PNG bytes (8-bit RGBA, sRGB by default).
    public func pngData(_ image: CIImage, colorSpace: CGColorSpace? = nil) -> Data? {
        context.pngRepresentation(of: image, format: .RGBA8, colorSpace: Self.outputSpace(colorSpace))
    }

    /// Full-resolution render of `recipe` to JPEG, off the caller's actor.
    public func exportJPEG(source: CIImage, depth: CIImage?, subjectMask: CIImage?,
                           recipe: EditRecipe, quality: Double = 0.92) async -> Data? {
        let image = render(source: source, depth: depth, subjectMask: subjectMask, recipe: recipe, quality: .export)
        let cs = source.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        return jpegData(image, quality: quality, colorSpace: cs)
    }

    /// Draws `image` into a Metal texture (e.g. an `MTKView` drawable) and commits the work on
    /// `commandBuffer` (or Core Image's own queue). Returns the task; call
    /// `waitUntilCompleted()` only if you need the pixels on the CPU right away.
    @discardableResult
    public func render(_ image: CIImage, to texture: MTLTexture, commandBuffer: MTLCommandBuffer? = nil,
                       colorSpace: CGColorSpace? = nil) throws -> CIRenderTask {
        let dest = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        dest.colorSpace = Self.outputSpace(colorSpace)
        dest.isFlipped = true // Metal textures are top-left origin; CI is bottom-left.
        return try context.startTask(toRender: image, to: dest)
    }

    static func outputSpace(_ cs: CGColorSpace?) -> CGColorSpace {
        cs ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
