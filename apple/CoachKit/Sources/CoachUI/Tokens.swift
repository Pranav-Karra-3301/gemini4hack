import SwiftUI
import CoreText

// Design tokens from design/DESIGN.md §3 ("darkroom").
// The one rule: amber (safelight) means the coach is speaking or acting; paper-white means you.

/// Colours, gradients and glows from DESIGN.md §3.
public enum CoachColor {
    /// Developer-tray black: ground, letterbox, 3D void.
    public static let ink = Color(hex: 0x08080A)
    /// Solid surfaces.
    public static let graphite = Color(hex: 0x17171A)
    /// Fibre-paper white: primary text and icons (the user).
    public static let paper = Color(hex: 0xF5F3EF)
    public static let paper62 = paper.opacity(0.62)
    public static let paper55 = paper.opacity(0.55)
    public static let paper45 = paper.opacity(0.45)
    /// THE accent: the coach.
    public static let safelight = Color(hex: 0xFFA53D)
    /// Glow core, waveform peak.
    public static let safelightHot = Color(hex: 0xFFD08A)
    /// Offline / error only.
    public static let signal = Color(hex: 0xFF4D3D)

    public static let glassFill = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.46)
    public static let glassFillStrong = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.55)
    /// Used where blur is unavailable (and in ImageRenderer snapshots).
    public static let glassFillFallback = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.78)
    public static let glassEdge = Color.white.opacity(0.12)
    public static let glassEdgeCoach = safelight.opacity(0.40)

    /// Primary buttons.
    public static let safelightGradient = LinearGradient(
        colors: [Color(hex: 0xFFB65C), safelight], startPoint: .top, endPoint: .bottom)

    /// Big round CTAs and the ready shutter (`--safelight-orb`), for a circle of `diameter`.
    public static func safelightOrb(diameter: CGFloat) -> RadialGradient {
        RadialGradient(
            stops: [.init(color: Color(hex: 0xFFE3B8), location: 0),
                    .init(color: Color(hex: 0xFFC06A), location: 0.42),
                    .init(color: safelight, location: 1)],
            center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: diameter * 0.86)
    }

    /// Blends paper (the user) toward safelight (the coach) by `amount` 0...1.
    public static func userToCoach(_ amount: Double) -> Color {
        amount <= 0.001 ? paper : paper.mix(with: safelight, by: min(1, amount))
    }
}

/// Type scale (DESIGN.md §3). Numerals and caps labels use a mono face; words use a grotesk.
/// Geist Mono and Inter Tight are used when the app bundles them; otherwise SF Mono and SF Pro.
public enum CoachFont {
    /// Mono for numerals, readouts and caps labels. Always tabular.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        if hasGeistMono { return Font.custom("Geist Mono", size: size).weight(weight).monospacedDigit() }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }

    /// Sans for words: captions, labels, buttons.
    public static func sans(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        if hasInterTight { return Font.custom("Inter Tight", size: size).weight(weight) }
        return Font.system(size: size, weight: weight)
    }

    /// `--text-label`: mono 11, caps; pair with `.tracking(CoachFont.labelTracking(11))`.
    public static let label = mono(11)
    /// `--text-readout`: mono 12.
    public static let readout = mono(12)
    /// `--text-caption`: sans 19/24.
    public static let caption = sans(19)

    /// Letter-spacing for caps mono labels (.14em).
    public static func labelTracking(_ size: CGFloat) -> CGFloat { size * 0.14 }

    static let hasGeistMono = fontFamilyExists("Geist Mono")
    static let hasInterTight = fontFamilyExists("Inter Tight")

    private static func fontFamilyExists(_ family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        return (CTFontCopyFamilyName(font) as String) == family
    }
}

/// Corner radii (DESIGN.md §3).
public enum CoachRadius {
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 20
    public static let lg: CGFloat = 28
    public static let thumb: CGFloat = 16
}

/// Durations in seconds (DESIGN.md §3 motion).
public enum CoachDuration {
    public static let instant = 0.09
    public static let fast = 0.16
    public static let base = 0.24
    public static let slow = 0.42
    public static let glide = 0.70
    public static let flight = 1.40
}

/// Timing curves (DESIGN.md §3 motion) as SwiftUI animations.
public enum CoachEase {
    public static func out(_ d: Double = CoachDuration.base) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: d) }
    public static func `in`(_ d: Double = CoachDuration.fast) -> Animation { .timingCurve(0.55, 0, 1, 0.45, duration: d) }
    public static func inOut(_ d: Double = CoachDuration.slow) -> Animation { .timingCurve(0.65, 0, 0.35, 1, duration: d) }
    public static func pop(_ d: Double = CoachDuration.base) -> Animation { .timingCurve(0.34, 1.56, 0.64, 1, duration: d) }

    /// Same curves as plain functions of progress 0...1, for time-driven drawing.
    static func outCurve(_ t: Double) -> Double { cubicBezier(t, 0.22, 1, 0.36, 1) }
    static func inOutCurve(_ t: Double) -> Double { cubicBezier(t, 0.65, 0, 0.35, 1) }

    /// CSS-style cubic-bezier(x1, y1, x2, y2) evaluated at x = t (Newton + bisection).
    static func cubicBezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let x = min(max(t, 0), 1)
        func bx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s }
        func by(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<24 {
            let v = bx(s)
            if abs(v - x) < 1e-5 { break }
            if v < x { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return by(s)
    }
}

// MARK: - Glass

struct CoachGlassBackground: ViewModifier {
    var cornerRadius: CGFloat
    var coach: Bool
    var strong: Bool
    @Environment(\.coachClock) private var fixedClock

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            ZStack {
                if fixedClock == nil {
                    // ImageRenderer cannot draw materials, so snapshots use the fallback fill.
                    shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    shape.fill(strong ? CoachColor.glassFillStrong : CoachColor.glassFill)
                } else {
                    shape.fill(CoachColor.glassFillFallback)
                }
                shape.strokeBorder(coach ? CoachColor.glassEdgeCoach : CoachColor.glassEdge, lineWidth: 1)
            }
        }
    }
}

public extension View {
    /// Frosted glass (DESIGN.md "glass recipe"); `coach` swaps the edge to the amber coach edge.
    func coachGlass(cornerRadius: CGFloat = CoachRadius.md, coach: Bool = false, strong: Bool = false) -> some View {
        modifier(CoachGlassBackground(cornerRadius: cornerRadius, coach: coach, strong: strong))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
