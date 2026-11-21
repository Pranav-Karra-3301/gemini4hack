import Foundation
import Security
import CoachModels

/// Where the pairing token is kept.
public protocol TokenStorage: Sendable {
    func readToken() throws -> String?
    /// `nil` deletes.
    func writeToken(_ token: String?) throws
}

/// Keychain storage (generic password, this device only, readable after first unlock).
public struct KeychainTokenStorage: TokenStorage {
    public let service: String
    public let account: String

    public init(service: String = "app.coach.core", account: String = "pairing-token") {
        self.service = service; self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func readToken() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw CoachError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func writeToken(_ token: String?) throws {
        let del = SecItemDelete(query as CFDictionary)
        guard del == errSecSuccess || del == errSecItemNotFound else { throw CoachError.keychain(del) }
        guard let token, !token.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CoachError.keychain(status) }
    }
}

/// In-memory storage for tests and previews.
public final class MemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func readToken() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func writeToken(_ token: String?) throws { lock.lock(); defer { lock.unlock() }; self.token = token }
}

/// Remembers the paired Core: host/port (and service name) in UserDefaults, token in the Keychain.
public final class PairingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let tokens: TokenStorage
    private let key: String

    public init(defaults: UserDefaults = .standard, tokens: TokenStorage = KeychainTokenStorage(),
                key: String = "coach.pairing") {
        self.defaults = defaults; self.tokens = tokens; self.key = key
    }

    /// The saved pairing, or nil if never paired. A missing Keychain token loads as `token == nil`.
    public func load() -> Pairing? {
        guard let host = defaults.string(forKey: key + ".host"), !host.isEmpty else { return nil }
        let port = defaults.integer(forKey: key + ".port")
        return Pairing(host: host, port: port == 0 ? Pairing.defaultPort : port, token: try? tokens.readToken())
    }

    /// Saves host/port and the token (nil token deletes it).
    public func save(_ pairing: Pairing) throws {
        try tokens.writeToken(pairing.token)
        defaults.set(pairing.host, forKey: key + ".host")
        defaults.set(pairing.port, forKey: key + ".port")
    }

    /// Updates the address after Bonjour finds the same Core on a new IP; keeps the token.
    public func updateAddress(host: String, port: Int) {
        defaults.set(host, forKey: key + ".host")
        defaults.set(port, forKey: key + ".port")
    }

    /// Forgets everything.
    public func clear() {
        try? tokens.writeToken(nil)
        defaults.removeObject(forKey: key + ".host")
        defaults.removeObject(forKey: key + ".port")
    }
}
