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

/// Full screen shows the whole conversation: each answer carries its question and every earlier
/// turn, oldest first (38's transcript view).
@MainActor
struct TranscriptTests {
    let bridge = FakeBridge()
    let overlay = FakeOverlay()
    let voice = FakeVoice()

    func make(conversations: (any ConversationPort)? = nil) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), bridge: bridge,
            overlay: overlay, pointer: FixedPointer(), conversations: conversations)
        c.start()
        return c
    }

    func ask(_ c: BuddyCoordinator, _ words: String, answer: String, lane: Mode = .quick) async {
        voice.setTranscript(words)
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: answer, shape: .card), lane: lane)])
        let before = answers.count
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(2)
        while answers.count == before, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    var answers: [Answer] { overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a } else { nil } } }

    @Test func eachAnswerCarriesItsQuestionAndTheEarlierTurns() async {
        let c = make()
        await ask(c, "what is QT?", answer: "Quantitative tightening.")
        await ask(c, "and mortgages?", answer: "Rates rose.", lane: .deep)
        await ask(c, "by how much?", answer: "About half a point.")

        #expect(answers.map(\.question) == ["what is QT?", "and mortgages?", "by how much?"])
        #expect(answers[0].earlier.isEmpty)
        #expect(answers[1].earlier.map(\.question) == ["what is QT?"])
        let third = answers[2].earlier
        #expect(third.map(\.question) == ["what is QT?", "and mortgages?"])
        #expect(third.map(\.block.say) == ["Quantitative tightening.", "Rates rose."])
        #expect(third.map(\.mode) == [.quick, .deep])
        #expect(third[1].model == .opus)
    }

    @Test func aNewConversationStartsAnEmptyTranscript() async {
        let c = make()
        await ask(c, "what is QT?", answer: "Quantitative tightening.")
        overlay.send(.newConversation)
        let deadline = ContinuousClock.now + .seconds(2)
        while !overlay.calls.contains(.resetPositions), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        await ask(c, "what's for lunch?", answer: "Soup.")
        #expect(answers.last?.earlier.isEmpty == true)
    }

    @Test func aPortWithoutATranscriptStillWorks() async {
        let c = make(conversations: SlowNewConversations()) // implements recordTurn only
        await ask(c, "one", answer: "First.")
        await ask(c, "two", answer: "Second.")
        #expect(answers.last?.question == "two")
        #expect(answers.last?.earlier.isEmpty == true)
        #expect(answers.last?.turn == 2) // the default record still counts the turn
    }

    @Test func chipsCarryNoTranscript() async {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext(result: .blocked(app: "1Password")), bridge: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        await ask(c, "what is this?", answer: "unused")
        #expect(answers.last?.block.say == "I don't look at 1Password.")
        #expect(answers.last?.question == nil)
        #expect(answers.last?.earlier.isEmpty == true)
    }

    @Test func aPressedActionShowsItsLabelNotItsPrompt() async {
        let c = make()
        voice.setTranscript("why is row 4 empty?")
        let block = BuddyBlock(say: "Your filter drops it.", shape: .card,
                               actions: [.init(label: "Loosen the filter", prompt: "Loosen the date filter in useFeed.ts to 14 days")])
        bridge.setScript([BuddyCoordinatorTests.done(block)])
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + .seconds(2)
        while answers.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }

        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Done: 14 days now.", shape: .card), lane: .deep)])
        overlay.send(.action(index: 0))
        while answers.count < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(answers.last?.question == "Loosen the filter")
        #expect(bridge.asked.last?.packet.utterance == "Loosen the date filter in useFeed.ts to 14 days") // the model still gets the prompt
    }

    /// A port whose `turns` leave out the turn just recorded (against the contract).
    @MainActor final class TurnsWithoutTheNewOne: ConversationPort {
        private let inner = MemoryConversations()
        private var kept: [TranscriptTurn] = []
        var current: ConversationTurn? { inner.current }
        func prepare(project: String?) async -> ConversationTurn { await inner.prepare(project: project) }
        func update(_ state: ConversationState) async { await inner.update(state) }
        func recordTurn(conversationID: String, question: String, answer: String) async -> ConversationTurn? {
            await inner.recordTurn(conversationID: conversationID, question: question, answer: answer)
        }
        func record(_ turn: TranscriptTurn, conversationID: String) async -> ConversationTurn? {
            var result = await inner.recordTurn(conversationID: conversationID, question: turn.question, answer: turn.block.say)
            result?.turns = kept
            kept.append(turn)
            return result
        }
        func startNew() async -> ConversationTurn { await inner.startNew() }
    }

    @Test func earlierTurnsDontDependOnWhetherThePortIncludesTheNewOne() async {
        let c = make(conversations: TurnsWithoutTheNewOne())
        await ask(c, "one", answer: "First.")
        await ask(c, "two", answer: "Second.")
        #expect(answers.last?.earlier.map(\.question) == ["one"])
    }
}
