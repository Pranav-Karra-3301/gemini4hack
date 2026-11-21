import Foundation

/// A manual camera control shown as a dial. Raw values are the `set_camera` argument names
/// (docs/CORE_API.md §2, camera-mode tools).
public enum CameraParameter: String, CaseIterable, Hashable, Sendable, Identifiable {
    case iso
    case shutter
    case ev
    case focus
    case whiteBalance = "wb_kelvin"
    case tint
    case zoom

    public var id: String { rawValue }

    /// The strip's default order: ISO · SHUTTER · EV · FOCUS · WB · ZOOM.
    public static let stripDefault: [CameraParameter] = [.iso, .shutter, .ev, .focus, .whiteBalance, .zoom]

    /// Caps label for chips and accessibility.
    public var title: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "SHUTTER"
        case .ev: return "EV"
        case .focus: return "FOCUS"
        case .whiteBalance: return "WB"
        case .tint: return "TINT"
        case .zoom: return "ZOOM"
        }
    }

    /// Spoken name for VoiceOver.
    public var spokenName: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "Shutter speed"
        case .ev: return "Exposure compensation"
        case .focus: return "Focus"
        case .whiteBalance: return "White balance"
        case .tint: return "Tint"
        case .zoom: return "Zoom"
        }
    }

    /// Whether the parameter has an AUTO state (ISO, shutter, focus, white balance).
    public var supportsAuto: Bool {
        switch self {
        case .iso, .shutter, .focus, .whiteBalance: return true
        case .ev, .tint, .zoom: return false
        }
    }

    /// Value range when the device doesn't report one (CORE_API.md `set_camera` limits).
    public var defaultRange: ClosedRange<Double> {
        switch self {
        case .iso: return 25...12800
        case .shutter: return 1.0 / 8000...1
        case .ev: return -3...3
        case .focus: return 0...1
        case .whiteBalance: return 2500...9000
        case .tint: return -50...50
        case .zoom: return 0.5...10
        }
    }

    /// Value used when a manual dial starts with nothing better.
    public var defaultValue: Double {
        switch self {
        case .iso: return 100
        case .shutter: return 1.0 / 125
        case .ev: return 0
        case .focus: return 0.5
        case .whiteBalance: return 5500
        case .tint: return 0
        case .zoom: return 1
        }
    }

    // MARK: Scale (dial "positions": one unit per detent)

    /// Points between adjacent detents on the ruler.
    var tickSpacing: Double {
        switch self {
        case .iso, .shutter: return 15        // third stops
        case .ev: return 14
        case .focus: return 8
        case .whiteBalance: return 7          // 100 K
        case .tint: return 6
        case .zoom: return 9                  // tenth of a stop of focal length
        }
    }

    /// Dial position for a value. Detents sit on integer positions.
    func position(for value: Double) -> Double {
        switch self {
        case .iso: return 3 * log2(max(value, 1) / 25)
        case .shutter: return 3 * log2(max(value, 1e-6) * 8000)
        case .ev: return value * 3
        case .focus: return value * 50
        case .whiteBalance: return (value - 2500) / 100
        case .tint: return value
        case .zoom: return 10 * log2(max(value, 0.01) / 0.5)
        }
    }

    /// Continuous value at a dial position.
    func value(at position: Double) -> Double {
        switch self {
        case .iso: return 25 * pow(2, position / 3)
        case .shutter: return pow(2, position / 3) / 8000
        case .ev: return position / 3
        case .focus: return position / 50
        case .whiteBalance: return 2500 + position * 100
        case .tint: return position
        case .zoom: return 0.5 * pow(2, position / 10)
        }
    }

    /// The marked value of the detent nearest to `position` (ISO 64, not 63.5; 1/125, not 1/128).
    func detentValue(at position: Double) -> Double {
        let unit = Int(position.rounded())
        switch self {
        case .iso:
            if unit >= 0 && unit < Self.isoStops.count { return Self.isoStops[unit] }
        case .shutter:
            if unit >= 0 && unit < Self.shutterStops.count { return Self.shutterStops[unit].seconds }
        case .ev:
            return (Double(unit) / 3 * 100).rounded() / 100
        case .focus:
            return Double(unit) / 50
        case .whiteBalance, .tint:
            return value(at: Double(unit))
        case .zoom:
            return (value(at: Double(unit)) * 100).rounded() / 100
        }
        return value(at: Double(unit))
    }

    /// Major ticks carry a label (full stops, round kelvin, lens switch points).
    func isMajor(_ unit: Int) -> Bool {
        switch self {
        case .iso, .shutter, .ev: return unit % 3 == 0
        case .focus: return unit % 10 == 0
        case .whiteBalance: return (unit + 5) % 10 == 0
        case .tint: return unit % 10 == 0
        case .zoom: return unit % 10 == 0
        }
    }

    /// Text under a major tick (nil = unlabeled major).
    func majorLabel(_ unit: Int) -> String? {
        switch self {
        case .iso:
            guard unit >= 0 && unit < Self.isoStops.count else { return nil }
            return String(Int(Self.isoStops[unit]))
        case .shutter:
            guard unit >= 0 && unit < Self.shutterStops.count else { return nil }
            return Self.shutterStops[unit].dial
        case .ev:
            let n = unit / 3
            return n == 0 ? "0" : (n > 0 ? "+\(n)" : "\u{2212}\(-n)")
        case .focus:
            return nil
        case .whiteBalance:
            return String(Int(value(at: Double(unit))))
        case .tint:
            guard unit % 25 == 0 else { return nil }
            return unit == 0 ? "0" : (unit > 0 ? "+\(unit)" : "\u{2212}\(-unit)")
        case .zoom:
            let v = value(at: Double(unit))
            return v < 1 ? ".5" : String(Int(v.rounded()))
        }
    }

    // MARK: Formatting

    /// Full readout: "ISO 400", "1/250", "+0.3", "5200K", "1.5×", "0.42", "+12".
    public func format(_ value: Double) -> String {
        switch self {
        case .iso: return "ISO \(isoText(value))"
        default: return shortFormat(value)
        }
    }

    /// Compact value for chips: "400", "1/250", "+0.3", "5200K", "1.5×".
    public func shortFormat(_ value: Double) -> String {
        switch self {
        case .iso:
            return isoText(value)
        case .shutter:
            let unit = Int(position(for: value).rounded())
            if unit >= 0 && unit < Self.shutterStops.count,
               abs(Self.shutterStops[unit].seconds - value) / value < 0.08 {
                return Self.shutterStops[unit].text
            }
            if value >= 0.3 { return String(format: "%.1f\u{2033}", value) }
            return "1/\(Int((1 / value).rounded()))"
        case .ev:
            let r = (value * 10).rounded() / 10
            if abs(r) < 0.05 { return "0.0" }
            return (r > 0 ? "+" : "\u{2212}") + String(format: "%.1f", abs(r))
        case .focus:
            return String(format: "%.2f", value)
        case .whiteBalance:
            return "\(Int((value / 10).rounded()) * 10)K"
        case .tint:
            let n = Int(value.rounded())
            return n == 0 ? "0" : (n > 0 ? "+\(n)" : "\u{2212}\(-n)")
        case .zoom:
            let r = (value * 10).rounded() / 10
            if abs(r - r.rounded()) < 0.05 { return "\(Int(r.rounded()))\u{00D7}" }
            return String(format: "%.1f\u{00D7}", r)
        }
    }

    /// Readout for a setting: the value, or "AUTO".
    public func format(_ setting: DialSetting) -> String {
        switch setting {
        case .auto: return "AUTO"
        case .manual(let v): return format(v)
        }
    }

    private func isoText(_ value: Double) -> String {
        let unit = Int(position(for: value).rounded())
        if unit >= 0 && unit < Self.isoStops.count, abs(Self.isoStops[unit] - value) / value < 0.04 {
            return String(Int(Self.isoStops[unit]))
        }
        return String(Int(value.rounded()))
    }

    // MARK: Tables

    /// Third-stop ISO marks from 25 (position 0) to 12800 (position 27).
    static let isoStops: [Double] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                                     1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]

    /// Third-stop shutter marks from 1/8000 (position 0) to 1 s (position 39).
    /// `text` is the readout, `dial` the short label printed under a major tick.
    static let shutterStops: [(seconds: Double, text: String, dial: String)] = {
        let denominators: [Double] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500,
                                      400, 320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10,
                                      8, 6, 5, 4]
        var stops = denominators.map { (seconds: 1 / $0, text: "1/\(Int($0))", dial: String(Int($0))) }
        for s in [0.3, 0.4, 0.5, 0.6, 0.8] {
            stops.append((seconds: s, text: String(format: "%.1f\u{2033}", s), dial: s == 0.5 ? "\u{00BD}\u{2033}" : ""))
        }
        stops.append((seconds: 1, text: "1\u{2033}", dial: "1\u{2033}"))
        return stops
    }()
}

/// A dial's setting: AUTO (optionally with the value the camera is metering) or a manual value.
public enum DialSetting: Hashable, Sendable {
    /// The camera decides; `metered` is its current value when known (the dial follows it, dimmed).
    case auto(metered: Double?)
    /// A fixed value.
    case manual(Double)

    public var isAuto: Bool { if case .auto = self { return true } else { return false } }

    /// The manual value, or the metered value in AUTO.
    public var value: Double? {
        switch self {
        case .auto(let m): return m
        case .manual(let v): return v
        }
    }
}
