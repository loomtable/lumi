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

    @Test("the defaults are a 30-minute idle timeout and an 8-second back window")
    func defaults() {
        #expect(policy.idleTimeout == 30 * 60)
        #expect(policy.backWindow == 8)
    }

    @Test("the first question starts fresh and stays pending until its turn finishes")
    func first() {
        var rules = ConversationRules(policy: policy)
        let (decision, chips) = rules.ask(projectFolder: "/p", at: t0, newID: "a")
        #expect(decision == .startFresh("a", .first))
        #expect(decision.conversationID == "a")
        #expect(chips.isEmpty)
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
        let (decision, chips) = rules.ask(projectFolder: "/p", at: t0.addingTimeInterval(60), newID: "b")
        #expect(decision == .continueCurrent("a"))
        #expect(chips.isEmpty)
        #expect(rules.lastActivity == t0.addingTimeInterval(60))
    }

    @Test("past the idle timeout the next question starts fresh with a resume chip")
    func idle() {
        var rules = withFinished()
        let (decision, chips) = rules.ask(projectFolder: nil, at: t0.addingTimeInterval(30 * 60 + 1), newID: "b")
        #expect(decision == .startFresh("b", .idle))
        #expect(chips == [.resume("a")])
        #expect(rules.currentID == "b")
        #expect(rules.currentIsPending)
    }

    @Test("exactly at the idle timeout the question continues")
    func idleBoundary() {
        var rules = withFinished()
        let (decision, chips) = rules.ask(projectFolder: nil, at: t0.addingTimeInterval(30 * 60), newID: "b")
        #expect(decision == .continueCurrent("a"))
        #expect(chips.isEmpty)
    }

    @Test("the idle timeout follows the policy")
    func customIdle() {
        var rules = ConversationRules(policy: ConversationPolicy(idleTimeout: 10))
        _ = rules.ask(projectFolder: nil, at: t0, newID: "a")
        rules.turnFinished(at: t0, projectFolder: nil)
        #expect(rules.ask(projectFolder: nil, at: t0.addingTimeInterval(10), newID: "b").0 == .continueCurrent("a"))
        #expect(rules.ask(projectFolder: nil, at: t0.addingTimeInterval(20.5), newID: "c").0 == .startFresh("c", .idle))
    }

    @Test("a different project in front starts fresh with keep-in-old")
    func otherProject() {
        var rules = withFinished("/p")
        let (decision, chips) = rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(1), newID: "b")
        #expect(decision == .startFresh("b", .otherProject))
        #expect(chips == [.keepInOld("a")])
        #expect(rules.currentProject == "/q")
    }

    @Test("no project in front continues and keeps the conversation's project")
    func nilProjectContinues() {
        var rules = withFinished("/p")
        let (decision, chips) = rules.ask(projectFolder: nil, at: t0.addingTimeInterval(1), newID: "b")
        #expect(decision == .continueCurrent("a"))
        #expect(chips.isEmpty)
        #expect(rules.currentProject == "/p")
    }

    @Test("a conversation without a project adopts the first project in front")
    func adoptsProject() {
        var rules = withFinished(nil)
        #expect(rules.ask(projectFolder: "/p", at: t0.addingTimeInterval(1), newID: "b").0 == .continueCurrent("a"))
        #expect(rules.currentProject == "/p")
        #expect(rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(2), newID: "c").0 == .startFresh("c", .otherProject))
    }

    @Test("a pending conversation without a project adopts the first project in front")
    func pendingAdoptsProject() {
        var rules = ConversationRules(policy: policy)
        _ = rules.ask(projectFolder: nil, at: t0, newID: "a")
        #expect(rules.ask(projectFolder: "/p", at: t0.addingTimeInterval(1), newID: "b").0 == .continueCurrent("a"))
        #expect(rules.currentProject == "/p")
        #expect(rules.currentIsPending)
    }

    @Test("⌘N starts fresh with a back chip for 8 s")
    func newConversation() {
        var rules = withFinished("/p")
        let now = t0.addingTimeInterval(5)
        let (decision, chips) = rules.newConversation(at: now, newID: "b")
        #expect(decision == .startFresh("b", .requested))
        #expect(chips == [.back(to: "a", until: now.addingTimeInterval(8))])
        #expect(rules.currentID == "b")
        #expect(rules.currentIsPending)
        #expect(rules.currentProject == nil)
    }

    @Test("⌘N with nothing current starts fresh without a chip")
    func newConversationFromNothing() {
        var rules = ConversationRules(policy: policy)
        let (decision, chips) = rules.newConversation(at: t0, newID: "a")
        #expect(decision == .startFresh("a", .requested))
        #expect(chips.isEmpty)
        #expect(rules.goBack(at: t0) == nil)
    }

    @Test("go back inside the window returns the previous conversation and its project")
    func goBackInWindow() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        #expect(rules.goBack(at: t0.addingTimeInterval(8)) == "a")
        #expect(rules.currentID == "a")
        #expect(rules.currentProject == "/p")
        #expect(!rules.currentIsPending)
        #expect(rules.goBack(at: t0.addingTimeInterval(8)) == nil)
        #expect(rules.ask(projectFolder: "/p", at: t0.addingTimeInterval(9), newID: "c").0 == .continueCurrent("a"))
    }

    @Test("go back after the window returns nil and keeps the new conversation")
    func goBackAfterWindow() {
        var rules = withFinished()
        _ = rules.newConversation(at: t0, newID: "b")
        #expect(rules.goBack(at: t0.addingTimeInterval(8.001)) == nil)
        #expect(rules.currentID == "b")
    }

    @Test("⌘N twice keeps the original back target")
    func newTwice() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        let (decision, chips) = rules.newConversation(at: t0.addingTimeInterval(2), newID: "c")
        #expect(decision == .startFresh("c", .requested))
        #expect(chips.count == 1)
        if case .back(let to, _) = chips.first { #expect(to == "a") } else { Issue.record("expected a back chip, got \(chips)") }
        #expect(rules.goBack(at: t0.addingTimeInterval(3)) == "a")
        #expect(rules.currentProject == "/p")
    }

    @Test("a pending fresh conversation takes the next question and still shows the back chip")
    func pendingTakesAsk() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        let (decision, chips) = rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(3), newID: "z")
        #expect(decision == .continueCurrent("b"))
        #expect(chips == [.back(to: "a", until: t0.addingTimeInterval(8))])
        #expect(rules.currentProject == "/q")
        // After the window the chip is gone.
        let (later, laterChips) = rules.ask(projectFolder: "/q", at: t0.addingTimeInterval(9), newID: "y")
        #expect(later == .continueCurrent("b"))
        #expect(laterChips.isEmpty)
    }

    @Test("switchTo makes a conversation current, not pending, and closes the back window")
    func switchTo() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        rules.switchTo("x", project: "/x", at: t0.addingTimeInterval(1))
        #expect(rules.currentID == "x")
        #expect(rules.currentProject == "/x")
        #expect(!rules.currentIsPending)
        #expect(rules.lastActivity == t0.addingTimeInterval(1))
        #expect(rules.goBack(at: t0.addingTimeInterval(2)) == nil)
        #expect(rules.ask(projectFolder: "/x", at: t0.addingTimeInterval(3), newID: "c").0 == .continueCurrent("x"))
    }

    @Test("forgetting clears the current conversation and the back target")
    func forgot() {
        var rules = withFinished("/p")
        _ = rules.newConversation(at: t0, newID: "b")
        rules.forgot("a")
        #expect(rules.currentID == "b")
        #expect(rules.goBack(at: t0.addingTimeInterval(1)) == nil)
        rules.forgot("b")
        #expect(rules.currentID == nil)
        #expect(rules.currentProject == nil)
        #expect(!rules.currentIsPending)
        #expect(rules.ask(projectFolder: nil, at: t0.addingTimeInterval(2), newID: "c").0 == .startFresh("c", .first))
    }

    @Test("forgetting another conversation leaves the current one")
    func forgotOther() {
        var rules = withFinished("/p")
        rules.forgot("zzz")
        #expect(rules.currentID == "a")
        #expect(rules.currentProject == "/p")
    }
}
