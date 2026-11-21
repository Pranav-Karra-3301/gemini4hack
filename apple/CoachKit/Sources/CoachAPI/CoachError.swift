import Foundation

/// Errors from `CoachClient`, `PairingStore` and the event stream. `errorDescription` is
/// written for people (show it as is).
public enum CoachError: Error, LocalizedError, Hashable, Sendable {
    /// Couldn't build a URL for this path.
    case invalidURL(String)
    /// The network failed (Core not running, wrong Wi-Fi, timeout). Carries a readable reason.
    case transport(String)
    /// 401/403: no token or the wrong one. Re-pair.
    case unauthorized(String)
    /// 404: the endpoint or the shot doesn't exist.
    case notFound(String)
    /// Any other non-2xx; `message` is Core's `{"error": …}`.
    case server(status: Int, message: String)
    /// The response wasn't the expected JSON.
    case decoding(String)
    /// Keychain failure (OSStatus).
    case keychain(Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let p): return "Invalid Coach Core URL: \(p)"
        case .transport(let m): return m
        case .unauthorized(let m): return "Coach Core refused the pairing token (\(m)). Pair again from the Mac app."
        case .notFound(let p): return "Not found on Coach Core: \(p)"
        case .server(let s, let m): return "Coach Core error \(s): \(m)"
        case .decoding(let m): return "Unexpected response from Coach Core: \(m)"
        case .keychain(let s): return "Keychain error \(s)"
        case .cancelled: return "Cancelled"
        }
    }

    /// HTTP status when the error came from a response.
    public var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .notFound: return 404
        case .server(let s, _): return s
        default: return nil
        }
    }

    static func from(status: Int, body: Data, path: String) -> CoachError {
        let msg = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            ?? (try? JSONDecoder().decode([String: [String: String]].self, from: body))?["error"]?["message"]
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401, 403: return .unauthorized(msg.isEmpty ? "HTTP \(status)" : msg)
        case 404: return .notFound(path)
        default: return .server(status: status, message: msg.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : msg)
        }
    }

    static func from(_ error: Error, host: String) -> CoachError {
        if let e = error as? CoachError { return e }
        if error is CancellationError { return .cancelled }
        guard let u = error as? URLError else { return .transport(error.localizedDescription) }
        switch u.code {
        case .cancelled: return .cancelled
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .transport("Can't reach Coach Core at \(host). Is the Mac app running, on the same Wi-Fi?")
        case .notConnectedToInternet, .networkConnectionLost:
            return .transport("The network dropped while talking to Coach Core at \(host).")
        case .timedOut:
            return .transport("Coach Core at \(host) took too long to answer.")
        case .appTransportSecurityRequiresSecureConnection:
            return .transport("App Transport Security blocked http://\(host). Allow local networking in Info.plist.")
        default:
            return .transport("Network error talking to Coach Core at \(host): \(u.localizedDescription)")
        }
    }
}
