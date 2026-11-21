import Foundation

// MARK: - Gemini function calls and responses

/// A function call from Gemini: an entry of Live `toolCall.functionCalls`, or a
/// `generateContent` `functionCall` part. `args` may be absent (decodes as empty).
public struct FunctionCall: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var args: [String: JSONValue]

    public init(id: String? = nil, name: String, args: [String: JSONValue] = [:]) {
        self.id = id; self.name = name; self.args = args
    }

    enum CodingKeys: String, CodingKey { case id, name, args }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        args = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .args)) ?? [:]
    }
}

/// When Gemini should react to a tool response (Live API `FunctionResponseScheduling`).
public enum ToolScheduling: String, Codable, Hashable, Sendable {
    /// Absorb the result without speaking (default for UI tools).
    case silent = "SILENT"
    /// Comment on the result once the model is idle.
    case whenIdle = "WHEN_IDLE"
    /// Interrupt and react now.
    case interrupt = "INTERRUPT"
}

/// One entry of `toolResponse.functionResponses`.
public struct FunctionResponse: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var response: JSONValue
    public var scheduling: ToolScheduling?

    public init(id: String?, name: String, response: JSONValue, scheduling: ToolScheduling? = .silent) {
        self.id = id; self.name = name; self.response = response; self.scheduling = scheduling
    }

    /// `{"ok": true, "applied": …}` for `call`.
    public static func ok(_ call: FunctionCall, applied: JSONValue? = nil,
                          scheduling: ToolScheduling = .silent) -> FunctionResponse {
        var body: [String: JSONValue] = ["ok": true]
        if let applied { body["applied"] = applied }
        return FunctionResponse(id: call.id, name: call.name, response: .object(body), scheduling: scheduling)
    }

    /// `{"ok": false, "error": …}` for `call`. Uses `WHEN_IDLE` so the coach can recover.
    public static func failure(_ call: FunctionCall, error: String,
                               scheduling: ToolScheduling = .whenIdle) -> FunctionResponse {
        FunctionResponse(id: call.id, name: call.name, response: ["ok": false, "error": .string(error)],
                         scheduling: scheduling)
    }
}

// MARK: - Value types used by the tools

/// A number that may also be `"auto"` (ISO, shutter, focus, white balance).
public enum AutoNumber: Codable, Hashable, Sendable {
    case auto
    case value(Double)

    /// `"auto"` → `.auto`; numbers and numeric strings (`"0.008"`, `"1/125"`) → `.value`.
    public init?(json: JSONValue) {
        if case .string(let s) = json, s.trimmingCharacters(in: .whitespaces).lowercased() == "auto" {
            self = .auto
        } else if let d = json.doubleValue, d.isFinite {
            self = .value(d)
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let v = AutoNumber(json: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Expected a number or \"auto\""))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .value(let d): try c.encode(d)
        }
    }

    public var isAuto: Bool { self == .auto }
    /// The number, or nil for `.auto`.
    public var number: Double? { if case .value(let d) = self { return d } else { return nil } }

    /// Clamps a number into `range`; `.auto` stays `.auto`.
    public func clamped(to range: ClosedRange<Double>) -> AutoNumber {
        guard case .value(let d) = self else { return self }
        return .value(min(max(d, range.lowerBound), range.upperBound))
    }
}

/// Lenient enum parsing shared by the tool enums: case-insensitive, `-`/space → `_`, aliases.
protocol LenientName: RawRepresentable, CaseIterable where RawValue == String {
    static var aliases: [String: Self] { get }
}

extension LenientName {
    static var aliases: [String: Self] { [:] }
    init?(lenient raw: String?) {
        guard let raw else { return nil }
        let k = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if let v = Self(rawValue: k) ?? Self.aliases[k] { self = v } else { return nil }
    }
}

/// `guide.direction`: a camera move in the raw (unmirrored) frame.
public enum GuideDirection: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case left, right, up, down, closer, back
    case rotateLeft = "rotate_left"
    case rotateRight = "rotate_right"
    case hold
    static var aliases: [String: GuideDirection] {
        ["forward": .closer, "in": .closer, "backward": .back, "backwards": .back, "away": .back,
         "further": .back, "stay": .hold, "still": .hold, "ccw": .rotateLeft, "cw": .rotateRight]
    }
}

/// `guide.strength`.
public enum GuideStrength: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case small, medium, large
}

/// `set_camera.mode`.
public enum CaptureMode: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case photo, portrait, night, macro
}

/// `set_camera.lens`.
public enum CameraLens: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case ultrawide, wide, tele
    static var aliases: [String: CameraLens] {
        ["ultra_wide": .ultrawide, "0.5x": .ultrawide, "telephoto": .tele, "1x": .wide, "main": .wide]
    }
}

/// `set_camera.flash`.
public enum FlashMode: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case off, on, auto
    static var aliases: [String: FlashMode] { ["true": .on, "false": .off] }
}

/// `set_intent.intent`.
public enum ShotIntent: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case portrait, group, landscape, object, food, street, document, other
}

/// `user_reaction.reaction`.
public enum UserReaction: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case pleased, disappointed, neutral
}

/// `compare.show`.
public enum CompareSide: String, Codable, CaseIterable, Hashable, Sendable, LenientName {
    case before, after
    static var aliases: [String: CompareSide] { ["original": .before, "edited": .after] }
}

// MARK: - Camera settings

/// `set_camera` arguments, and what the camera actually applied (encode it into the tool response).
/// Every field is optional: only the fields Gemini sent are changed.
public struct CameraSettings: Codable, Hashable, Sendable {
    public var mode: CaptureMode?
    public var lens: CameraLens?
    /// Device zoom factor, 0.5–10.
    public var zoom: Double?
    public var iso: AutoNumber?
    /// Seconds (0.008 = 1/125 s).
    public var shutter: AutoNumber?
    /// −3..3.
    public var ev: Double?
    /// Lens position 0..1.
    public var focus: AutoNumber?
    /// Point of interest in the raw frame, 0..1.
    public var focusX: Double?
    public var focusY: Double?
    /// 2500–9000 K.
    public var wbKelvin: AutoNumber?
    /// −50..50.
    public var tint: Double?
    public var flash: FlashMode?
    public var torch: Bool?
    /// Short reason (≤ 8 words) to show next to the dial.
    public var why: String?
    /// Argument names that were present but unusable (not encoded). Report them back to Gemini.
    public var ignored: [String] = []

    public init(mode: CaptureMode? = nil, lens: CameraLens? = nil, zoom: Double? = nil, iso: AutoNumber? = nil,
                shutter: AutoNumber? = nil, ev: Double? = nil, focus: AutoNumber? = nil, focusX: Double? = nil,
                focusY: Double? = nil, wbKelvin: AutoNumber? = nil, tint: Double? = nil, flash: FlashMode? = nil,
                torch: Bool? = nil, why: String? = nil) {
        self.mode = mode; self.lens = lens; self.zoom = zoom; self.iso = iso; self.shutter = shutter
        self.ev = ev; self.focus = focus; self.focusX = focusX; self.focusY = focusY; self.wbKelvin = wbKelvin
        self.tint = tint; self.flash = flash; self.torch = torch; self.why = why
    }

    /// Ranges from CORE_API.md. ISO and shutter limits come from the device (pass them to `clamped`).
    public enum Limits {
        public static let zoom: ClosedRange<Double> = 0.5...10
        public static let ev: ClosedRange<Double> = -3...3
        public static let focus: ClosedRange<Double> = 0...1
        public static let point: ClosedRange<Double> = 0...1
        public static let wbKelvin: ClosedRange<Double> = 2500...9000
        public static let tint: ClosedRange<Double> = -50...50
    }

    /// Parses `set_camera` args leniently; unusable fields land in `ignored`.
    public init(args: [String: JSONValue]) {
        let a = ToolArgs(args)
        self.init()
        mode = a.parse("mode", CaptureMode.init(lenient:), &ignored)
        lens = a.parse("lens", CameraLens.init(lenient:), &ignored)
        zoom = a.number("zoom", &ignored)
        iso = a.auto("iso", &ignored)
        shutter = a.auto("shutter", &ignored)
        ev = a.number("ev", &ignored)
        focus = a.auto("focus", &ignored)
        focusX = a.number("focus_x", &ignored)
        focusY = a.number("focus_y", &ignored)
        wbKelvin = a.auto("wb_kelvin", &ignored)
        tint = a.number("tint", &ignored)
        if let f = a["flash"] {
            if let m = FlashMode(lenient: f.stringValue) { flash = m }
            else if let b = f.boolValue { flash = b ? .on : .off } else { ignored.append("flash") }
        }
        if let t = a["torch"] {
            if let b = t.boolValue { torch = b } else { ignored.append("torch") }
        }
        why = a.string("why")
        let known: Set<String> = ["mode", "lens", "zoom", "iso", "shutter", "ev", "focus", "focus_x", "focus_y",
                                  "wb_kelvin", "tint", "flash", "torch", "why"]
        ignored += args.keys.filter { !known.contains($0) }.sorted()
    }

    /// Clamps every field to the documented ranges (and the device's ISO / shutter / zoom ranges if given).
    public func clamped(iso isoRange: ClosedRange<Double>? = nil, shutter shutterRange: ClosedRange<Double>? = nil,
                        zoom zoomRange: ClosedRange<Double>? = nil) -> CameraSettings {
        func c(_ v: Double?, _ r: ClosedRange<Double>) -> Double? { v.map { min(max($0, r.lowerBound), r.upperBound) } }
        var s = self
        s.zoom = c(zoom, zoomRange ?? Limits.zoom)
        s.ev = c(ev, Limits.ev)
        s.focus = focus?.clamped(to: Limits.focus)
        s.focusX = c(focusX, Limits.point)
        s.focusY = c(focusY, Limits.point)
        s.wbKelvin = wbKelvin?.clamped(to: Limits.wbKelvin)
        s.tint = c(tint, Limits.tint)
        if let isoRange { s.iso = iso?.clamped(to: isoRange) }
        if let shutterRange { s.shutter = shutter?.clamped(to: shutterRange) }
        return s
    }

    /// True when no setting would change (only `why` or nothing).
    public var isEmpty: Bool {
        mode == nil && lens == nil && zoom == nil && iso == nil && shutter == nil && ev == nil && focus == nil
            && focusX == nil && focusY == nil && wbKelvin == nil && tint == nil && flash == nil && torch == nil
    }

    enum CodingKeys: String, CodingKey {
        case mode, lens, zoom, iso, shutter, ev, focus, tint, flash, torch, why
        case focusX = "focus_x", focusY = "focus_y", wbKelvin = "wb_kelvin"
    }
}

// MARK: - Typed tools

/// Camera-mode tools (CORE_API.md §2, `mode: camera`).
public enum CameraTool: Hashable, Sendable {
    /// Big arrow in the viewfinder.
    case guide(direction: GuideDirection, strength: GuideStrength)
    /// Apply with AVFoundation, animate the matching dials, answer with the clamped values applied.
    case setCamera(CameraSettings)
    case setIntent(intent: ShotIntent, subject: String?)
    case userReaction(reaction: UserReaction, heard: String?)
    /// Shutter glow on/off.
    case shotReady(Bool)
    /// Capture and sync to the Mac.
    case takePhoto(reason: String?)

    public static let names: Set<String> = ["guide", "set_camera", "set_intent", "user_reaction", "shot_ready", "take_photo"]

    /// Nil if `call` isn't a camera tool or a required argument is unusable.
    public init?(_ call: FunctionCall) {
        let a = ToolArgs(call.args)
        switch call.name {
        case "guide":
            guard let d = GuideDirection(lenient: a.string("direction")) else { return nil }
            self = .guide(direction: d, strength: GuideStrength(lenient: a.string("strength")) ?? .medium)
        case "set_camera":
            self = .setCamera(CameraSettings(args: call.args))
        case "set_intent":
            self = .setIntent(intent: ShotIntent(lenient: a.string("intent")) ?? .other, subject: a.string("subject"))
        case "user_reaction":
            self = .userReaction(reaction: UserReaction(lenient: a.string("reaction")) ?? .neutral, heard: a.string("heard"))
        case "shot_ready":
            self = .shotReady(a["ready"]?.boolValue ?? true)
        case "take_photo":
            self = .takePhoto(reason: a.string("reason"))
        default:
            return nil
        }
    }
}

/// Edit-mode tools (CORE_API.md §2, `mode: edit`).
public enum EditTool: Hashable, Sendable {
    /// Animate one slider to `value` (~600 ms), caption `why`, highlight `region`; answer when done.
    case editStep(EditStep)
    /// Apply several sliders at once (animated). Values are clamped; nulls and unknown names dropped.
    case setSliders(values: [Slider: Double], why: String?)
    /// Highlight a region mask (nil clears).
    case selectRegion(String?)
    case compare(CompareSide)
    case reset
    /// `PUT /api/shots/{id}/edit`.
    case saveEdit

    public static let names: Set<String> = ["edit_step", "set_sliders", "select_region", "compare", "reset", "save_edit"]

    /// Nil if `call` isn't an edit tool or a required argument is unusable.
    public init?(_ call: FunctionCall) {
        let a = ToolArgs(call.args)
        switch call.name {
        case "edit_step":
            guard let slider = a.string("slider").flatMap(Slider.init(name:)) else { return nil }
            let raw = a["value"]
            let value = raw?.doubleValue
            // A missing/unparseable value is only meaningful for focus_depth (null = auto).
            if value == nil && slider != .focusDepth { return nil }
            self = .editStep(EditStep(slider: slider, value: value, why: a.string("why") ?? "",
                                      region: a.regionId("region")))
        case "set_sliders":
            var raw = a["values"]
            if case .string(let s)? = raw, let d = s.data(using: .utf8) {   // stringified object
                raw = try? JSONDecoder().decode(JSONValue.self, from: d)
            }
            guard let obj = raw?.objectValue else { return nil }
            self = .setSliders(values: SliderValues.clamped(SliderValues.parse(obj)), why: a.string("why"))
        case "select_region":
            self = .selectRegion(a.regionId("region"))
        case "compare":
            if let side = CompareSide(lenient: a.string("show")) { self = .compare(side) }
            else if let b = a["show"]?.boolValue { self = .compare(b ? .before : .after) }
            else { self = .compare(.before) }
        case "reset":
            self = .reset
        case "save_edit":
            self = .saveEdit
        default:
            return nil
        }
    }
}

/// Any coach tool call: typed when recognized, otherwise the raw call.
public enum CoachTool: Hashable, Sendable {
    case camera(CameraTool)
    case edit(EditTool)
    /// Unknown tool or unusable arguments: answer with `FunctionResponse.failure`.
    case unknown(FunctionCall)

    public init(_ call: FunctionCall) {
        if let t = CameraTool(call) { self = .camera(t) }
        else if let t = EditTool(call) { self = .edit(t) }
        else { self = .unknown(call) }
    }
}

// MARK: - Argument helpers

/// Lenient accessors over a function call's `args`.
struct ToolArgs {
    let args: [String: JSONValue]
    init(_ args: [String: JSONValue]) { self.args = args }

    /// The value, treating JSON null as absent.
    subscript(key: String) -> JSONValue? {
        guard let v = args[key], !v.isNull else { return nil }
        return v
    }

    func string(_ key: String) -> String? {
        guard let s = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Region ids: null, "", "none" and "null" mean no region.
    func regionId(_ key: String) -> String? {
        guard let s = string(key), !["none", "null", "nil"].contains(s.lowercased()) else { return nil }
        return s
    }

    func number(_ key: String, _ ignored: inout [String]) -> Double? {
        guard let v = self[key] else { return nil }
        if let d = v.doubleValue, d.isFinite { return d }
        ignored.append(key)
        return nil
    }

    func auto(_ key: String, _ ignored: inout [String]) -> AutoNumber? {
        guard let v = self[key] else { return nil }
        if let a = AutoNumber(json: v) { return a }
        ignored.append(key)
        return nil
    }

    func parse<T>(_ key: String, _ make: (String?) -> T?, _ ignored: inout [String]) -> T? {
        guard let v = self[key] else { return nil }
        if let t = make(v.stringValue) { return t }
        ignored.append(key)
        return nil
    }
}
