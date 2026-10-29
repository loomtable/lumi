import Foundation

/// Studio's Settings list (04 §6.1): eleven pages in the window's sidebar. They replace the eight
/// tabs of `SettingsPane`, which stays the deep-link vocabulary (a failure chip's Fix, the menu
/// bar's problem rows, a relaunch's resume) and maps onto a page with `init(_:)`.
///
/// Stored settings don't move: every page reads and writes the same `SettingsStore` sections under
/// the same UserDefaults keys as the old panes (`storageKeys`).
public nonisolated enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general, voice, model, claudeCode, connections, teammates, privacy, permissions, appearance, notifications, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .voice: "Voice"
        case .model: "Model for voice answers"
        case .claudeCode: "Claude Code"
        case .connections: "Connections"
        case .teammates: "Teammates"
        case .privacy: "Privacy"
        case .permissions: "Permissions"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .about: "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .voice: "mic"
        case .model: "cpu"
        case .claudeCode: "terminal"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .teammates: "person.2"
        case .privacy: "lock"
        case .permissions: "checkmark.shield"
        case .appearance: "circle.lefthalf.filled"
        case .notifications: "bell"
        case .about: "info.circle"
        }
    }

    /// The hero row's one sentence: what the page controls.
    public var summary: String {
        switch self {
        case .general: "The Lumi key, the dictation key, and Lumi in the Dock."
        case .voice: "How you talk to Lumi, and how Lumi answers."
        case .model: "Which Claude model answers when you ask out loud, and how hard it thinks."
        case .claudeCode: "The Claude Code on this Mac that does the work."
        case .connections: "The tools your Claude Code can use."
        case .teammates: "Whether a session may split work across background helpers."
        case .privacy: "Apps Lumi never reads, and what stays on this Mac."
        case .permissions: "The macOS permissions Lumi needs."
        case .appearance: "How answers look and where they appear."
        case .notifications: "How Lumi tells you a session is ready or needs you."
        case .about: "Version, source and licence."
        }
    }

    /// The hero orb's face (04 §6.4).
    public var expression: LumiExpression {
        switch self {
        case .voice: .curious
        case .privacy, .permissions: .look
        case .notifications: .sleepy
        case .about, .general, .appearance: .happy
        case .model, .claudeCode, .connections, .teammates: .open
        }
    }

    /// The old Settings tab a deep link names → the page that now holds it. Today's links only
    /// open Privacy for a missing grant (Input Monitoring, Accessibility, the card's Details), so
    /// Privacy → Permissions; Conversations' history and temporary mode now live in Privacy.
    public init(_ pane: SettingsPane) {
        self = switch pane {
        case .keys: .general
        case .models: .model
        case .voice: .voice
        case .appearance: .appearance
        case .conversations: .privacy
        case .connections: .connections
        case .privacy: .permissions
        case .claudeCode: .claudeCode
        }
    }

    /// The `SettingsStore` sections this page edits, by storage key. Every section is on at least
    /// one page, so every setting stays reachable (`SettingsPaneMigrationTests`).
    public var storageKeys: [String] {
        switch self {
        case .general: [KeysPreferences.storageKey, DictationPreferences.storageKey, DockPreferences.storageKey]
        case .voice: [VoicePreferences.storageKey, SessionsPreferences.storageKey]
        case .model: [ModelPreferences.storageKey]
        case .claudeCode: []
        case .connections: [ConnectionsPreferences.storageKey]
        case .teammates: [TeammatesPreferences.storageKey]
        case .privacy: [PrivacyPreferences.storageKey, ConversationsPreferences.storageKey]
        case .permissions: []
        case .appearance: [AppearancePreferences.storageKey]
        case .notifications: [NotificationsPreferences.storageKey, SessionsPreferences.storageKey]
        case .about: []
        }
    }

    /// How a relaunch's resume stores a page. Prefixed, so it never reads as an old pane's raw value
    /// (old "privacy" meant the grants, now Permissions).
    var resumeValue: String { Self.resumePrefix + rawValue }
    static let resumePrefix = "page:"

    /// A stored resume value: a page written by Studio, or an old pane mapped onto its page.
    init?(resumeValue raw: String) {
        if raw.hasPrefix(Self.resumePrefix) {
            guard let page = SettingsPage(rawValue: String(raw.dropFirst(Self.resumePrefix.count))) else { return nil }
            self = page
        } else if let pane = SettingsPane(rawValue: raw) {
            self.init(pane)
        } else {
            return nil
        }
    }
}

/// The orb's faces in Studio (Home, the Settings hero rows). The orb always has eyes.
public nonisolated enum LumiExpression: String, Sendable, CaseIterable {
    case happy, open, curious, look, sleepy
}
