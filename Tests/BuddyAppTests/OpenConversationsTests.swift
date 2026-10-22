@testable import BuddyApp
import BuddyCompanion
import BuddyCore
import BuddyOverlay
import Testing

extension BuddyCoordinatorTests {
    @Test func commandYInACardAsksTheShellForTheConversationsWindow() async {
        bridge.setScript([Self.done(BuddyBlock(say: "It's QT.", shape: .card))])
        let coordinator = makeCoordinator()
        var opened = 0
        coordinator.onOpenConversations = { opened += 1 }
        await tapToTalk(coordinator)
        overlay.send(.openConversations)
        await settle(until: { opened == 1 })
        #expect(opened == 1)
        #expect(coordinator.phase == .showing, "the card stays as it is")
        #expect(bridge.asked.count == 1, "no model turn")
    }

    @Test func popOutOnARichCardOpensTheConversationsWindow() async {
        bridge.setScript([Self.done(BuddyBlock(say: "It's QT.", shape: .card))])
        let coordinator = makeCoordinator()
        var opened = 0
        coordinator.onOpenConversations = { opened += 1 }
        await tapToTalk(coordinator)
        overlay.send(.popOut)
        await settle(until: { opened == 1 })
        #expect(opened == 1 && coordinator.phase == .showing)
    }

    @Test func commandCommaInACardOpensSettingsAtItsLastPane() async {
        bridge.setScript([Self.done(BuddyBlock(say: "It's QT.", shape: .card))])
        let coordinator = makeCoordinator()
        var opened = 0, panes: [SettingsPane] = []
        coordinator.onOpenSettings = { opened += 1 }
        coordinator.onOpenSettingsPane = { panes.append($0) }
        await tapToTalk(coordinator)
        overlay.send(.openSettings)
        await settle(until: { opened == 1 })
        #expect(opened == 1 && panes.isEmpty, "no pane: Settings opens where the user left it")
        #expect(coordinator.phase == .showing && bridge.asked.count == 1)
    }
}
