import Foundation
import Testing
@testable import BuddyApp
import BuddyBridge
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace

/// QA U48: v2 session turns trace their first event, first spoken word and answer.
@MainActor
struct TurnMarksTests {
    typealias Mark = TurnMarks.Mark
    let ok = TurnEnd(kind: .voice, markdown: "Done.", block: BuddyBlock(say: "Done.", shape: .chip))

    @Test func theFirstEventIsMarkedOnceOnEveryPath() {
        var marks = TurnMarks()
        let m1 = marks.marks(for: .runState(.running), inPage: false, speaks: false)
        #expect(m1 == [Mark(event: .quickFirstEvent)])
        let m2 = marks.marks(for: .turnEnded(ok), inPage: false, speaks: false)
        #expect(m2.isEmpty, "the Glance marks its own answer")
    }

    @Test func aPageTurnMarksItsFirstWordAndAnswer() {
        var marks = TurnMarks()
        _ = marks.marks(for: .runState(.running), inPage: true, speaks: true)
        let m3 = marks.marks(for: .sayFirstSentence("Done."), inPage: true, speaks: true)
        #expect(m3 == [Mark(event: .firstSpokenWord)])
        let m4 = marks.marks(for: .say("Done."), inPage: true, speaks: true)
        #expect(m4.isEmpty)
        let m5 = marks.marks(for: .turnEnded(ok), inPage: true, speaks: true)
        #expect(m5 == [Mark(event: .answerShown, outcome: .ok)])
    }

    @Test func aSilentPageTurnMarksOnlyItsAnswerAndAFailedOneSaysSo() {
        var marks = TurnMarks()
        let m6 = marks.marks(for: .turnEnded(TurnEnd(kind: .typed, markdown: "", isError: true)), inPage: true, speaks: false)
        #expect(m6
            == [Mark(event: .quickFirstEvent), Mark(event: .answerShown, outcome: .failed)])
        var spoken = TurnMarks()
        // A typed answer with "Speak answers" on is spoken from its first sentence at the end.
        let m7 = spoken.marks(for: .turnEnded(TurnEnd(kind: .typed, markdown: "Hi.")), inPage: true, speaks: true)
        #expect(m7
            == [Mark(event: .quickFirstEvent), Mark(event: .firstSpokenWord), Mark(event: .answerShown, outcome: .ok)])
    }

    /// Routes every turn to one open session, as SessionRouting does with sessions on.
    final class SessionRouter: TurnRouting {
        let inner: any TurnRouting
        let id = SessionID.new()
        init(_ inner: any TurnRouting) { self.inner = inner }
        func route(_ request: RouteRequest) async -> RoutedTurn {
            var routed = await inner.route(request)
            routed.sessionID = id
            routed.conversation.state.id = id.rawValue
            routed.launch = SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp"))
            return routed
        }
    }

    @Test func aV2VoiceTurnOnTheGlanceTracesAllThree() async {
        let trace = RecordingTrace()
        let engine = FakeSessionEngine(session: [
            .turnStarted(userUUID: "u", kind: .voice), .sayFirstSentence("Done."), .say("Done."), .turnEnded(ok),
        ])
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: FakeVoice(), context: FakeContext.packet(), turns: engine,
                                 overlay: FakeOverlay(), pointer: FixedPointer(), trace: trace)
        c.routing = SessionRouter(c.routing)
        c.start()
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + waitCeiling
        while !trace.events.contains(.answerShown), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        guard case .session = engine.sent.first?.request.target else { Issue.record("a session turn"); return }
        let marks = trace.events.filter { [.quickFirstEvent, .firstSpokenWord, .answerShown].contains($0) }
        #expect(marks == [.quickFirstEvent, .firstSpokenWord, .answerShown])
        let untimed = trace.entries.filter { marks.contains($0.event) && !$0.timed }
        #expect(untimed.isEmpty, "each mark carries its latency")
    }

    @Test func aComposerTurnInThePageTracesItsFirstEventAndAnswer() async {
        let s = SessionID(rawValue: "s_1")
        let port = SessionScriptPort([.turnStarted(userUUID: "u", kind: .typed), .turnEnded(TurnEnd(kind: .typed, markdown: "Done"))])
        let flow = PageFlow(panel: FakePanel(), turns: port, permissions: LivePermissionHost(answering: FakeAnswering()))
        flow.makeRequest = { id, submit in
            TurnRequest(question: Question(packet: ContextPacket(askedAt: .now, utterance: submit.text)), state: ConversationState(id: id.rawValue),
                        kind: submit.kind, target: .session(id, SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp"))))
        }
        var traced: [(TraceEvent, TraceOutcome?)] = []
        flow.trace = { event, _, outcome in traced.append((event, outcome)) }
        await flow.handle(.submit(s, PageSubmit(text: "Fix it", kind: .typed, withScreen: false)))
        #expect(traced.map(\.0) == [.quickFirstEvent, .answerShown])
        #expect(traced.last?.1 == .ok)
    }
}
