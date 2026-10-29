@testable import BuddyApp
import BuddyBridge
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import Foundation
import Synchronization
import Testing

/// V-04 (audit-voice): a Quick (cascade) answer never reached LiveSessions, so peeks, previews,
/// counts and order went stale for most voice sessions. It now finishes through the same reducer
/// as an open session's turn end.
@MainActor
struct CascadeTurnTests {
    private func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try await condition()
    }

    private func packet(_ utterance: String) -> ContextPacket {
        var p = ContextPacket(askedAt: .now, utterance: utterance)
        p.app = .init(name: "Safari", bundle: "com.apple.Safari", kind: .browser)
        return p
    }

    /// A spoken summons: a new Quick session, and the turn the cascade's port saves for it.
    private func quickTurn(_ h: LiveSessionsTests.Harness, _ question: String, at now: Date) async throws -> SessionID {
        let plan = await h.sessions.plan(SummonInput(source: .talkKey, kind: .voice, now: now), packet: packet(question))
        #expect(plan.harness == .quick)
        _ = try await h.index.recordTurn(id: plan.id.rawValue, at: now, quickSessionID: "q-\(plan.id.rawValue)",
                                         deepSessionID: nil, lastLane: .quick, projectFolder: nil, deepFolder: nil)
        return plan.id
    }

    @Test func aQuickAnswerUpdatesTheLastLineStatusPreviewAndOrder() async throws {
        let h = try LiveSessionsTests.Harness()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let older = try await quickTurn(h, "what's the weather in Lisbon", at: t0)
        let newer = try await quickTurn(h, "how big is this table", at: t0.addingTimeInterval(60))
        let before = try #require(try await h.index.record(id: older.rawValue))

        _ = try await h.index.recordTurn(id: older.rawValue, at: t0.addingTimeInterval(120), quickSessionID: "q", deepSessionID: nil,
                                         lastLane: .quick, projectFolder: nil, deepFolder: nil)
        h.sessions.finishCascadeTurn(older, kind: .voice, question: "and tomorrow?",
                                     block: BuddyBlock(say: "Sunny, 24 degrees.", shape: .chip))
        let snap = try #require(h.sessions.snapshots.first { $0.id == older })
        #expect(snap.lastSay == "Sunny, 24 degrees.", "the peek has a line at once")
        guard case .done(_, true) = snap.status else { Issue.record("done, unread: \(snap.status)"); return }
        #expect(try await eventually { h.sessions.snapshots.first?.id == older }, "the answered session moves to the top")
        #expect(try await eventually { try await h.index.record(id: older.rawValue)?.status == .doneUnread })
        let after = try #require(try await h.index.record(id: older.rawValue))
        #expect(after.turns == before.turns + 1, "counted once, by the cascade's port")
        #expect(after.voiceRulesNeeded == before.voiceRulesNeeded, "no open Claude session got the rules")
        #expect(h.sessions.snapshots.first { $0.id == older }?.turns == after.turns)
        _ = newer
    }

    @Test func aRelaunchedQuickSessionPeeksItsLastAnswerFromTheRecap() async throws {
        let h = try LiveSessionsTests.Harness()
        let id = try await quickTurn(h, "what's the weather in Lisbon", at: Date())
        try await h.index.setRecap(["Q: what's the weather in Lisbon\nA: Sunny, 24 degrees."], id: id.rawValue)
        let again = LiveSessions(store: SessionStore(index: h.index, files: h.files, home: LiveSessionsTests.home.path),
                                 manager: h.manager, trust: { FolderTrust(trustedPaths: []) })
        await again.reload()
        #expect(again.snapshots.first { $0.id == id }?.lastSay == "Sunny, 24 degrees.")
        #expect(ContextPacket.Conversation.recapAnswer("Q: x") == nil)
    }

    @Test func aQuickTopicNamesTheSessionAndOneWithoutAsksTheTitler() async throws {
        let h = try LiveSessionsTests.Harness()
        let titler = CountingTitler(SessionTopic(title: "Table size", symbol: "tablecells"))
        h.sessions.titler = titler
        let named = try await quickTurn(h, "plan a trip to Lisbon", at: Date())
        h.sessions.finishCascadeTurn(named, kind: .voice, question: "plan a trip to Lisbon",
                                     block: BuddyBlock(say: "Three days.", shape: .chip,
                                                       topic: SessionTopic(title: "Lisbon trip", symbol: "airplane")))
        #expect(try await eventually { try await h.index.record(id: named.rawValue)?.title == "Lisbon trip" })

        let plain = try await quickTurn(h, "how big is this table", at: Date())
        h.sessions.finishCascadeTurn(plain, kind: .voice, question: "how big is this table",
                                     block: BuddyBlock(say: "Twelve rows.", shape: .chip))
        #expect(try await eventually { try await h.index.record(id: plain.rawValue)?.title == "Table size" })
        #expect(titler.calls == 1, "only the answer without a topic")
    }

    /// The coordinator finishes a cascade answer's session once, through the router.
    @Test func theCoordinatorFinishesAQuickAnswersSession() async throws {
        let bridge = FakeBridge()
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "It's QT.", shape: .card), id: "s_q")])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: bridge,
                                 overlay: FakeOverlay(), pointer: FixedPointer())
        let spy = CascadeSpyRouting()
        c.routing = spy
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        #expect(try await eventually { !spy.finished.isEmpty })
        #expect(spy.finished.map(\.say) == ["It's QT."])
        #expect(spy.finished.first?.kind == .voice)
    }

    /// An answer Quick handed to the session's open Claude session is finished by that session's own
    /// events, not a second time here (no doubled recap entry).
    @Test func aHandOffIntoTheOpenSessionIsNotFinishedTwice() async throws {
        guard case .done(var result) = BuddyCoordinatorTests.done(BuddyBlock(say: "It's QT.", shape: .card), lane: .deep, id: "s_q")
        else { Issue.record("a done event"); return }
        result.inOpenSession = true
        let bridge = FakeBridge()
        bridge.setScript([.handingOff(say: "Let me check."), .done(result)])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let overlay = FakeOverlay()
        let c = BuddyCoordinator(settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: bridge,
                                 overlay: overlay, pointer: FixedPointer())
        let spy = CascadeSpyRouting()
        c.routing = spy
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        #expect(try await eventually { c.phase == .showing })
        #expect(spy.finished.isEmpty)
    }
}

private final class CountingTitler: SessionTitler {
    let reply: SessionTopic
    let count = Mutex(0)
    init(_ reply: SessionTopic) { self.reply = reply }
    var calls: Int { count.withLock { $0 } }
    func topic(question: String, answer: String) async -> SessionTopic? {
        count.withLock { $0 += 1 }
        return reply
    }
}

@MainActor
private final class CascadeSpyRouting: TurnRouting {
    private let inner = ConversationRouting(conversations: MemoryConversations(), trust: { FolderTrust(trustedPaths: []) })
    var finished: [(id: SessionID, kind: TurnKind, say: String)] = []

    func route(_ request: RouteRequest) async -> RoutedTurn { await inner.route(request) }

    func cascadeTurnFinished(_ id: SessionID, kind: TurnKind, question: String, block: BuddyBlock) {
        finished.append((id, kind, block.say))
    }
}
