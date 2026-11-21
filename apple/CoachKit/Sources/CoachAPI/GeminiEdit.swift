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
            return "- \(s.rawValue): \(meaning(s)); range \(fmt(spec.range.lowerBound))…\(fmt(spec.range.upperBound)), neutral \(fmt(spec.neutralValue)), now \(fmt(now))"
        }.joined(separator: "\n")
        let ask: String
        if let request, !request.isEmpty {
            ask = """
            The photographer said: "\(request)".
            Make exactly that change with 1–3 fader moves (only the faders it needs). If they ask to \
            undo or reset, move the faders back toward neutral.
            """
        } else {
            ask = """
            Edit this photo the way a careful photographer would: fix the light first, then colour, \
            then depth. 2–5 fader moves, natural and subtle rather than heavy.
            """
        }
        let prompt = """
        You edit one photo with physical faders. The faders, with their current values:
        \(table)

        \(ask)

        Reply as JSON: "steps" lists the moves in the order to play them, each with the fader name \
        and its new absolute value inside its range. "say" is one short spoken line (at most 8 \
        words, warm and plain, no numbers, no fader names) telling the photographer what you did.
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
                        ]),
                        "required": .array([.string("slider"), .string("value")]),
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
                      case .number(let v)? = st["value"] else { continue }
                steps.removeAll { $0.slider == s }
                steps.append(EditStep(slider: s, value: v))
            }
        }
        return Plan(say: say, steps: steps, milliseconds: ms)
    }

    static func meaning(_ s: Slider) -> String {
        switch s {
        case .exposure: return "overall brightness in stops"
        case .contrast: return "contrast"
        case .highlights: return "bright areas (negative recovers them)"
        case .shadows: return "dark areas (positive lifts them)"
        case .whites: return "white point"
        case .blacks: return "black point"
        case .warmth: return "colour temperature (positive warmer)"
        case .tint: return "green (negative) to magenta (positive)"
        case .vibrance: return "gentle colour richness"
        case .saturation: return "colour saturation"
        case .clarity: return "midtone crispness"
        case .vignette: return "edge darkening (negative darker edges)"
        case .subjectLight: return "brightness of the main subject or face"
        case .backgroundLight: return "brightness of the background"
        case .depthBlur: return "background blur by depth"
        case .focusDepth: return "focus distance for the blur"
        }
    }

    public static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
