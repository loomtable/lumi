import AppKit
import BuddyApp
import BuddyCompanion
import BuddyCore
import Observation
import SwiftUI

/// The menu bar item. A click tucks the answer on screen into
/// the item or brings the kept one back; with nothing kept it opens the menu. A right or ⌃-click
/// always opens the menu. An NSStatusItem rather than MenuBarExtra, which can't tell the clicks
/// apart or say where it sits.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var pulse: Task<Void, Never>?
    private var dim = false
    private var appearance: NSKeyValueObservation?
    private var displayOptions: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Opens the windows the engine and this menu ask for: SwiftUI's openWindow and
        // openSettings need a SwiftUI view that lives as long as the app.
        let requests = NSHostingView(rootView: WindowRequests(model: model))
        requests.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        button.addSubview(requests)
        appearance = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.render() }
        }
        model.runtime.statusItemFrame = { [weak self] in self?.screenFrame }
        // Reduce Motion turned on or off: the pulse follows at once.
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updatePulse() } }
        follow()
    }

    /// The item's frame on screen (AppKit coordinates), for the overlay's fold. Nil while the item
    /// isn't shown (hidden by the system, or past the notch).
    var screenFrame: CGRect? {
        guard let button = item.button, let window = button.window, window.isVisible else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked() {
        // A chip or report may have replaced the answer without a phase change.
        model.runtime.updateKeptAnswer()
        let event = NSApp.currentEvent
        // VoiceOver's press is no mouse click: it gets the menu, where Show Last Answer comes first.
        let mouse = event?.type == .leftMouseUp || event?.type == .rightMouseUp
        let secondary = !mouse || event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        switch StatusItemClick.action(secondary: secondary, answerShowing: model.runtime.answerShowing,
                                      answerKept: model.runtime.answerKept) {
        case .openMenu: openMenu()
        case .tuckAnswer: model.runtime.tuckAnswer()
        // Nothing to bring back after all (a Forget since the last phase change): the menu.
        case .showLastAnswer: if !model.runtime.recallLastAnswer() { openMenu() }
        }
    }

    /// The menu only while it shows, so the next click comes back to `clicked`.
    private func openMenu() {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.runtime.updateKeptAnswer()
        menu.removeAllItems()
        let rows = StatusMenuItem.menu(
            answerKept: model.runtime.answerKept, problems: model.runtime.problems,
            needsSetUp: OnboardingModel.needsOnboarding(external: model.onboardingSteps),
            keyName: model.settings.keys.key.settingsName, paused: model.isPaused)
        for row in rows {
            guard let title = row.title else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: title, action: row.action == nil ? nil : #selector(chose), keyEquivalent: row.keyEquivalent)
            entry.target = self
            entry.isEnabled = row.enabled
            entry.state = row.checked ? .on : .off
            entry.representedObject = row.action.map(ActionBox.init)
            menu.addItem(entry)
        }
    }

    private final class ActionBox: NSObject {
        let action: StatusMenuItem.Action
        init(_ action: StatusMenuItem.Action) { self.action = action }
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        switch action {
        case .showLastAnswer: model.runtime.recallLastAnswer()
        case .relaunch: model.runtime.permissions.relaunch()
        case .openPane(let pane): model.openSettings(at: pane)
        case .setUp: model.openOnboarding()
        case .openSettings: model.openSettings()
        case .conversations: model.openConversations()
        case .togglePause: model.isPaused.toggle()
        case .checkForUpdates: NSWorkspace.shared.open(StatusMenuItem.releasesURL)
        case .sendFeedback: sendFeedback()
        case .quit: NSApp.terminate(nil)
        }
    }

    /// A new email in the user's mail app; with no mail app set up, the address goes to the
    /// clipboard instead and a note says so.
    private func sendFeedback() {
        guard !NSWorkspace.shared.open(StatusMenuItem.feedbackURL()) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(StatusMenuItem.feedbackAddress, forType: .string)
        model.runtime.showNote("Copied \(StatusMenuItem.feedbackAddress)")
    }

    // MARK: Icon

    /// Re-renders whenever what the icon shows changes, and pulses while busy.
    private func follow() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        updatePulse()
    }

    private func updatePulse() {
        let pulsing = model.runtime.activity == .busy && !model.isPaused
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if pulsing, pulse == nil {
            // A menu bar image can't animate itself; swapping it on a timer can.
            pulse = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(550))
                    guard let self else { return }
                    dim.toggle()
                    render()
                }
            }
        } else if !pulsing, pulse != nil {
            pulse?.cancel()
            pulse = nil
            dim = false
            render()
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let paused = model.isPaused, attention = model.runtime.permissions.needsAttention
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = MenuBarDot.image(activity: model.runtime.activity, paused: paused, dark: dark,
                                        alpha: dim ? 0.4 : 1, badge: attention)
        button.setAccessibilityLabel(MenuBarDot.accessibilityText(activity: model.runtime.activity, paused: paused,
                                                                 attention: attention))
    }
}
