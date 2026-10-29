import AppKit
import BuddyCompanion
import Foundation
import Testing
@testable import BuddyApp

@MainActor
struct DockPresenceTests {
    final class Fake {
        var applied: [NSApplication.ActivationPolicy] = []
        var active = false
        var activations = 0
    }

    private func presence(_ f: Fake) -> DockPresence {
        DockPresence(apply: { f.applied.append($0) }, isActive: { f.active }, activate: { f.activations += 1 })
    }

    @Test func showInDockPicksTheActivationPolicyAtOnce() {
        let f = Fake(), dock = presence(f)
        dock.show(inDock: true)
        #expect(f.applied == [.regular], "on by default: a Dock icon")
        dock.show(inDock: true)
        #expect(f.applied == [.regular], "unchanged: nothing applied again")
        dock.show(inDock: false)
        dock.show(inDock: true)
        #expect(f.applied == [.regular, .accessory, .regular], "each change applies without a relaunch")
    }

    /// Leaving the Dock deactivates the app; only an app that was active comes back. Nothing here
    /// ever activates Lumi over the user's app.
    @Test func turningTheIconOffKeepsTheLumiWindowInFrontButNeverTakesFocus() {
        let f = Fake(), dock = presence(f)
        f.active = true
        dock.show(inDock: false)
        #expect(f.activations == 0, "launch never activates")
        dock.show(inDock: true)
        #expect(f.activations == 0, "joining the Dock doesn't need it")
        dock.show(inDock: false)
        #expect(f.activations == 1, "the Settings page the switch is on stays in front")
        f.active = false
        dock.show(inDock: true)
        dock.show(inDock: false)
        #expect(f.activations == 1, "in the background: left there")
    }

    @Test func theDockMenuOffersOpenNewSessionAndSettings() {
        let menu = StatusMenuItem.dockMenu(needsSetUp: false)
        #expect(menu.map(\.title) == ["Open Lumi", "New Session", "Settings…"])
        #expect(menu.compactMap(\.action) == [.openStudio, .newSession, .openSettings])
        #expect(Set(menu.compactMap(\.action).compactMap { LumiWindow.opened(by: $0, needsSetUp: false) }) == [.studio])
        let setUp = StatusMenuItem.dockMenu(needsSetUp: true)
        #expect(setUp.compactMap(\.action) == [.setUp])
        #expect(LumiWindow.opened(by: .newSession, needsSetUp: true) == .onboarding)
    }

    /// A Dock click or reopen opens the Lumi window, even with a kept answer or other windows open.
    @Test func reopenOpensTheLumiWindow() {
        #expect(LumiWindow.onReopen(needsSetUp: false) == .studio)
        #expect(LumiWindow.onReopen(needsSetUp: true) == .onboarding)
    }
}
