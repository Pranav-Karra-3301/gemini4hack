import CoachModels
import Foundation

extension GeminiDirect {
    /// `streamGenerateContent?alt=sse`: the same body as `generate`, but yields the reply's text
    /// as it arrives (thought parts skipped). Throws on a non-200 reply or a blocked prompt.
    public func stream(model: String = GeminiDirect.strongModel, contents: [JSONValue],
                       options: Options = Options()) -> AsyncThrowingStream<String, Error> {
        let key = apiKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !key.isEmpty else { throw Failure.noKey }
                    var body: [String: JSONValue] = ["contents": .array(contents)]
                    if let system = options.system {
                        body["systemInstruction"] = .object(["parts": .array([GeminiDirect.text(system)])])
                    }
                    var gen: [String: JSONValue] = [:]
                    if let t = options.thinking { gen["thinkingConfig"] = .object(["thinkingLevel": .string(t)]) }
                    if let t = options.temperature { gen["temperature"] = .number(t) }
                    if !gen.isEmpty { body["generationConfig"] = .object(gen) }

                    var comps = URLComponents(url: GeminiDirect.api.appendingPathComponent("models/\(model):streamGenerateContent"),
                                              resolvingAgainstBaseURL: false)!
                    comps.queryItems = [URLQueryItem(name: "alt", value: "sse")]
                    var req = URLRequest(url: comps.url!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = options.timeout
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    req.httpBody = try JSONEncoder().encode(JSONValue.object(body))

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 4096 { break } }
                        throw Failure.http(status, GeminiDirect.errorMessage(data))
                    }
                    var parser = SSEParser()
                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(512)
                    func drain(_ items: [SSEItem]) throws {
                        for case .event(let e) in items {
                            for t in try GeminiDirect.streamTexts(e.data) { continuation.yield(t) }
                        }
                    }
                    for try await b in bytes {
                        chunk.append(b)
                        if b == 0x0A { try drain(parser.feed(chunk)); chunk.removeAll(keepingCapacity: true) }
                    }
                    chunk.append(contentsOf: Array("\n\n".utf8))
                    try drain(parser.feed(chunk))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The non-thought text parts of one SSE `data:` payload.
    static func streamTexts(_ payload: String) throws -> [String] {
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "[DONE]",
              case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else { return [] }
        if case .object(let e)? = root["error"] {
            throw Failure.badReply(e["message"]?.stringValue ?? "stream error")
        }
        guard case .array(let cands)? = root["candidates"], case .object(let cand)? = cands.first else {
            if case .object(let fb)? = root["promptFeedback"], let r = fb["blockReason"]?.stringValue {
                throw Failure.blocked(r)
            }
            return []
        }
        guard case .object(let c)? = cand["content"], case .array(let parts)? = c["parts"] else { return [] }
        var out: [String] = []
        for case .object(let p) in parts {
            if p["thought"] == .bool(true) { continue }
            if let t = p["text"]?.stringValue, !t.isEmpty { out.append(t) }
        }
        return out
    }
}
