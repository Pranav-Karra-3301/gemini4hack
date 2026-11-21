import CoachModels
import Foundation

// Public value types for CoachLive. See docs/CORE_API.md §2 for the protocol these map to.

/// Where and until when a Live session may connect: the `ws_url` and `expire_time` from
/// `POST /api/live/token` (Core mints it; the API key never reaches the device).
///
/// `LiveSession` reuses `wsURL` for reconnects until `expireTime`, then asks its token provider
/// for a fresh one.
public struct LiveCredential: Sendable, Equatable {
    /// `wss://…BidiGenerateContentConstrained?access_token=…`. Treat as a secret: never log it.
    public var wsURL: URL
    /// When the token stops accepting new connections (`expire_time`). `nil` = unknown.
    public var expireTime: Date?
    /// The model locked into the token (`model`), for display only.
    public var model: String?
    /// After this no new connection (resumes included, to be safe) may use the token
    /// (`new_session_expire_time`). `nil` = same as `expireTime`.
    public var newSessionExpireTime: Date?

    public init(wsURL: URL, expireTime: Date? = nil, model: String? = nil, newSessionExpireTime: Date? = nil) {
        self.wsURL = wsURL
        self.expireTime = expireTime
        self.model = model
        self.newSessionExpireTime = newSessionExpireTime
    }

    /// From the typed Core response (`CoachClient.liveToken(_:)`).
    public init(_ response: LiveTokenResponse) throws {
        guard let url = response.wsURL else { throw LiveError.badToken("missing ws_url") }
        self.init(wsURL: url, expireTime: response.expiresAt, model: response.model,
                  newSessionExpireTime: response.newSessionExpiresAt)
    }

    /// Parses the JSON body of `POST /api/live/token` (`ws_url`, `expire_time`, `model`).
    /// Use this until you have a `CoachAPI` client that returns a typed response.
    public init(coreTokenJSON data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["ws_url"] as? String, let url = URL(string: s)
        else { throw LiveError.badToken("missing ws_url") }
        self.init(wsURL: url,
                  expireTime: (obj["expire_time"] as? String).flatMap(LiveCredential.parseDate),
                  model: obj["model"] as? String,
                  newSessionExpireTime: (obj["new_session_expire_time"] as? String).flatMap(LiveCredential.parseDate))
    }

    /// True when a new connection can no longer use the token: past (or within `margin` seconds
    /// of) the earlier of `newSessionExpireTime` and `expireTime`.
    public func isExpired(margin: TimeInterval = 5, now: Date = Date()) -> Bool {
        let ends = [newSessionExpireTime, expireTime].compactMap { $0 }
        guard let end = ends.min() else { return false }
        return end.timeIntervalSince(now) < margin
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Connection state of a `LiveSession`, reported through `LiveEvent.status`.
public enum LiveStatus: Sendable, Equatable {
    /// Minting a token / opening the socket / waiting for `setupComplete`.
    case connecting
    /// `setupComplete` received; media and tool responses flow.
    case live
    /// The socket dropped or the server sent `goAway`; reconnecting (1-based attempt).
    case reconnecting(attempt: Int)
    /// `stop()` was called. Terminal.
    case closed
    /// Gave up (setup rejected, reconnects exhausted). Terminal.
    case error(String)
}

/// How Gemini should treat a tool result (`FunctionResponse.scheduling`, NON_BLOCKING tools).
public enum LiveScheduling: String, Sendable {
    /// Add the result to context without prompting a reply. Default for UI tools.
    case silent = "SILENT"
    /// Let the model comment once it's done speaking ("that's brighter now").
    case whenIdle = "WHEN_IDLE"
    /// Stop the current answer and react to the result right away.
    case interrupt = "INTERRUPT"
}

/// One thing that happened in a Live session. Delivered in order on `LiveSession.events`.
public enum LiveEvent: Sendable {
    /// Connection state changed.
    case status(LiveStatus)
    /// Gemini wants a tool run. `argsJSON` is the raw `args` object (`"{}"` when absent).
    /// Answer with `LiveSession.respond(to:name:result:scheduling:)`.
    case toolCall(id: String, name: String, argsJSON: String)
    /// Gemini withdrew tool calls it had issued (user interrupted). Undo them if cheap.
    case toolCallCancelled(ids: [String])
    /// A fragment of the transcription of the user's speech (append fragments).
    case inputTranscript(String)
    /// A fragment of the transcription of Gemini's speech (append fragments).
    case outputTranscript(String)
    /// Gemini started (`true`) or finished (`false`) producing audio for a turn.
    /// Playback runs slightly behind; use `LiveAudio.isPlaying` for what the user hears.
    case speaking(Bool)
    /// The user barged in; queued audio was flushed from `audioOutput` (if attached).
    case interrupted
    /// The model finished its turn.
    case turnComplete
    /// 24 kHz mono PCM16 audio, only emitted when no `audioOutput` is attached.
    case audio(Data)
    /// A reconnect finished. `resumed` says whether the server accepted the resumption handle;
    /// either way re-send what the model must know with `sendContext(_:)` (gemini-3.8-live
    /// currently resumes without the turns so far). The next frame is sent automatically.
    case reconnected(resumed: Bool)
}

/// What `LiveSession.sendFrame` did with a frame.
public enum LiveFrameResult: Sendable, Equatable {
    /// Sent to Gemini.
    case sent
    /// Less than the minimum interval (1 s) since the last sent frame.
    case throttled
    /// Looked the same as the last sent frame.
    case unchanged
    /// Not connected (or the socket is backed up); dropped.
    case notLive
    /// Couldn't decode or encode the image.
    case invalid
}

/// Errors thrown by CoachLive.
public enum LiveError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyStarted
    case badToken(String)
    /// The server refused the connection or the setup (HTTP status or WebSocket close code + reason).
    case setupRejected(code: Int, reason: String)
    case setupTimeout
    case closed
    /// A server frame that isn't valid Live API JSON.
    case protocolError(String)
    case audio(String)

    public var description: String {
        switch self {
        case .alreadyStarted: return "LiveSession was already started"
        case .badToken(let s): return "bad live token: \(s)"
        case .setupRejected(let code, let reason): return "live setup rejected (\(code)) \(reason)"
        case .setupTimeout: return "live setup timed out"
        case .closed: return "live session closed"
        case .protocolError(let s): return "live protocol: \(s)"
        case .audio(let s): return "audio: \(s)"
        }
    }
}

/// Decoding helpers for tool-call arguments.
public enum LiveToolArgs {
    /// `argsJSON` as a dictionary (`[:]` if it isn't a JSON object).
    public static func dictionary(_ argsJSON: String) -> [String: Any] {
        guard let d = argsJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// `argsJSON` decoded into a `Decodable` type (e.g. a CoachModels tool-args struct).
    public static func decode<T: Decodable>(_ type: T.Type, from argsJSON: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(argsJSON.utf8))
    }
}
