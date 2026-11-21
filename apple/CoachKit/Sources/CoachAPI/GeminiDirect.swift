import CoachModels
import Foundation

/// Calls the Gemini API straight from the device (no Core in between).
///
/// One `generateContent` request per call. Parts and function calls stay as `JSONValue` so a
/// model turn (including its `thoughtSignature`s) can be sent back unchanged in the next turn of
/// an agent loop, as Gemini 4 function calling requires.
///
/// The key comes from the app's Info.plist (`GeminiAPIKey`, filled from the gitignored
/// `apple/Local.xcconfig` → `GEMINI_API_KEY`), or from `-geminiKey` / `UserDefaults` for testing.
public final class GeminiDirect: @unchecked Sendable {
    public static let api = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    /// Fastest Gemini 4 for image + JSON/tool calls (~3.7 s measured against Core).
    public static let fastModel = "gemini-4-hydrogen"
    /// Slower, stronger Gemini 4 (~6 s) for edits and reviews where quality beats latency.
    public static let strongModel = "gemini-4-neon"
    /// Text-to-speech for spoken replies.
    public static let ttsModel = "gemini-3.8-flash-lite-tts"

    public let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// The key from `-geminiKey`/`UserDefaults("geminiKey")`, else Info.plist `GeminiAPIKey`.
    /// Nil when neither is set (or the plist still holds the unexpanded `$(GEMINI_API_KEY)`).
    public static func keyFromBundle(_ bundle: Bundle = .main) -> String? {
        if let k = UserDefaults.standard.string(forKey: "geminiKey"), !k.isEmpty { return k }
        guard let k = bundle.object(forInfoDictionaryKey: "GeminiAPIKey") as? String else { return nil }
        let trimmed = k.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    // MARK: Parts

    public static func text(_ s: String) -> JSONValue { .object(["text": .string(s)]) }

    /// An inline image part. `resolution` is a Gemini mediaResolution level
    /// ("MEDIA_RESOLUTION_LOW" keeps live frames cheap and fast).
    public static func image(_ data: Data, mime: String = "image/jpeg", resolution: String? = nil) -> JSONValue {
        var part: [String: JSONValue] = [
            "inlineData": .object(["mimeType": .string(mime), "data": .string(data.base64EncodedString())])
        ]
        if let resolution { part["mediaResolution"] = .object(["level": .string(resolution)]) }
        return .object(part)
    }

    public static func user(_ parts: [JSONValue]) -> JSONValue {
        .object(["role": .string("user"), "parts": .array(parts)])
    }

    /// The reply to one function call, sent back in a `user` turn.
    public static func functionResponse(name: String, id: String?, response: JSONValue) -> JSONValue {
        var fr: [String: JSONValue] = ["name": .string(name), "response": response]
        if let id { fr["id"] = .string(id) }
        return .object(["functionResponse": .object(fr)])
    }

    // MARK: Request

    public struct Options: Sendable {
        public var system: String?
        /// `functionDeclarations` (Gemini schema objects). Empty = no tools.
        public var functions: [JSONValue] = []
        /// "AUTO" (default), "ANY" (must call a function) or "NONE".
        public var functionMode: String?
        /// JSON Schema for a JSON reply (`responseJsonSchema`); ignored when `functions` is set.
        public var jsonSchema: JSONValue?
        /// Gemini 4 thinkingLevel: low / medium / high. Nil = model default.
        public var thinking: String? = "low"
        public var temperature: Double?
        public var timeout: TimeInterval = 30

        public init(system: String? = nil, functions: [JSONValue] = [], functionMode: String? = nil,
                    jsonSchema: JSONValue? = nil, thinking: String? = "low", temperature: Double? = nil,
                    timeout: TimeInterval = 30) {
            self.system = system
            self.functions = functions
            self.functionMode = functionMode
            self.jsonSchema = jsonSchema
            self.thinking = thinking
            self.temperature = temperature
            self.timeout = timeout
        }
    }

    public struct FunctionCall: Sendable, Hashable {
        public var id: String?
        public var name: String
        public var args: [String: JSONValue]
    }

    public struct Reply: Sendable {
        /// The model turn as returned (`{"role":"model","parts":[...]}`): append it to the history
        /// before the function responses so thought signatures survive.
        public var content: JSONValue
        public var text: String
        public var calls: [FunctionCall]
        public var finishReason: String?
        public var milliseconds: Int

        /// The text parsed as JSON (for `jsonSchema` requests); strips ``` fences if present.
        public func json() throws -> JSONValue {
            var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("```") {
                s = s.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                if let r = s.range(of: "```", options: .backwards) { s = String(s[..<r.lowerBound]) }
            }
            return try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
        }
    }

    public enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case blocked(String)
        case badReply(String)

        public var errorDescription: String? {
            switch self {
            case .noKey: return "No Gemini API key (set GEMINI_API_KEY in apple/Local.xcconfig)."
            case .http(let code, let msg): return "Gemini HTTP \(code): \(msg)"
            case .blocked(let why): return "Gemini blocked the request: \(why)"
            case .badReply(let why): return "Gemini reply unreadable: \(why)"
            }
        }
    }

    /// One `generateContent` call. `contents` is the whole conversation (user/model turns).
    /// Retries once on 429/5xx/network errors.
    public func generate(model: String = GeminiDirect.fastModel, contents: [JSONValue],
                         options: Options = Options()) async throws -> Reply {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        var body: [String: JSONValue] = ["contents": .array(contents)]
        if let system = options.system {
            body["systemInstruction"] = .object(["parts": .array([GeminiDirect.text(system)])])
        }
        var gen: [String: JSONValue] = [:]
        if let t = options.thinking { gen["thinkingConfig"] = .object(["thinkingLevel": .string(t)]) }
        if let t = options.temperature { gen["temperature"] = .number(t) }
        if !options.functions.isEmpty {
            body["tools"] = .array([.object(["functionDeclarations": .array(options.functions)])])
            if let mode = options.functionMode {
                body["toolConfig"] = .object(["functionCallingConfig": .object(["mode": .string(mode)])])
            }
        } else if let schema = options.jsonSchema {
            gen["responseMimeType"] = .string("application/json")
            gen["responseJsonSchema"] = schema
        }
        if !gen.isEmpty { body["generationConfig"] = .object(gen) }

        var req = URLRequest(url: GeminiDirect.api.appendingPathComponent("models/\(model):generateContent"))
        req.httpMethod = "POST"
        req.timeoutInterval = options.timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let started = Date()
        var lastError: Error = Failure.badReply("no attempt")
        for attempt in 0..<2 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(700)) }
            try Task.checkCancellation()
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    let msg = GeminiDirect.errorMessage(data)
                    lastError = Failure.http(status, msg)
                    if status == 429 || status >= 500 { continue }
                    throw lastError
                }
                return try GeminiDirect.parse(data, ms: Int(Date().timeIntervalSince(started) * 1000))
            } catch let e as Failure {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func errorMessage(_ data: Data) -> String {
        if let v = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let o) = v, case .object(let e)? = o["error"], let m = e["message"]?.stringValue {
            return m
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    static func parse(_ data: Data, ms: Int) throws -> Reply {
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Failure.badReply("not an object")
        }
        guard case .array(let cands)? = root["candidates"], case .object(let cand)? = cands.first else {
            if case .object(let fb)? = root["promptFeedback"], let r = fb["blockReason"]?.stringValue {
                throw Failure.blocked(r)
            }
            throw Failure.badReply("no candidates")
        }
        let content = cand["content"] ?? .object(["role": .string("model"), "parts": .array([])])
        var text = ""
        var calls: [FunctionCall] = []
        if case .object(let c) = content, case .array(let parts)? = c["parts"] {
            for case .object(let p) in parts {
                if p["thought"] == .bool(true) { continue }
                if let t = p["text"]?.stringValue { text += t }
                if case .object(let fc)? = p["functionCall"], let name = fc["name"]?.stringValue {
                    var args: [String: JSONValue] = [:]
                    if case .object(let a)? = fc["args"] { args = a }
                    calls.append(FunctionCall(id: fc["id"]?.stringValue, name: name, args: args))
                }
            }
        }
        return Reply(content: content, text: text, calls: calls,
                     finishReason: cand["finishReason"]?.stringValue, milliseconds: ms)
    }
}
