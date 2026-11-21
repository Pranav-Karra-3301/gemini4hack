import Foundation

/// The recipe's film look (CORE_API.md §6): `"look": {"id": "look-fit-1", "strength": 0.6}`.
/// Applied after the global sliders and before vignette, depth blur and grain.
public struct LookRef: Codable, Hashable, Sendable {
    /// Look id from `GET /api/shots/{id}/looks`.
    public var id: String
    /// 0...1 (clamped). Scales the LUT (mixed with identity) and every effect. Missing = 1.
    public var strength: Double

    public init(id: String, strength: Double = 1) {
        self.id = id
        self.strength = strength.isFinite ? min(max(strength, 0), 1) : 1
    }

    enum CodingKeys: String, CodingKey { case id, strength }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try? c.decodeIfPresent(JSONValue.self, forKey: .strength)
        self.init(id: try c.decode(String.self, forKey: .id), strength: s?.doubleValue ?? 1)
    }
}

/// The film effects that come with a look's LUT (`effects` in CORE_API.md §6, `<look>.effects.json`).
/// Every field is optional on the wire; a missing effect has amount 0. Values are kept as sent;
/// the renderer clamps them to the ranges below.
public struct LookEffects: Codable, Hashable, Sendable {
    public var grain: Grain
    public var halation: Halation
    public var bloom: Bloom
    public var vignette: Vignette

    public init(grain: Grain = Grain(), halation: Halation = Halation(), bloom: Bloom = Bloom(),
                vignette: Vignette = Vignette()) {
        self.grain = grain; self.halation = halation; self.bloom = bloom; self.vignette = vignette
    }

    /// No effects (LUT only).
    public static let none = LookEffects()

    /// Film grain: luminance-weighted, strongest in the midtones.
    public struct Grain: Codable, Hashable, Sendable {
        /// 0...0.6.
        public var amount: Double
        /// Grain size in px at a 2048 px long side (scales with the image), 0.5...3.
        public var size: Double
        /// 0...1: more coarse second octave and a little color noise.
        public var roughness: Double
        /// Renderer option (not from Core): re-seed the grain every frame (24 fps) like real film.
        /// Off by default so still previews don't shimmer.
        public var animated: Bool

        public init(amount: Double = 0, size: Double = 1, roughness: Double = 0.5, animated: Bool = false) {
            self.amount = amount; self.size = size; self.roughness = roughness; self.animated = animated
        }

        enum CodingKeys: String, CodingKey { case amount, size, roughness, animated }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(amount: c.number(.amount) ?? 0, size: c.number(.size) ?? 1,
                      roughness: c.number(.roughness) ?? 0.5,
                      animated: (try? c.decodeIfPresent(Bool.self, forKey: .animated)) ?? false)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(amount, forKey: .amount)
            try c.encode(size, forKey: .size)
            try c.encode(roughness, forKey: .roughness)
            if animated { try c.encode(animated, forKey: .animated) }
        }
    }

    /// Red-orange glow bleeding out of bright highlights.
    public struct Halation: Codable, Hashable, Sendable {
        /// 0...0.6.
        public var amount: Double
        /// sRGB luminance where the glow starts, 0.6...1.
        public var threshold: Double
        /// Blur radius as a fraction of the long side, 0.002...0.03.
        public var radius: Double
        /// Tint hue in degrees (film.py; classic 10–25). Used when `tint` is absent.
        public var hue: Double?
        /// Tint as linear RGB `[r, g, b]` (the §6 example). Wins over `hue`.
        public var tint: [Double]?

        public init(amount: Double = 0, threshold: Double = 0.8, radius: Double = 0.008,
                    hue: Double? = 15, tint: [Double]? = nil) {
            self.amount = amount; self.threshold = threshold; self.radius = radius; self.hue = hue; self.tint = tint
        }

        enum CodingKeys: String, CodingKey { case amount, threshold, radius, hue, tint }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tint = (try? c.decodeIfPresent([JSONValue].self, forKey: .tint))?.compactMap(\.doubleValue)
            self.init(amount: c.number(.amount) ?? 0, threshold: c.number(.threshold) ?? 0.8,
                      radius: c.number(.radius) ?? 0.008, hue: c.number(.hue),
                      tint: tint?.count == 3 ? tint : nil)
        }
    }

    /// Soft neutral diffusion of the highlights.
    public struct Bloom: Codable, Hashable, Sendable {
        /// 0...0.5.
        public var amount: Double
        /// sRGB luminance where the bloom starts, 0.6...1.
        public var threshold: Double
        /// Blur radius as a fraction of the long side, 0.005...0.06.
        public var radius: Double

        public init(amount: Double = 0, threshold: Double = 0.8, radius: Double = 0.02) {
            self.amount = amount; self.threshold = threshold; self.radius = radius
        }

        enum CodingKeys: String, CodingKey { case amount, threshold, radius }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(amount: c.number(.amount) ?? 0, threshold: c.number(.threshold) ?? 0.8,
                      radius: c.number(.radius) ?? 0.02)
        }
    }

    /// Corner darkening. Composes with the `vignette` slider without stacking (see CoachEdit).
    public struct Vignette: Codable, Hashable, Sendable {
        /// Corner darkening 0...0.45. The sign is ignored: film.py sends `0.16`, the §6 example
        /// (slider convention) `-0.15`; both darken.
        public var amount: Double
        /// Where the falloff starts, as a fraction of the half diagonal, 0.3...1.
        public var midpoint: Double

        public init(amount: Double = 0, midpoint: Double = 0.6) {
            self.amount = amount; self.midpoint = midpoint
        }

        enum CodingKeys: String, CodingKey { case amount, midpoint }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(amount: c.number(.amount) ?? 0, midpoint: c.number(.midpoint) ?? 0.6)
        }
    }

    enum CodingKeys: String, CodingKey { case grain, halation, bloom, vignette }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(grain: (try? c.decodeIfPresent(Grain.self, forKey: .grain)) ?? Grain(),
                  halation: (try? c.decodeIfPresent(Halation.self, forKey: .halation)) ?? Halation(),
                  bloom: (try? c.decodeIfPresent(Bloom.self, forKey: .bloom)) ?? Bloom(),
                  vignette: (try? c.decodeIfPresent(Vignette.self, forKey: .vignette)) ?? Vignette())
    }
}

/// One designed look: `POST /api/shots/{id}/looks` response and an item of `GET .../looks`.
public struct Look: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    /// The film stock it evokes, e.g. "Kodak Gold 200".
    public var evokes: String?
    public var rationale: String?
    /// Path of the 33³ `.cube` (sRGB in/out), e.g. `/api/shots/<id>/looks/<look>/lut.cube`.
    public var lut: String?
    public var size: Int?
    public var effects: LookEffects?
    public var spec: JSONValue?
    public var model: String?
    public var ms: Double?

    public init(id: String, name: String? = nil, evokes: String? = nil, rationale: String? = nil,
                lut: String? = nil, size: Int? = nil, effects: LookEffects? = nil, spec: JSONValue? = nil,
                model: String? = nil, ms: Double? = nil) {
        self.id = id; self.name = name; self.evokes = evokes; self.rationale = rationale
        self.lut = lut; self.size = size; self.effects = effects; self.spec = spec
        self.model = model; self.ms = ms
    }
}

private extension KeyedDecodingContainer {
    /// A finite number (or numeric string); nil when missing, null or malformed.
    func number(_ key: Key) -> Double? {
        guard let v = (try? decodeIfPresent(JSONValue.self, forKey: key)) ?? nil, let d = v.doubleValue,
              d.isFinite else { return nil }
        return d
    }
}
