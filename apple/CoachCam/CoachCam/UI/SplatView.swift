import CoachUI
import CoreGraphics
import Metal
import MetalKit
import OSLog
import SwiftUI
import UIKit
import simd

// The shot as soft Gaussian splats in 3D (the Wayback look): ~250k points unprojected from the
// photo and its depth map through a ~26 mm pinhole, each a round splat with a Gaussian falloff in
// the photo's colour, drawn far to near with premultiplied blending in Metal.
// One-finger drag orbits (±25°), pinch zooms, double-tap resets; a slow idle sway shows the parallax.

struct SplatView: View {
    let photo: CGImage
    let depthPNG: Data
    @State private var cloud: SplatCloud?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let cloud {
                SplatMetalView(cloud: cloud).transition(.opacity)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(GXColor.signal)
            } else {
                ProgressView().tint(GXColor.label)
            }
        }
        .animation(CoachEase.out(CoachDuration.slow), value: cloud != nil)
        .task(id: ObjectIdentifier(photo)) {
            if let hit = ShotCaches.splats.get(photo) { cloud = hit; return }
            let photo = photo, png = depthPNG
            let built = await Task.detached(priority: .userInitiated) { SplatCloud.build(photo: photo, depthPNG: png) }.value
            guard !Task.isCancelled else { return }
            if let built {
                ShotCaches.splats.put(photo, built)
                cloud = built
            } else {
                failed = true
            }
        }
    }
}

/// A few recent shots' derived views (depth ramp, splats, slabs), keyed by the photo's identity.
@MainActor
final class ShotCache<Value> {
    private var entries: [(key: CGImage, value: Value)] = []
    private let capacity: Int

    init(capacity: Int = 3) { self.capacity = capacity }

    func get(_ key: CGImage) -> Value? { entries.first { $0.key === key }?.value }

    func put(_ key: CGImage, _ value: Value) {
        entries.removeAll { $0.key === key }
        entries.insert((key, value), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }
}

@MainActor
enum ShotCaches {
    static let splats = ShotCache<SplatCloud>(capacity: 2)
    static let depthRamps = ShotCache<UIImage>(capacity: 3)
    static let slabs = ShotCache<[DepthCloud.Slab]>(capacity: 2)
}

// MARK: - Building

/// One splat as the shader reads it: position (m, eye space of the original camera), world radius,
/// sRGB colour. 20 bytes, matching `Splat` in the Metal source.
struct SplatVertex {
    var x: Float, y: Float, z: Float, r: Float
    var rgba: UInt32
}

struct SplatCloud: Sendable {
    let vertices: [SplatVertex]
    /// Distance from the original eye to the orbit target (median depth, m).
    let focus: Float
    /// Vertical field of view of the original photo (radians) and its aspect (w / h).
    let fovY: Float
    let aspect: Float

    static let targetCount = 250_000
    /// Splat diameter in grid cells: enough overlap that the Gaussians read as one soft surface.
    static let footprint: Float = 2.4
    /// Far depths are pulled in (z' = focus · (z / focus)^k) so the background stays close.
    static let depthPow: Float = 0.65
    static let edgeLogJump: Float = 0.1

    static func build(photo: CGImage, depthPNG: Data) -> SplatCloud? {
        guard let depth = DepthCloud.decode(depthPNG), depth.width > 1, depth.height > 1 else { return nil }
        let aspect = Float(photo.width) / Float(max(1, photo.height))
        let gw = max(2, Int((Float(targetCount) * aspect).squareRoot().rounded()))
        let gh = max(2, Int((Float(targetCount) / Float(gw)).rounded()))
        guard let px = DepthCloud.pixels(photo, gw, gh) else { return nil }

        // Depth per grid cell (bilinear-free nearest sample), log mm; 0 = unknown.
        var ld = [Float](repeating: .nan, count: gw * gh)
        var valid: [Float] = []
        valid.reserveCapacity(gw * gh / 4)
        for j in 0..<gh {
            let sy = min(depth.height - 1, Int((Float(j) + 0.5) * Float(depth.height) / Float(gh)))
            for i in 0..<gw {
                let sx = min(depth.width - 1, Int((Float(i) + 0.5) * Float(depth.width) / Float(gw)))
                let v = depth.mm[sy * depth.width + sx]
                guard v > 0 else { continue }
                let l = logf(Float(v))
                ld[j * gw + i] = l
                if (i ^ j) & 3 == 0 { valid.append(l) }
            }
        }
        guard valid.count > 16 else { return nil }
        valid.sort()
        let lo = valid[Int(Float(valid.count - 1) * 0.02)]
        let hi = max(lo + 1e-3, valid[Int(Float(valid.count - 1) * 0.98)])
        let mid = valid[valid.count / 2]
        let focus = expf(mid) / 1000

        // ~26 mm equivalent: f = 26 / 43.27 of the frame diagonal.
        let f = 0.601 * (Float(gw * gw + gh * gh)).squareRoot()
        let cx = Float(gw) / 2, cy = Float(gh) / 2

        var out: [SplatVertex] = []
        out.reserveCapacity(gw * gh)
        var keys: [Float] = []
        keys.reserveCapacity(gw * gh)
        for j in 0..<gh {
            for i in 0..<gw {
                let k = j * gw + i
                var l = ld[k]
                if l.isNaN {
                    l = hi
                } else {
                    if i + 1 < gw, !ld[k + 1].isNaN, abs(ld[k + 1] - l) > edgeLogJump { continue }
                    if j + 1 < gh, !ld[k + gw].isNaN, abs(ld[k + gw] - l) > edgeLogJump { continue }
                }
                let z0 = expf(min(hi, max(lo, l))) / 1000
                let z = focus * powf(z0 / focus, depthPow)
                let u = Float(i) + 0.5 - cx, v = Float(j) + 0.5 - cy
                let rgba = UInt32(px[4 * k]) | UInt32(px[4 * k + 1]) << 8 | UInt32(px[4 * k + 2]) << 16 | 255 << 24
                out.append(SplatVertex(x: u * z / f, y: -v * z / f, z: -z, r: footprint * 0.5 * z / f, rgba: rgba))
                keys.append(z)
            }
        }
        guard !out.isEmpty else { return nil }
        // Far first, so plain "over" blending is right for the ±25° the orbit allows.
        let order = keys.indices.sorted { keys[$0] > keys[$1] }
        let sorted = order.map { out[$0] }
        let fovY = 2 * atanf(Float(gh) / 2 / f)
        return SplatCloud(vertices: sorted, focus: focus, fovY: fovY, aspect: aspect)
    }
}

// MARK: - Metal view

private struct SplatMetalView: UIViewRepresentable {
    let cloud: SplatCloud

    func makeCoordinator() -> SplatRenderer { SplatRenderer(cloud: cloud) }

    func makeUIView(context: Context) -> MTKView {
        let r = context.coordinator
        let view = MTKView(frame: .zero, device: r.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.delegate = r
        r.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

/// Orbit state + the draw. Gestures set targets; each frame eases toward them.
final class SplatRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let buffer: MTLBuffer?
    private let count: Int
    private let cloud: SplatCloud

    static let maxYaw: Float = 25 * .pi / 180
    static let maxPitch: Float = 15 * .pi / 180

    private var yaw: Float = 0, pitch: Float = 0, zoom: Float = 1
    private var goalYaw: Float = 0, goalPitch: Float = 0, goalZoom: Float = 1
    private var panStart = SIMD2<Float>(0, 0)
    private var pinchStart: Float = 1
    private var lastTouch = CACurrentMediaTime()
    private var sway: Float = 0
    private let born = CACurrentMediaTime()

    init(cloud: SplatCloud) {
        self.cloud = cloud
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        count = cloud.vertices.count
        buffer = cloud.vertices.withUnsafeBytes { raw in
            raw.baseAddress.flatMap { device?.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
        }
        super.init()
        pipeline = Self.makePipeline(device)
    }

    func attach(to view: MTKView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let reset = UITapGestureRecognizer(target: self, action: #selector(onReset))
        reset.numberOfTapsRequired = 2
        [pan, pinch, reset].forEach(view.addGestureRecognizer)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        lastTouch = CACurrentMediaTime()
        if g.state == .began { panStart = SIMD2(goalYaw, goalPitch) }
        let t = g.translation(in: g.view)
        goalYaw = min(Self.maxYaw, max(-Self.maxYaw, panStart.x - Float(t.x) * 0.006))
        goalPitch = min(Self.maxPitch, max(-Self.maxPitch, panStart.y - Float(t.y) * 0.004))
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        lastTouch = CACurrentMediaTime()
        if g.state == .began { pinchStart = goalZoom }
        goalZoom = min(1.5, max(0.45, pinchStart / Float(max(g.scale, 0.01))))
    }

    @objc private func onReset() {
        lastTouch = CACurrentMediaTime()
        goalYaw = 0; goalPitch = 0; goalZoom = 1
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let buffer, let queue, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        let ease: Float = 0.16
        yaw += (goalYaw - yaw) * ease
        pitch += (goalPitch - pitch) * ease
        zoom += (goalZoom - zoom) * ease
        // Idle sway fades in after 1.5 s without a touch, out the moment one lands.
        let idle = now - lastTouch > 1.5
        sway += ((idle ? 1 : 0) - sway) * (idle ? 0.02 : 0.2)
        let t = Float(now - born)
        let swayYaw = sway * 0.09 * sinf(t * 0.55)
        let swayPitch = sway * 0.025 * sinf(t * 0.37)

        let size = view.drawableSize
        let viewAspect = Float(size.width / max(1, size.height))
        // Fit the whole photo: widen the vertical FOV when the view is narrower than the photo.
        let tanHalf = max(tanf(cloud.fovY / 2), tanf(cloud.fovY / 2) * cloud.aspect / viewAspect)
        let proj = Self.perspective(tanHalfY: tanHalf, aspect: viewAspect, near: 0.02, far: 400)
        let target = SIMD3<Float>(0, 0, -cloud.focus)
        let a = yaw + swayYaw, b = pitch + swayPitch
        let dir = SIMD3<Float>(sinf(a) * cosf(b), sinf(b), cosf(a) * cosf(b))
        let eye = target + dir * cloud.focus * zoom
        let mv = Self.lookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
        let fade = Float(min(1, (now - born) / 0.6))
        var u = Uniforms(mvp: proj * mv, mv: mv,
                         pixelsPerUnit: Float(size.height) / (2 * tanHalf), alpha: fade * fade * (3 - 2 * fade))

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private struct Uniforms {
        var mvp: simd_float4x4
        var mv: simd_float4x4
        var pixelsPerUnit: Float
        var alpha: Float
    }

    private static let log = Logger(subsystem: "app.heliocam.CoachCam", category: "Splat")

    private static func makePipeline(_ device: MTLDevice?) -> MTLRenderPipelineState? {
        guard let device else { log.error("no Metal device"); return nil }
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: shader, options: nil) } catch {
            log.error("splat shader failed to compile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "splat_v")
        d.fragmentFunction = lib.makeFunction(name: "splat_f")
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { return try device.makeRenderPipelineState(descriptor: d) } catch {
            log.error("splat pipeline failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Each splat is a point sprite sized from its world radius and eye depth; the fragment is a
    /// round Gaussian (exp(-4r²), ~2% at the rim), premultiplied.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Splat { packed_float4 pr; uchar4 c; };
    struct U { float4x4 mvp; float4x4 mv; float ppu; float alpha; };
    struct VOut { float4 pos [[position]]; float size [[point_size]]; float4 color; };
    vertex VOut splat_v(uint vid [[vertex_id]], const device Splat* s [[buffer(0)]], constant U& u [[buffer(1)]]) {
        Splat sp = s[vid];
        float4 p = float4(sp.pr.x, sp.pr.y, sp.pr.z, 1.0);
        float z = max(0.02, -(u.mv * p).z);
        VOut o;
        o.pos = u.mvp * p;
        o.size = clamp(2.0 * sp.pr.w * u.ppu / z, 1.0, 64.0);
        o.color = float4(float3(sp.c.rgb) / 255.0, u.alpha);
        return o;
    }
    fragment float4 splat_f(VOut in [[stage_in]], float2 pc [[point_coord]]) {
        float2 d = pc * 2.0 - 1.0;
        float r2 = dot(d, d);
        if (r2 > 1.0) discard_fragment();
        float a = exp(-4.0 * r2) * in.color.a;
        return float4(in.color.rgb * a, a);
    }
    """

    private static func perspective(tanHalfY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tanHalfY, x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                                       SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0),
                                       SIMD4(s.z, u.z, -f.z, 0),
                                       SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
}
