import Foundation

/// Processing state of one shot asset.
public enum AssetStatus: String, Codable, Hashable, Sendable {
    case none, pending, running, done, error

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AssetStatus(rawValue: raw) ?? .none
    }

    /// `pending` or `running`.
    public var isInProgress: Bool { self == .pending || self == .running }
}

/// Depth map metadata (`assets.depth.meta`). `depth.png` is 16-bit grayscale millimetres, 0 = unknown.
public struct DepthMeta: Codable, Hashable, Sendable {
    public var width: Int?
    public var height: Int?
    /// 2nd / 98th percentile depth, in `units` (use these to normalize).
    public var p02: Double?
    public var p98: Double?
    public var focalPx: Double?
    public var units: String?

    public init(width: Int? = nil, height: Int? = nil, p02: Double? = nil, p98: Double? = nil,
                focalPx: Double? = nil, units: String? = nil) {
        self.width = width; self.height = height; self.p02 = p02; self.p98 = p98
        self.focalPx = focalPx; self.units = units
    }

    enum CodingKeys: String, CodingKey {
        case width, height, p02, p98, units
        case focalPx = "focal_px"
    }
}

/// One asset of a shot: status plus where to fetch it.
public struct ShotAsset: Codable, Hashable, Sendable {
    public var status: AssetStatus
    /// Relative URL (e.g. `/api/shots/<id>/depth.png`); resolve against Core's base URL.
    public var url: String?
    /// Per-region URLs (only `masks`): region id → `/api/shots/<id>/masks/<rid>.png`.
    public var urls: [String: String]?
    /// Only `depth`.
    public var meta: DepthMeta?
    /// Set when `status == .error`.
    public var error: String?
    /// How long the stage took.
    public var ms: Double?
    /// Inline preview: `{"lighting": 3.2, "composition": 4.1}` for score, a sentence for suggest.
    public var summary: JSONValue?
    /// Number of regions (only `regions`).
    public var count: Int?
    /// Model that produced it (e.g. masks' segmenter).
    public var model: String?

    public init(status: AssetStatus = .none, url: String? = nil, urls: [String: String]? = nil,
                meta: DepthMeta? = nil, error: String? = nil, ms: Double? = nil, summary: JSONValue? = nil,
                count: Int? = nil, model: String? = nil) {
        self.status = status; self.url = url; self.urls = urls; self.meta = meta; self.error = error
        self.ms = ms; self.summary = summary; self.count = count; self.model = model
    }

    /// `summary` as text (suggest's one-liner).
    public var summaryText: String? { if case .string(let s)? = summary { return s } else { return nil } }

    /// `summary` as axis → score (score's `{"lighting": 3.2, "composition": 4.1}`).
    public var summaryScores: [String: Double] { summary?.objectValue?.compactMapValues(\.doubleValue) ?? [:] }

    public static let missing = ShotAsset()

    /// Done and fetchable.
    public var isReady: Bool { status == .done && (url != nil || urls != nil) }

    enum CodingKeys: String, CodingKey { case status, url, urls, meta, error, ms, summary, count, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(AssetStatus.self, forKey: .status) ?? .none
        url = try c.decodeIfPresent(String.self, forKey: .url)
        urls = try c.decodeIfPresent([String: String].self, forKey: .urls)
        meta = try? c.decodeIfPresent(DepthMeta.self, forKey: .meta)  // only depth's meta is typed
        error = try c.decodeIfPresent(String.self, forKey: .error)
        ms = try? c.decodeIfPresent(Double.self, forKey: .ms)
        summary = try c.decodeIfPresent(JSONValue.self, forKey: .summary)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// All assets of a shot. Missing entries decode as `.missing` (status `none`).
public struct ShotAssets: Codable, Hashable, Sendable {
    public var image, original, thumb, depth, regions, masks, score, suggest, splat: ShotAsset

    public init(image: ShotAsset = .missing, original: ShotAsset = .missing, thumb: ShotAsset = .missing,
                depth: ShotAsset = .missing, regions: ShotAsset = .missing, masks: ShotAsset = .missing,
                score: ShotAsset = .missing, suggest: ShotAsset = .missing, splat: ShotAsset = .missing) {
        self.image = image; self.original = original; self.thumb = thumb; self.depth = depth
        self.regions = regions; self.masks = masks; self.score = score; self.suggest = suggest
        self.splat = splat
    }

    enum CodingKeys: String, CodingKey { case image, original, thumb, depth, regions, masks, score, suggest, splat }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func a(_ k: CodingKeys) throws -> ShotAsset { try c.decodeIfPresent(ShotAsset.self, forKey: k) ?? .missing }
        self.init(image: try a(.image), original: try a(.original), thumb: try a(.thumb), depth: try a(.depth),
                  regions: try a(.regions), masks: try a(.masks), score: try a(.score),
                  suggest: try a(.suggest), splat: try a(.splat))
    }

    /// True while Core is still working on the automatic pipeline (depth → score/regions → masks → suggest).
    public var isProcessing: Bool {
        [depth, regions, masks, score, suggest].contains { $0.status.isInProgress }
    }
}

/// Capture metadata sent with `POST /api/shots` (all optional) and echoed in the record.
public struct ShotMeta: Codable, Hashable, Sendable {
    public var source: String?
    public var device: String?
    /// ISO 8601 UTC.
    public var takenAt: String?
    public var iso: Double?
    /// Seconds.
    public var shutter: Double?
    public var ev: Double?
    public var wbKelvin: Double?
    public var tint: Double?
    /// `ultrawide` / `wide` / `tele`.
    public var lens: String?
    public var zoom: Double?
    /// `photo` / `portrait` / `night` / `macro`.
    public var mode: String?
    /// Lens position 0..1.
    public var focus: Double?
    /// `back` / `front`.
    public var facing: String?
    public var intent: String?
    public var subject: String?
    public var keep: [String]?
    public var scene: String?
    /// Coaching lines spoken during the shot.
    public var coach: [String]?

    public init(source: String? = nil, device: String? = nil, takenAt: String? = nil, iso: Double? = nil,
                shutter: Double? = nil, ev: Double? = nil, wbKelvin: Double? = nil, tint: Double? = nil,
                lens: String? = nil, zoom: Double? = nil, mode: String? = nil, focus: Double? = nil,
                facing: String? = nil, intent: String? = nil, subject: String? = nil, keep: [String]? = nil,
                scene: String? = nil, coach: [String]? = nil) {
        self.source = source; self.device = device; self.takenAt = takenAt; self.iso = iso
        self.shutter = shutter; self.ev = ev; self.wbKelvin = wbKelvin; self.tint = tint; self.lens = lens
        self.zoom = zoom; self.mode = mode; self.focus = focus; self.facing = facing; self.intent = intent
        self.subject = subject; self.keep = keep; self.scene = scene; self.coach = coach
    }

    public var takenDate: Date? { CoachJSON.date(from: takenAt) }

    enum CodingKeys: String, CodingKey {
        case source, device, iso, shutter, ev, tint, lens, zoom, mode, focus, facing, intent, subject, keep, scene, coach
        case takenAt = "taken_at"
        case wbKelvin = "wb_kelvin"
    }
}

/// A shot record (`GET /api/shots/{id}`).
public struct Shot: Codable, Hashable, Sendable, Identifiable {
    /// Time-sortable: `YYYYMMDD-HHMMSS-xxxx`.
    public var id: String
    /// ISO 8601 UTC.
    public var created: String?
    /// ISO 8601 UTC, bumped on every change.
    public var updated: String?
    public var width: Int?
    public var height: Int?
    public var meta: ShotMeta?
    public var assets: ShotAssets
    /// The saved edit, if any.
    public var edit: EditRecipe?

    public init(id: String, created: String? = nil, updated: String? = nil, width: Int? = nil, height: Int? = nil,
                meta: ShotMeta? = nil, assets: ShotAssets = ShotAssets(), edit: EditRecipe? = nil) {
        self.id = id; self.created = created; self.updated = updated; self.width = width; self.height = height; self.meta = meta
        self.assets = assets; self.edit = edit
    }

    public var createdDate: Date? { CoachJSON.date(from: created) }
    public var updatedDate: Date? { CoachJSON.date(from: updated) }

    enum CodingKeys: String, CodingKey { case id, created, updated, width, height, meta, assets, edit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        meta = try c.decodeIfPresent(ShotMeta.self, forKey: .meta)
        assets = try c.decodeIfPresent(ShotAssets.self, forKey: .assets) ?? ShotAssets()
        edit = try c.decodeIfPresent(EditRecipe.self, forKey: .edit)
    }
}

/// `GET /api/shots` response.
public struct ShotList: Codable, Hashable, Sendable {
    public var shots: [Shot]
    public init(shots: [Shot]) { self.shots = shots }
}

/// A server-sent event from `GET /api/events`.
public enum ShotEvent: Hashable, Sendable {
    /// Sent once per connection (payload as sent, often an object).
    case hello(JSONValue)
    /// A shot was created, an asset changed status, or an edit was saved.
    case shot(Shot)
    case shotDeleted(id: String)
    /// The `: ping` keep-alive comment.
    case ping
    /// Any other event name, kept for forward compatibility.
    case other(event: String, data: String)
}
