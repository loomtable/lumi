import BuddyCore
import BuddyKeys
import BuddyOverlay
import Foundation

extension AppRuntime {
    /// The buddy key's options, with the switcher's key map while `LumiFeatures.switcher` is on.
    /// Every `BuddyKeyMonitor` start and update goes through here, so a key change keeps it.
    static func keyOptions(_ keys: BuddyKeyMonitor.Options, features: LumiFeatures = .current()) -> BuddyKeyMonitor.Options {
        var options = keys
        options.gesture.switcher = features.switcher ? SwitcherKeyMap(buddy: keys.key) : nil
        return options
    }

    /// The strip's "next" key for this buddy key: "`" for a ⌘ key (⌘Tab is the app switcher's), else Tab.
    static func switcherNextKeyName(_ key: BuddyKey) -> String {
        key == .rightCommand || key == .leftCommand ? "`" : "Tab"
    }

    /// The key monitor; with the switcher on, a consuming tap that takes buddy key + Tab (and
    /// the other strip keys) so the front app never sees them (keys' recipe, handoffs/keys.md).
    static func makeKeyMonitor(_ keys: BuddyKeyMonitor.Options, features: LumiFeatures = .current()) -> BuddyKeyMonitor {
        guard features.switcher else { return BuddyKeyMonitor(options: keys, source: EventTapSource()) }
        let arming = KeyArming()
        return BuddyKeyMonitor(
            options: keyOptions(keys, features: features), source: EventTapSource(arming: arming),
            switcherTap: SwitcherTap(arming: arming))
    }

    /// The switcher and notifications, behind `LumiFeatures.switcher`. They read
    /// the session store the Studio source is attached to (foundation attaches it in
    /// `makeSessionEngine`, which runs first); without one, nothing is built.
    func makeSwitcher(_ coordinator: BuddyCoordinator, features: LumiFeatures) {
        guard features.switcher, let sessions = studioSource.port else { return }
        let presenter = LiveSwitcher()
        let voice = coordinator.voice
        let flow = SwitcherFlow(
            presenter: presenter, sessions: sessions, heardSpeech: { await voice.heardSpeechSeconds() }, trace: traceLog)
        flow.nextKeyName = Self.switcherNextKeyName(preferences.current.keys.key)
        let monitor = monitor
        flow.onTapClosed = { Task { await monitor?.closeSwitcher() } }
        presenter.onShown = { [weak flow] in flow?.stripShown() }
        // One surface (63-SWITCHER-UX): the strip grows out of the pill, the pill follows the
        // highlight, and the capsules step aside while the strip is open.
        let pill = coordinator.overlay as? BuddyOverlayController  // nil in tests
        presenter.pillAnchor = { pill.flatMap { p in p.pillScreenFrame.map { (frame: $0, atBottom: p.statusAtBottom) } } }
        presenter.onOpenChanged = { [weak coordinator] in coordinator?.overlay.setSwitcherOpen($0) }
        flow.onTarget = { [weak coordinator] in coordinator?.overlay.setPillTarget($0) }
        coordinator.attachSwitcher(flow)
        // The peek's inline Allow/Deny goes to the permission host (a click, so any tier).
        flow.onApprove = { [weak coordinator] id, session, allow in
            await coordinator?.pageFlow?.permissions.respond(id, in: session, allow: allow)
        }

        let notifier = LiveNotifier()
        let preferences = preferences
        let attention = AttentionController(
            presenter: presenter, sessions: sessions, notifier: notifier, presence: SystemPresence(),
            settings: { preferences.current.sessions })
        // A banner click is a deliberate pick. A session one of our voice turns is waiting on
        // comes back as the Glance's approval card (V-03); otherwise the session opens, in the
        // Panel (or the Lumi window with the Panel off), not a 4 s peek (V-11).
        notifier.onClick = { [weak self, weak coordinator] id in
            await sessions.setCurrent(id)
            if coordinator?.openWaiting(id) == true { return }
            if await coordinator?.pageFlow?.open(id) != true { self?.onOpenStudioSession?(id) }
        }
        notifier.becomeDelegate()
        attention.start { [weak flow] in flow?.sessionsChanged($0) }

        // One reader for the presenter's events, for the app's lifetime: it keeps the switcher and
        // attention alive.
        let events = presenter.events
        Task { @MainActor [weak coordinator] in
            _ = attention
            for await event in events {
                switch event {
                case .stop(let id):
                    await coordinator?.turns.cancel(conversation: id.rawValue)
                case .highlighted, .tileClicked, .newSessionClicked, .approve, .closed:
                    await flow.handle(event)
                }
            }
        }
    }
}
