import BuddyCore
import BuddyKeys
import Foundation

/// Settings › Voice and Appearance, v2 sessions: the voice layer and typed-answer speech.
public nonisolated struct SessionsPreferences: SettingsSection {
    public static let storageKey = "settings.sessions.v1"

    public var voiceLayer: VoiceLayerScope = .voiceTurns
    public var speakTypedAnswers: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case voiceLayer, speakTypedAnswers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        voiceLayer = c.value(.voiceLayer, default: d.voiceLayer)
        speakTypedAnswers = c.value(.speakTypedAnswers, default: d.speakTypedAnswers)
    }
}

/// Settings › Conversations › "Notify me when I'm away".
public nonisolated struct NotificationsPreferences: SettingsSection {
    public static let storageKey = "settings.notifications.v1"

    public var notifyWhenAway: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey { case notifyWhenAway }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifyWhenAway = c.value(.notifyWhenAway, default: Self().notifyWhenAway)
    }
}

/// Settings › Teammates.
public nonisolated struct TeammatesPreferences: SettingsSection {
    public static let storageKey = "settings.teammates.v1"

    public var mode: TeammatesMode = .askFirst
    /// 1–5, default 3 (lead).
    public var maxSubagents: Int = 3

    public init() {}

    enum CodingKeys: String, CodingKey { case mode, maxSubagents }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        mode = c.value(.mode, default: d.mode)
        // Out of range: the default, as for the other sections' numbers.
        let max = c.value(.maxSubagents, default: d.maxSubagents)
        maxSubagents = SessionSettings.maxSubagentsRange.contains(max) ? max : d.maxSubagents
    }
}

/// Settings › General: the dictation key and how it works. Tap it (or hold it), speak, and the
/// words are typed at the cursor.
public nonisolated struct DictationPreferences: SettingsSection {
    public static let storageKey = "settings.dictation.v1"
    /// Stored in `dictationKey` for the Auto default.
    public static let autoValue = "auto"

    /// Off means no dictation key at all.
    public var enabled: Bool = true
    /// "auto" (the default), or a `BuddyKey.rawValue` the user picked.
    public var dictationKey: String = DictationPreferences.autoValue
    /// `DictationMode.rawValue`: tap to start and stop (the default), or hold to talk.
    public var modeValue: String = DictationMode.toggle.rawValue

    public init() {}

    /// Tap to toggle or hold; an unknown stored value reads as the default.
    public var mode: DictationMode {
        get { DictationMode(rawValue: modeValue) ?? .toggle }
        set { modeValue = newValue.rawValue }
    }

    /// The key the user picked, or nil for Auto (an unknown stored name also reads as Auto).
    public var key: BuddyKey? {
        get { BuddyKey(rawValue: dictationKey) }
        set { dictationKey = newValue?.rawValue ?? Self.autoValue }
    }

    /// What Settings › General shows as selected.
    public var choice: DictationKeyChoice {
        get {
            guard enabled else { return .off }
            return key.map { .key($0) } ?? .auto
        }
        set {
            switch newValue {
            case .off: enabled = false
            case .auto: enabled = true; key = nil
            case .key(let k): enabled = true; key = k
            }
        }
    }

    /// The key in effect and the line Settings shows for it (`DictationKeyResolver`).
    public func resolved(buddyKey: BuddyKey, in environment: KeyEnvironment) -> DictationKeyResolution {
        DictationKeyResolver.resolve(choice, buddyKey: buddyKey, in: environment)
    }

    enum CodingKeys: String, CodingKey { case enabled, dictationKey, modeValue = "mode" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, default: d.enabled)
        dictationKey = c.value(.dictationKey, default: d.dictationKey)
        modeValue = c.value(.modeValue, default: d.modeValue)
    }
}
