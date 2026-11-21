import Foundation

/// How to reach a Core: host, port and bearer token. Round-trips the
/// `coach://pair?host=…&port=…&token=…` URL shown as a QR code by the Mac app,
/// and decodes `GET /api/pair`.
public struct Pairing: Codable, Hashable, Sendable {
    public static let scheme = "coach"
    public static let defaultPort = 8787

    public var host: String
    public var port: Int
    /// `nil` for loopback (no auth needed).
    public var token: String?

    public init(host: String, port: Int = Pairing.defaultPort, token: String? = nil) {
        self.host = host; self.port = port; self.token = token
    }

    /// The Mac's own Core (no token).
    public static let local = Pairing(host: "127.0.0.1")

    /// Parses `coach://pair?host=192.168.1.20&port=8787&token=abc`. Returns nil for other URLs.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Pairing.scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `coach://pair?...` puts "pair" in the host; `coach:pair?...` in the path.
        let action = (comps.host ?? comps.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard action.lowercased() == "pair" else { return nil }
        let items = comps.queryItems ?? []
        func q(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let host = q("host") else { return nil }
        let port = q("port").flatMap(Int.init) ?? Pairing.defaultPort
        guard (1...65535).contains(port) else { return nil }
        self.init(host: host, port: port, token: q("token"))
    }

    /// Parses a pairing URL string (e.g. a scanned QR payload).
    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    /// Parses a typed address: `192.168.1.20`, `192.168.1.20:8787`, `http://mac.local:8787`, `[fe80::1]:8787`.
    public init?(address: String, token: String?) {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard let comps = URLComponents(string: s), let host = comps.host, !host.isEmpty else { return nil }
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                  port: comps.port ?? Pairing.defaultPort, token: (t?.isEmpty ?? true) ? nil : t)
    }

    /// `coach://pair?host=…&port=…&token=…` (token omitted when nil).
    public var url: URL {
        var c = URLComponents()
        c.scheme = Pairing.scheme
        c.host = "pair"
        var items = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port))]
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        c.queryItems = items
        return c.url!
    }

    /// `http://host:port` (IPv6 hosts are bracketed).
    public var baseURL: URL {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(port)")!
    }

    /// True for 127.0.0.1 / ::1 / localhost (no token needed).
    public var isLoopback: Bool { ["127.0.0.1", "::1", "localhost"].contains(host.lowercased()) }

    enum CodingKeys: String, CodingKey { case host, port, token }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Pairing.defaultPort
        token = try c.decodeIfPresent(String.self, forKey: .token)
    }
}
