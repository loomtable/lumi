import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// A reply spoken in pieces continues itself; only a new turn cuts what's playing.
@MainActor
struct SpeechContinuationTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()

    func make(_ bridge: FakeBridge, research: FakeResearch? = nil) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer(), research: research)
        c.start()
        return c
    }

    func ask(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(2)
        while c.phase != .showing, c.phase != .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<50 { await Task.yield() }
    }

    var spoken: [String] { voice.calls.compactMap { if case .speak(let t) = $0 { t } else { nil } } }

    @Test func firstSentenceThenTheRestIsOneReply() async {
        let c = make(FakeBridge(script: [
            .turn(lane: .quick, .sayFirstSentence("It's the totals row.")),
            BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row. Column C is text.", shape: .card)),
        ]))
        await ask(c)
        #expect(spoken == ["It's the totals row.", "Column C is text."])
        #expect(voice.continuations == [false, true])
    }

    @Test func handoffLineAndDeepsAnswerContinueQuicksSentence() async {
        let c = make(FakeBridge(script: [
            .turn(lane: .quick, .sayFirstSentence("Let me check.")),
            .handingOff(say: "Let me check. One moment."),
            .turn(lane: .deep, .sayFirstSentence("Your filter drops last week.")),
            .turn(lane: .deep, .say("Your filter drops last week. Loosen it in dev.")),
            BuddyCoordinatorTests.done(
                BuddyBlock(say: "Your filter drops last week. Loosen it in dev.", shape: .card), lane: .deep),
        ]))
        await ask(c)
        #expect(spoken == ["Let me check.", "One moment.", "Your filter drops last week.", "Loosen it in dev."])
        #expect(voice.continuations == [false, true, true, true])
    }

    @Test func aNewTurnStartsAFreshReply() async {
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "One.", shape: .chip))])
        let c = make(bridge)
        await ask(c)
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Two.", shape: .chip))])
        await ask(c)
        #expect(spoken == ["One.", "Two."])
        #expect(voice.continuations == [false, false])
    }

    @Test func aFinishedResearchJobIsAFreshReply() async {
        let research = FakeResearch()
        let c = make(FakeBridge(), research: research)
        research.onDone?(job("QT"))
        let deadline = ContinuousClock.now + .seconds(2)
        while spoken.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(voice.continuations == [false])
        withExtendedLifetime(c) {}
    }

    @Test func stopSpeakingSilencesTheRestOfTheTurn() async {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let bridge = ManualBridge()
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(2)
        while bridge.streamCount == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }

        bridge.send(.turn(lane: .quick, .sayFirstSentence("Let me check.")))
        while spoken.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        overlay.send(.stopSpeaking) // 🔈
        for _ in 0..<50 { await Task.yield() }

        bridge.send(.handingOff(say: "Let me check. One moment."))
        bridge.send(.turn(lane: .deep, .sayFirstSentence("Your filter drops last week.")))
        bridge.send(BuddyCoordinatorTests.done(
            BuddyBlock(say: "Your filter drops last week. Loosen it.", shape: .card), lane: .deep))
        bridge.finish()
        while c.phase != .showing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        for _ in 0..<50 { await Task.yield() }
        #expect(c.phase == .showing) // the answer still shows
        #expect(spoken == ["Let me check."])
    }

    @Test func theAnswersSpeechWaitsForItsCard() async {
        overlay.presentsAnswersImmediately = false // an overlay still measuring card HTML
        let c = make(FakeBridge(script: [
            BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row.", shape: .card)),
        ]))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(2)
        while c.phase != .showing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(spoken.isEmpty) // the card isn't on screen yet

        let presentedAt = ContinuousClock.now
        overlay.send(.answerPresented)
        while spoken.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(spoken == ["It's the totals row."])
        #expect(ContinuousClock.now - presentedAt < .milliseconds(200)) // on the event, not the cap
    }

    @Test func aSlowCardDelaysTheVoiceAtMostTheCap() async {
        overlay.presentsAnswersImmediately = false // and the overlay never reports it
        let c = make(FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))]))
        let start = ContinuousClock.now
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = start + .seconds(4)
        while spoken.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(spoken == ["Yes."])
        #expect(ContinuousClock.now - start >= BuddyCoordinator.presentWait)
        // Under the 4 s deadline (no cap would hit it), with room for a loaded machine.
        #expect(ContinuousClock.now - start < BuddyCoordinator.presentWait + .seconds(1))
    }

    @Test func aStreamedFirstSentenceShowsInThePillAsItIsSpoken() async {
        let c = make(FakeBridge(script: [
            .turn(lane: .quick, .sayFirstSentence("It's the totals row.")),
            BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row. Column C is text.", shape: .card)),
        ]))
        await ask(c)
        let status = overlay.calls.firstIndex(of: .headline("It's the totals row."))
        let firstSpeech = voice.calls.firstIndex(of: .speak("It's the totals row."))
        #expect(status != nil && firstSpeech != nil)
    }

    @Test func aFullyStreamedHeadlineIsInThePillAndSpokenBeforeTheCard() async {
        overlay.presentsAnswersImmediately = false
        let overlay = overlay
        voice.setOverlayCount { await MainActor.run { overlay.calls.count } }
        let bridge = ManualBridge()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(3)
        while bridge.streamCount == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }

        bridge.send(.turn(lane: .quick, .sayFirstSentence("It's the totals row.")))
        bridge.send(.turn(lane: .quick, .say("It's the totals row. Column C is text.")))
        while spoken.count < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        // No card yet, but the whole headline is in the pill, so all of it is heard: no gap.
        #expect(spoken == ["It's the totals row.", "Column C is text."])
        // The mark is the overlay's length when the voice was asked to speak: speak awaits it
        // before returning, so it's in `marks` only after a short hop. Wait for it, not a time.
        func restMark() -> Int? { voice.marks.first { $0.call == .speak("Column C is text.") }?.overlayIndex }
        while restMark() == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        let full = overlay.calls.firstIndex(of: .headline("It's the totals row. Column C is text."))
        let rest = restMark()
        #expect(full != nil && rest != nil && full! < rest!) // shown before it's heard

        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row. Column C is text.", shape: .card)))
        bridge.finish()
        while c.phase != .showing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        overlay.send(.answerPresented)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(spoken == ["It's the totals row.", "Column C is text."]) // nothing again at the card
        #expect(voice.continuations == [false, true])
    }

    @Test func theHeadlineStaysInThePillOverALaterStatus() async {
        let c = make(FakeBridge(script: [
            .turn(lane: .quick, .sayFirstSentence("It's the totals row.")),
            .turn(lane: .quick, .status("Reading the table")),
            BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row.", shape: .card)),
        ]))
        await ask(c)
        #expect(overlay.calls.contains(.headline("It's the totals row.")))
        #expect(!overlay.calls.contains(.status("Reading the table")))
    }
}
