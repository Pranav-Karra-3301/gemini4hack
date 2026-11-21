import CoreGraphics
import SwiftUI
import UIKit

/// The depth map as a "Gemini blue" ramp: far = deep navy, near = bright white (by inverse depth,
/// so the near range gets most of the tones). Holding shows the photo underneath. No legend.
struct DepthMapView: View {
    let photo: UIImage
    let depthPNG: Data
    let holding: Bool
    @State private var ramp: UIImage?

    var body: some View {
        ZStack {
            Image(uiImage: photo).resizable().interpolation(.high)
            if let ramp {
                Image(uiImage: ramp).resizable().interpolation(.high)
                    .opacity(holding ? 0 : 1)
                    .animation(.easeOut(duration: 0.18), value: holding)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: ramp != nil)
        .task(id: ObjectIdentifier(photo)) {
            guard let key = photo.cgImage else { return }
            if let hit = ShotCaches.depthRamps.get(key) { ramp = hit; return }
            let png = depthPNG
            let img = await Task.detached(priority: .userInitiated) { DepthRamp.image(png: png) }.value
            guard !Task.isCancelled, let img else { return }
            ShotCaches.depthRamps.put(key, img)
            ramp = img
        }
    }
}

enum DepthRamp {
    /// Navy → Gemini blue → ice → white, near = bright.
    static let stops: [(Float, Float, Float)] = [
        (6, 10, 30), (18, 36, 96), (58, 104, 214), (140, 182, 246), (236, 243, 255),
    ]

    static func image(png: Data) -> UIImage? {
        guard let depth = DepthCloud.decode(png) else { return nil }
        let w = depth.width, h = depth.height
        let valid = depth.mm.filter { $0 > 0 }.sorted()
        guard valid.count > 16 else { return nil }
        let near = Float(valid[valid.count * 2 / 100]), far = Float(valid[valid.count * 98 / 100])
        let invN = 1 / max(near, 1), invF = 1 / max(far, near + 1)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let d = Float(depth.mm[i])
            var c = stops[0]
            if d > 0 {
                let t = max(0, min(1, (1 / d - invF) / (invN - invF)))
                let f = t * Float(stops.count - 1)
                let k = min(Int(f), stops.count - 2), u = f - Float(k)
                let s = u * u * (3 - 2 * u)
                let a = stops[k], b = stops[k + 1]
                c = (a.0 + (b.0 - a.0) * s, a.1 + (b.1 - a.1) * s, a.2 + (b.2 - a.2) * s)
            }
            rgba[i * 4] = UInt8(c.0); rgba[i * 4 + 1] = UInt8(c.1); rgba[i * 4 + 2] = UInt8(c.2); rgba[i * 4 + 3] = 255
        }
        let cg = rgba.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return cg.map { UIImage(cgImage: $0) }
    }
}
