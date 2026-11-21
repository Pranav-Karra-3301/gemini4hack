import Foundation

// Local adjustment layers (docs/CORE_API.md §7): semantic masks, the `edit/local` plan and the
// recipe's `layers`. Decoding is lenient like the rest of the recipe (bad values are clamped or
// defaulted, a malformed layer is dropped); `PUT /api/shots/{id}/edit` is where Core is strict.

/// How a layer's feather treats photo edges.
public enum LayerEdge: String, Codable, Hashable, Sendable, CaseIterable {
    /// Soft over smooth areas, crisp where the mask edge meets a real edge in the photo.
    case image
    /// Same, but the edges come from the depth map (depth steps).
    case depth
    /// Plain Gaussian blur.
    case none
}

/// Which pixels a layer edits: `mask.source` (inverted if `invert`) × Π(1 − `subtract`), then feathered.
public struct LayerMask: Codable, Hashable, Sendable {
    /// A semantic mask name (`sky`, `subject`, `t3`, ...) or a region id (`r1`).
    public var source: String
    /// Use 1 − mask.
    public var invert: Bool
    /// Mask names multiplied out as (1 − each), at most 4 (e.g. background minus sky).
    public var subtract: [String]
    /// 0...100: blur radius, 100 = 4% of the image's long side; 0 = the mask as is.
    public var feather: Double
    public var edge: LayerEdge

    public static let maxSubtract = 4

    public init(source: String, invert: Bool = false, subtract: [String] = [], feather: Double = 0,
                edge: LayerEdge = .image) {
        self.source = source
        self.invert = invert
        var seen = Set<String>([source])
        self.subtract = Array(subtract.filter { seen.insert($0).inserted }.prefix(Self.maxSubtract))
        self.feather = feather.isFinite ? min(max(feather, 0), 100) : 0
        self.edge = edge
    }

    enum CodingKeys: String, CodingKey { case source, invert, subtract, feather, edge }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let subtract = (try? c.decodeIfPresent([JSONValue].self, forKey: .subtract))?.compactMap(\.stringValue) ?? []
        let feather = (try? c.decodeIfPresent(JSONValue.self, forKey: .feather))?.doubleValue ?? 0
        let edge = ((try? c.decodeIfPresent(String.self, forKey: .edge)) ?? nil).flatMap { LayerEdge(rawValue: $0) } ?? .image
        let invert = (try? c.decodeIfPresent(JSONValue.self, forKey: .invert))?.boolValue ?? false
        self.init(source: try c.decode(String.self, forKey: .source), invert: invert, subtract: subtract,
                  feather: feather, edge: edge)
    }
}

/// One masked adjustment (CORE_API.md §7 "Recipe `layers`").
public struct EditLayer: Codable, Hashable, Sendable, Identifiable {
    /// `[A-Za-z0-9_-]{1,32}`, unique in the recipe (`l1`, `l2`, ...).
    public var id: String
    /// What the layer edits, for the UI (≤ 60 chars).
    public var target: String
    public var mask: LayerMask
    /// Relative adjustments inside the mask, clamped; only `EditLayer.sliders`. Empty = no-op.
    public private(set) var values: [Slider: Double]
    /// One sentence for the UI.
    public var why: String

    /// The sliders a layer may use: exposure ... clarity (no vignette, subject/background light, depth blur).
    public static let sliders: [Slider] = [.exposure, .contrast, .highlights, .shadows, .whites, .blacks,
                                           .warmth, .tint, .vibrance, .saturation, .clarity]
    /// Most layers a recipe carries.
    public static let maxCount = 5

    public init(id: String, target: String = "", mask: LayerMask, values: [Slider: Double] = [:], why: String = "") {
        self.id = id
        self.target = target
        self.mask = mask
        self.values = [:]
        self.why = why
        for (k, v) in values { set(k, v) }
    }

    /// Sets a slider (clamped); `nil`, 0 or a slider layers can't use removes it.
    public mutating func set(_ slider: Slider, _ value: Double?) {
        guard Self.sliders.contains(slider), let value, value.isFinite else { values[slider] = nil; return }
        let v = slider.spec.clamp(value)
        values[slider] = abs(v) < 1e-9 ? nil : v
    }

    public subscript(slider: Slider) -> Double {
        get { values[slider] ?? 0 }
        set { set(slider, newValue) }
    }

    /// True when the layer changes nothing.
    public var isIdentity: Bool { values.isEmpty }

    enum CodingKeys: String, CodingKey { case id, target, mask, values, why }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .values)) ?? nil
        let mask = try c.decode(LayerMask.self, forKey: .mask)
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
                  target: (try? c.decodeIfPresent(String.self, forKey: .target)) ?? mask.source,
                  mask: mask, values: SliderValues.parse(raw ?? [:]),
                  why: (try? c.decodeIfPresent(String.self, forKey: .why)) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(target, forKey: .target)
        try c.encode(mask, forKey: .mask)
        try c.encode(SliderValues.named(values), forKey: .values)
        try c.encode(why, forKey: .why)
    }

    /// Lenient list decoding: drops malformed layers, keeps the first `maxCount`, gives empty or
    /// repeated ids a fresh `lN`.
    public static func decodeList(_ raw: [JSONValue]) -> [EditLayer] {
        var out: [EditLayer] = []
        var ids = Set<String>()
        for v in raw {
            guard var l = try? v.decode(EditLayer.self) else { continue }
            if l.id.isEmpty || ids.contains(l.id) {
                var n = out.count + 1
                while ids.contains("l\(n)") { n += 1 }
                l.id = "l\(n)"
            }
            ids.insert(l.id)
            out.append(l)
            if out.count == maxCount { break }
        }
        return out
    }
}

/// `POST /api/shots/{id}/edit/local` body.
public struct LocalEditRequest: Codable, Hashable, Sendable {
    public var goal: String?
    public var values: [String: Double]
    public var subject: String?
    public init(goal: String? = nil, values: [Slider: Double] = [:], subject: String? = nil) {
        self.goal = goal
        self.values = SliderValues.named(values)
        self.subject = subject
    }
}

/// `POST /api/shots/{id}/edit/local` response: a full global slider set plus 1–5 layers.
public struct LocalEditPlan: Codable, Hashable, Sendable {
    public var summary: String
    public var why: String
    /// The complete new global values (clamped).
    public var values: [Slider: Double]
    public var layers: [EditLayer]
    public var subject: String?
    public var model: String?
    public var ms: Double?
    public var cached: Bool?

    public init(summary: String = "", why: String = "", values: [Slider: Double] = [:], layers: [EditLayer] = [],
                subject: String? = nil, model: String? = nil, ms: Double? = nil, cached: Bool? = nil) {
        self.summary = summary; self.why = why
        self.values = SliderValues.clamped(values)
        self.layers = layers; self.subject = subject; self.model = model; self.ms = ms; self.cached = cached
    }

    /// The plan as a recipe: `base` (crop, look) with the plan's global values and layers.
    public func recipe(base: EditRecipe = .identity) -> EditRecipe {
        var r = EditRecipe(values: values, subject: subject ?? base.subject, crop: base.crop, version: base.version)
        r.look = base.look
        r.layers = layers.isEmpty ? nil : layers
        return r
    }

    enum CodingKeys: String, CodingKey { case summary, why, values, layers, subject, model, ms, cached }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
        self.init(summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
                  why: try c.decodeIfPresent(String.self, forKey: .why) ?? "",
                  values: SliderValues.parse(raw),
                  layers: EditLayer.decodeList(try c.decodeIfPresent([JSONValue].self, forKey: .layers) ?? []),
                  subject: try c.decodeIfPresent(String.self, forKey: .subject),
                  model: try c.decodeIfPresent(String.self, forKey: .model),
                  ms: try c.decodeIfPresent(Double.self, forKey: .ms),
                  cached: try c.decodeIfPresent(Bool.self, forKey: .cached))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(why, forKey: .why)
        try c.encode(SliderValues.named(values), forKey: .values)
        try c.encode(layers, forKey: .layers)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(ms, forKey: .ms)
        try c.encodeIfPresent(cached, forKey: .cached)
    }
}

/// `GET /api/shots/{id}/semantic/semantic.json` (and the `POST .../semantic` answer).
public struct SemanticMasks: Codable, Hashable, Sendable {
    /// One soft 8-bit mask PNG over the whole image (long side 1024).
    public struct Mask: Codable, Hashable, Sendable {
        /// `/api/shots/<id>/semantic/<name>.png` (absent in `/api/semantic-masks`, which inlines `png`).
        public var url: String?
        /// `data:image/png;base64,...` from `POST /api/semantic-masks`.
        public var png: String?
        public var width: Int?
        public var height: Int?
        /// Fraction of the image covered.
        public var area: Double?
        /// `sam2.1`, `sam2.1+depth`, `depth+box`, `box+depth`, `union`, `1-subject+depth`.
        public var source: String?
        public var label: String?
        /// person, face, sky, ... for items; the union name for unions; `subject` / `background`.
        public var kind: String?
        /// Item ids the mask covers.
        public var ids: [String]?
    }

    /// One edit target Gemini named.
    public struct Target: Codable, Hashable, Sendable {
        public var id: String
        public var label: String?
        public var kind: String?
        /// Normalized like `/api/regions` (origin top-left).
        public var box: NormBox?
    }

    public struct NormBox: Codable, Hashable, Sendable {
        public var x: Double, y: Double, w: Double, h: Double
    }

    public var version: Int?
    public var created: String?
    /// By name: unions (`people`, `sky`, ...), `subject`, `background` and items `t1`, `t2`, ...
    public var masks: [String: Mask]
    public var targets: [Target]?
    /// Item ids that make up `subject`.
    public var subject: [String]?
    public var labels: [String]?
    public var model: String?
    public var segmenter: String?
    public var cached: Bool?

    /// Mask names, unions first, then items in numeric order (`t2` before `t10`).
    public var names: [String] {
        func item(_ s: String) -> Int? { s.first == "t" ? Int(s.dropFirst()) : nil }
        return masks.keys.sorted { a, b in
            switch (item(a), item(b)) {
            case let (x?, y?): return x < y
            case (nil, _?): return true
            case (_?, nil): return false
            default: return a < b
            }
        }
    }
}

public extension EditRecipe {
    /// Every mask name the recipe's layers read (sources and subtracts), in first-use order.
    var layerMaskNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for l in layers ?? [] { for n in [l.mask.source] + l.mask.subtract where seen.insert(n).inserted { out.append(n) } }
        return out
    }
}
