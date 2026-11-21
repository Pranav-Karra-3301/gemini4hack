import CoachModels
import Foundation

/// Gemini text-to-speech straight from the device (`responseModalities: ["AUDIO"]`).
/// Server reference: `server/gemini.py` `tts()`.
extension GeminiDirect {
    /// The natural-sounding TTS model for the live coach's voice.
    public static let voiceModel = "gemini-3.8-flash-tts"
    /// Used when `voiceModel` errors.
    public static let voiceFallbackModel = GeminiDirect.ttsModel

    /// Speech for `text` as WAV bytes (the API answers 24 kHz mono PCM16, as WAV or raw PCM;
    /// raw PCM is wrapped). Put any style tag inside `text`, e.g. "[warm, calm] Take a step back.":
    /// these models read a "Say ...:" preamble out loud and reject a system instruction.
    public func speech(_ text: String, voice: String, model: String = GeminiDirect.voiceModel,
                       timeout: TimeInterval = 10) async throws -> Data {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        let body: JSONValue = .object([
            "contents": .array([GeminiDirect.user([GeminiDirect.text(text)])]),
            "generationConfig": .object([
                "responseModalities": .array([.string("AUDIO")]),
                "speechConfig": .object([
                    "voiceConfig": .object(["prebuiltVoiceConfig": .object(["voiceName": .string(voice)])]),
                ]),
            ]),
        ])
        var req = URLRequest(url: GeminiDirect.api.appendingPathComponent("models/\(model):generateContent"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let inline = parts.lazy.compactMap({ $0["inlineData"] as? [String: Any] }).first,
              let b64 = inline["data"] as? String, let audio = Data(base64Encoded: b64), !audio.isEmpty
        else { throw Failure.badReply("no audio in TTS reply (\(model))") }
        if audio.prefix(4) == Data("RIFF".utf8) { return audio }
        var rate = 24000
        for piece in String(describing: inline["mimeType"] ?? "").split(separator: ";") {
            let kv = piece.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("rate="), let r = Int(kv.dropFirst(5)) { rate = r }
        }
        return Self.wav(pcm16: audio, rate: rate)
    }

    /// Mono PCM16 little-endian wrapped in a 44-byte WAV header.
    public static func wav(pcm16 pcm: Data, rate: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le32(UInt32(36 + pcm.count))
        d += Data("WAVEfmt ".utf8)
        d += le32(16) + le16(1) + le16(1)
        d += le32(UInt32(rate)) + le32(UInt32(rate * 2)) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(UInt32(pcm.count))
        d += pcm
        return d
    }
}
