import BuddyConversations
import Foundation
import SwiftUI

/// Claude Code as Settings › Claude Code shows it. The shell fills it from BuddyBridge;
/// nil fields read as "checking…".
public nonisolated struct ClaudeCodeStatus: Sendable, Equatable {
    public var executablePath: String?
    public var version: String?
    public var loggedIn: Bool?
    /// "Claude Max", "API key"…: how it's signed in, without the account itself.
    public var loginDetail: String?
    public var pluginLoaded: Bool?
    /// Why the plugin isn't loaded (validation output or a `plugin_errors` entry), shown with Repair.
    public var pluginProblem: String?
    /// True once a check has finished, so "not found" can be told apart from "checking…". Build
    /// a checked status with `init(report:pluginErrors:)`; the plain init (false) means
    /// no check has finished yet, and the pane shows "Checking…" until one does.
    public var checked: Bool

    public init(executablePath: String? = nil, version: String? = nil, loggedIn: Bool? = nil, loginDetail: String? = nil,
                pluginLoaded: Bool? = nil, pluginProblem: String? = nil, checked: Bool = false) {
        self.executablePath = executablePath
        self.version = version
        self.loggedIn = loggedIn
        self.loginDetail = loginDetail
        self.pluginLoaded = pluginLoaded
        self.pluginProblem = pluginProblem
        self.checked = checked
    }
}

/// Settings › Claude Code's buttons. The shell provides them (re-run the probe; re-copy the
/// bundled plugin, "Repair plugin"); nil hides the button.
public nonisolated struct ClaudeCodeActions: Sendable {
    public var refresh: (@Sendable () async -> Void)?
    public var repairPlugin: (@Sendable () async throws -> Void)?

    public init(refresh: (@Sendable () async -> Void)? = nil, repairPlugin: (@Sendable () async throws -> Void)? = nil) {
        self.refresh = refresh
        self.repairPlugin = repairPlugin
    }
}

/// Settings › Privacy's trace log buttons. The shell provides them; nil hides the button.
public nonisolated struct TraceLogActions: Sendable {
    /// "Delete trace log": removes every trace file.
    public var delete: (@Sendable () async -> Void)?

    public init(delete: (@Sendable () async -> Void)? = nil) {
        self.delete = delete
    }
}

/// Opens Settings at a pane. The shell provides it; the default does nothing.
public nonisolated struct SettingsPaneOpener: Sendable {
    public var open: (@MainActor @Sendable (SettingsPane) -> Void)?

    public init(_ open: (@MainActor @Sendable (SettingsPane) -> Void)? = nil) {
        self.open = open
    }

    @MainActor public func callAsFunction(_ pane: SettingsPane) { open?(pane) }
}

/// A folder Lumi writes to, for Settings › Privacy "what is stored" (the shell maps
/// BuddyVoice's VoiceStorage and others onto these).
public nonisolated struct StorageLocation: Sendable, Equatable, Identifiable {
    public var title: String
    public var url: URL
    public var bytes: Int64?

    public var id: URL { url }

    public init(title: String, url: URL, bytes: Int64? = nil) {
        self.title = title
        self.url = url
        self.bytes = bytes
    }
}

/// Services the app shell injects into Settings and onboarding. Panes read these; SettingsView's
/// initialiser never changes when a pane needs something new.
extension EnvironmentValues {
    /// Non-prompting permission checks and fix actions.
    @Entry public var permissions: any PermissionChecking = SystemPermissions.shared
    /// The conversation index, for Settings › Conversations. Nil in previews and tests.
    @Entry public var conversationManager: ConversationManager? = nil
    @Entry public var claudeCodeStatus = ClaudeCodeStatus()
    @Entry public var claudeCodeActions = ClaudeCodeActions()
    @Entry public var storageLocations: [StorageLocation] = []
    @Entry public var traceLogActions = TraceLogActions()
    /// Opens Settings at a pane (e.g. onboarding's "Record a different key…"). The shell
    /// provides it; the default does nothing.
    @Entry public var openSettingsPane = SettingsPaneOpener()
    /// Told when Settings › Keys starts and stops practising the buddy key.
    @Entry public var keyPractice: KeyPracticeCoordinator = .unwired
}

/// While Settings › Keys or onboarding is practising, the shell must not summon, so a practice
/// tap doesn't also start a question. Counted, so two places practising at once can't switch
/// each other off. The shell sets `onChange`; the default does nothing.
public final class KeyPracticeCoordinator {
    public var onChange: (Bool) -> Void
    private var users = 0
    public var isActive: Bool { users > 0 }

    /// The default when the shell injects nothing.
    public static let unwired = KeyPracticeCoordinator()

    public init(onChange: @escaping (Bool) -> Void = { _ in }) {
        self.onChange = onChange
    }

    /// Call `begin` when practice starts and `end` exactly once when it stops.
    public func begin() {
        users += 1
        if users == 1 { onChange(true) }
    }

    public func end() {
        guard users > 0 else { return }
        users -= 1
        if users == 0 { onChange(false) }
    }
}
