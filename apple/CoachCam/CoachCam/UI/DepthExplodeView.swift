import CoachAPI
import CoachModels
import CoachUI
import CoreGraphics
import ImageIO
import SceneKit
import SwiftUI
import UIKit

// A rough 3D "exploded" view of a shot: Core's depth.png (16-bit mm) turned into a SceneKit point
// cloud coloured from the photo, cut into depth slabs that drift apart along z on appear.
// Drag to orbit, pinch to zoom, tap to collapse or explode again.

/// The photo plus Core's `depth.png` (16-bit grayscale millimetres, 0 = unknown, same aspect).
struct DepthExplodeView: View {
    private let photo: CGImage
    private let depthPNG: Data
    @State private var slabs: [DepthCloud.Slab]?
    @State private var failed = false

    init(photo: CGImage, depthPNG: Data) {
        self.photo = photo
        self.depthPNG = depthPNG
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let slabs {
                DepthCloudSceneView(slabs: slabs).ignoresSafeArea()
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(GXColor.signal)
            } else {
                ProgressView().tint(GXColor.label)
            }
        }
        .animation(CoachEase.out(CoachDuration.slow), value: slabs != nil)
        .task {
            let photo = photo, png = depthPNG
            let built = await Task.detached(priority: .userInitiated) { () -> [DepthCloud.Slab]? in
                guard let depth = DepthCloud.decode(png) else { return nil }
                let s = DepthCloud.slabs(photo: photo, depth: depth)
                return s.contains { !$0.positions.isEmpty } ? s : nil
            }.value
            if let built { slabs = built } else { failed = true }
        }
    }
}

// MARK: - Loading from Core

extension DepthExplodeView {
    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Fetches `image.jpg` and `depth.png` for a shot, waiting up to `wait` seconds for the depth
    /// stage if it is still running. Uses CoachClient's authenticated asset requests.
    static func fetch(client: CoachClient, shot: Shot, wait: TimeInterval = 20) async throws -> (photo: CGImage, depthPNG: Data) {
        var shot = shot
        let deadline = Date().addingTimeInterval(wait)
        while !shot.assets.depth.isReady {
            if shot.assets.depth.status == .error {
                throw LoadError(message: "depth failed for \(shot.id): \(shot.assets.depth.error ?? "unknown error")")
            }
            guard Date() < deadline else { throw LoadError(message: "depth not ready for \(shot.id) after \(Int(wait)) s") }
            try await Task.sleep(for: .seconds(1))
            shot = try await client.shot(id: shot.id)
        }
        let base = "/api/shots/" + (shot.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? shot.id)
        let imagePath = shot.assets.image.url ?? base + "/image.jpg"
        let depthPath = shot.assets.depth.url ?? base + "/depth.png"
        async let imageData = client.assetData(imagePath)
        async let depthData = client.assetData(depthPath)
        let (jpeg, png) = try await (imageData, depthData)
        guard let photo = uprightImage(jpeg, maxPixel: 1024) else {
            throw LoadError(message: "image.jpg for \(shot.id) did not decode (\(jpeg.count) bytes)")
        }
        return (photo, png)
    }

    /// Decodes with EXIF orientation applied, capped at `maxPixel` on the long side.
    static func uprightImage(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Loads a shot's photo and depth from Core, then shows the exploded cloud.
struct DepthExplodeShotView: View {
    let client: CoachClient
    let shot: Shot
    @State private var loaded: Loaded?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private struct Loaded { let photo: CGImage; let depthPNG: Data }

    init(client: CoachClient, shot: Shot) {
        self.client = client
        self.shot = shot
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let loaded {
                DepthExplodeView(photo: loaded.photo, depthPNG: loaded.depthPNG)
            } else if let error {
                Text(error).font(CoachFont.label).foregroundStyle(GXColor.label)
                    .multilineTextAlignment(.center).padding(24)
            } else {
                ProgressView().tint(GXColor.label)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GXColor.label)
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, 6)
        }
        .task(id: shot.id) {
            do {
                let r = try await DepthExplodeView.fetch(client: client, shot: shot)
                loaded = Loaded(photo: r.photo, depthPNG: r.depthPNG)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - SceneKit view

private struct DepthCloudSceneView: UIViewRepresentable {
    let slabs: [DepthCloud.Slab]

    func makeCoordinator() -> DepthCloudScene { DepthCloudScene(slabs: slabs) }

    func makeUIView(context: Context) -> SCNView {
        let cloud = context.coordinator
        let view = SCNView(frame: .zero)
        view.scene = cloud.scene
        view.pointOfView = cloud.camera
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.inertiaEnabled = true
        let tap = UITapGestureRecognizer(target: cloud, action: #selector(DepthCloudScene.toggle))
        view.addGestureRecognizer(tap)
        cloud.start()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}

/// The scene: camera, a slowly swinging pivot and one point-cloud node per depth slab.
private final class DepthCloudScene: NSObject {
    let scene = SCNScene()
    let camera = SCNNode()
    private let pivot = SCNNode()
    private var slabNodes: [(node: SCNNode, explodedZ: Float)] = []
    private var exploded = false

    init(slabs: [DepthCloud.Slab]) {
        super.init()
        scene.background.contents = UIColor.black
        scene.fogColor = UIColor.black
        scene.fogStartDistance = CGFloat(DepthCloud.cameraZ - 0.2)
        scene.fogEndDistance = CGFloat(DepthCloud.cameraZ + 3.4)
        scene.fogDensityExponent = 1.4

        let cam = SCNCamera()
        cam.fieldOfView = DepthCloud.fovY
        cam.zNear = 0.05
        cam.zFar = 40
        camera.camera = cam
        camera.position = SCNVector3(0, 0, DepthCloud.cameraZ)
        scene.rootNode.addChildNode(camera)

        pivot.eulerAngles = SCNVector3(0.06, 0, 0)
        scene.rootNode.addChildNode(pivot)
        for (i, slab) in slabs.enumerated() {
            guard let node = DepthCloud.node(for: slab) else { continue }
            pivot.addChildNode(node)
            slabNodes.append((node, DepthCloud.explodedOffset(slab: i)))
        }
    }

    func start() {
        let swing: CGFloat = 0.35
        let right = SCNAction.rotateTo(x: 0.06, y: swing, z: 0, duration: 9, usesShortestUnitArc: true)
        let left = SCNAction.rotateTo(x: 0.06, y: -swing, z: 0, duration: 9, usesShortestUnitArc: true)
        right.timingMode = .easeInEaseOut
        left.timingMode = .easeInEaseOut
        let first = SCNAction.rotateTo(x: 0.06, y: swing, z: 0, duration: 4.5, usesShortestUnitArc: true)
        first.timingMode = .easeInEaseOut
        pivot.runAction(.sequence([.wait(duration: 0.4), first, .repeatForever(.sequence([left, right]))]), forKey: "orbit")
        setExploded(true, delay: 0.5)
    }

    @objc func toggle() { setExploded(!exploded, delay: 0) }

    private func setExploded(_ on: Bool, delay: TimeInterval) {
        exploded = on
        for (node, z) in slabNodes {
            let move = SCNAction.move(to: SCNVector3(0, 0, on ? z : 0), duration: on ? 1.8 : 1.1)
            move.timingMode = .easeInEaseOut
            node.runAction(delay > 0 ? .sequence([.wait(duration: delay), move]) : move, forKey: "explode")
        }
    }
}

// MARK: - Preview

#if DEBUG
enum DepthExplodePreview {
    /// `server/checks/fixtures/coach/can_far_messy_table.jpg`, found relative to this source file.
    static var photo: CGImage {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.append(path: "server/checks/fixtures/coach/can_far_messy_table.jpg")
        if let data = try? Data(contentsOf: url), let img = DepthExplodeView.uprightImage(data, maxPixel: 1024) {
            return img
        }
        let ctx = CGContext(data: nil, width: 192, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [UIColor.orange.cgColor, UIColor.blue.cgColor] as CFArray,
                                          locations: nil)!, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        return ctx.makeImage()!
    }

    /// A synthetic depth ramp at the photo's aspect: 0.6 m at the bottom to 4 m at the top, with a
    /// near round "subject" in the middle.
    static func depthRamp(for photo: CGImage, longSide: Int = 384) -> Data {
        let aspect = Double(photo.width) / Double(photo.height)
        let w = aspect >= 1 ? longSide : Int(Double(longSide) * aspect)
        let h = aspect >= 1 ? Int(Double(longSide) / aspect) : longSide
        var mm = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let fy = Double(y) / Double(h - 1)
                var d = 4000 - 3400 * fy
                let dx = (Double(x) / Double(w) - 0.5) / 0.18, dy = (fy - 0.55) / 0.14
                if dx * dx + dy * dy < 1 { d = 900 }
                mm[y * w + x] = UInt16(d)
            }
        }
        return DepthCloud.encodePNG16(mm, width: w, height: h) ?? Data()
    }
}

#Preview("Depth explode") {
    let photo = DepthExplodePreview.photo
    DepthExplodeView(photo: photo, depthPNG: DepthExplodePreview.depthRamp(for: photo))
}
#endif

// MARK: - Point cloud

/// Builds the cloud: a ~256 px grid over the photo, each sample unprojected through a pinhole at
/// its (log-normalised) depth, then bucketed into `slabCount` slabs, nearest first.
enum DepthCloud {
    static let slabCount = 6
    /// Slab spacing multiplier when exploded.
    static let spread: Float = 2.5
    static let longSide = 256
    /// Vertical field of view of the virtual eye and the scene camera, in degrees.
    static let fovY: CGFloat = 42
    /// Eye-space distance of the nearest / farthest point (scene units).
    static let near: Float = 1.2
    static let range: Float = 1.2
    static var mid: Float { near + range / 2 }
    /// The camera sits this far in front of the cloud's centre.
    static let cameraZ: Float = 3.1
    /// Exploding pushes slabs away from this eye distance (a third of the way in), so the
    /// foreground stays near where it was and the background recedes.
    static var anchor: Float { near + range * 0.3 }
    /// Neighbouring samples further apart than this in log depth are edge "flying pixels" (dropped).
    static let edgeLogJump: Float = 0.07

    struct Depth: Sendable {
        let width: Int
        let height: Int
        let mm: [UInt16]
    }

    /// One slab: packed xyz positions and linear rgb colours.
    struct Slab: Sendable {
        var positions: [Float] = []
        var colors: [Float] = []
    }

    /// Decodes Core's 16-bit grayscale `depth.png`. Reads the raw samples when the layout allows
    /// (no colour management), otherwise redraws into a 16-bit gray context.
    static func decode(_ png: Data) -> Depth? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        if img.bitsPerComponent == 16, img.bitsPerPixel == 16,
           let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            let order = img.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
            let little = order == CGBitmapInfo.byteOrder16Little.rawValue
            let bpr = img.bytesPerRow
            var mm = [UInt16](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = p + y * bpr
                for x in 0..<w {
                    let a = UInt16(row[2 * x]), b = UInt16(row[2 * x + 1])
                    mm[y * w + x] = little ? (b << 8 | a) : (a << 8 | b)
                }
            }
            return Depth(width: w, height: h, mm: mm)
        }
        var mm = [UInt16](repeating: 0, count: w * h)
        let ok = mm.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16,
                                      bytesPerRow: w * 2, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Depth(width: w, height: h, mm: mm) : nil
    }

    /// 16-bit grayscale PNG (used for the preview's synthetic depth).
    static func encodePNG16(_ mm: [UInt16], width: Int, height: Int) -> Data? {
        let bytes = mm.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                                bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The photo resampled to `w×h`, RGBA8 sRGB, top row first.
    static func pixels(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    static func slabs(photo: CGImage, depth: Depth) -> [Slab] {
        let aspect = Float(photo.width) / Float(max(1, photo.height))
        let gw = aspect >= 1 ? longSide : max(1, Int((Float(longSide) * aspect).rounded()))
        let gh = aspect >= 1 ? max(1, Int((Float(longSide) / aspect).rounded())) : longSide
        guard let px = pixels(photo, gw, gh), depth.width > 0, depth.height > 0 else { return [] }

        // Nearest depth sample per grid cell, as log(mm); NaN = unknown.
        var ld = [Float](repeating: .nan, count: gw * gh)
        var valid: [Float] = []
        valid.reserveCapacity(gw * gh)
        for j in 0..<gh {
            let sy = min(depth.height - 1, Int((Float(j) + 0.5) * Float(depth.height) / Float(gh)))
            for i in 0..<gw {
                let sx = min(depth.width - 1, Int((Float(i) + 0.5) * Float(depth.width) / Float(gw)))
                let v = depth.mm[sy * depth.width + sx]
                if v > 0 {
                    let l = logf(Float(v))
                    ld[j * gw + i] = l
                    valid.append(l)
                }
            }
        }
        guard !valid.isEmpty else { return [] }
        valid.sort()
        let lo = valid[Int(Float(valid.count - 1) * 0.02)]
        let hi = max(lo + 1e-3, valid[Int(Float(valid.count - 1) * 0.98)])

        let t = Float(tan(fovY * .pi / 360))
        var out = [Slab](repeating: Slab(), count: slabCount)
        for j in 0..<gh {
            for i in 0..<gw {
                let k = j * gw + i
                let l = ld[k]
                if l.isNaN { continue }
                if i + 1 < gw, !ld[k + 1].isNaN, abs(ld[k + 1] - l) > edgeLogJump { continue }
                if j + 1 < gh, !ld[k + gw].isNaN, abs(ld[k + gw] - l) > edgeLogJump { continue }
                let zn = min(1, max(0, (l - lo) / (hi - lo)))
                let s = min(slabCount - 1, Int(zn * Float(slabCount)))
                let dist = near + zn * range
                let u = (Float(i) + 0.5) / Float(gw) - 0.5
                let v = (Float(j) + 0.5) / Float(gh) - 0.5
                out[s].positions.append(u * 2 * t * aspect * dist)
                out[s].positions.append(-v * 2 * t * dist)
                out[s].positions.append(mid - dist)
                out[s].colors.append(linear(px[4 * k]))
                out[s].colors.append(linear(px[4 * k + 1]))
                out[s].colors.append(linear(px[4 * k + 2]))
            }
        }
        return out
    }

    /// z offset of slab `i` when exploded: its nominal centre pushed `spread`× away from `anchor`.
    static func explodedOffset(slab i: Int) -> Float {
        let centre = near + (Float(i) + 0.5) / Float(slabCount) * range
        return -(centre - anchor) * (spread - 1)
    }

    /// SceneKit treats vertex colours as linear.
    private static func linear(_ c: UInt8) -> Float { powf(Float(c) / 255, 2.2) }

    static func node(for slab: Slab) -> SCNNode? {
        let n = slab.positions.count / 3
        guard n > 0 else { return nil }
        let pos = slab.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let col = slab.colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertices = SCNGeometrySource(data: pos, semantic: .vertex, vectorCount: n, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let colors = SCNGeometrySource(data: col, semantic: .color, vectorCount: n, usesFloatComponents: true,
                                       componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(indices: (0..<UInt32(n)).map { $0 }, primitiveType: .point)
        // World-space size ≈ 2× the grid spacing at mid depth; clamped on screen so it stays a dense splat.
        element.pointSize = 2.2 * 2 * CGFloat(tan(fovY * .pi / 360)) * CGFloat(mid) / CGFloat(longSide)
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 5
        let geometry = SCNGeometry(sources: [vertices, colors], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}
