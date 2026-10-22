import Foundation

/// The result of checking an ElevenLabs key.
public enum ElevenLabsCheck: Equatable, Sendable {
    case ok
    case invalidKey
    case quotaExceeded
    case unreachable(String)
}

/// The ElevenLabs key and voices, for Settings › Voice and onboarding.
public protocol ElevenLabsAccounting: Sendable {
    /// Whether a key is saved (never reads it).
    var hasKey: Bool { get }
    func saveKey(_ key: String) throws
    func deleteKey() throws
    /// Checks the saved key.
    func validate() async -> ElevenLabsCheck
    /// Checks `key` before it's saved.
    func validate(key: String) async -> ElevenLabsCheck
    func voices() async throws -> [ElevenLabsVoice]
}

/// The real account: the key in the Keychain, checks against ElevenLabs' voice list.
public final class ElevenLabsAccount: ElevenLabsAccounting {
    /// What leaves the Mac when ElevenLabs is the voice. Questions, context and screenshots go to Anthropic
    /// through Claude Code either way (Settings › Privacy).
    public static let privacyNote = "Reply text is sent to ElevenLabs to be spoken. Nothing else goes to ElevenLabs."
    /// A premade voice every account has (George, used in ElevenLabs' own examples).
    public static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"

    private let keys: any SecretStore
    let client: ElevenLabsClient

    public init(keys: any SecretStore = CachedSecretStore.elevenLabs, http: any HTTPStreamer = URLSessionStreamer()) {
        self.keys = keys
        client = ElevenLabsClient(http: http, keys: keys)
    }

    public var hasKey: Bool { keys.contains() }

    public func saveKey(_ key: String) throws {
        try keys.write(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func deleteKey() throws { try keys.delete() }

    public func validate() async -> ElevenLabsCheck { await check { try await self.client.voices() } }

    public func validate(key: String) async -> ElevenLabsCheck {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .invalidKey }
        return await check { try await self.client.voices(key: key) }
    }

    /// Empty when the key may speak but not list voices; the picker then offers the default voice.
    public func voices() async throws -> [ElevenLabsVoice] {
        do {
            return try await client.voices()
        } catch ElevenLabsFailure.missingPermission {
            return []
        }
    }

    private func check(_ call: @Sendable () async throws -> [ElevenLabsVoice]) async -> ElevenLabsCheck {
        do {
            _ = try await call()
            return .ok
        } catch let failure as ElevenLabsFailure {
            switch failure {
            case .noKey, .keyUnreadable, .invalidKey: return .invalidKey
            // The key was accepted; it just can't list voices (a restricted key that can still speak).
            case .missingPermission: return .ok
            case .quotaExceeded: return .quotaExceeded
            case .unreachable(let why): return .unreachable(why)
            case .modelRejected, .badResponse: return .unreachable("unexpected response from ElevenLabs")
            }
        } catch {
            return .unreachable("unexpected error")
        }
    }
}
