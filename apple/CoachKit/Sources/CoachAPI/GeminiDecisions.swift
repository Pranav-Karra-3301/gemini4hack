import CoachModels
import Foundation

/// Gemini Decision 1 (`POST /v1beta/decisions`) straight from the device: one image (+ optional
/// voice clip) in, probabilities for a few multiple-choice questions out, in ~0.8 s. Fast enough
/// to run between the slower Gemini 4 agent steps.
///
/// Ask every question about the same input in ONE call: the input is billed once per request.
/// Port of `server/gemini.py decisions()`; questions in the same shape as `server/cam.py`
/// `DECIDE_QUESTIONS`: `{"name": {"type": "choice", "instructions": "...", "criteria": {"option": "when"}}}`.
public extension GeminiDirect {
    static let decisionModel = "gemini-decision-1"

    /// One choice question.
    struct Choice: Sendable {
        public var instructions: String
        /// option → when to pick it.
        public var criteria: [String: String]
        public init(instructions: String, criteria: [String: String]) {
            self.instructions = instructions
            self.criteria = criteria
        }
        var json: JSONValue {
            .object([
                "type": .string("choice"),
                "instructions": .string(instructions),
                "criteria": .object(criteria.mapValues { .string($0) }),
            ])
        }
    }

    /// Answers: question → option → probability (0...1). `raw` keeps the whole response.
    struct Decision: Sendable {
        public var probabilities: [String: [String: Double]]
        public var raw: JSONValue
        public var milliseconds: Int

        /// The most likely option for `question`, and its probability.
        public func top(_ question: String) -> (option: String, p: Double)? {
            guard let probs = probabilities[question], let best = probs.max(by: { $0.value < $1.value }) else {
                return nil
            }
            return (best.key, best.value)
        }
    }

    /// Input items for `decide`.
    static func decisionText(_ s: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(s)])
    }

    static func decisionImage(_ jpeg: Data, resolution: String = "low") -> JSONValue {
        .object([
            "type": .string("image"), "data": .string(jpeg.base64EncodedString()),
            "mime_type": .string("image/jpeg"), "resolution": .string(resolution),
        ])
    }

    /// `wav`: 16-bit PCM WAV, keep it to the last ~6 s.
    static func decisionAudio(_ wav: Data) -> JSONValue {
        .object(["type": .string("audio"), "data": .string(wav.base64EncodedString()), "mime_type": .string("audio/wav")])
    }

    func decide(input: [JSONValue], questions: [String: Choice], timeout: TimeInterval = 6) async throws -> Decision {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        let body: JSONValue = .object([
            "model": .string(GeminiDirect.decisionModel),
            "input": .array(input),
            "questions": .object(questions.mapValues(\.json)),
        ])
        var req = URLRequest(url: GeminiDirect.api.appendingPathComponent("decisions"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONEncoder().encode(body)

        let started = Date()
        var lastError: Error = Failure.badReply("no attempt")
        for attempt in 0..<2 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(400)) }
            try Task.checkCancellation()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                lastError = Failure.http(status, GeminiDirect.errorMessage(data))
                if status == 429 || status >= 500 { continue }
                throw lastError
            }
            let root = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let o) = root, case .object(let answers)? = o["answers"] else {
                throw Failure.badReply("decisions returned no answers")
            }
            var probs: [String: [String: Double]] = [:]
            for (q, a) in answers {
                guard case .object(let ans) = a else { continue }
                if case .object(let p)? = ans["probabilities"] {
                    probs[q] = p.compactMapValues(\.doubleValue)
                }
            }
            return Decision(probabilities: probs, raw: root, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        }
        throw lastError
    }
}
