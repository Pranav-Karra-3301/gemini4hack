import Foundation

/// Which tool set and prompt Core locks into a Live token.
public enum LiveMode: String, Codable, Hashable, Sendable {
    /// iPhone shooting with live coaching.
    case camera
    /// Mac editing a shot (needs `shot_id`).
    case edit
}

/// Camera facing.
public enum CameraFacing: String, Codable, Hashable, Sendable { case back, front }

/// `POST /api/live/token` body.
public struct LiveTokenRequest: Codable, Hashable, Sendable {
    public var mode: LiveMode
    public var voice: Bool
    public var facing: CameraFacing?
    public var shotId: String?
    /// Extra context appended to the system prompt.
    public var context: String
    /// Edit mode: the editor's current slider values (JSON names); default = the shot's saved edit.
    public var values: [String: Double]?
    /// Edit mode: the editor's subject region id; default = the saved edit's.
    public var subject: String?

    public init(mode: LiveMode, voice: Bool = true, facing: CameraFacing? = .back, shotId: String? = nil,
                context: String = "", values: [String: Double]? = nil, subject: String? = nil) {
        self.mode = mode; self.voice = voice; self.facing = facing; self.shotId = shotId; self.context = context
        self.values = values; self.subject = subject
    }

    /// Camera-mode session.
    public static func camera(facing: CameraFacing = .back, voice: Bool = true, context: String = "") -> Self {
        LiveTokenRequest(mode: .camera, voice: voice, facing: facing, context: context)
    }

    /// Edit-mode session for one shot.
    public static func edit(shotId: String, voice: Bool = true, context: String = "",
                            values: [String: Double]? = nil, subject: String? = nil) -> Self {
        LiveTokenRequest(mode: .edit, voice: voice, facing: nil, shotId: shotId, context: context,
                         values: values, subject: subject)
    }

    enum CodingKeys: String, CodingKey {
        case mode, voice, facing, context, values, subject
        case shotId = "shot_id"
    }
}

/// `POST /api/live/token` response: connect to `wsURL`, send `{"setup": {}}`.
public struct LiveTokenResponse: Codable, Hashable, Sendable {
    /// `auth_tokens/...`
    public var token: String
    public var model: String
    public var wsUrl: String
    public var expireTime: String?
    public var newSessionExpireTime: String?

    public init(token: String, model: String, wsUrl: String, expireTime: String? = nil,
                newSessionExpireTime: String? = nil) {
        self.token = token; self.model = model; self.wsUrl = wsUrl
        self.expireTime = expireTime; self.newSessionExpireTime = newSessionExpireTime
    }

    public var wsURL: URL? { URL(string: wsUrl) }
    /// After this, the token can't be used at all (mint a new one).
    public var expiresAt: Date? { CoachJSON.date(from: expireTime) }
    /// After this, no new session (including resumption) can start with the token.
    public var newSessionExpiresAt: Date? { CoachJSON.date(from: newSessionExpireTime) }

    /// True if a new session can still be opened at `date` (with a safety margin).
    public func canStartSession(at date: Date = Date(), margin: TimeInterval = 5) -> Bool {
        guard let end = newSessionExpiresAt ?? expiresAt else { return true }
        return date.addingTimeInterval(margin) < end
    }

    enum CodingKeys: String, CodingKey {
        case token, model
        case wsUrl = "ws_url"
        case expireTime = "expire_time"
        case newSessionExpireTime = "new_session_expire_time"
    }
}
