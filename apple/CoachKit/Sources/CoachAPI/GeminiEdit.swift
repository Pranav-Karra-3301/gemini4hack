import CoachModels
import Foundation

/// Photo edits planned by Gemini straight from the device: the photo, the current fader values
/// and (for a spoken request) what the user said → one short spoken line and a list of fader
/// moves, played one after another so the user can follow them.
///
/// Same slider vocabulary as Core's `/edit/suggest` and `/autoedit` (CORE_API.md §4).
public enum GeminiEdit {
    public struct Plan: Sendable, Equatable {
        /// One short line Gemini says out loud.
        public var say: String
        /// Absolute fader targets, in the order to play them.
        public var steps: [EditStep]
        public var milliseconds: Int
    }

    /// - Parameters:
    ///   - jpeg: the photo (≤1024 px is plenty and keeps it fast).
    ///   - values: the faders' current values (missing = neutral).
    ///   - sliders: the faders on screen; Gemini may only move these.
    ///   - request: what the user said ("warmer", "brighter face"); nil = Edit for Me.
    public static func plan(gemini: GeminiDirect, jpeg: Data, values: [Slider: Double], sliders: [Slider],
                            request: String?, model: String) async throws -> Plan {
        let table = sliders.map { s -> String in
            let spec = s.spec
            let now = values[s] ?? spec.neutralValue
            return "- \(s.rawValue): \(meaning(s)) Range \(fmt(spec.range.lowerBound))…\(fmt(spec.range.upperBound)), neutral \(fmt(spec.neutralValue)), now \(fmt(now))."
        }.joined(separator: "\n")
        let ask: String
        if let request, !request.isEmpty {
            ask = """
            The photographer said: "\(request)".
            Make exactly that change with 1–3 fader moves (only the faders it needs), with values big \
            enough to see at a glance. If they ask to undo or reset, move the faders back toward neutral.
            """
        } else {
            ask = """
            Edit this photo the way a skilled photographer would. First look: what is the subject, \
            where is the light coming from, what is wrong with it (too dark, flat, cold, busy \
            background) and what mood it should have. Then fix the light first, then colour, then \
            depth. Use 2–4 fader moves, each one clearly visible but never overcooked; leave a fader \
            alone when the photo doesn't need it.
            """
        }
        let prompt = """
        You edit one photo with physical faders. The faders, what a value actually does to the \
        picture, and their current values:
        \(table)

        \(ask)

        Reply as JSON: "steps" lists the moves in the order to play them, each with the fader name, \
        its new absolute value inside its range, and "why": 2–5 plain words about what you saw \
        (e.g. "face is in shadow", "cold flat daylight"). "say" is one short natural sentence \
        (at most 9 words, warm and plain, no numbers, no fader names) telling the photographer \
        what you did.
        """
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "say": .object(["type": .string("string")]),
                "steps": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "slider": .object(["type": .string("string"),
                                               "enum": .array(sliders.map { .string($0.rawValue) })]),
                            "value": .object(["type": .string("number")]),
                            "why": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("slider"), .string("value"), .string("why")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("say"), .string("steps")]),
        ])
        let reply = try await gemini.generate(
            model: model,
            contents: [GeminiDirect.user([GeminiDirect.image(jpeg), GeminiDirect.text(prompt)])],
            options: .init(jsonSchema: schema, thinking: "low", timeout: 40))
        return try parse(reply.json(), sliders: sliders, ms: reply.milliseconds)
    }

    /// `{"say": "...", "steps": [{"slider": "...", "value": n}]}` → a plan (unknown faders dropped,
    /// values clamped, a fader moved twice keeps its last value).
    public static func parse(_ json: JSONValue, sliders: [Slider], ms: Int = 0) throws -> Plan {
        guard case .object(let o) = json else { throw GeminiDirect.Failure.badReply("not an object") }
        let say = o["say"]?.stringValue ?? ""
        var steps: [EditStep] = []
        if case .array(let arr)? = o["steps"] {
            for case .object(let st) in arr {
                guard let name = st["slider"]?.stringValue, let s = Slider(rawValue: name), sliders.contains(s),
                      case .number(let v)? = st["value"], v.isFinite else { continue }
                let why = (st["why"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                steps.removeAll { $0.slider == s }
                // EditStep clamps to the fader's range; snap to its step so the readout lands clean.
                steps.append(EditStep(slider: s, value: s.spec.snap(s.spec.clamp(v)), why: String(why.prefix(40))))
            }
        }
        return Plan(say: oneLine(say), steps: Array(steps.prefix(5)), milliseconds: ms)
    }

    /// The first sentence of `say`, at most ~14 words (it is spoken aloud).
    static func oneLine(_ say: String) -> String {
        var t = say.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = t.firstIndex(where: { ".!?".contains($0) }) { t = String(t[...end]) }
        let words = t.split(whereSeparator: \.isWhitespace)
        return words.count > 14 ? words.prefix(14).joined(separator: " ") : t
    }

    /// What a value really does in CoachEdit's renderer (EditRenderer / EditLayers), so Gemini
    /// picks values that are visible but tasteful.
    static func meaning(_ s: Slider) -> String {
        switch s {
        case .exposure: return "Overall brightness in stops (EV). ±0.2 is subtle, ±0.4 clearly brighter/darker, beyond ±0.8 is heavy."
        case .contrast: return "Tone-curve contrast. +10…+25 adds tasteful punch, −10…−20 softens; beyond ±40 looks harsh."
        case .highlights: return "Bright areas; negative recovers skies and hot spots (−20…−50 typical)."
        case .shadows: return "Lifts dark areas only (gentle in this renderer): under +15 is barely visible, +20…+45 opens faces and shade clearly, above +60 looks flat."
        case .whites: return "White point."
        case .blacks: return "Black point."
        case .warmth: return "White balance, positive warmer/golden, negative cooler/bluer. Gentle in this renderer: under ±10 is invisible, ±18…±35 reads clearly, beyond ±55 is a strong colour cast."
        case .tint: return "Green (negative) to magenta (positive)."
        case .vibrance: return "Richer muted colours, protects skin. +15…+35 is visible but natural; beyond +50 looks artificial; negative quietens colour."
        case .saturation: return "Colour saturation."
        case .clarity: return "Midtone crispness."
        case .vignette: return "Edge darkening (negative darker edges)."
        case .subjectLight: return "Brightness of the main subject or face."
        case .backgroundLight: return "Brightness of the background."
        case .depthBlur: return "Blurs the background by measured depth, keeping the nearest subject sharp. +20…+45 gives a clear portrait look; beyond +60 looks fake. Use it only when there is a clear subject in front of a busy background."
        case .focusDepth: return "Focus distance for the blur."
        }
    }

    public static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
