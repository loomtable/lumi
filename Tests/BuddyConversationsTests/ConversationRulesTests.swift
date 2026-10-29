import Foundation
import Testing
@testable import BuddyConversations

@Suite("ConversationRules")
struct ConversationRulesTests {
    let policy = ConversationPolicy()

    /// Rules with one finished conversation "a" in `project`, last active at t0.
    func withFinished(_ project: String? = nil) -> ConversationRules {
        var rules = ConversationRules(policy: policy)
        _ = rules.ask(projectFolder: project, at: t0, newID: "a")
        rules.turnFinished(at: t0, projectFolder: project)
        return rules
    }

    @Test("the default is a 30-minute idle timeout")
    func defaults() {
        #expect(policy.idleTimeout == 30 * 60)
    }

    @Test("the first question starts fresh and stays pending until its turn finishes")
    func first() {
        var rules = ConversationRules(policy: policy)
        let decision = rules.ask(projectFolder: "/p", at: t0, newID: "a")
        #expect(decision == .startFresh("a", .first))
        #expect(decision.conversationID == "a")
        #expect(rules.currentID == "a")
        #expect(rules.currentIsPending)
        #expect(rules.currentProject == "/p")
        rules.turnFinished(at: t0, projectFolder: nil)
        #expect(!rules.currentIsPending)
        #expect(rules.currentProject == "/p")
    }

    @Test("follow-ups continue by default")
    func continues() {
        var rules = withFinished("/p")
        let decision = rules.ask(projectFolder: "/p", at: t0.addingTimeInterval(60), newID: "b")
        #expect(decision == .continueCurrent("a"))
        #expect(rules.lastActivity == t0.addingTimeInterval(60))
    }

    @Test("past the idle timeout the next question starts fresh")
    func idle() {
        var rules = withFinished()
        let decision = rules.ask(projectFolder: nil, at: t0.addingTimeInterval(30 * 60 + 1), newID: "b")
        #expect(decision == .startFresh("b", .idle))
        #expect(rules.currentID == "b")
        #expect(rules.currentIsPending)
    }

    @Test("exactly at the idle timeout the question continues")
    func idleBoundary() {
        var rules = withFinished()
        let decision = rules.ask(projectFolder: nil, at: t0.addingTimeInterval(30 * 60), newID: "b")
        #expect(decision == .continueCurrent("a"))
    }

    @Test("the idle timeout follows the policy")
    func customIdle() {
        var rules = ConversationRules(policy: ConversationPolicy(idleTimeout: 10))
        _ = rules.ask(projectFolder: nil, at: t0, newID: "a")
        rules.turnFinished(at: t0, projectFolder: nil)
        #expect(rules.ask(projectFolder: nil, at: t0.addingTimeInterval(10), newID: "b") == .continueCurrent("a"))
        #expect(rules.ask(projectFolder: nil, at: t0.addingTimeInterval(20.5), newID: "c") == .startFresh("c", .idle))
    }

    @Test("a different project in front continues the conversation (the resume bug)")
    func otherProjectContinues() {
        var rules = withFinished("/p")
        let decision = rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(1), newID: "b")
        #expect(decision == .continueCurrent("a"))
        #expect(rules.currentProject == "/p")
    }

    @Test("home is never a project: Deep in home doesn't make a later repo 'another project'")
    func homeIsNotAProject() {
        var rules = ConversationRules(policy: ConversationPolicy(home: "/Users/me"))
        _ = rules.ask(projectFolder: nil, at: t0, newID: "a")
        rules.turnFinished(at: t0, projectFolder: "/Users/me/")
        #expect(rules.currentProject == nil)
        #expect(rules.ask(projectFolder: "/Users/me", at: t0.addingTimeInterval(1), newID: "b") == .continueCurrent("a"))
        #expect(rules.currentProject == nil)
        #expect(rules.ask(projectFolder: "/Users/me/Developer/lumi", at: t0.addingTimeInterval(2), newID: "c") == .continueCurrent("a"))
        #expect(rules.currentProject == "/Users/me/Developer/lumi")
    }

    @Test("no project in front continues and keeps the conversation's project")
    func nilProjectContinues() {
        var rules = withFinished("/p")
        let decision = rules.ask(projectFolder: nil, at: t0.addingTimeInterval(1), newID: "b")
        #expect(decision == .continueCurrent("a"))
        #expect(rules.currentProject == "/p")
    }

    @Test("a conversation without a project adopts the first project in front")
    func adoptsProject() {
        var rules = withFinished(nil)
        #expect(rules.ask(projectFolder: "/p", at: t0.addingTimeInterval(1), newID: "b") == .continueCurrent("a"))
        #expect(rules.currentProject == "/p")
        #expect(rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(2), newID: "c") == .continueCurrent("a"))
    }

    @Test("a pending conversation without a project adopts the first project in front")
    func pendingAdoptsProject() {
        var rules = ConversationRules(policy: policy)
        _ = rules.ask(projectFolder: nil, at: t0, newID: "a")
        #expect(rules.ask(projectFolder: "/p", at: t0.addingTimeInterval(1), newID: "b") == .continueCurrent("a"))
        #expect(rules.currentProject == "/p")
        #expect(rules.currentIsPending)
    }

    @Test("⌘N starts fresh, pending, with no project")
    func newConversation() {
        var rules = withFinished("/p")
        let now = t0.addingTimeInterval(5)
        let decision = rules.newConversation(at: now, newID: "b")
        #expect(decision == .startFresh("b", .requested))
        #expect(rules.currentID == "b")
        #expect(rules.currentIsPending)
        #expect(rules.currentProject == nil)
    }

    @Test("⌘N with nothing current starts fresh")
    func newConversationFromNothing() {
        var rules = ConversationRules(policy: policy)
        let decision = rules.newConversation(at: t0, newID: "a")
        #expect(decision == .startFresh("a", .requested))
    }

    @Test("a pending fresh conversation takes the next question")
    func pendingTakesAsk() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        let decision = rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(3), newID: "z")
        #expect(decision == .continueCurrent("b"))
        #expect(rules.currentProject == "/q")
        let later = rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(9), newID: "y")
        #expect(later == .continueCurrent("b"))
    }

    @Test("switchTo makes a conversation current and not pending")
    func switchTo() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        rules.switchTo("x", project: "/x", at: t0.addingTimeInterval(1))
        #expect(rules.currentID == "x")
        #expect(rules.currentProject == "/x")
        #expect(!rules.currentIsPending)
        #expect(rules.lastActivity == t0.addingTimeInterval(1))
        #expect(rules.ask(projectFolder: "/x", at: t0.addingTimeInterval(3), newID: "c") == .continueCurrent("x"))
    }

    @Test("forgetting clears the current conversation")
    func forgot() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        rules.forgot("a")
        #expect(rules.currentID == "b")
        rules.forgot("b")
        #expect(rules.currentID == nil)
        #expect(rules.currentProject == nil)
        #expect(!rules.currentIsPending)
        #expect(rules.ask(projectFolder: nil, at: t0.addingTimeInterval(2), newID: "c") == .startFresh("c", .first))
    }

    @Test("forgetting another conversation leaves the current one")
    func forgotOther() {
        var rules = withFinished("/p")
        rules.forgot("zzz")
        #expect(rules.currentID == "a")
        #expect(rules.currentProject == "/p")
    }
}
