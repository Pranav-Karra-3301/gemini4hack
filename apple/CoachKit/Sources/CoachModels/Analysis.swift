import Foundation

/// Normalized rectangle (0..1 of the image, origin top-left).
public struct NormRect: Codable, Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }
}

/// A region from `/api/regions` / `regions.json`.
public struct Region: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var box: NormRect
    /// `"focus"` (subject or light worth building around) or `"remove"` (distracting).
    public var tag: String
    /// One short line of coaching.
    public var note: String

    public init(id: String, box: NormRect, tag: String = "focus", note: String = "") {
        self.id = id; self.box = box; self.tag = tag; self.note = note
    }

    public var isFocus: Bool { tag == "focus" }
    public var isRemove: Bool { tag == "remove" }

    enum CodingKeys: String, CodingKey { case id, box, tag, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        box = try c.decode(NormRect.self, forKey: .box)
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? "focus"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// `/api/regions` response and `regions.json`.
public struct RegionsResponse: Codable, Hashable, Sendable {
    public var regions: [Region]
    public var model: String?
    public var ms: Double?
    public init(regions: [Region], model: String? = nil, ms: Double? = nil) {
        self.regions = regions; self.model = model; self.ms = ms
    }
}

/// One score axis (lighting or composition) with its 1–5 distribution.
public struct Score: Codable, Hashable, Sendable {
    /// Expected value of `distribution`.
    public var score: Double
    /// `[1, 5]`.
    public var scale: [Double]
    /// 0..1.
    public var confidence: Double?
    /// Bucket ("1"..."5") → probability.
    public var distribution: [String: Double]
    /// Short human summary (may be empty).
    public var label: String

    public init(score: Double, scale: [Double] = [1, 5], confidence: Double? = nil,
                distribution: [String: Double] = [:], label: String = "") {
        self.score = score; self.scale = scale; self.confidence = confidence
        self.distribution = distribution; self.label = label
    }

    /// Probabilities ordered by bucket (1, 2, 3, ...).
    public var bins: [(bucket: Int, p: Double)] {
        distribution.compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.bucket < $1.bucket }
    }

    /// `score` mapped to 0..1 on `scale`.
    public var normalized: Double {
        guard scale.count == 2, scale[1] > scale[0] else { return score }
        return min(max((score - scale[0]) / (scale[1] - scale[0]), 0), 1)
    }

    enum CodingKeys: String, CodingKey { case score, scale, confidence, distribution, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Double.self, forKey: .score)
        scale = try c.decodeIfPresent([Double].self, forKey: .scale) ?? [1, 5]
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        let raw = try c.decodeIfPresent([String: JSONValue].self, forKey: .distribution) ?? [:]
        distribution = raw.compactMapValues { $0.doubleValue }
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

/// `/api/score` response and `score.json`.
public struct ScoreReport: Codable, Hashable, Sendable {
    public var provider: String?
    public var scores: [String: Score]
    public var ms: Double?

    public init(provider: String? = nil, scores: [String: Score], ms: Double? = nil) {
        self.provider = provider; self.scores = scores; self.ms = ms
    }

    public var lighting: Score? { scores["lighting"] }
    public var composition: Score? { scores["composition"] }
}

/// `GET /api/health`.
public struct Health: Codable, Hashable, Sendable {
    public var ok: Bool
    public var version: Int?
    public var lan: Bool?
    /// Model warm states, shape owned by Core (e.g. `{"depth": "warm"}`).
    public var models: [String: JSONValue]?

    public init(ok: Bool, version: Int? = nil, lan: Bool? = nil, models: [String: JSONValue]? = nil) {
        self.ok = ok; self.version = version; self.lan = lan; self.models = models
    }
}
