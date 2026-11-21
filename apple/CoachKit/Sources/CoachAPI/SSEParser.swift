import Foundation
import CoachModels

/// One server-sent event.
public struct SSEEvent: Hashable, Sendable {
    /// `event:` field, `"message"` when absent.
    public var event: String
    /// `data:` lines joined with `\n`.
    public var data: String
    public var id: String?
}

/// What the parser emits: dispatched events and comment lines (Core sends `: ping`).
public enum SSEItem: Hashable, Sendable {
    case event(SSEEvent)
    case comment(String)
}

/// Incremental Server-Sent Events parser (WHATWG rules). Feed it bytes in any chunking,
/// including splits inside a line, inside a UTF-8 character, or between `\r` and `\n`.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var sawFirstLine = false
    private var eventName = ""
    private var dataLines: [String] = []
    private var hasData = false
    private var lastId: String?
    /// The last `retry:` value in milliseconds, if the server sent one.
    public private(set) var retryMs: Int?

    public init() {}

    /// Feeds raw bytes and returns any items completed by them.
    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEItem] where S.Element == UInt8 {
        var out: [SSEItem] = []
        for b in bytes {
            switch b {
            case 0x0A:  // LF
                if lastWasCR { lastWasCR = false; continue }
                endLine(&out)
            case 0x0D:  // CR
                endLine(&out)
                lastWasCR = true
            default:
                lastWasCR = false
                line.append(b)
            }
        }
        return out
    }

    /// Convenience for text chunks.
    public mutating func feed(_ text: String) -> [SSEItem] { feed(Array(text.utf8)) }

    /// Forget any partial event (call when reconnecting).
    public mutating func reset() {
        let retry = retryMs
        self = SSEParser()
        retryMs = retry
    }

    private mutating func endLine(_ out: inout [SSEItem]) {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if !sawFirstLine {
            sawFirstLine = true
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }  // BOM
        }
        if bytes.isEmpty {
            if hasData {
                out.append(.event(SSEEvent(event: eventName.isEmpty ? "message" : eventName,
                                           data: dataLines.joined(separator: "\n"), id: lastId)))
            }
            eventName = ""; dataLines = []; hasData = false
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix(":") {
            out.append(.comment(String(text.dropFirst()).trimmingCharacters(in: .whitespaces)))
            return
        }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text); value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value)); hasData = true
        case "id": if !value.contains("\0") { lastId = String(value) }
        case "retry": if let ms = Int(value) { retryMs = ms }
        default: break
        }
    }
}

extension ShotEvent {
    /// Maps a Core SSE item to a `ShotEvent` (`hello`, `shot`, `shot_deleted`, `: ping`).
    /// A `shot` whose JSON doesn't decode becomes `.other` instead of failing the stream.
    public init?(_ item: SSEItem) {
        switch item {
        case .comment(let c):
            guard c.lowercased().hasPrefix("ping") else { return nil }
            self = .ping
        case .event(let e):
            let data = Data(e.data.utf8)
            switch e.event {
            case "hello":
                self = .hello((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(e.data))
            case "shot":
                if let shot = try? JSONDecoder().decode(Shot.self, from: data) { self = .shot(shot) }
                else { self = .other(event: e.event, data: e.data) }
            case "shot_deleted":
                if let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.stringValue {
                    self = .shotDeleted(id: id)
                } else { self = .other(event: e.event, data: e.data) }
            case "ping":
                self = .ping
            default:
                self = .other(event: e.event, data: e.data)
            }
        }
    }
}
