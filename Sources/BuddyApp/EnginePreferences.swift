import BuddyCompanion
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import Foundation
import Synchronization

/// The Settings values the live engine reads: blocked apps at each capture, screenshot retention
/// at each sweep, the buddy key, the coordinator's settings (routing, models, voice replies,
/// sounds), the Research model and the overlay's effects and placement. The shell maps the
/// SettingsStore onto this (`init(store:)`) and hands it to `AppRuntime.apply(_:)` at launch and
/// on every change.
public struct EnginePreferences: Sendable, Equatable {
    /// Apps the user blocked, on top of the built-in ones (Settings › Privacy).
    public var blockedBundleIDs: Set<String>
    /// How long screenshots are kept (Settings › Privacy), at most 24 h.
    public var screenshotRetention: TimeInterval
    /// The buddy key, its gesture timing and the secure-input rule (Settings › Keys).
    public var keys: BuddyKeyMonitor.Options
    /// Routing, the Quick and Deep models, voice replies and sounds. `keySymbol` comes from `keys`.
    public var coordinator: BuddyCoordinator.Settings
    /// The model and effort each new Research job starts with (Settings › Models).
    public var research: ModeConfig
    /// Effects and placement (Settings › Appearance).
    public var overlay: OverlaySettings
    /// Settings › Conversations: after this long idle the next question starts fresh.
    public var idleTimeout: TimeInterval = 30 * 60
    /// Settings › Conversations: conversations unused this long leave the index.
    public var retentionDays: Int = 90
    /// Settings › Conversations: nothing saved while on.
    public var temporaryConversations = false
    /// Settings › Privacy › Trace log: timings and event kinds only.
    public var traceLogEnabled = false
    /// v2 sessions: voice layer, typed-answer speech, ambient signals, notifications, teammates.
    public var sessions = SessionSettings()
    /// Settings › General: the dictation key in effect; nil when off, the buddy key, or in conflict.
    /// Also in `keys.dictationKey` (what the key monitor runs) while `LumiFeatures.dictation` is on.
    public var dictationKey: BuddyKey? = .rightCommand

    public init(blockedBundleIDs: Set<String> = [], screenshotRetention: TimeInterval = ScreenshotStore.retention,
                keys: BuddyKeyMonitor.Options = BuddyKeyMonitor.Options(),
                coordinator: BuddyCoordinator.Settings = BuddyCoordinator.Settings(),
                research: ModeConfig = .default(for: .research), overlay: OverlaySettings = OverlaySettings()) {
        self.blockedBundleIDs = blockedBundleIDs
        self.screenshotRetention = screenshotRetention
        self.keys = keys
        self.coordinator = coordinator
        self.research = research
        self.overlay = overlay
        self.coordinator.keySymbol = keys.key.symbol
    }

    public var blocklist: Blocklist { Blocklist(userBundleIDs: blockedBundleIDs) }
}

extension EnginePreferences {
    /// Every engine-facing setting from the shared store, field for field.
    /// `keyEnvironment` feeds the dictation key's Auto pick and conflict check; the default sees no
    /// other apps and a 🌐 key that does nothing. The app passes `KeyEnvironment.current()`.
    @MainActor
    public init(store: SettingsStore, keyEnvironment: KeyEnvironment = KeyEnvironment(),
                features: LumiFeatures = .current()) {
        var coordinator = BuddyCoordinator.Settings()
        coordinator.routing = store.models.routing
        coordinator.quick = store.models.quick
        coordinator.deep = store.models.deep
        coordinator.voiceReplies = switch store.voice.voiceReplies {
        case .always: .always
        case .onlyWhenISpoke: .onlyWhenSpoken
        case .off: .off
        }
        coordinator.sounds = store.appearance.sounds
        let look = store.appearance
        // Settings › Appearance: no rings means no OCR or AX work either; Insert off leaves Copy only.
        coordinator.rings = look.showRings
        coordinator.insert = look.insertAndReplace
        self.init(
            blockedBundleIDs: Set(store.privacy.blockedBundleIDs),
            screenshotRetention: TimeInterval(store.privacy.screenshotRetentionHours) * 3600,
            keys: PracticeModel.options(store.keys),
            coordinator: coordinator,
            research: store.models.research,
            overlay: OverlaySettings(glow: look.speakingGlow, dotField: look.dotField, inkIn: look.inkIn,
                                     placement: Placer.Mode(rawValue: look.placement.rawValue) ?? .smart,
                                     statusPosition: OverlaySettings.StatusPosition(rawValue: look.statusPosition.rawValue) ?? .top,
                                     rings: look.showRings))
        idleTimeout = TimeInterval(store.conversations.idleTimeoutMinutes) * 60
        retentionDays = store.conversations.retentionDays
        temporaryConversations = store.conversations.temporaryMode
        traceLogEnabled = store.privacy.traceLogEnabled
        sessions = SessionSettings(
            // Voice replies Off silences typed and in-page answers too (QA S-19).
            voiceLayer: store.sessions.voiceLayer,
            speakTypedAnswers: store.sessions.speakTypedAnswers && store.voice.voiceReplies != .off,
            notifyWhenAway: store.notifications.notifyWhenAway, teammates: store.teammates.mode,
            maxSubagents: store.teammates.maxSubagents)
        dictationKey = store.dictation.resolved(buddyKey: store.keys.key, in: keyEnvironment).key
        if features.dictation { keys.dictationKey = dictationKey }
        keys.dictationMode = store.dictation.mode
    }
}

/// The current preferences, readable from any thread (context capture, the sweep task).
final class EnginePreferencesBox: Sendable {
    private let state = Mutex(EnginePreferences())

    var current: EnginePreferences { state.withLock { $0 } }

    /// Returns the previous value.
    @discardableResult
    func set(_ new: EnginePreferences) -> EnginePreferences {
        state.withLock { old in
            defer { old = new }
            return old
        }
    }
}
