import Foundation

/// Normalized crop (0..1 of the image, origin top-left) plus rotation in degrees.
public struct Crop: Codable, Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double, angle: Double
    public init(x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1, angle: Double = 0) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.angle = angle
    }
    public static let full = Crop()
    public var isIdentity: Bool { self == .full }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 1
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 1
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
    }
}

/// A portable edit (CORE_API.md §4). Missing slider values mean the default.
/// Values are always stored clamped to the slider's range.
public struct EditRecipe: Codable, Hashable, Sendable {
    public var version: Int
    /// Non-default slider values. `focus_depth` absent = the subject's median depth.
    public private(set) var values: [Slider: Double]
    /// Region id whose mask drives `subject_light`, `background_light` and the default focus depth.
    public var subject: String?
    public var crop: Crop?
    /// Film look (CORE_API.md §6), applied after the global sliders. nil = none. Additive: old
    /// recipes without `look` decode as before and encode byte-identically.
    public var look: LookRef?
    /// Masked local adjustments (CORE_API.md §7, Layers.swift), at most 5, applied in order after
    /// the global sliders and before the look. nil = none. Additive like `look`.
    public var layers: [EditLayer]?

    public init(values: [Slider: Double] = [:], subject: String? = nil, crop: Crop? = nil, version: Int = 1) {
        self.version = version
        self.values = [:]
        self.subject = subject
        self.crop = crop
        for (k, v) in values { set(k, v) }
    }

    /// The untouched original.
    public static let identity = EditRecipe()

    /// The recipe's value or the slider's default (`nil` only for an auto `focus_depth`).
    public func value(_ slider: Slider) -> Double? { values[slider] ?? slider.spec.defaultValue }

    /// Same as `value(_:)` but never nil (auto focus depth reads as the range's lower bound).
    public subscript(slider: Slider) -> Double {
        get { value(slider) ?? slider.spec.neutralValue }
        set { set(slider, newValue) }
    }

    /// Sets a slider, clamped to its range. `nil` (or the default) removes the entry.
    public mutating func set(_ slider: Slider, _ value: Double?) {
        let spec = slider.spec
        guard let value, value.isFinite else { values[slider] = nil; return }
        let v = spec.clamp(value)
        if let d = spec.defaultValue, abs(v - d) < 1e-9 { values[slider] = nil } else { values[slider] = v }
    }

    /// Returns a copy with several sliders set (clamped).
    public func applying(_ changes: [Slider: Double]) -> EditRecipe {
        var r = self
        for (k, v) in changes { r.set(k, v) }
        return r
    }

    /// Back to the original (keeps `subject`; drops the look).
    public mutating func reset() { values = [:]; crop = nil; look = nil; layers = nil }

    /// True when rendering this recipe would return the original image.
    public var isIdentity: Bool {
        values.isEmpty && (crop?.isIdentity ?? true) && (look?.strength ?? 0) <= 0 && (layers ?? []).allSatisfy(\.isIdentity)
    }

    /// Values as `[String: Double]` (JSON names), e.g. for `suggestEdit(values:)` or prompts.
    public var namedValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    enum CodingKeys: String, CodingKey { case version, values, subject, crop, look, layers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
        self.init(values: SliderValues.parse(raw),
                  subject: try c.decodeIfPresent(String.self, forKey: .subject),
                  crop: try c.decodeIfPresent(Crop.self, forKey: .crop),
                  version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 1)
        look = (try? c.decodeIfPresent(LookRef.self, forKey: .look)) ?? nil
        if let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .layers)) ?? nil {
            layers = EditLayer.decodeList(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(namedValues, forKey: .values)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encodeIfPresent(look, forKey: .look)
        try c.encodeIfPresent(layers, forKey: .layers)
    }
}

/// Helpers for `{slider_name: number}` JSON objects (recipes, suggestions, `set_sliders`).
public enum SliderValues {
    /// Keeps known sliders with numeric (or numeric-string) values; drops unknown names and nulls.
    public static func parse(_ raw: [String: JSONValue]) -> [Slider: Double] {
        var out: [Slider: Double] = [:]
        for (k, v) in raw {
            guard let s = Slider(name: k), let d = v.doubleValue, d.isFinite else { continue }
            out[s] = d
        }
        return out
    }

    /// Clamps every value to its slider's range.
    public static func clamped(_ values: [Slider: Double]) -> [Slider: Double] {
        values.reduce(into: [:]) { $0[$1.key] = $1.key.spec.clamp($1.value) }
    }

    /// JSON names, e.g. for tool responses.
    public static func named(_ values: [Slider: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }
}

/// One step of a guided edit: a `suggest` step or an `edit_step` tool call.
public struct EditStep: Codable, Hashable, Sendable {
    public var slider: Slider
    /// Target value (clamped). `nil` only for `focus_depth` = back to auto.
    public var value: Double?
    /// Short reason shown as the caption.
    public var why: String
    /// Region to highlight while the step runs.
    public var region: String?

    public init(slider: Slider, value: Double?, why: String = "", region: String? = nil) {
        self.slider = slider
        self.value = value.map { slider.spec.clamp($0) }
        self.why = why
        self.region = region
    }

    enum CodingKeys: String, CodingKey { case slider, value, why, region }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .slider)
        guard let slider = Slider(name: name) else {
            throw DecodingError.dataCorruptedError(forKey: .slider, in: c, debugDescription: "Unknown slider \(name)")
        }
        let v = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        self.init(slider: slider, value: v?.doubleValue,
                  why: try c.decodeIfPresent(String.self, forKey: .why) ?? "",
                  region: try c.decodeIfPresent(String.self, forKey: .region))
    }
}

/// `POST /api/shots/{id}/edit/suggest` body.
public struct EditSuggestRequest: Codable, Hashable, Sendable {
    public var values: [String: Double]
    public var goal: String?
    public init(values: [Slider: Double] = [:], goal: String? = nil) {
        self.values = SliderValues.named(values)
        self.goal = goal
    }
}

/// `POST /api/shots/{id}/edit/suggest` response (also stored as `suggest.json`).
public struct EditSuggestion: Codable, Hashable, Sendable {
    public var summary: String
    /// 3–8 steps in editing order.
    public var steps: [EditStep]
    /// The final values after all steps (clamped).
    public var values: [Slider: Double]
    public var subject: String?
    public var model: String?
    public var ms: Double?

    public init(summary: String, steps: [EditStep], values: [Slider: Double]? = nil, subject: String? = nil,
                model: String? = nil, ms: Double? = nil) {
        self.summary = summary
        self.steps = steps
        self.values = SliderValues.clamped(values ?? steps.reduce(into: [:]) { acc, s in
            if let v = s.value { acc[s.slider] = v }
        })
        self.subject = subject
        self.model = model
        self.ms = ms
    }

    /// The suggestion as a recipe applied on top of `base`.
    public func recipe(base: EditRecipe = .identity) -> EditRecipe {
        var r = base.applying(values)
        if let subject { r.subject = subject }
        return r
    }

    enum CodingKeys: String, CodingKey { case summary, steps, values, subject, model, ms }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Skip steps with unknown sliders instead of failing the whole suggestion.
        let rawSteps = try c.decodeIfPresent([JSONValue].self, forKey: .steps) ?? []
        let steps = rawSteps.compactMap { try? $0.decode(EditStep.self) }
        let rawValues = try c.decodeIfPresent([String: JSONValue].self, forKey: .values)
        self.init(summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
                  steps: steps,
                  values: rawValues.map(SliderValues.parse),
                  subject: try c.decodeIfPresent(String.self, forKey: .subject),
                  model: try c.decodeIfPresent(String.self, forKey: .model),
                  ms: try c.decodeIfPresent(Double.self, forKey: .ms))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(steps, forKey: .steps)
        try c.encode(SliderValues.named(values), forKey: .values)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(ms, forKey: .ms)
    }
}
