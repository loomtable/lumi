import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
import BuddyBridge
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// The Phase 0 seams: the coordinator sends every turn through `TurnPort`, asks `TurnRouting`
/// for the conversation and `AnswerDelivery` for the surface.
@MainActor
struct TurnSeamTests {
    let overlay = FakeOverlay()
    static let answer = BuddyBlock(say: "It's the totals row.", shape: .card)

    final class RecordingRouter: TurnRouting {
        let inner: any TurnRouting
        var requests: [RouteRequest] = []
        init(_ inner: any TurnRouting) { self.inner = inner }
        func route(_ request: RouteRequest) async -> RoutedTurn {
            requests.append(request)
            return await inner.route(request)
        }
    }

    final class RecordingDelivery: AnswerDelivery {
        var asked: [(String, TurnKind)] = []
        func surface(for answer: Answer, conversationID: String, kind: TurnKind) -> AnswerSurface {
            asked.append((conversationID, kind))
            return .glance
        }
    }

    private func make(_ turns: any TurnPort) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: turns,
            overlay: overlay, pointer: FixedPointer())
        coordinator.start()
        return coordinator
    }

    private func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private func typedAsk(_ coordinator: BuddyCoordinator, _ text: String) async {
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: text, source: .textBox))
        await settle(until: { coordinator.phase == .showing })
    }

    @Test func aTypedQuestionIsRoutedSentAsATypedCascadeTurnAndShownInTheGlance() async {
        let engine = FakeSessionEngine(cascade: [BuddyCoordinatorTests.done(Self.answer)])
        let coordinator = make(engine)
        let router = RecordingRouter(coordinator.routing)
        let delivery = RecordingDelivery()
        coordinator.routing = router
        coordinator.delivery = delivery
        let page = SessionID.new()
        coordinator.pages = FakePageSurfaces(showing: page)
        await typedAsk(coordinator, "which row is wrong?")

        #expect(router.requests.map(\.kind) == [.typed])
        #expect(router.requests.first?.visiblePage?.id == page)
        #expect(engine.sent.count == 1)
        guard case .cascade = engine.sent.first?.request.target else { Issue.record("a cascade turn"); return }
        #expect(engine.sent.first?.request.kind == .typed)
        #expect(delivery.asked.map(\.1) == [.typed])
        #expect(overlay.calls.contains { if case .answer = $0 { true } else { false } })
    }

    @Test func theDefaultRouterKeepsTodaysConversation() async {
        let conversations = MemoryConversations()
        let router = ConversationRouting(conversations: conversations, trust: { FolderTrust(trustedPaths: []) })
        let first = await router.route(RouteRequest(packet: ContextPacket(askedAt: .now, utterance: "a"), kind: .voice))
        let second = await router.route(RouteRequest(packet: ContextPacket(askedAt: .now, utterance: "b"), kind: .voice))
        #expect(first.sessionID == second.sessionID)
        #expect(first.sessionID.rawValue == first.conversation.state.id)
        #expect(first.harness == .quick)
    }

    @Test func aBridgeAnswersCascadeAndDeeperTurnsAndEndsSessionTurns() async {
        let bridge = FakeBridge(script: [.handingOff(say: "x")])
        let state = ConversationState(id: "c_1")
        let question = Question(packet: ContextPacket(askedAt: .now, utterance: "q"))
        var got: [TurnStreamEvent] = []
        for await e in await bridge.send(TurnRequest(question: question, state: state, kind: .voice, target: .cascade)) { got.append(e) }
        for await e in await bridge.send(TurnRequest(question: question, state: state, kind: .voice, target: .deeper)) { got.append(e) }
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: URL(filePath: "/tmp"))
        for await e in await bridge.send(TurnRequest(question: question, state: state, kind: .typed, target: .session(.new(), launch))) {
            got.append(e)
        }
        #expect(got == [.cascade(.handingOff(say: "x")), .cascade(.handingOff(say: "x"))])
        #expect(bridge.asked.count == 1 && bridge.deeperCount == 1)
    }
}
