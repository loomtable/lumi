import BuddyCore
import Testing
@testable import BuddyApp

/// QA U14: the Glance card's ⤢ Continue counts a voice turn's steps only after reviewable work.
struct StepTallyTests {
    @Test func readsAloneShowNoCountAndAnEditShowsEveryMainStep() {
        var tally = StepTally()
        tally.apply(.step(TrailStep(id: "a", kind: .read, verb: "Reading")))
        tally.apply(.step(TrailStep(id: "b", kind: .search, verb: "Searching for")))
        #expect(tally.shown == nil)
        tally.apply(.step(TrailStep(id: "c", kind: .edit, verb: "Editing")))
        tally.apply(.step(TrailStep(id: "c", kind: .edit, verb: "Editing"))) // the same tool use again
        tally.apply(.step(TrailStep(id: "d", kind: .read, verb: "Reading", subagent: "t1"))) // a teammate's
        #expect(tally.shown == 3)
    }

    @Test func anApprovalOrATeammateIsWorthReviewing() {
        var asked = StepTally()
        asked.apply(.permissionRequested(PermissionAsk(id: "p", title: "Run ls", toolName: "Bash", detail: .command("ls"), tier: .needsClick)))
        #expect(asked.shown == 1)
        var mate = StepTally()
        mate.apply(.task(.started(taskID: "t", toolUseID: nil, name: "Scout", description: "Look", kind: .agent)))
        #expect(mate.shown == 1)
        var job = StepTally()
        job.apply(.task(.started(taskID: "j", toolUseID: nil, name: nil, description: "sleep", kind: .bash)))
        #expect(job.shown == nil)
    }
}
