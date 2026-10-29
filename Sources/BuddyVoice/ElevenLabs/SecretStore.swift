import BuddyCore
import Foundation
import Security
import Synchronization

/// One secret (the ElevenLabs API key). Never written to UserDefaults or logs.
public protocol SecretStore: Sendable {
    /// Whether a secret is stored, without reading it.
    func contains() -> Bool
    func read() throws -> String?
    func write(_ secret: String) throws
    func delete() throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// A generic password in the login keychain. (The data-protection keychain, which honours "this device
/// only", needs a keychain-access-group entitlement a self-signed build doesn't have; the login keychain
/// isn't synced to iCloud either way.)
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// Where Lumi keeps the ElevenLabs API key.
    public static let elevenLabs = KeychainSecretStore(service: BuddyCore.paths.keychainService("elevenlabs"), account: "api-key")

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func contains() -> Bool {
        var q = query
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ secret: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Reads the secret once and keeps it in memory, so a reply never touches the Keychain (where a read
/// can raise a password prompt). Writes and deletes go through and update the copy at once.
public final class CachedSecretStore: SecretStore {
    private let base: any SecretStore
    /// nil: not read yet; .some(nil): read, none saved.
    private let cache = Mutex<String??>(nil)

    public init(_ base: any SecretStore) { self.base = base }

    /// The one store the speaker and the account share, so a saved key is used by the next reply.
    public static let elevenLabs = CachedSecretStore(KeychainSecretStore.elevenLabs)

    public func contains() -> Bool {
        if let cached = cache.withLock({ $0 }) { return cached != nil }
        return base.contains()
    }

    public func read() throws -> String? {
        if let cached = cache.withLock({ $0 }) { return cached }
        let value = try base.read()
        cache.withLock { $0 = .some(value) }
        return value
    }

    public func write(_ secret: String) throws {
        try base.write(secret)
        cache.withLock { $0 = .some(secret) }
    }

    public func delete() throws {
        try base.delete()
        cache.withLock { $0 = .some(nil) }
    }
}
