@testable import BuddyApp
import BuddyBridge
import BuddyCore
import Foundation
import Testing

@MainActor
struct PermissionHostTests {
    let s = SessionID(rawValue: "s_1")
    let answering = FakeAnswering()

    func ask(_ id: String, tier: ApprovalTier = .reversible) -> PermissionAsk {
        PermissionAsk(id: id, title: "Edit a.md", toolName: "Edit", detail: .plain(""), tier: tier)
    }

    @Test func allowAlwaysAndDenyBecomeDecisions() async {
        let host = LivePermissionHost(answering: answering)
        for id in ["a", "b", "c"] { host.observe(.permissionRequested(ask(id)), in: s) }
        #expect(host.pending(in: s).map(\.ask.id) == ["a", "b", "c"])
        await host.respond("a", in: s, allow: true)
        await host.respond("b", in: s, allow: true, always: true)
        await host.respond("c", in: s, allow: false, message: "Use make")
        #expect(answering.recorded == [
            .decide("a", s, .allow(updatedInput: nil)), .decide("b", s, .allowForSession), .decide("c", s, .deny(message: "Use make")),
        ])
        #expect(host.pending.isEmpty)
    }

    @Test func neverAnswersTwiceOrACancelledRequest() async {
        let host = LivePermissionHost(answering: answering)
        host.observe(.permissionRequested(ask("a")), in: s)
        await host.respond("a", in: s, allow: true)
        await host.respond("a", in: s, allow: false)
        // The engine's echo of the request after an answer doesn't bring it back.
        host.observe(.permissionRequested(ask("a")), in: s)
        #expect(host.pending.isEmpty)
        #expect(answering.recorded.count == 1)

        host.observe(.permissionRequested(ask("b")), in: s)
        host.observe(.permissionResolved(id: "b"), in: s) // the CLI cancelled it
        #expect(host.pending.isEmpty)
    }

    @Test func aSpokenYesOnlyForReversibleAsksWhileFocusedAndHeld() async {
        let host = LivePermissionHost(answering: answering)
        host.observe(.permissionRequested(ask("send", tier: .needsClick)), in: s)
        #expect(await host.approveByVoice(in: s, cardFocused: true, keyHeld: true) == nil)
        host.observe(.permissionRequested(ask("edit")), in: s)
        #expect(await host.approveByVoice(in: s, cardFocused: false, keyHeld: true) == nil)
        #expect(await host.approveByVoice(in: s, cardFocused: true, keyHeld: false) == nil)
        #expect(await host.approveByVoice(in: s, cardFocused: true, keyHeld: true) == "edit")
        #expect(answering.recorded == [.decide("edit", s, .allow(updatedInput: nil))])
        #expect(host.pending(in: s).map(\.ask.id) == ["send"])
    }

    @Test func questionsAreAnsweredWithTheirLabels() async {
        let host = LivePermissionHost(answering: answering)
        let q = QuestionAsk(id: "q", items: [.init(question: "Which?", header: "Pick", options: [.init(label: "A"), .init(label: "B")])])
        host.observe(.questionAsked(q), in: s)
        await host.answerQuestion("q", in: s, answers: ["Which?": "B"])
        await host.answerQuestion("q", in: s, answers: ["Which?": "A"])
        #expect(answering.recorded == [.answer("q", s, ["Which?": "B"])])
    }

    @Test func anUnsentReplyLeavesTheAskPending() async {
        let host = LivePermissionHost(answering: FakeAnswering(writes: false))
        host.observe(.permissionRequested(ask("a")), in: s)
        #expect(await host.respond("a", in: s, allow: true) == false)
        #expect(host.pending.map(\.ask.id) == ["a"])
        #expect(host.ask("a")?.id == "a")
        let none = LivePermissionHost(answering: NoPermissionAnswering())
        none.observe(.permissionRequested(ask("b")), in: s)
        #expect(await none.respond("b", in: s, allow: true) == false)
        #expect(none.pending.count == 1)
    }

    @Test func aTeammatesAskSurvivesTheLeadsTurnEnd() {
        // QA R9: a background teammate still waits for its answer after the lead's result.
        let host = LivePermissionHost(answering: answering)
        host.observe(.permissionRequested(PermissionAsk(id: "t", title: "Edit", toolName: "Edit", detail: .plain(""), tier: .reversible,
                                                        asker: "Researcher")), in: s)
        host.observe(.permissionRequested(ask("lead")), in: s)
        host.observe(.turnEnded(TurnEnd(kind: .typed, markdown: "")), in: s)
        #expect(host.pending.map(\.ask.id) == ["t"])
        host.observe(.processEnded(status: 0, midTurn: false), in: s)
        #expect(host.pending.isEmpty)
    }

    @Test func aFinishedTurnClearsItsAsks() {
        let host = LivePermissionHost(answering: answering)
        host.observe(.permissionRequested(ask("a")), in: s)
        host.observe(.permissionRequested(ask("b")), in: SessionID(rawValue: "s_2"))
        host.observe(.turnEnded(TurnEnd(kind: .typed, markdown: "")), in: s)
        #expect(host.pending.map(\.ask.id) == ["b"])
    }
}
