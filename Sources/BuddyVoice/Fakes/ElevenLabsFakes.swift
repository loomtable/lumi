import Foundation
import Synchronization

/// An in-memory secret, for tests: never touches the Keychain.
public final class FakeSecretStore: SecretStore {
    private let value: Mutex<String?>
    public init(_ secret: String? = nil) { value = Mutex(secret) }
    public func contains() -> Bool { value.withLock { $0 != nil } }
    public func read() throws -> String? { value.withLock { $0 } }
    public func write(_ secret: String) throws { value.withLock { $0 = secret } }
    public func delete() throws { value.withLock { $0 = nil } }
}

/// Scripted ElevenLabs account for Settings and onboarding tests.
public final class FakeElevenLabsAccount: ElevenLabsAccounting {
    private struct State {
        var key: String?
        var check: ElevenLabsCheck = .ok
        var voices: [ElevenLabsVoice] = [ElevenLabsVoice(id: ElevenLabsAccount.defaultVoiceID, name: "George", category: "premade")]
    }
    private let state: Mutex<State>

    public init(key: String? = nil, check: ElevenLabsCheck = .ok) {
        state = Mutex(State(key: key, check: check))
    }

    public func setCheck(_ check: ElevenLabsCheck) { state.withLock { $0.check = check } }
    public func setVoices(_ voices: [ElevenLabsVoice]) { state.withLock { $0.voices = voices } }
    public var savedKey: String? { state.withLock { $0.key } }

    public var hasKey: Bool { state.withLock { $0.key != nil } }
    public func saveKey(_ key: String) throws { state.withLock { $0.key = key } }
    public func deleteKey() throws { state.withLock { $0.key = nil } }
    public func validate() async -> ElevenLabsCheck { state.withLock { $0.key == nil ? .invalidKey : $0.check } }
    public func validate(key: String) async -> ElevenLabsCheck { state.withLock { $0.check } }
    public func voices() async throws -> [ElevenLabsVoice] {
        try state.withLock { s in
            guard s.key != nil, s.check == .ok else { throw ElevenLabsFailure.invalidKey }
            return s.voices
        }
    }
}
