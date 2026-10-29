import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// Regression tests for the review of the first coordinator: stale turns, Esc and new presses
/// racing in-flight work, handoff speech, Deep failures and privacy.
@MainActor
struct CoordinatorRaceTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()

    func make(bridge: any BridgePort, context: any ContextPort = FakeContext.packet(), escape: (any EscapePort)? = nil) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: context, turns: bridge,
            overlay: overlay, escape: escape, pointer: FixedPointer())
        coordinator.start()
        return coordinator
    }

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func tapToTalk(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
    }

    var answers: [String] {
        overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block.say } else { nil } }
    }

    var spoken: [String] {
        voice.calls.compactMap { if case .speak(let t) = $0 { t } else { nil } }
    }

    static func done(_ block: BuddyBlock?, lane: Mode = .quick, id: String = "", sessionID: String? = nil) -> CascadeEvent {
        BuddyCoordinatorTests.done(block, lane: lane, sessionID: sessionID, id: id)
    }

    @Test func staleTurnNeverShowsOverANewListeningPill() async {
        let bridge = ManualBridge()
        let c = make(bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }

        await c.handle(.gesture(.pressBegan(fresh: false))) // the user asks again before the answer arrives
        await c.handle(.gesture(.holdBegan))
        #expect(c.phase == .listening(confirmedTap: false, holding: true))
        bridge.send(Self.done(BuddyBlock(say: "Old answer.", shape: .chip)))
        bridge.finish()
        for _ in 0..<20 { await Task.yield() }

        #expect(answers.isEmpty)
        #expect(!spoken.contains("Old answer."))
        #expect(c.phase == .listening(confirmedTap: false, holding: true))
        #expect(bridge.cancelled.count == 1)
    }

    @Test func cancelledTurnStillSavesSessionIDsForTheNextQuestion() async {
        let bridge = ManualBridge()
        let c = make(bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }
        let conversationID = try! #require(bridge.askedStates.first?.id)

        await c.escapePressed() // cancelled while thinking: the UI stops following the turn
        bridge.send(Self.done(nil, id: conversationID, sessionID: "quick-session-1"))
        bridge.finish()
        for _ in 0..<20 { await Task.yield() }

        await tapToTalk(c)
        await waitFor { bridge.streamCount == 2 }
        #expect(bridge.askedStates[1].id == conversationID)
        #expect(bridge.askedStates[1].quickSessionID == "quick-session-1")
    }

    @Test func escapeWhileThinkingCancelsBridgeAndShowsNothing() async {
        let bridge = ManualBridge()
        let c = make(bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }

        await c.escapePressed()
        #expect(c.phase == .idle)
        #expect(bridge.cancelled.count == 1)
        bridge.send(.turn(lane: .quick, .failed(.cancelled)))
        bridge.send(Self.done(nil))
        bridge.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(answers.isEmpty)
    }

    @Test func escapeRoutesThroughScopedTap() async {
        let escape = FakeEscape()
        let c = make(bridge: ManualBridge(), escape: escape)
        overlay.send(.wantsEscape(true))
        await waitFor { escape.isActive }
        #expect(escape.isActive)

        await c.handle(.gesture(.pressBegan(fresh: false)))
        escape.press()
        await waitFor { c.phase == .idle }
        #expect(voice.calls.contains(.discard))

        overlay.send(.wantsEscape(false))
        await waitFor { !escape.isActive }
        #expect(!escape.isActive)
    }

    @Test func handoffLineSpokenOnceWithRealisticStream() async {
        let bridge = FakeBridge(script: [
            .turn(lane: .quick, .sayFirstSentence("Let me check the repo.")),
            .turn(lane: .quick, .say("Let me check the repo.")),
            .handingOff(say: "Let me check the repo."),
            .turn(lane: .deep, .sayFirstSentence("Your filter drops last week.")),
            Self.done(BuddyBlock(say: "Your filter drops last week. Loosen it?", shape: .card), lane: .deep),
        ])
        let c = make(bridge: bridge)
        await tapToTalk(c)
        await waitFor { c.phase == .showing && spoken.count == 3 } // the rest follows the card
        #expect(spoken == ["Let me check the repo.", "Your filter drops last week.", "Loosen it?"])
    }

    @Test func deepFailureAfterHandoffShowsErrorNotQuicksPromise() async {
        let handoffBlock = BuddyBlock(say: "Let me check the repo.", shape: .chip, handoff: .deep)
        let bridge = FakeBridge(script: [
            .handingOff(say: "Let me check the repo."),
            .turn(lane: .deep, .failed(.launchFailed("no claude"))),
            Self.done(handoffBlock, lane: .quick),
        ])
        let c = make(bridge: bridge)
        await tapToTalk(c)
        await waitFor { c.phase == .showing }
        #expect(answers == ["Claude Code stopped unexpectedly."])
    }

    @Test func streamEndingWithoutDoneDoesNotLeaveThePillUp() async {
        let bridge = ManualBridge()
        let c = make(bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }
        bridge.finish()
        await waitFor { c.phase == .showing }
        #expect(answers == ["Claude Code stopped unexpectedly."])
    }

    @Test func blockedAppIsNeverScreenshotted() async {
        let context = CountingContext(result: .blocked(app: "1Password"))
        let c = make(bridge: FakeBridge(), context: context)
        await tapToTalk(c)
        await waitFor { c.phase == .showing }
        #expect(context.screenshotCount == 0)
        #expect(answers == ["I don't look at 1Password."])
    }

    @Test func theScreenshotIsAskedForTheFrontWindowAndPointer() async {
        var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "")
        packet.app = .init(name: "Safari", bundle: "com.apple.Safari", kind: .browser)
        packet.window = .init(title: "Docs", bounds: .init(x: 40, y: 60, width: 1200, height: 800))
        packet.cursor = .init(x: 500, y: 400)
        let context = CountingContext(result: .packet(packet, ContextTimings(totalMs: 2, sensorMs: [:], late: [])))
        let c = make(bridge: FakeBridge(), context: context)
        await tapToTalk(c)
        await waitFor { context.screenshotCount == 1 }
        #expect(context.focuses == [ModelRegion.Focus(window: CGRect(x: 40, y: 60, width: 1200, height: 800),
                                                      cursor: CGPoint(x: 500, y: 400))])
    }

    @Test func noFrontAppNeverReusesTheOldPacket() async {
        let bridge = FakeBridge(script: [Self.done(BuddyBlock(say: "Ok.", shape: .chip))])
        let c = make(bridge: bridge, context: FakeContext(result: .noFrontApp))
        await tapToTalk(c)
        await waitFor { c.phase == .showing }
        #expect(bridge.asked.first?.packet.app == nil)
        #expect(bridge.asked.first?.packet.selection == nil)
    }

    @Test func pausedIgnoresGestures() async {
        let c = make(bridge: FakeBridge())
        await c.setPaused(true)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(c.phase == .idle)
        #expect(!voice.calls.contains(.start))
    }

    @Test func pausingWhileListeningDiscards() async {
        let c = make(bridge: FakeBridge())
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.setPaused(true)
        #expect(c.phase == .idle)
        #expect(voice.calls.contains(.discard))
    }

    @Test func holdDiscardedDuringTapToTalkKeepsListening() async {
        let c = make(bridge: FakeBridge())
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.holdDiscarded(.otherKey(14))))
        #expect(c.phase == .listening(confirmedTap: true, holding: false))
    }

    @Test func doubleTapOnTheSendPressSends() async {
        let bridge = FakeBridge(script: [Self.done(BuddyBlock(say: "Ok.", shape: .chip))])
        let c = make(bridge: bridge)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.doubleTap))
        await waitFor { c.phase == .showing }
        #expect(bridge.asked.count == 1)
    }

    @Test func voiceErrorMessagesAreShownAsIs() async {
        let unavailable = UnavailableVoice()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: unavailable, context: FakeContext.packet(), turns: FakeBridge(),
            overlay: overlay, pointer: FixedPointer())
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(answers == ["Voice isn't set up yet."])
    }
}
