import Foundation

/// An edit slider (docs/CORE_API.md §4). Raw values are the JSON names.
/// `allCases` is in editing order: light, color, detail, local, lens.
public enum Slider: String, Codable, CaseIterable, Hashable, Sendable, CodingKeyRepresentable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case warmth, tint, vibrance, saturation
    case clarity, vignette
    case subjectLight = "subject_light"
    case backgroundLight = "background_light"
    case depthBlur = "depth_blur"
    case focusDepth = "focus_depth"

    /// The slider's range, default, unit and labels.
    public var spec: SliderSpec { SliderSpec.table[self]! }

    /// Lenient lookup: accepts `"subject_light"`, `"subjectLight"`, `"Subject Light"`.
    public init?(name: String) {
        if let s = Slider(rawValue: name) { self = s; return }
        let key = name.lowercased().filter { $0.isLetter }
        guard let s = Slider.allCases.first(where: { $0.rawValue.filter { $0.isLetter } == key }) else {
            return nil
        }
        self = s
    }
}

/// Paper-style slider groups, in the order the editor shows them.
public enum SliderGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case light, color, detail, local, lens

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .color: return "Color"
        case .detail: return "Detail"
        case .local: return "Subject"
        case .lens: return "Lens"
        }
    }

    /// Sliders in this group, in display order.
    public var sliders: [Slider] { Slider.allCases.filter { $0.spec.group == self } }
}

/// Static description of one slider: range, default, step, unit and labels.
public struct SliderSpec: Hashable, Sendable {
    public let slider: Slider
    public let range: ClosedRange<Double>
    /// `nil` only for `focus_depth` (null = the subject's median depth).
    public let defaultValue: Double?
    public let step: Double
    /// Display unit: `"EV"`, `"m"` or `""`.
    public let unit: String
    public let displayName: String
    public let group: SliderGroup
    /// One-line meaning from the API doc (useful in tooltips and prompts).
    public let meaning: String

    /// True when the slider is centred on zero (draw the fill from the middle).
    public var isBipolar: Bool { range.lowerBound < 0 && range.upperBound > 0 }

    /// The value a control shows when the recipe has none (auto `focus_depth` shows the range's lower bound).
    public var neutralValue: Double { defaultValue ?? range.lowerBound }

    /// Clamps to `range`; NaN becomes the default.
    public func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return neutralValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Clamps and rounds to `step`.
    public func snap(_ value: Double) -> Double {
        let v = clamp(value)
        guard step > 0 else { return v }
        let snapped = (v / step).rounded() * step
        // Trim float noise (0.30000000000000004).
        return clamp((snapped * 1_000_000).rounded() / 1_000_000)
    }

    /// Human-readable value: `"+0.30 EV"`, `"-12"`, `"2.4 m"`, `"Auto"` for a nil focus depth.
    public func format(_ value: Double?) -> String {
        guard let value else { return "Auto" }
        switch slider {
        case .exposure: return String(format: "%+.2f EV", value)
        case .focusDepth: return String(format: "%.1f m", value)
        default:
            let n = Int(value.rounded())
            return isBipolar && n > 0 ? "+\(n)" : "\(n)"
        }
    }

    /// The full table, exactly per CORE_API.md §4.
    public static let table: [Slider: SliderSpec] = {
        func s(_ sl: Slider, _ r: ClosedRange<Double>, _ d: Double?, _ step: Double, _ unit: String,
               _ name: String, _ g: SliderGroup, _ m: String) -> (Slider, SliderSpec) {
            (sl, SliderSpec(slider: sl, range: r, defaultValue: d, step: step, unit: unit,
                            displayName: name, group: g, meaning: m))
        }
        let pm = -100.0...100.0
        return Dictionary(uniqueKeysWithValues: [
            s(.exposure, -3...3, 0, 0.05, "EV", "Exposure", .light, "overall brightness"),
            s(.contrast, pm, 0, 1, "", "Contrast", .light, "global contrast"),
            s(.highlights, pm, 0, 1, "", "Highlights", .light, "bright tones"),
            s(.shadows, pm, 0, 1, "", "Shadows", .light, "dark tones"),
            s(.whites, pm, 0, 1, "", "Whites", .light, "white point"),
            s(.blacks, pm, 0, 1, "", "Blacks", .light, "black point"),
            s(.warmth, pm, 0, 1, "", "Warmth", .color, "white balance, cooler to warmer"),
            s(.tint, pm, 0, 1, "", "Tint", .color, "green to magenta"),
            s(.vibrance, pm, 0, 1, "", "Vibrance", .color, "muted colors only"),
            s(.saturation, pm, 0, 1, "", "Saturation", .color, "all colors"),
            s(.clarity, pm, 0, 1, "", "Clarity", .detail, "local contrast (midtone detail)"),
            s(.vignette, pm, 0, 1, "", "Vignette", .detail, "negative darkens the edges"),
            s(.subjectLight, pm, 0, 1, "", "Subject light", .local, "brightness inside the subject mask"),
            s(.backgroundLight, pm, 0, 1, "", "Background light", .local, "brightness outside the subject mask"),
            s(.depthBlur, 0...100, 0, 1, "", "Depth blur", .lens, "lens blur from the depth map, focused at focus_depth"),
            s(.focusDepth, 0.1...50, nil, 0.1, "m", "Focus depth", .lens, "focus distance in meters; Auto = the subject's median depth"),
        ])
    }()
}
