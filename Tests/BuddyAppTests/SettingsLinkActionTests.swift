@testable import BuddyApp
import BuddyCompanion
import BuddyContext
import BuddyCore
import BuddyOverlay
import BuddyTrace
import Foundation
import Testing

@MainActor
final class FakeOpenURL: OpenURLPort {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

extension BuddyCoordinatorTests {
    @Test func aSettingsLinkActionOpensSystemSettingsWithNoModelTurn() async {
        let block = BuddyBlock(
            say: "Screen Recording is off.", shape: .chip,
            actions: [.init(label: "Open Screen Recording", prompt: "buddy://settings/screen-recording")])
        bridge.setScript([Self.done(block)])
        let opener = FakeOpenURL()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, inserter: inserter, pointer: FixedPointer(), openURL: opener)
        coordinator.start()
        await tapToTalk(coordinator)

        overlay.send(.action(index: 0))
        await settle(until: { !opener.opened.isEmpty })
        #expect(opener.opened == [PermissionKind.screenRecording.settingsURL])
        await settle()
        #expect(bridge.asked.count == 1, "no Deep turn, no shell")
        #expect(coordinator.phase == .idle, "the card closes: the user is off to System Settings")
        await settle(until: { voice.calls.contains(.stopSpeaking) })
        #expect(voice.calls.contains(.stopSpeaking), "and the reply stops speaking")
    }

    @Test func theLinkButtonOpensOnlyTheShownAnswersLink() async throws {
        let draft = try #require(URL(string: "https://mail.google.com/mail/#drafts/abc"))
        let block = BuddyBlock(say: "Drafted it.", shape: .card,
                               link: BuddyBlock.Link(label: "Open draft", url: draft))
        bridge.setScript([Self.done(block)])
        let opener = FakeOpenURL()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, inserter: inserter, pointer: FixedPointer(), openURL: opener)
        coordinator.start()
        await tapToTalk(coordinator)

        overlay.send(.openLink(try #require(URL(string: "https://evil.example/x")))) // not this card's
        overlay.send(.openLink(draft))
        await settle(until: { !opener.opened.isEmpty })
        #expect(opener.opened == [draft])
        #expect(bridge.asked.count == 1, "no model turn")
    }

    @Test func aCardsLinkTakesAnActionSlot() {
        let three = (1...3).map { BuddyBlock.Action(label: "\($0)", prompt: "p") }
        let link = BuddyBlock.Link(label: "Open draft", url: URL(string: "https://mail.google.com/x")!)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .card, actions: three, link: link)) == 2)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .card, actions: three, link: link), mainAction: .copy) == 1)
        #expect(BuddyCoordinator.visibleActions(BuddyBlock(say: "", shape: .chip, actions: three, link: link)) == 1) // chips show no link
    }
}

extension TraceTests {
    private func coordinator(_ context: any ContextPort, bridge: FakeBridge = FakeBridge(),
                             openURL: (any OpenURLPort)? = nil) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: voice, context: context, bridge: bridge,
                                 overlay: overlay, pointer: FixedPointer(), trace: trace, openURL: openURL)
        c.start()
        return c
    }

    private var missing: Int { trace.events.filter { $0 == .permissionMissing }.count }

    /// Long enough for a late duplicate to land, so "exactly once" means it.
    private func settleBriefly() async { try? await Task.sleep(for: .milliseconds(50)) }

    @Test func microphoneAccessOffIsTracedOnce() async {
        let c = make(FakeBridge())
        voice.eventSink.yield(.permissionDenied)
        await settle(until: { missing > 0 })
        await settleBriefly()
        #expect(missing == 1)
        withExtendedLifetime(c) {}
    }

    @Test func aMissingScreenRecordingGrantIsTracedOnce() async {
        let bridge = FakeBridge()
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "It's QT.", shape: .card))])
        let c = coordinator(notGranted(), bridge: bridge)
        await ask(c)
        await settle(until: { c.phase == .showing })
        #expect(missing == 1)
        // A typed follow-up in the card takes no new screenshot, so nothing more is traced.
        overlay.send(.submitted(text: "and in 2024?", source: .reply))
        await settle(until: { bridge.asked.count == 2 && c.phase != .thinking })
        #expect(missing == 1)
    }

    @Test func aGrantedScreenshotTracesNothingMissing() async {
        let c = coordinator(FakeContext.packet())
        await ask(c)
        await settle(until: { trace.events.contains(.screenshot) })
        #expect(missing == 0)
    }

    @Test func noFrontAppWithoutTheGrantIsTracedToo() async {
        let c = coordinator(notGranted(.noFrontApp))
        await ask(c)
        await settle(until: { missing > 0 })
        await settleBriefly()
        #expect(missing == 1)
    }

    @Test func openingASettingsLinkIsNotASecondMissingGrant() async {
        let bridge = FakeBridge()
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(
            say: "Screen Recording is off.", shape: .chip,
            actions: [.init(label: "Open Screen Recording", prompt: "buddy://settings/screen-recording")]))])
        let opener = FakeOpenURL()
        let c = coordinator(notGranted(), bridge: bridge, openURL: opener)
        await ask(c)
        await settle(until: { c.phase == .showing })
        overlay.send(.action(index: 0))
        await settle(until: { !opener.opened.isEmpty })
        await settleBriefly()
        #expect(opener.opened.count == 1, "the link path really ran")
        #expect(missing == 1, "the denial at the screenshot, not again at the link")
    }
}

extension BuddyCoordinatorTests {
    @Test func aSettingsLinkOnAHiddenActionIsIgnored() async {
        let block = BuddyBlock(say: "Screen Recording is off.", shape: .chip,
                               actions: [.init(label: "Explain", prompt: "Explain it"),
                                         .init(label: "Open", prompt: "buddy://settings/screen-recording")])
        bridge.setScript([Self.done(block)])
        let opener = FakeOpenURL()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
                                           overlay: overlay, inserter: inserter, pointer: FixedPointer(), openURL: opener)
        coordinator.start()
        await tapToTalk(coordinator)
        overlay.send(.action(index: 1)) // a chip shows one button: index 1 isn't visible
        await settle()
        #expect(opener.opened.isEmpty && bridge.asked.count == 1)
    }

    @Test func aSettingsLinkOnTheFirstActionWinsOverInsert() async {
        let block = BuddyBlock(say: "Screen Recording is off.", shape: .card,
                               actions: [.init(label: "Open Screen Recording", prompt: "buddy://settings/screen-recording")],
                               insert: "some text")
        bridge.setScript([Self.done(block)])
        let opener = FakeOpenURL()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
                                           overlay: overlay, inserter: inserter, pointer: FixedPointer(), openURL: opener)
        coordinator.start()
        await tapToTalk(coordinator)
        overlay.send(.action(index: 0))
        await settle(until: { !opener.opened.isEmpty })
        #expect(opener.opened.count == 1 && inserter.inserted.isEmpty, "the button says Open, so it opens")
    }
}

/// A packet (or `result`), but Screen Recording isn't granted.
func notGranted(_ result: ContextResult? = nil) -> FakeContext {
    var context = result.map { FakeContext(result: $0) } ?? .packet()
    context.shot = nil
    context.unavailable = .notGranted
    return context
}
