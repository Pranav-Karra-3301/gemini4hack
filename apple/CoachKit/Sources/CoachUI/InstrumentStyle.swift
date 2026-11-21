import CoreText
import SwiftUI

// v2 "Instruments" look (design/V2_INSTRUMENT.md, Paper page "v2 · Camera (iPhone)"):
// gx-* tokens, the Google Sans Flex / Geist Mono type, and small drawing helpers that mirror the
// CSS the design is written in (elliptical radial gradients, inset shadows, the thin-film glow).

/// Who changed a value. Gemini's changes play the visible roll (blur, overshoot, settle, glow);
/// the user's own changes follow their finger.
public enum CoachActor: Hashable, Sendable {
    case user
    case gemini
}

/// The `gx-*` colour tokens of the v2 instrument design.
public enum GXColor {
    /// Ground behind everything (`--gx-void`).
    public static let void = Color(rgba: 0x04060CFF)
    /// Instrument panel under the viewfinder.
    public static let panel = Color(rgba: 0x070A14FF)
    /// Viewfinder backing (`--gx-night`).
    public static let night = Color(rgba: 0x0C1222FF)
    /// The one hairline weight: 1px grid lines and cell dividers.
    public static let hairline = Color(rgba: 0xB4CEFF1F)
    /// Numerals and icons (the user).
    public static let frost = Color(rgba: 0xEEF3FFFF)
    /// Caps mono labels (frost 45%).
    public static let label = Color(rgba: 0xEEF3FF73)
    /// Gemini acting.
    public static let gemini = Color(rgba: 0x4C8DFFFF)
    /// Glow core.
    public static let geminiHot = Color(rgba: 0xB4CEFFFF)
    /// Gradient tail only.
    public static let iris = Color(rgba: 0x9A7CF6FF)
    /// Errors only.
    public static let signal = Color(rgba: 0xFF5A5FFF)
}

/// v2 type: numerals in Google Sans Flex 500, caps labels in Geist Mono 500.
/// Both fonts ship in `Resources/Fonts` (OFL) and register on first use; until the package
/// declares them as resources (or the app bundles them), SF Pro and SF Mono stand in.
public enum GXFont {
    /// Numerals and values (`--gx-font-display`).
    public static func display(_ size: CGFloat, weight: CGFloat = 500) -> Font {
        if let ct = variableFont(family: displayFamily, size: size, weight: weight, opticalSize: true) {
            return Font(ct)
        }
        return .system(size: size, weight: swiftUIWeight(weight))
    }

    /// Caps labels and small readouts (`--gx-font-mono`). Pair with `.tracking(size * 0.14)`.
    public static func mono(_ size: CGFloat, weight: CGFloat = 500) -> Font {
        if let ct = variableFont(family: monoFamily, size: size, weight: weight, opticalSize: false) {
            return Font(ct)
        }
        return .system(size: size, weight: swiftUIWeight(weight), design: .monospaced)
    }

    /// Registers the bundled fonts once (safe to call repeatedly). The font functions call it.
    @discardableResult
    public static func registerBundledFonts() -> Bool { registered }

    static let displayFamily = "Google Sans Flex"
    static let monoFamily = "Geist Mono"

    static var hasDisplay: Bool { _ = registered; return familyExists(displayFamily) }
    static var hasMono: Bool { _ = registered; return familyExists(monoFamily) }

    /// Registers every .ttf/.otf under `directory` for this process; returns how many registered.
    @discardableResult
    static func register(directory: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for case let url as URL in walker where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { count += 1 }
        }
        return count
    }

    /// Looks for the SwiftPM resource bundle by name, so this compiles with or without
    /// `resources:` in Package.swift (no `Bundle.module` reference).
    private static let registered: Bool = {
        let bundleName = "CoachKit_CoachUI.bundle"
        let hosts = [Bundle.main, Bundle(for: FontBundleToken.self)] + Bundle.allBundles + Bundle.allFrameworks
        var roots: [URL] = []
        for host in hosts {
            if let r = host.resourceURL { roots.append(r) }
            roots.append(host.bundleURL)
            roots.append(host.bundleURL.deletingLastPathComponent())
        }
        var found = 0
        var seen = Set<String>()
        for root in roots {
            let candidate = root.appendingPathComponent(bundleName)
            guard seen.insert(candidate.path).inserted,
                  FileManager.default.fileExists(atPath: candidate.path) else { continue }
            found += register(directory: candidate)
            if found > 0 { break }
        }
        return found > 0
    }()

    private static func familyExists(_ family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        return (CTFontCopyFamilyName(font) as String) == family
    }

    /// A variable-font instance at `weight` (and optical size = point size, like CSS `auto`).
    static func variableFont(family: String, size: CGFloat, weight: CGFloat, opticalSize: Bool) -> CTFont? {
        _ = registered
        let base = CTFontCreateWithName(family as CFString, size, nil)
        guard (CTFontCopyFamilyName(base) as String) == family else { return nil }
        var desc = CTFontCopyFontDescriptor(base)
        let axes = (CTFontCopyVariationAxes(base) as? [[CFString: Any]]) ?? []
        let ids = Set(axes.compactMap { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value })
        let wght: UInt32 = 0x7767_6874, opsz: UInt32 = 0x6F70_737A
        if ids.contains(wght) { desc = CTFontDescriptorCreateCopyWithVariation(desc, NSNumber(value: wght), weight) }
        if opticalSize, ids.contains(opsz) { desc = CTFontDescriptorCreateCopyWithVariation(desc, NSNumber(value: opsz), size) }
        return CTFontCreateWithFontDescriptor(desc, size, nil)
    }

    /// Advance width of `text` set in the display face (fallback: SF Pro).
    static func displayWidth(_ text: String, size: CGFloat, tracking: CGFloat = 0) -> CGFloat {
        let font = variableFont(family: displayFamily, size: size, weight: 500, opticalSize: true)
            ?? CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func swiftUIWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<350: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
}

private final class FontBundleToken {}

// MARK: - Thin-film (iridescent) glow

enum Iridescent {
    /// `conic-gradient(from 200deg, #7AA7FF, #B48CFF, #FF8FCF, #FFC27A, #8CF5D2, #7AA7FF)`.
    static let ring = Gradient(stops: [
        .init(color: Color(rgba: 0x7AA7FFFF), location: 0),
        .init(color: Color(rgba: 0xB48CFFFF), location: 0.2),
        .init(color: Color(rgba: 0xFF8FCFFF), location: 0.4),
        .init(color: Color(rgba: 0xFFC27AFF), location: 0.6),
        .init(color: Color(rgba: 0x8CF5D2FF), location: 0.8),
        .init(color: Color(rgba: 0x7AA7FFFF), location: 1),
    ])
    /// The faint tint a changing numeral takes.
    static let numeral = LinearGradient(stops: [
        .init(color: Color(rgba: 0xD6E4FFFF), location: 0),
        .init(color: Color(rgba: 0xD6E4FFFF), location: 0.3),
        .init(color: Color(rgba: 0xE8DAFFFF), location: 0.5),
        .init(color: Color(rgba: 0xFFDDEEFF), location: 0.7),
        .init(color: Color(rgba: 0xFFDDEEFF), location: 1),
    ], startPoint: .leading, endPoint: .trailing)
    /// Seconds per lap of the glow around the cell border.
    static let lap = 2.4
}

/// The inner border glow of a changing value: the thin-film spectrum flowing around the inside
/// edge, falling off ~12px inward (CSS: conic fill under a 7px-blurred core inset by 3).
struct IridescentEdge: View {
    var opacity: Double
    var date: Date

    var body: some View {
        let turns = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Iridescent.lap) / Iridescent.lap
        let start = Angle.degrees(110 + 360 * turns)
        AngularGradient(gradient: Iridescent.ring, center: .center, startAngle: start, endAngle: start + .degrees(360))
            .opacity(opacity)
            .mask {
                ZStack {
                    Rectangle()
                    Rectangle().padding(3).blur(radius: 7).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

// MARK: - CSS helpers

/// CSS `radial-gradient(ellipse rx ry at cx cy, …)` with radii and centre as fractions of the box.
struct EllipticalFill: View {
    var stops: [Gradient.Stop]
    var rx: CGFloat
    var ry: CGFloat
    var cx: CGFloat
    var cy: CGFloat
    /// `circle farthest-corner` instead of explicit radii.
    var farthestCorner = false

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: cx * size.width, y: cy * size.height)
            var rX = rx * size.width, rY = ry * size.height
            if farthestCorner {
                let dx = max(c.x, size.width - c.x), dy = max(c.y, size.height - c.y)
                rX = (dx * dx + dy * dy).squareRoot()
                rY = rX
            }
            rX = max(rX, 0.001)
            rY = max(rY, 0.001)
            let k = rY / rX
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: 1, y: k)
            let rect = CGRect(x: -c.x, y: -c.y / k, width: size.width, height: size.height / k)
            ctx.fill(Path(rect), with: .radialGradient(Gradient(stops: stops), center: .zero, startRadius: 0, endRadius: rX))
        }
        .allowsHitTesting(false)
    }
}

/// CSS `box-shadow: inset x y blur spread color` inside a rounded rect of `radius`.
struct InsetShadow: View {
    var color: Color
    var x: CGFloat = 0
    var y: CGFloat = 0
    var blur: CGFloat = 0
    var spread: CGFloat = 0
    var radius: CGFloat
    var style: RoundedCornerStyle = .circular

    var body: some View {
        GeometryReader { geo in
            let r = CGRect(origin: .zero, size: geo.size)
            let hole = Self.hole(r.insetBy(dx: spread, dy: spread).offsetBy(dx: x, dy: y), in: r)
            let pad = blur * 2 + abs(x) + abs(y) + abs(spread) + 4
            Path { p in
                p.addRect(r.insetBy(dx: -pad, dy: -pad))
                if hole.width > 0, hole.height > 0 {
                    let hr = max(0, min(radius - spread, min(hole.width, hole.height) / 2))
                    p.addRoundedRect(in: hole, cornerSize: CGSize(width: hr, height: hr), style: style)
                }
            }
            .fill(color, style: FillStyle(eoFill: true))
            .blur(radius: blur / 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: style))
        .allowsHitTesting(false)
    }

    /// Where the hole's edge coincides with the clip edge, push it 1pt out so anti-aliasing
    /// doesn't leave a hairline of shadow colour around the whole shape.
    static func hole(_ h: CGRect, in r: CGRect) -> CGRect {
        let minX = h.minX <= r.minX + 0.5 ? h.minX - 1 : h.minX
        let minY = h.minY <= r.minY + 0.5 ? h.minY - 1 : h.minY
        let maxX = h.maxX >= r.maxX - 0.5 ? h.maxX + 1 : h.maxX
        let maxY = h.maxY >= r.maxY - 0.5 ? h.maxY + 1 : h.maxY
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// CSS outer `box-shadow: x y blur spread color`, drawn only outside the rounded rect.
struct OuterGlow: View {
    var color: Color
    var x: CGFloat = 0
    var y: CGFloat = 0
    var blur: CGFloat
    var spread: CGFloat = 0
    var radius: CGFloat
    var style: RoundedCornerStyle = .circular

    var body: some View {
        GeometryReader { geo in
            let r = CGRect(origin: .zero, size: geo.size)
            let s = r.insetBy(dx: -spread, dy: -spread).offsetBy(dx: x, dy: y)
            let sr = max(0, radius + spread)
            let pad = blur * 2 + abs(x) + abs(y) + abs(spread) + 4
            Path { p in p.addRoundedRect(in: s, cornerSize: CGSize(width: sr, height: sr), style: style) }
                .fill(color)
                .blur(radius: blur / 2)
                .mask {
                    Path { p in
                        p.addRect(r.insetBy(dx: -pad, dy: -pad))
                        p.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius), style: style)
                    }
                    .fill(style: FillStyle(eoFill: true))
                }
        }
        .allowsHitTesting(false)
    }
}

extension Color {
    /// `0xRRGGBBAA`, as written in the design's CSS.
    init(rgba: UInt32) {
        self.init(.sRGB,
                  red: Double((rgba >> 24) & 0xFF) / 255,
                  green: Double((rgba >> 16) & 0xFF) / 255,
                  blue: Double((rgba >> 8) & 0xFF) / 255,
                  opacity: Double(rgba & 0xFF) / 255)
    }

    /// Same colour, alpha multiplied by `k`.
    func alpha(_ k: Double) -> Color { opacity(max(0, min(1, k))) }
}

enum GXMath {
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    /// `cubic-bezier(.2, .8, .2, 1)`, the v2 ease-out.
    static func easeOut(_ t: Double) -> Double { CoachEase.cubicBezier(clamp01(t), 0.2, 0.8, 0.2, 1) }
}
