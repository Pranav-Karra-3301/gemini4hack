import Foundation

/// Any JSON value. Used for tool-call arguments, tool responses and the few
/// open-ended fields in the Core API (e.g. `health.models`, the SSE `hello` payload).
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Converts any `Encodable` value (e.g. `CameraSettings`) into a `JSONValue`.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// The number, or a string that parses as a number (`"0.008"`, `"1/125"`).
    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return JSONValue.parseNumber(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// The string, or a number/bool rendered as text.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// A bool, or `"true"`/`"false"`/`1`/`0`.
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o } else { return nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a } else { return nil }
    }

    public var isNull: Bool { self == .null }

    /// Object member access; `nil` for non-objects and missing keys.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Parses `"0.25"`, `"+1.5"`, `"1/125"` and `"1/125s"`.
    static func parseNumber(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasSuffix("s") { s.removeLast() }
        if let d = Double(s) { return d.isFinite ? d : nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return nil
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}

/// Shared JSON coders for Core payloads. Models use explicit snake_case `CodingKeys`,
/// so plain coders work too; these just sort keys for stable output.
public enum CoachJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    public static var decoder: JSONDecoder { JSONDecoder() }

    /// Parses Core's ISO 8601 timestamps (with or without fractional seconds / offset).
    public static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        // Python's isoformat() without an offset: treat as UTC.
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        g.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            g.dateFormat = fmt
            if let d = g.date(from: string) { return d }
        }
        return nil
    }

    /// Formats a date as ISO 8601 UTC with milliseconds (`2026-11-21T14:30:05.123Z`).
    public static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
