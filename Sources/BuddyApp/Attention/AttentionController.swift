import AppKit
import BuddyConversations
import BuddyCore
import BuddyOverlay
import CoreGraphics
import Foundation
import UserNotifications

/// Posts and withdraws Lumi's macOS notifications. Live: `LiveNotifier`.
@MainActor public protocol NotificationPosting: AnyObject {
    func post(_ banner: Banner) async
    func withdraw(_ session: SessionID) async
}

/// Whether the user is at the Mac. Live: `SystemPresence`.
@MainActor public protocol PresenceSource: AnyObject {
    var presence: Presence { get }
}

/// The ambient side of sessions (03 §5, lead's Oct 28 decisions): notifications only by
/// `NotificationPolicy`, while the strip's tiles follow every change. Background sessions never
/// open a card, take the voice or move focus; running, ready and needs-you show in the capsules,
/// the switcher and the sidebar.
@MainActor
public final class AttentionController {
    public static let presenceInterval: Duration = .seconds(15)

    private let presenter: any SwitcherPresenting
    private let sessions: any SessionsPort
    private let notifier: any NotificationPosting
    private let presenceSource: any PresenceSource
    private let settings: @MainActor () -> SessionSettings
    private let scheduler: SwitcherScheduler
    private let now: @MainActor () -> Date

    private var tracker = TransitionTracker()
    private var policy = NotificationPolicy()
    private var presence = PresenceTracker()
    private var reminderTimer: Task<Void, Never>?
    private var presenceTimer: Task<Void, Never>?
    private var watch: Task<Void, Never>?

    /// The user came back after being away (Lumi's wake motion; no catch-up card).
    public var onCameBack: (@MainActor () -> Void)?

    public init(
        presenter: any SwitcherPresenting, sessions: any SessionsPort, notifier: any NotificationPosting,
        presence: any PresenceSource, settings: @escaping @MainActor () -> SessionSettings,
        scheduler: SwitcherScheduler = .live, now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.presenter = presenter
        self.sessions = sessions
        self.notifier = notifier
        self.presenceSource = presence
        self.settings = settings
        self.scheduler = scheduler
        self.now = now
    }

    /// Follows the sessions until `stop`. `onChange` also gets every list (the switcher flow).
    public func start(onChange: (@MainActor ([SessionSnapshot]) -> Void)? = nil) {
        watch?.cancel()
        let stream = sessions.changes()
        watch = Task { [weak self] in
            for await list in stream {
                guard let self else { return }
                await self.update(list)
                onChange?(list)
            }
        }
        schedulePresenceCheck()
    }

    public func stop() {
        for task in [watch, reminderTimer, presenceTimer] { task?.cancel() }
    }

    // MARK: Updates

    /// One sessions list: the strip's tiles in place, then banners for what changed.
    public func update(_ list: [SessionSnapshot]) async {
        presenter.refresh(list)
        let at = now()
        let present = checkPresence()
        let on = settings()
        for t in tracker.update(list, now: at) {
            for action in policy.handle(t, presence: present, enabled: on.notifyWhenAway, now: at) {
                await perform(action)
            }
        }
        scheduleReminder()
    }

    // MARK: Notifications

    private func perform(_ action: NotificationAction) async {
        switch action {
        case .post(let banner): await notifier.post(banner)
        case .withdraw(let id): await notifier.withdraw(id)
        }
    }

    private func scheduleReminder() {
        reminderTimer?.cancel()
        guard let due = policy.nextReminder else { return }
        let wait = max(0, due.timeIntervalSince(now()))
        reminderTimer = scheduler.after(.milliseconds(Int(wait * 1000) + 1)) { [weak self] in
            Task { await self?.remind() }
        }
    }

    /// Reminders that are due (a needs-you unanswered for 30 min).
    public func remind() async {
        for action in policy.tick(now: now(), presence: checkPresence(), enabled: settings().notifyWhenAway) {
            await perform(action)
        }
        scheduleReminder()
    }

    // MARK: Presence

    @discardableResult
    private func checkPresence() -> Presence {
        let p = presenceSource.presence
        if presence.update(p) == .cameBack { onCameBack?() }
        return p
    }

    private func schedulePresenceCheck() {
        presenceTimer?.cancel()
        presenceTimer = scheduler.after(Self.presenceInterval) { [weak self] in
            self?.checkPresence()
            self?.schedulePresenceCheck()
        }
    }
}

// MARK: - Live adapters

/// Presence from the system idle timer and the lock and display-sleep notifications only
/// (03 §5.3). Nothing is read from the screen.
@MainActor
public final class SystemPresence: PresenceSource {
    private var locked = false
    private var displayAsleep = false
    private var observers: [any NSObjectProtocol] = []

    public init() {
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (SystemPresence) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { change(self) } }
            })
        }
        on(dc, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        on(dc, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
    }

    isolated deinit {
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            DistributedNotificationCenter.default().removeObserver(o)
        }
    }

    /// `kCGAnyInputEventType`.
    private static let anyInput = CGEventType(rawValue: ~0) ?? .null

    public var presence: Presence {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
        return Presence.of(secondsSinceInput: idle, locked: locked, displayAsleep: displayAsleep)
    }
}

/// Lumi's notifications through UserNotifications. It never asks for permission itself (the
/// one prompt belongs to onboarding's wording); without it, nothing posts. No sound.
@MainActor
public final class LiveNotifier: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    nonisolated static let sessionKey = "session"

    /// A banner was clicked: make its session current and show it.
    public var onClick: (@MainActor (SessionID) async -> Void)?

    override public init() { super.init() }

    /// Receives clicks. Only with the switcher flag on: nothing else in Lumi posts.
    public func becomeDelegate() { UNUserNotificationCenter.current().delegate = self }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let id = Self.session(from: response.notification.request.content.userInfo) else { return }
        await onClick?(id)
    }

    /// Banners post only when the user is away, so one arriving while Lumi is active still shows.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    public func post(_ banner: Banner) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.body = banner.body
        content.sound = nil
        content.interruptionLevel = banner.level == .active ? .active : .passive
        content.threadIdentifier = "sessions"
        content.userInfo = [Self.sessionKey: banner.session.rawValue]
        let request = UNNotificationRequest(identifier: Self.identifier(banner.session), content: content, trigger: nil)
        try? await center.add(request)
    }

    public func withdraw(_ session: SessionID) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(session)])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(session)])
    }

    /// The session a clicked notification belongs to.
    public nonisolated static func session(from userInfo: [AnyHashable: Any]) -> SessionID? {
        (userInfo[sessionKey] as? String).map(SessionID.init(rawValue:))
    }

    nonisolated static func identifier(_ id: SessionID) -> String { "lumi.session." + id.rawValue }
}
