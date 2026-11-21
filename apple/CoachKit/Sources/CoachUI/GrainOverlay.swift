import CoreGraphics
import SwiftUI

/// Fine film grain for dark surfaces (panel, keys, ground). Hit-testing is off.
///
///     panel.overlay(GrainOverlay())          // the design's 3%
///     key.overlay(GrainOverlay(amount: 0.07).blendMode(.overlay))
///
/// `amount` 0.03 reproduces the design's "grain 3%" texture (frost speckle on a 200pt tile);
/// other amounts scale it linearly. `animated` re-rolls the grain 12 times a second.
public struct GrainOverlay: View {
    private let amount: Double
    private let animated: Bool
    private let tile: CGFloat
    @Environment(\.coachClock) private var fixedClock

    public init(amount: Double = 0.03, animated: Bool = false) {
        self.init(amount: amount, animated: animated, tile: 200)
    }

    init(amount: Double, animated: Bool, tile: CGFloat) {
        self.amount = amount
        self.animated = animated
        self.tile = tile
    }

    public var body: some View {
        Group {
            if animated, fixedClock == nil {
                TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
                    grain(frame: Int(context.date.timeIntervalSinceReferenceDate * 12))
                }
            } else {
                grain(frame: 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func grain(frame: Int) -> some View {
        // Shift the tile by a large odd step each frame so successive frames never line up.
        let dx = CGFloat((frame * 73) % 200) / 200 * tile
        let dy = CGFloat((frame * 131) % 200) / 200 * tile
        return GeometryReader { geo in
            Image(decorative: GrainTile.image, scale: GrainTile.pixels / tile)
                .resizable(resizingMode: .tile)
                .frame(width: geo.size.width + tile, height: geo.size.height + tile)
                .offset(x: -dx, y: -dy)
        }
        .clipped()
        .opacity(0.16 * amount / 0.03)
    }
}

/// The design's grain SVG (`feTurbulence` fractal noise, alpha = 1.8·n − 0.62, colour
/// (.93, .95, 1)), approximated with seeded per-pixel noise. Opacity is applied by the view.
enum GrainTile {
    static let pixels: CGFloat = 200
    static let image: CGImage = make(size: Int(pixels), seed: 0x9E37_79B9_7F4A_7C15)

    static func make(size: Int, seed: UInt64) -> CGImage {
        var state = seed
        func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let n = (next() + next() + next()) / 3
            let a = min(1, max(0, 1.8 * n - 0.62))
            // Premultiplied RGBA.
            bytes[i * 4 + 0] = UInt8((0.93 * a * 255).rounded())
            bytes[i * 4 + 1] = UInt8((0.95 * a * 255).rounded())
            bytes[i * 4 + 2] = UInt8((1.00 * a * 255).rounded())
            bytes[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// The tap-to-focus mark: a 56pt blue "+" with a soft glow. Tap-to-focus only; Gemini guides
/// with the viewfinder edge (`EdgeGlow`), not with this mark. Centre it on the tapped point:
///
///     TapFocusMark().position(tapPoint)
public struct TapFocusMark: View {
    public init() {}

    public var body: some View {
        ZStack {
            Circle().fill(RadialGradient(stops: [
                .init(color: Color(rgba: 0x4C8DFF6B), location: 0),
                .init(color: Color(rgba: 0x4C8DFF29), location: 0.38),
                .init(color: Color(rgba: 0x4C8DFF00), location: 0.70),
            ], center: .center, startRadius: 0, endRadius: 28 * 2.0.squareRoot()))
            cross.stroke(Color(rgba: 0x4C8DFF8C), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            cross.stroke(GXColor.geminiHot, style: StrokeStyle(lineWidth: 1.5))
        }
        .frame(width: 56, height: 56)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var cross: Path {
        Path { p in
            p.move(to: CGPoint(x: 28, y: 14)); p.addLine(to: CGPoint(x: 28, y: 42))
            p.move(to: CGPoint(x: 14, y: 28)); p.addLine(to: CGPoint(x: 42, y: 28))
        }
    }
}
