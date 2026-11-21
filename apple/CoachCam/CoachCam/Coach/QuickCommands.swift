import CoachModels
import Foundation

/// Instant voice commands for the live camera: "make it darker", "zoom in", "two x", "warmer",
/// "portrait mode", "take it". Matched on the PARTIAL transcript, so the dials move while the
/// user is still talking (no Gemini round trip). Gemini 4 still hears the sentence afterwards
/// unless the command covered it.
struct QuickCommands {
    /// Current camera values the relative moves start from.
    struct Camera {
        var ev: Double
        var zoom: Double
        var wbKelvin: Double
    }

    enum Action {
        case set(CameraSettings, ack: String, hint: String)
        case takePhoto
    }

    /// Keys already applied in this utterance, with how many times each phrase was matched.
    private var applied: [String: Int] = [:]
    /// Values this utterance already set (the camera snapshot can lag behind the dials).
    private var carried: Camera?

    mutating func reset() { applied = [:]; carried = nil }

    /// True when every word of `text` is part of a command we handled (no need to ask Gemini).
    func covers(_ text: String) -> Bool {
        guard !applied.isEmpty else { return false }
        let words = Self.normalize(text).split(separator: " ")
        return words.count <= 5
    }

    /// New actions for this partial transcript (each phrase fires once per occurrence).
    mutating func actions(for partial: String, camera: Camera) -> [Action] {
        let text = Self.normalize(partial)
        var out: [Action] = []
        var cam = carried ?? camera
        for rule in Self.rules {
            let n = rule.count(text)
            let done = applied[rule.key] ?? 0
            guard n > done else { continue }
            applied[rule.key] = n
            for _ in done..<n {
                guard let a = rule.make(text, cam) else { continue }
                if case .set(let s, _, _) = a {
                    if let ev = s.ev { cam.ev = ev }
                    if let z = s.zoom { cam.zoom = z }
                    if case .value(let k)? = s.wbKelvin { cam.wbKelvin = k }
                }
                out.append(a)
            }
        }
        if !out.isEmpty { carried = cam }
        return out
    }

    // MARK: Rules

    private struct Rule {
        var key: String
        var pattern: NSRegularExpression
        var make: (String, Camera) -> Action?

        func count(_ text: String) -> Int {
            pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
    }

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static let evStep = 0.7
    static let zoomStep = 1.6

    private static let rules: [Rule] = [
        Rule(key: "darker", pattern: re(#"\b(darker|too bright|less bright|dimmer|darken|underexpose|tone it down)\b"#)) { _, c in
            .set(CameraSettings(ev: max(-3, c.ev - evStep), why: "user: darker"), ack: "Darker.", hint: "Darker")
        },
        Rule(key: "brighter", pattern: re(#"\b(brighter|lighter|too dark|more light|brighten|overexpose|lift it)\b"#)) { _, c in
            .set(CameraSettings(ev: min(3, c.ev + evStep), why: "user: brighter"), ack: "Brighter.", hint: "Brighter")
        },
        Rule(key: "zoomTo", pattern: re(#"\b(?:zoom (?:to |at )?|go (?:to )?)?(0\.5|point five|half|1|one|2|two|3|three|5|five|10|ten) ?(?:x|times)\b"#)) { text, _ in
            guard let z = zoomValue(text) else { return nil }
            return .set(CameraSettings(zoom: z, why: "user: zoom \(z)x"), ack: "Got it.", hint: "Zoom \(fmt(z))×")
        },
        Rule(key: "zoomIn", pattern: re(#"\b(zoom in|zoom closer|punch in|tighter|zoom it in)\b"#)) { _, c in
            let z = min(10, c.zoom * zoomStep)
            return .set(CameraSettings(zoom: z, why: "user: zoom in"), ack: "Zooming in.", hint: "Zoom \(fmt(z))×")
        },
        Rule(key: "zoomOut", pattern: re(#"\b(zoom out|wider|go wide|zoom it out|pull back)\b"#)) { _, c in
            let z = max(0.5, c.zoom / zoomStep)
            return .set(CameraSettings(zoom: z, why: "user: zoom out"), ack: "Zooming out.", hint: "Zoom \(fmt(z))×")
        },
        Rule(key: "warmer", pattern: re(#"\b(warmer|warm it up|too blue|too cold)\b"#)) { _, c in
            .set(CameraSettings(wbKelvin: .value(min(9000, c.wbKelvin + 800)), why: "user: warmer"), ack: "Warmer.", hint: "Warmer")
        },
        Rule(key: "cooler", pattern: re(#"\b(cooler|colder|too warm|too orange|too yellow)\b"#)) { _, c in
            .set(CameraSettings(wbKelvin: .value(max(2500, c.wbKelvin - 800)), why: "user: cooler"), ack: "Cooler.", hint: "Cooler")
        },
        Rule(key: "portrait", pattern: re(#"\bportrait mode\b|\bswitch to portrait\b"#)) { _, _ in
            .set(CameraSettings(mode: .portrait, why: "user: portrait"), ack: "Got it.", hint: "Portrait")
        },
        Rule(key: "photo", pattern: re(#"\bphoto mode\b|\bnormal mode\b|\bswitch to photo\b"#)) { _, _ in
            .set(CameraSettings(mode: .photo, why: "user: photo mode"), ack: "Got it.", hint: "Photo")
        },
        Rule(key: "night", pattern: re(#"\bnight mode\b"#)) { _, _ in
            .set(CameraSettings(mode: .night, why: "user: night"), ack: "Got it.", hint: "Night")
        },
        Rule(key: "take", pattern: re(#"\b(take it|take the (?:photo|picture|shot)|take a (?:photo|picture)|snap it|shoot it)\b"#)) { _, _ in
            .takePhoto
        },
    ]

    private static func zoomValue(_ text: String) -> Double? {
        let words: [String: Double] = ["0.5": 0.5, "point five": 0.5, "half": 0.5, "1": 1, "one": 1, "2": 2, "two": 2,
                                       "3": 3, "three": 3, "5": 5, "five": 5, "10": 10, "ten": 10]
        let m = re(#"(0\.5|point five|half|10|ten|1|one|2|two|3|three|5|five) ?(?:x|times)\b"#)
        let ns = text as NSString
        guard let last = m.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return words[ns.substring(with: last.range(at: 1)).lowercased()]
    }

    private static func fmt(_ z: Double) -> String {
        z == z.rounded() ? String(Int(z)) : String(format: "%.1f", z)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9.' ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
