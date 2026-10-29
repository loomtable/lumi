import Foundation
import Testing
@testable import BuddyApp
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// The coordinator's switcher hook: buddy key + Tab picks where the recording goes.
@MainActor
struct SwitcherGlueTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let presenter = FakeSwitcher()
    let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Ok.", shape: .chip))])
    let sessions: FakeSessionsPort
    let a = SessionID(rawValue: "a"), b = SessionID(rawValue: "b")

    init() {
        let now = Date()
        sessions = FakeSessionsPort([
            .switcherSample("a", used: now.addingTimeInterval(-10)),
            .switcherSample("b", used: now.addingTimeInterval(-300)),
        ], current: SessionID(rawValue: "a"))
    }

    let timers = ManualScheduler()

    func make(speech: TimeInterval?, flag: Bool = true) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer())
        if flag {
            c.attachSwitcher(SwitcherFlow(presenter: presenter, sessions: sessions, heardSpeech: { speech },
                                          scheduler: timers.scheduler))
        }
        c.start()
        return c
    }

    /// The coordinator's router, recording what each ask asked for.
    func spy(_ c: BuddyCoordinator) -> SpyRouting {
        let spy = SpyRouting(c.routing)
        c.routing = spy
        return spy
    }

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func holdTabSpeakSendsToTheHighlightedSession() async {
        let c = make(speech: 1)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        #expect(presenter.isOpen)
        await c.handle(.gesture(.switcherReleased))
        await waitFor { bridge.asked.count == 1 }
        #expect(sessions.calls.first == .setCurrent(b))
        #expect(bridge.asked.count == 1)
        #expect(!presenter.isOpen)
    }

    @Test func holdTabSilenceSwitchesAndSendsNothing() async {
        let c = make(speech: 0.1)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        await c.handle(.gesture(.switcherReleased))
        await waitFor { c.phase == .idle }
        #expect(sessions.calls == [.setCurrent(b)])
        #expect(voice.calls.contains(.discard))
        #expect(bridge.asked.isEmpty)
        #expect(presenter.calls.last == .peek(b))
    }

    @MainActor final class Heard {
        var seconds: TimeInterval
        init(_ seconds: TimeInterval) { self.seconds = seconds }
    }

    /// V-12: a pick made without speech steers the next summon, so the context rule can't send
    /// the next question elsewhere; it lasts for one summon.
    @Test func aSilentPickGoesWithTheNextSummonOnly() async {
        let speech = Heard(0.1)
        let c = make(speech: nil)
        c.attachSwitcher(SwitcherFlow(presenter: presenter, sessions: sessions, heardSpeech: { speech.seconds },
                                      scheduler: timers.scheduler))
        let spy = spy(c)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        await c.handle(.gesture(.switcherReleased))
        await waitFor { c.phase == .idle }

        speech.seconds = 1
        for asked in 1...2 { // the next summon, then one more
            await c.handle(.gesture(.pressBegan(fresh: false)))
            await c.handle(.gesture(.holdBegan))
            await c.handle(.gesture(.holdEnded))
            await waitFor { spy.requests.count == asked }
        }
        #expect(spy.requests.map(\.source) == [.switcherPick(b), nil])
    }

    @Test func tapModeRetargetsAndTheSendingTapCommits() async {
        let c = make(speech: 1)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await waitFor { c.phase == .listening(confirmedTap: true, holding: false) }
        await c.handle(.switcher(.next))
        #expect(presenter.isOpen)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await waitFor { bridge.asked.count == 1 }
        #expect(sessions.calls.first == .setCurrent(b))
        #expect(!presenter.isOpen)
    }

    // MARK: QA R1: the pick decides where the turn goes

    @Test func heldPickReachesTheRouterAsASwitcherPick() async {
        let c = make(speech: 1)
        let routes = spy(c)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        await c.handle(.gesture(.switcherReleased))
        await waitFor { routes.requests.count == 1 }
        #expect(routes.requests.first?.source == .switcherPick(b))
        #expect(c.nextRouteSource == nil) // one-shot
    }

    @Test func aSwitchWithoutSpeechRoutesNothingAndOnlySetsCurrent() async {
        let c = make(speech: 0)
        let routes = spy(c)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        await c.handle(.gesture(.switcherReleased))
        await waitFor { c.phase == .idle }
        #expect(routes.requests.isEmpty)
        #expect(c.nextRouteSource == nil)
        #expect(sessions.calls == [.setCurrent(b)])
    }

    @Test func tapPickCommittedByTheTimerReachesTheRouter() async {
        let c = make(speech: 1)
        let routes = spy(c)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await waitFor { c.phase == .listening(confirmedTap: true, holding: false) }
        await c.handle(.switcher(.next))
        timers.fire(after: SwitcherFlow.tapCommitAfter)
        await waitFor { c.nextRouteSource == .switcherPick(b) }
        await c.handle(.gesture(.pressBegan(fresh: false))) // the sending press: same listen
        await c.handle(.gesture(.tap))
        await waitFor { routes.requests.count == 1 }
        #expect(routes.requests.first?.source == .switcherPick(b))
    }

    @Test func tapPickCommittedByTheSendingTapReachesTheRouter() async {
        let c = make(speech: 1)
        let routes = spy(c)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await waitFor { c.phase == .listening(confirmedTap: true, holding: false) }
        await c.handle(.switcher(.next))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await waitFor { routes.requests.count == 1 }
        #expect(routes.requests.first?.source == .switcherPick(b))
    }

    @Test func plusWithSpeechStartsANewSession() async {
        let c = make(speech: 1)
        let routes = spy(c)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.new)))
        await c.handle(.gesture(.switcherReleased))
        await waitFor { routes.requests.count == 1 }
        #expect(routes.newSessions == 1)
        #expect(routes.requests.first?.source != .switcherPick(a))
        #expect(routes.requests.first?.source != .switcherPick(b))
    }

    @Test func theStripNeverOpensDuringADictation() async {
        let c = make(speech: 1)
        c.dictation = DictationController(
            voice: voice, overlay: overlay, inserter: FakeDictationInserter(), pointer: FixedPointer(),
            coordinatorPhase: { [weak c] in c?.phase ?? .idle }, frontmostPID: { 7 })
        await c.handle(.dictation(.began))
        #expect(c.dictation?.isActive == true)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        await c.handle(.switcher(.next))
        await c.handle(.gesture(.switcherReleased))
        try? await Task.sleep(for: .milliseconds(20)) // let a deferred prepare run, if any
        #expect(presenter.calls.isEmpty)
        #expect(sessions.calls.isEmpty)
        #expect(bridge.asked.isEmpty)
    }

    @Test func aDictationBeginningClosesAnOpenStrip() async {
        let c = make(speech: 1)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        #expect(presenter.isOpen)
        await c.handle(.dictation(.began))
        #expect(!presenter.isOpen)
        #expect(c.switcherFlow?.isOpen == false)
        #expect(presenter.calls.last == .close(commit: false))
    }

    @Test func aDictationBeginningEndsTapModeAndDropsThePick() async {
        let c = make(speech: 1)
        var closed = 0
        c.switcherFlow?.onTapClosed = { closed += 1 }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await waitFor { c.phase == .listening(confirmedTap: true, holding: false) }
        await c.handle(.switcher(.next))
        #expect(c.switcherFlow?.inTapMode == true)
        await c.handle(.dictation(.began))
        #expect(c.switcherFlow?.inTapMode == false)
        #expect(!presenter.isOpen)
        #expect(closed == 1)
        #expect(await c.switcherFlow?.takePick() == nil)
    }

    @Test func flagOffLeavesKeysAsTheyWere() async {
        let c = make(speech: 1, flag: false)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.switcher(.next))
        await c.handle(.gesture(.holdEnded))
        await waitFor { bridge.asked.count == 1 }
        #expect(presenter.calls.isEmpty)
        #expect(sessions.calls.isEmpty)
    }
}
