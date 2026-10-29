import Foundation
import Observation

/// One section of Settings, stored as a single JSON value under a versioned key.
///
/// Each section lives in its own file. Decode with `decodeIfPresent` and fall back
/// to the default for every field (see `KeysPreferences.init(from:)`), so adding a field never loses
/// the user's other settings. Bump the key's version only for a change that can't be decoded
/// leniently, and migrate in `SettingsStore.migrate`.
public nonisolated protocol SettingsSection: Codable, Sendable, Equatable {
    /// "settings.<section>.v<version>"
    static var storageKey: String { get }
    init()
}

/// Settings in UserDefaults, observable by SwiftUI. Writing a section saves it immediately.
///
/// There is one shared store per process, created and injected by the app shell (SettingsView,
/// onboarding and the runtime all read the same instance). Don't create others outside tests:
/// two stores over the same defaults would not see each other's writes.
@Observable
public final class SettingsStore {
    public var keys: KeysPreferences { didSet { save(keys, previous: oldValue) } }
    public var privacy: PrivacyPreferences { didSet { save(privacy, previous: oldValue) } }
    public var conversations: ConversationsPreferences { didSet { save(conversations, previous: oldValue) } }
    public var voice: VoicePreferences { didSet { save(voice, previous: oldValue) } }
    public var appearance: AppearancePreferences { didSet { save(appearance, previous: oldValue) } }
    public var models: ModelPreferences { didSet { save(models, previous: oldValue) } }
    public var connections: ConnectionsPreferences { didSet { save(connections, previous: oldValue) } }
    public var sessions: SessionsPreferences { didSet { save(sessions, previous: oldValue) } }
    public var notifications: NotificationsPreferences { didSet { save(notifications, previous: oldValue) } }
    public var teammates: TeammatesPreferences { didSet { save(teammates, previous: oldValue) } }
    public var dictation: DictationPreferences { didSet { save(dictation, previous: oldValue) } }
    public var dock: DockPreferences { didSet { save(dock, previous: oldValue) } }

    @ObservationIgnored private let defaults: UserDefaults

    /// `defaults` is `.standard` in the app; tests pass a suite of their own.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrate(defaults)
        keys = Self.load(defaults)
        privacy = Self.load(defaults)
        conversations = Self.load(defaults)
        voice = Self.load(defaults)
        appearance = Self.load(defaults)
        models = Self.load(defaults)
        connections = Self.load(defaults)
        sessions = Self.load(defaults)
        notifications = Self.load(defaults)
        teammates = Self.load(defaults)
        dictation = Self.load(defaults)
        dock = Self.load(defaults)
        // Once: someone who finished onboarding, or just its old Voice step (which loaded the
        // models), before the voice choice existed already has the voice. Never again, so a later
        // "not chosen" never turns into a download by itself.
        if !defaults.bool(forKey: Self.voiceSetupMigratedKey) {
            defaults.set(true, forKey: Self.voiceSetupMigratedKey)
            let voiceStepDone = OnboardingModel.completedSteps(defaults).contains(OnboardingStepKind.external(id: VoiceOnboarding.stepID).id)
            if voice.setup == .notChosen, voiceStepDone || !OnboardingModel.needsOnboarding(external: [], defaults: defaults) {
                var migrated = voice
                // No saved voice section means they ran on the old defaults, Parakeet and Kokoro, whose
                // models are on disk: keep those rather than the Mac voice fresh installs now get.
                if defaults.data(forKey: VoicePreferences.storageKey) == nil {
                    migrated.speechModel = VoicePreferences.storedSpeechModel
                    migrated.replyVoice = VoicePreferences.storedReplyVoice
                }
                migrated.setup = .voice
                voice = migrated
                save(voice, previous: VoicePreferences())
            }
        }
    }

    static let voiceSetupMigratedKey = "settings.voice.setupMigrated"

    /// Puts every section back to its default ("Restore defaults" applies per pane instead).
    public func resetAll() {
        keys = KeysPreferences()
        privacy = PrivacyPreferences()
        conversations = ConversationsPreferences()
        // Whether the voice was set up is a choice, not a preference: it survives a reset.
        var voice = VoicePreferences()
        voice.setup = self.voice.setup
        self.voice = voice
        appearance = AppearancePreferences()
        models = ModelPreferences()
        sessions = SessionsPreferences()
        notifications = NotificationsPreferences()
        teammates = TeammatesPreferences()
        dictation = DictationPreferences()
        dock = DockPreferences()
        // `connections` records what Lumi added to Claude Code: a reset mustn't forget it.
    }

    static func load<S: SettingsSection>(_ defaults: UserDefaults) -> S {
        guard let data = defaults.data(forKey: S.storageKey) else { return S() }
        // Unreadable data (a downgrade, corruption): defaults, and the bad value is left in
        // place until the next save so a newer build can still read it.
        return (try? JSONDecoder().decode(S.self, from: data)) ?? S()
    }

    private func save<S: SettingsSection>(_ section: S, previous: S) {
        guard section != previous, let data = try? JSONEncoder().encode(section) else { return }
        defaults.set(data, forKey: S.storageKey)
    }

    /// Moves values from older keys to the current ones. Nothing to migrate yet (v1).
    static func migrate(_ defaults: UserDefaults) {}
}

/// The decoding helper every section uses: a missing or invalid field keeps its default.
extension KeyedDecodingContainer {
    nonisolated func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
