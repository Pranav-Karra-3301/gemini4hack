import Foundation

// Wire format of the Gemini Live API (BidiGenerateContent), JSON text frames.
// Client messages are built by hand for the hot paths (audio/video are base64 inside a fixed
// envelope, so no JSONSerialization per audio chunk). Server messages are parsed with
// JSONSerialization because one message can carry several fields at once (audio parts +
// transcripts + turnComplete, or sessionResumptionUpdate next to serverContent).

/// A message from the client to Gemini.
enum LiveClientMessage {
    /// `{"setup":{"sessionResumption":{}}}`, or `{"setup":{"sessionResumption":{"handle":…}}}`
    /// when resuming. Everything else (model, prompt, tools) is locked into the ephemeral token.
    /// Core mints with a fieldMask that leaves `sessionResumption` to the client (CORE_API §2), so
    /// the empty object is what turns resumption handles on: `{"setup":{}}` gets none, and every
    /// ~10 min connection reset then loses the conversation. A token minted without a fieldMask
    /// ignores the client's setup, so this is harmless there.
    case setup(resumeHandle: String?)
    /// 16 kHz mono PCM16 little-endian.
    case audio(Data)
    /// One JPEG frame.
    case video(jpeg: Data)
    /// A typed user turn (`realtimeInput.text`).
    case text(String)
    /// Silent context (`clientContent`, role user, `turnComplete: false`): added to the
    /// conversation without prompting a reply (verified on gemini-3.8-live 2026-11-21).
    case context(String)
    /// Mic paused: lets server VAD close the turn without waiting for more audio.
    case audioStreamEnd
    /// Results for one or more tool calls.
    case toolResponse([LiveFunctionResponse])

    static let audioMime = "audio/pcm;rate=16000"

    /// The JSON text frame.
    func json() throws -> String {
        switch self {
        case .setup(let handle):
            guard let handle, !handle.isEmpty else { return #"{"setup":{"sessionResumption":{}}}"# }
            return try Self.serialize(["setup": ["sessionResumption": ["handle": handle]]])
        case .audio(let pcm):
            return #"{"realtimeInput":{"audio":{"data":""# + pcm.base64EncodedString()
                + #"","mimeType":"audio/pcm;rate=16000"}}}"#
        case .video(let jpeg):
            return #"{"realtimeInput":{"video":{"data":""# + jpeg.base64EncodedString()
                + #"","mimeType":"image/jpeg"}}}"#
        case .text(let text):
            return try Self.serialize(["realtimeInput": ["text": text]])
        case .context(let text):
            return try Self.serialize(["clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": false,
            ] as [String: Any]])
        case .audioStreamEnd:
            return #"{"realtimeInput":{"audioStreamEnd":true}}"#
        case .toolResponse(let responses):
            let list: [[String: Any]] = responses.map { r in
                var o: [String: Any] = ["id": r.id, "name": r.name, "response": r.response]
                if let s = r.scheduling { o["scheduling"] = s.rawValue }
                return o
            }
            return try Self.serialize(["toolResponse": ["functionResponses": list]])
        }
    }

    static func serialize(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// One `FunctionResponse`. `response` must be a JSON object.
struct LiveFunctionResponse {
    var id: String
    var name: String
    var response: [String: Any]
    var scheduling: LiveScheduling?

    /// Wraps any JSON-compatible value: dictionaries pass through, everything else becomes
    /// `{"result": value}` (the API requires an object).
    static func object(from value: Any) -> [String: Any] {
        if let d = value as? [String: Any] { return d }
        return ["result": value]
    }

    /// Encodes a `Codable` result into a JSON object.
    static func object<T: Encodable>(encoding value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return object(from: obj)
    }
}

/// A tool call from Gemini.
struct LiveToolCall: Equatable {
    var id: String
    var name: String
    var argsJSON: String
}

/// Everything one server message said, flattened. Absent fields stay empty/false/nil.
struct LiveServerMessage {
    var setupComplete = false
    /// Decoded `inlineData` audio parts (24 kHz PCM16), in order.
    var audio: [Data] = []
    /// Non-thought text parts (rare with AUDIO output).
    var text: [String] = []
    var inputTranscript: String?
    var outputTranscript: String?
    var interrupted = false
    var turnComplete = false
    var generationComplete = false
    var toolCalls: [LiveToolCall] = []
    var cancelledToolCallIDs: [String] = []
    /// `sessionResumptionUpdate.newHandle`, only when `resumable` is true and the handle non-empty.
    var resumeHandle: String?
    /// Present when the message is a `goAway`: seconds left before the server closes.
    var goAwayTimeLeft: TimeInterval?
    /// A top-level `error` object/string, if the server sent one.
    var error: String?

    /// Parses one frame. Throws only if the frame isn't a JSON object.
    init(json data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveError.protocolError("server message is not a JSON object")
        }
        self.init(object: obj)
    }

    init(object obj: [String: Any]) {
        if obj["setupComplete"] != nil { setupComplete = true }

        if let sc = obj["serverContent"] as? [String: Any] {
            if let turn = sc["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any],
                       let b64 = inline["data"] as? String,
                       (inline["mimeType"] as? String)?.hasPrefix("audio/") ?? true,
                       let bytes = Data(base64Encoded: b64) {
                        audio.append(bytes)
                    } else if let t = part["text"] as? String, (part["thought"] as? Bool) != true {
                        text.append(t)
                    }
                }
            }
            inputTranscript = (sc["inputTranscription"] as? [String: Any])?["text"] as? String
            outputTranscript = (sc["outputTranscription"] as? [String: Any])?["text"] as? String
            interrupted = (sc["interrupted"] as? Bool) ?? false
            turnComplete = (sc["turnComplete"] as? Bool) ?? false
            generationComplete = (sc["generationComplete"] as? Bool) ?? false
        }

        if let tc = obj["toolCall"] as? [String: Any], let calls = tc["functionCalls"] as? [[String: Any]] {
            for c in calls {
                let args: String
                if let a = c["args"], JSONSerialization.isValidJSONObject(a),
                   let d = try? JSONSerialization.data(withJSONObject: a, options: [.withoutEscapingSlashes]) {
                    args = String(decoding: d, as: UTF8.self)
                } else {
                    args = "{}"
                }
                toolCalls.append(LiveToolCall(id: c["id"] as? String ?? "", name: c["name"] as? String ?? "",
                                              argsJSON: args))
            }
        }

        if let cancel = obj["toolCallCancellation"] as? [String: Any] {
            cancelledToolCallIDs = cancel["ids"] as? [String] ?? []
        }

        if let upd = obj["sessionResumptionUpdate"] as? [String: Any],
           (upd["resumable"] as? Bool) == true,
           let h = upd["newHandle"] as? String, !h.isEmpty {
            resumeHandle = h
        }

        if let ga = obj["goAway"] as? [String: Any] {
            goAwayTimeLeft = Self.parseDuration(ga["timeLeft"])
        } else if obj["goAway"] != nil {
            goAwayTimeLeft = 0
        }

        if let e = obj["error"] {
            if let s = e as? String { error = s }
            else if let d = e as? [String: Any] { error = (d["message"] as? String) ?? "\(d)" }
        }
    }

    /// Protobuf JSON Duration ("9.5s") or a bare number of seconds. Unknown → 0.
    static func parseDuration(_ v: Any?) -> TimeInterval {
        if let n = v as? NSNumber { return n.doubleValue }
        guard var s = v as? String else { return 0 }
        if s.hasSuffix("s") { s.removeLast() }
        return TimeInterval(s) ?? 0
    }
}
