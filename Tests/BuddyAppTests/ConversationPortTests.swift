import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// Records calls over the in-memory rules, so the coordinator's use of the port is visible.
@MainActor final class RecordingConversations: ConversationPort {
    private let inner = MemoryConversations()
    private(set) var prepared: [String?] = []
    private(set) var updates: [ConversationState] = []
    private(set) var recorded: [String] = []
    private(set) var newCount = 0
    private(set) var switched: [String] = []
    private(set) var screenshots: [(path: String, conversation: String)] = []
    var log: [String] = []

    var current: ConversationTurn? { inner.current }
    func prepare(project: String?) async -> ConversationTurn {
        prepared.append(project)
        log.append("prepare")
        return await inner.prepare(project: project)
    }
    func update(_ state: ConversationState) async {
        updates.append(state)
        await inner.update(state)
    }
    func recordTurn(conversationID: String, question: String, answer: String) async -> ConversationTurn? {
        recorded.append(question)
        return await inner.recordTurn(conversationID: conversationID, question: question, answer: answer)
    }
    func startNew() async -> ConversationTurn {
        newCount += 1
        log.append("new")
        return await inner.startNew()
    }
    func switchTo(_ id: String) async -> ConversationTurn? {
        switched.append(id)
        return inner.current
    }
    func recordScreenshot(_ path: String, conversationID: String) async {
        screenshots.append((path, conversationID))
    }
}

/// `startNew` parks until released, like an index write that takes a while.
@MainActor final class SlowNewConversations: ConversationPort {
    private let inner = MemoryConversations()
    private var parked: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { parked.count }

    var current: ConversationTurn? { inner.current }
    func prepare(project: String?) async -> ConversationTurn { await inner.prepare(project: project) }
    func update(_ state: ConversationState) async { await inner.update(state) }
    func recordTurn(conversationID: String, question: String, answer: String) async -> ConversationTurn? {
        await inner.recordTurn(conversationID: conversationID, question: question, answer: answer)
    }
    func startNew() async -> ConversationTurn {
        await withCheckedContinuation { parked.append($0) }
        return await inner.startNew()
    }
    func release() {
        let p = parked
        parked.removeAll()
        p.forEach { $0.resume() }
    }
}

@MainActor
struct ConversationPortTests {
    @Test func aListenStartedWhileTheNewConversationIsCreatedSurvives() async {
        let conversations = SlowNewConversations()
        let overlay = FakeOverlay()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: FakeBridge(),
            overlay: overlay, pointer: FixedPointer(), conversations: conversations)
        c.start()

        overlay.send(.newConversation)
        let deadline = ContinuousClock.now + waitCeiling
        while conversations.waiting == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        await c.handle(.gesture(.pressBegan(fresh: false))) // the key, while the index is still writing
        conversations.release()
        for _ in 0..<100 { await Task.yield() }
        #expect(c.phase == .listening(confirmedTap: false, holding: false))
        #expect(overlay.calls.last { if case .dismiss = $0 { true } else { false } } == .dismiss(.requested))
        #expect(!overlay.calls.drop { $0 != .listening(CGPoint(x: 400, y: 300), hint: "tap ⌥ to send") }.contains(.dismiss(.requested)))
    }

    @Test func theCoordinatorUsesTheInjectedPort() async {
        let conversations = RecordingConversations()
        let overlay = FakeOverlay()
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip), sessionID: "q1")])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer(), conversations: conversations)
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + waitCeiling
        while c.phase != .showing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }

        #expect(conversations.prepared.count == 1)
        #expect(conversations.updates.first?.quickSessionID == "q1")
        #expect(conversations.recorded == ["what does this mean?"])
        #expect(conversations.current?.turn == 1)
        #expect(bridge.asked.first?.packet.conversation?.id == conversations.current?.state.id)
        // Recorded off the question's path: give its task a moment.
        for _ in 0..<1000 where conversations.screenshots.isEmpty { await Task.yield() }
        #expect(conversations.screenshots.map(\.path) == ["/tmp/shot.jpg"], "linked so Forget deletes it")
        #expect(conversations.screenshots.first?.conversation == conversations.current?.state.id)

        overlay.send(.newConversation)
        while conversations.newCount == 0, ContinuousClock.now < deadline + .seconds(2) { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(conversations.newCount == 1)
        #expect(conversations.current?.turn == 0)
    }

    // MARK: New conversation and resume (⇧ + buddy key, "new topic", chips)

    private func make(_ conversations: RecordingConversations, _ overlay: FakeOverlay, _ bridge: FakeBridge,
                      voice: FakeVoice = FakeVoice()) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer(), conversations: conversations)
        c.start()
        return c
    }

    private func hold(_ c: BuddyCoordinator, fresh: Bool) async {
        await c.handle(.gesture(.pressBegan(fresh: fresh)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + waitCeiling
        while c.phase == .thinking || c.phase == .listening(confirmedTap: false, holding: true), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func shiftWithTheBuddyKeyAsksInANewConversation() async {
        let conversations = RecordingConversations()
        let overlay = FakeOverlay()
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let c = make(conversations, overlay, bridge)
        await hold(c, fresh: true)
        #expect(conversations.log.prefix(2) == ["new", "prepare"], "the new conversation exists before the question takes one")
        #expect(overlay.calls.contains(.listening(CGPoint(x: 400, y: 300), hint: "new session · tap ⌥ to send")))
        #expect(overlay.calls.contains(.toast("New session")))
        #expect(bridge.asked.count == 1)
    }

    @Test func aPlainPressContinues() async {
        let conversations = RecordingConversations()
        let c = make(conversations, FakeOverlay(), FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))]))
        await hold(c, fresh: false)
        #expect(conversations.newCount == 0)
    }

    @Test func sayingNewTopicStartsFreshAndAsksTheRest() async {
        let conversations = RecordingConversations()
        let voice = FakeVoice()
        voice.setTranscript("New topic, what's a heat pump?")
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "A pump.", shape: .chip))])
        let c = make(conversations, FakeOverlay(), bridge, voice: voice)
        await hold(c, fresh: false)
        #expect(conversations.newCount == 1)
        #expect(bridge.asked.first?.packet.utterance == "what's a heat pump?")
    }

    @Test func conversationCommandsAreWholeWordsAtTheStart() {
        #expect(ConversationCommand.parse("new topic") == .newTopic(rest: ""))
        #expect(ConversationCommand.parse("Start over. What's this?") == .newTopic(rest: "What's this?"))
        #expect(ConversationCommand.parse("new topics in physics") == nil)
        #expect(ConversationCommand.parse("what's the new topic here") == nil)
        #expect(ConversationCommand.parse("go back") == nil, "going back is the switcher's, not a command")
    }

    @Test func aShiftChordTypedOverAnAnswerLeavesItAlone() async {
        let conversations = RecordingConversations()
        let overlay = FakeOverlay()
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let c = make(conversations, overlay, bridge)
        await hold(c, fresh: false)
        #expect(c.phase == .showing)
        await c.handle(.gesture(.pressBegan(fresh: true))) // ⇧ then right ⌥ …
        await c.handle(.gesture(.cancelled(.otherKey(27)))) // … then "-": an em dash
        #expect(c.phase == .showing)
        #expect(overlay.calls.filter { if case .listening = $0 { true } else { false } }.count == 1, "no second listen started")
    }

    @Test func aShiftTapOverAnAnswerListensInANewConversation() async {
        let conversations = RecordingConversations()
        let overlay = FakeOverlay()
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let c = make(conversations, overlay, bridge)
        await hold(c, fresh: false)
        await c.handle(.gesture(.pressBegan(fresh: true)))
        await c.handle(.gesture(.tap))
        #expect(c.phase == .listening(confirmedTap: true, holding: false))
        #expect(overlay.calls.contains(.listening(CGPoint(x: 400, y: 300), hint: "new session · tap ⌥ to send")))
    }
}
