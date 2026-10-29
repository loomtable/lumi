import Foundation
import Testing
@testable import BuddyApp
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// Round 3 voice audit (30-QA V-11, V-13, V-14, V-16).
@MainActor
struct VoiceAuditTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let panel = FakePanel()
    static let answer = BuddyBlock(say: "It's the totals row.", shape: .card)

    func turn(_ question: String) -> TranscriptTurn {
        TranscriptTurn(question: question, block: BuddyBlock(say: "Ok.", shape: .chip), mode: .quick, model: .haiku)
    }

    func make(_ turns: any TurnPort) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: turns, overlay: overlay, pointer: FixedPointer())
        c.start()
        return c
    }

    func flow(_ sessions: FakeSessionsPort = FakeSessionsPort()) -> PageFlow {
        PageFlow(panel: panel, turns: SessionScriptPort([]), permissions: LivePermissionHost(answering: FakeAnswering()),
                 sessions: sessions)
    }

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func voiceAsk(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        await waitFor { c.phase == .showing }
    }

    /// V-11: a capsule or banner click opens the session with its whole history.
    @Test func openingASessionShowsThePanelWithItsWholeHistory() async {
        let s = SessionID(rawValue: "s_1")
        let f = flow(FakeSessionsPort([SessionSnapshot(id: s, title: "Trip", color: .ember, harness: .open, lastUsed: .now)]))
        f.history = { _ in [turn("a"), turn("b")] }
        #expect(await f.open(s))
        #expect(panel.calls.contains(.show(s, turns: 2)))
        #expect(await f.open(SessionID(rawValue: "gone")) == false, "the caller falls back to the Lumi window")
    }

    /// V-14: ⤢ Continue shows every stored turn, plus the card's own if it isn't written yet.
    @Test func continueShowsTheWholeSession() async {
        let c = make(FakeBridge(script: [BuddyCoordinatorTests.done(Self.answer)]))
        let f = flow()
        f.history = { _ in [self.turn("from yesterday"), self.turn("and before")] }
        c.pageFlow = f
        await voiceAsk(c)
        let id = try? #require(c.kept?.conversationID)
        overlay.send(.popOut)
        await waitFor { !panel.calls.isEmpty }
        #expect(panel.calls.first == .show(SessionID(rawValue: id ?? ""), turns: 3))
        #expect(c.phase == .idle)
    }

    /// V-13: a typed reply on a card is routed, to the card's session, like any typed turn.
    @Test func aTypedReplyIsRoutedToTheCardsSession() async {
        let c = make(FakeBridge(script: [BuddyCoordinatorTests.done(Self.answer)]))
        let spy = SpyRouting(c.routing)
        c.routing = spy
        await voiceAsk(c)
        let card = try? #require(c.kept?.conversationID)
        overlay.send(.submitted(text: "and May?", source: .reply))
        await waitFor { spy.requests.count == 2 }
        #expect(spy.requests.last?.kind == .typed)
        #expect(spy.requests.last?.source == .composer(SessionID(rawValue: card ?? "")))
        #expect(spy.requests.last?.packet.utterance == "and May?")
    }

    /// V-16: Esc silences the rest of an in-page answer; the next answer speaks again.
    @Test func escStopsAnInPageAnswerForGood() async {
        let c = make(FakeBridge(script: []))
        c.speakInPage("First part.", continuing: false)
        await waitFor { voice.calls.contains(.speak("First part.")) }
        await c.escapePressed()
        c.speakInPage("The rest.", continuing: true)
        c.speakInPage("Next answer.", continuing: false)
        await waitFor { voice.calls.contains(.speak("Next answer.")) }
        #expect(!voice.calls.contains(.speak("The rest.")))
    }
}
