@testable import BuddyApp
import BuddyBridge
import BuddyCore
import Foundation
import Testing

/// The shared Phase 0 fakes behave as their docs say, so streams can build on them.
@MainActor
struct SeamFakesTests {
    private func request(_ target: TurnRequest.Target, kind: TurnKind = .typed) -> TurnRequest {
        TurnRequest(question: Question(packet: ContextPacket(askedAt: .now, utterance: "hi")), state: ConversationState(id: "c_1"), kind: kind, target: target)
    }

    @Test func sessionTurnsReplayTheScriptAndRecordTheLaunch() async {
        let id = SessionID.new()
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: URL(filePath: "/tmp"))
        let engine = FakeSessionEngine(session: [.runState(.running), .turnEnded(TurnEnd(kind: .typed, markdown: "ok"))])
        var got: [TurnStreamEvent] = []
        for await event in await engine.send(request(.session(id, launch))) { got.append(event) }
        #expect(got == [.session(.runState(.running)), .session(.turnEnded(TurnEnd(kind: .typed, markdown: "ok")))])
        #expect(engine.launches == [launch])
        #expect(engine.sent.first?.session == id)
    }

    @Test func manualSessionStreamsStayOpenUntilFinished() async {
        let id = SessionID.new()
        let engine = FakeSessionEngine(manual: true)
        let stream = await engine.send(request(.session(id, SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp")))))
        engine.emit(.compacted, to: id)
        engine.finish(id)
        var got: [TurnStreamEvent] = []
        for await event in stream { got.append(event) }
        #expect(got == [.session(.compacted)])
    }

    @Test func sessionsPortPublishesChanges() async throws {
        let a = SessionSnapshot.sample("s_a")
        let port = FakeSessionsPort([a])
        var changes = port.changes().makeAsyncIterator()
        #expect(await changes.next()?.map(\.id) == [a.id])
        port.apply(.turnStarted(userUUID: nil, kind: .voice), to: a.id)
        guard case .thinking = await changes.next()?.first?.status else { Issue.record("thinking"); return }
        await port.setPinned(true, for: a.id)
        #expect(await changes.next()?.first?.pinned == true)
        try await port.forget(a.id)
        #expect(await changes.next()?.isEmpty == true)
    }

    @Test func noPageIsVisibleUntilTheTestSaysSo() {
        #expect(NoPageSurfaces().visiblePage == nil)
        let id = SessionID.new()
        #expect(FakePageSurfaces(showing: id, kind: .studio).visiblePage?.id == id)
    }
}
