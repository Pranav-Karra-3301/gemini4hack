import Foundation

/// One exposure reading shown on an `InstrumentDrums` drum: ISO, shutter (seconds) or EV (stops).
///
///     InstrumentValue.iso(400).text            // "400"
///     InstrumentValue.shutter(1.0 / 125).text  // "1/125"
///     InstrumentValue.ev(0.3).text             // "+0.3"
///     InstrumentValue.iso(320, auto: true).text // "AUTO" (320 is the metered value)
public struct InstrumentValue: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case iso, shutter, ev
    }

    public var kind: Kind
    /// ISO, shutter in seconds, or EV in stops. While `isAuto`, the metered value (if known).
    public var number: Double
    /// The camera chooses the value; the drum shows `AUTO`. EV has no auto (it is a bias).
    public var isAuto: Bool

    public init(_ kind: Kind, _ number: Double, auto: Bool = false) {
        self.kind = kind
        self.number = number
        self.isAuto = auto && kind != .ev
    }

    public static func iso(_ iso: Double, auto: Bool = false) -> InstrumentValue { .init(.iso, iso, auto: auto) }
    public static func shutter(_ seconds: Double, auto: Bool = false) -> InstrumentValue { .init(.shutter, seconds, auto: auto) }
    public static func ev(_ stops: Double) -> InstrumentValue { .init(.ev, stops) }

    /// The caps label over the drum: `ISO`, `SS`, `EV`.
    public var label: String {
        switch kind {
        case .iso: return "ISO"
        case .shutter: return "SS"
        case .ev: return "EV"
        }
    }

    /// Display text: `400`, `1/125`, `1″`, `+0.3`, `0.0`, `-0.7`, or `AUTO`.
    public var text: String {
        if isAuto { return "AUTO" }
        let p = Self.parts(kind, number)
        return p.prefix + p.body
    }

    // MARK: Formatting

    /// `1/125` splits into a small "1/" prefix and the "125" body; neighbours show the body only.
    static func parts(_ kind: Kind, _ n: Double) -> (prefix: String, body: String) {
        switch kind {
        case .iso:
            return ("", String(Int(max(0, n).rounded())))
        case .shutter:
            guard n > 0 else { return ("", "0") }
            if n >= 0.95 {
                let r = (n * 10).rounded() / 10
                return ("", r == r.rounded() ? "\(Int(r))\u{2033}" : String(format: "%.1f\u{2033}", r))
            }
            let d = 1 / n
            if d >= 10 { return ("1/", String(Int(d.rounded()))) }
            let r = (d * 10).rounded() / 10
            return ("1/", r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r))
        case .ev:
            let r = (n * 10).rounded() / 10
            if r == 0 { return ("", "0.0") }
            // Hyphen-minus, per the design (the true minus glyph is avoided).
            return ("", (r > 0 ? "+" : "-") + String(format: "%.1f", abs(r)))
        }
    }

    // MARK: Detents

    /// Full-stop ladders, left to right as they sit on the drum (the design's neighbours:
    /// 200 · 400 · 800, 60 · 1/125 · 250, -0.3 · 0.0 · +0.3).
    static func ladder(_ kind: Kind) -> [Double] {
        switch kind {
        case .iso: return [25, 50, 100, 200, 400, 800, 1600, 3200, 6400]
        case .shutter: return [1, 1.0 / 2, 1.0 / 4, 1.0 / 8, 1.0 / 15, 1.0 / 30, 1.0 / 60, 1.0 / 125, 1.0 / 250,
                               1.0 / 500, 1.0 / 1000, 1.0 / 2000, 1.0 / 4000, 1.0 / 8000]
        case .ev: return (-9...9).map { (Double($0) / 3 * 100).rounded() / 100 }
        }
    }

    /// A monotonic coordinate in stops (increasing left to right on the drum).
    static func stops(_ kind: Kind, _ n: Double) -> Double {
        switch kind {
        case .iso: return log2(max(n, 1))
        case .shutter: return -log2(max(n, 1e-6))
        case .ev: return n
        }
    }

    /// The drum's values: the ladder plus any off-ladder values in `including` (e.g. Gemini's ISO 320).
    static func strip(_ kind: Kind, including extra: [Double]) -> [Double] {
        var values = ladder(kind)
        // Splice a value in only when no ladder detent reads the same (ISO 400.4 is "400",
        // EV 0.3 is the 1/3-stop "+0.3", but Gemini's ISO 320 or 1/100 get their own detent).
        for v in extra where !values.contains(where: { parts(kind, $0) == parts(kind, v) }) {
            values.append(v)
        }
        return values.sorted { stops(kind, $0) < stops(kind, $1) }
    }

    /// Index of `n` in `strip` (nearest by stops).
    static func index(of n: Double, in strip: [Double], kind: Kind) -> Int {
        let s = stops(kind, n)
        var best = 0
        for i in strip.indices where abs(stops(kind, strip[i]) - s) < abs(stops(kind, strip[best]) - s) { best = i }
        return best
    }

    /// Fractional position `p` in `strip`, as stops (piecewise linear, clamped at the ends).
    static func stops(atPosition p: Double, in strip: [Double], kind: Kind) -> Double {
        guard strip.count > 1 else { return strip.first.map { stops(kind, $0) } ?? 0 }
        let i = min(max(Int(p.rounded(.down)), 0), strip.count - 2)
        let a = stops(kind, strip[i]), b = stops(kind, strip[i + 1])
        return a + (b - a) * (min(max(p, 0), Double(strip.count - 1)) - Double(i))
    }

    /// Inverse of `stops(atPosition:)`.
    static func position(ofStops s: Double, in strip: [Double], kind: Kind) -> Double {
        guard strip.count > 1 else { return 0 }
        let c = strip.map { stops(kind, $0) }
        if s <= c[0] { return 0 }
        for i in 0..<(c.count - 1) where s <= c[i + 1] {
            return Double(i) + (s - c[i]) / max(c[i + 1] - c[i], 1e-9)
        }
        return Double(c.count - 1)
    }
}
