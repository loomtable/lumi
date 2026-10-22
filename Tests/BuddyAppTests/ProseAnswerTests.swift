import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// A turn that ends in plain prose (a clarifying question, "A or B?") shows it as a card, not as
/// "finished without an answer I can show".
@MainActor
struct ProseAnswerTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()

    func make(_ bridge: FakeBridge) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer())
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

    static func done(prose: String, lane: Mode = .quick) -> CascadeEvent {
        let result = StreamEvent.TurnResult(
            subtype: "success", isError: false, sessionID: "s1", text: prose, terminalReason: nil,
            apiErrorStatus: nil, durationMS: nil, ttftMS: nil, costUSD: nil, permissionDenials: 0)
        let outcome = TurnOutcome(result: result, extraction: .init(block: nil, prose: prose), timing: TurnTiming())
        var state = ConversationState(id: "")
        state.lastLane = lane
        return .done(CascadeResult(lane: lane, outcome: outcome, state: state, handoffToFirstText: nil))
    }

    var answers: [BuddyBlock] { overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block } else { nil } } }

    @Test func theFirstSentenceIsTheHeadlineAndTheRestIsPlainCardText() {
        let block = BuddyCoordinator.proseBlock("  Which sheet do you mean? Q3 or Q4.\n\nQ4 has <b>draft</b> rows & notes.\n")
        #expect(block?.say == "Which sheet do you mean?")
        #expect(block?.shape == .card)
        #expect(block?.cardHTML == "<p>Q3 or Q4.</p><p>Q4 has &lt;b&gt;draft&lt;/b&gt; rows &amp; notes.</p>")
        #expect(BuddyCoordinator.proseBlock("Line one?\nA\nB")?.cardHTML == "<p>A<br>B</p>")
    }

    @Test func oneSentenceIsAChipAndNothingOrABrokenBlockIsNoAnswer() {
        #expect(BuddyCoordinator.proseBlock("Did you mean the Q3 sheet?") == BuddyBlock(say: "Did you mean the Q3 sheet?", shape: .chip))
        #expect(BuddyCoordinator.proseBlock(" \n ") == nil)
        #expect(BuddyCoordinator.proseBlock("Here:\n```buddy\n{\"shape\": \"card\"}\n```") == nil)
    }

    @Test func aClarifyingQuestionShowsAsACardAndItsHeadlineIsSpoken() async {
        let c = make(FakeBridge(script: [Self.done(prose: "Which sheet do you mean? Q3 has the totals, Q4 the drafts.")]))
        await ask(c)
        #expect(answers.map(\.say) == ["Which sheet do you mean?"])
        #expect(answers.first?.cardHTML == "<p>Q3 has the totals, Q4 the drafts.</p>")
        #expect(voice.calls.contains(.speak("Which sheet do you mean?")))
        #expect(!voice.calls.contains { if case .speak(let s) = $0 { s.contains("Q3") } else { false } })
        #expect(c.phase == .showing)
    }

    @Test func deepsProseAnswersToo() async {
        let c = make(FakeBridge(script: [
            .handingOff(say: "Let me check the repo."),
            Self.done(prose: "Should I fix both files or just the parser?", lane: .deep),
        ]))
        await ask(c)
        #expect(answers.map(\.say) == ["Should I fix both files or just the parser?"])
    }

    @Test func aFailedTurnStillSaysWhatWentWrong() async {
        let c = make(FakeBridge(script: [.turn(lane: .quick, .failed(.timedOut)), Self.done(prose: "Partial thought")]))
        await ask(c)
        #expect(!answers.map(\.say).contains("Partial thought"))
    }
}
