import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

struct TrailReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func read(_ id: String, _ file: String) -> SessionEvent {
        .step(TrailStep(id: id, kind: .read, verb: "Reading", object: file))
    }

    @Test func startsThinkingAndShowsTheFirstStepAtOnce() {
        var trail = Trail(startedAt: t0)
        #expect(trail.live == "Thinking")
        trail.apply(read("a", "budget.md"), at: at(1))
        #expect(trail.live == "Reading budget.md")
        #expect(trail.liveLine(at: at(41)) == "Reading budget.md · 1 step · 0:41")
    }

    @Test func throttlesVerbChangesTo600ms() {
        var trail = Trail(startedAt: t0)
        trail.apply(read("a", "a.md"), at: at(1))
        trail.apply(.step(TrailStep(id: "b", kind: .bash, verb: "Run the auth tests")), at: at(1.2))
        #expect(trail.live == "Reading a.md")
        #expect(trail.nextTick == at(1.6))
        trail.tick(at: at(1.5))
        #expect(trail.live == "Reading a.md")
        trail.tick(at: at(1.6))
        #expect(trail.live == "Running the auth tests")
        #expect(trail.nextTick == nil)
    }

    @Test func aBurstOfReadsReadsAsACount() {
        var trail = Trail(startedAt: t0)
        for (i, f) in ["a", "b", "c", "d", "e", "f", "g"].enumerated() {
            trail.apply(read("r\(i)", "\(f).md"), at: at(1 + Double(i) * 0.05))
        }
        trail.tick(at: at(2))
        #expect(trail.live == "Reading 7 files")
        #expect(trail.stepCount == 7)
    }

    @Test func foldsThreeOrMoreSameKindStepsAndKeepsShorterRunsApart() {
        var trail = Trail(startedAt: t0)
        trail.apply(read("1", "a.md"), at: at(1))
        trail.apply(read("2", "b.md"), at: at(2))
        trail.apply(read("3", "c.md"), at: at(3))
        trail.apply(.step(TrailStep(id: "4", kind: .edit, verb: "Editing", object: "a.md")), at: at(4))
        trail.apply(read("5", "d.md"), at: at(5))
        trail.apply(read("6", "e.md"), at: at(6))
        let groups = trail.groups
        #expect(groups.map(\.rows.count) == [3, 1, 1, 1])
        #expect(groups[0].isFolded)
        #expect(groups[0].title == "Read 3 files")
        #expect(groups[1].title == "Edited a.md")
        #expect(groups[2].title == "Read d.md")
    }

    @Test func finishesStepsAndMarksErrors() {
        var trail = Trail(startedAt: t0)
        trail.apply(.step(TrailStep(id: "b", kind: .bash, verb: "Run the auth tests")), at: at(1))
        trail.apply(.stepFinished(id: "b", isError: true, preview: "2 failed"), at: at(15))
        #expect(trail.rows[0].status == .failed)
        #expect(trail.rows[0].duration == 14)
        #expect(trail.rows[0].preview == "2 failed")
        #expect(trail.rows[0].line == "Ran the auth tests")
    }

    @Test func aRepeatedStepIDUpdatesTheRowWithItsDiff() {
        var trail = Trail(startedAt: t0)
        trail.apply(.step(TrailStep(id: "e", kind: .edit, verb: "Editing", object: "a.swift")), at: at(1))
        let diff = StepDetail.diff(path: "/r/a.swift", old: "let x = 1", new: "let x = 2")
        trail.apply(.step(TrailStep(id: "e", kind: .edit, verb: "Editing", object: "a.swift", detail: diff)), at: at(2))
        #expect(trail.rows.count == 1)
        #expect(trail.rows[0].step?.detail == diff)
        #expect(trail.rows[0].startedAt == at(1))
    }

    @Test func subagentStepsStayOutOfTheLeadsTrail() {
        var trail = Trail(startedAt: t0)
        trail.apply(.step(TrailStep(id: "x", kind: .read, verb: "Reading", object: "a.md", subagent: "agent-1")), at: at(1))
        #expect(trail.rows.isEmpty)
    }

    @Test func doneLineSummarisesTheTurn() {
        var trail = Trail(startedAt: t0)
        for i in 0..<9 { trail.apply(read("r\(i)", "f\(i).md"), at: at(1)) }
        trail.apply(.step(TrailStep(id: "e1", kind: .edit, verb: "Editing", object: "a.md")), at: at(2))
        trail.apply(.step(TrailStep(id: "e2", kind: .edit, verb: "Editing", object: "a.md")), at: at(3))
        trail.apply(.step(TrailStep(id: "w", kind: .write, verb: "Writing", object: "b.md")), at: at(4))
        trail.apply(.step(TrailStep(id: "m", kind: .mcp(server: "claude_ai_Slack"), verb: "Using", object: "Slack")), at: at(5))
        trail.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Done.")), at: at(41))
        #expect(trail.phase == .done)
        #expect(trail.doneLine == "Worked for 0:41 · read 9 files, edited 2, checked Slack")
        #expect(trail.rows.allSatisfy { $0.status != .running })
    }

    @Test func aTurnWithNoStepsSaysOnlyHowLong() {
        var trail = Trail(startedAt: t0)
        trail.apply(.text("Hi", subagent: nil), at: at(1))
        trail.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "Hi")), at: at(4))
        #expect(trail.doneLine == "Worked for 0:04")
    }

    @Test func stopFreezesTheLine() {
        var trail = Trail(startedAt: t0)
        trail.apply(read("a", "a.md"), at: at(1))
        trail.stop(at: at(12))
        #expect(trail.phase == .stopped)
        #expect(trail.live == "Stopped")
        #expect(trail.doneLine == "Stopped after 0:12")
        // Events after the stop don't revive it.
        trail.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "")), at: at(13))
        #expect(trail.phase == .stopped)
    }

    @Test func failureNamesTheLastStep() {
        var trail = Trail(startedAt: t0)
        trail.apply(read("a", "invoices.pdf"), at: at(1))
        trail.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "", isError: true,
                                       error: SessionFailure(reason: .crashed, retryable: true))), at: at(3))
        #expect(trail.phase == .failed("Claude Code stopped unexpectedly."))
        #expect(trail.doneLine == "Claude Code stopped unexpectedly.")

        var other = Trail(startedAt: t0)
        other.apply(read("a", "invoices.pdf"), at: at(1))
        other.apply(.processEnded(status: 9, midTurn: true), at: at(2))
        // Interrupted isn't a failure (QA U11): the page offers Continue.
        #expect(other.phase == .interrupted)
        #expect(other.doneLine == "Interrupted")
    }

    @Test func aFailureSaysWhyInPlainWordsNeverARawCode() {
        // Round 3 S-07: "Couldn't finish: billing_error".
        func line(_ reason: SessionFailure.Reason, step: String? = nil) -> String {
            var trail = Trail(startedAt: t0)
            trail.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "", isError: true,
                                           error: SessionFailure(reason: reason, lastStep: step, retryable: false))), at: at(2))
            return trail.doneLine
        }
        #expect(line(.api("billing_error")) == "Your Claude plan is out of credit.")
        #expect(line(.api("model_not_found")) == "That model isn't available on your plan.")
        #expect(line(.api("error_max_turns"), step: "Reading a.md") == "Stopped after too many steps. Say continue to keep going.")
        // An unknown code falls back to the step it stopped on, else the plain default.
        #expect(line(.api("error_during_execution"), step: "Reading a.md") == "Couldn't finish: reading a.md")
        #expect(line(.api("error_during_execution")) == "Couldn't finish: the turn ended early")
        // A sentence from the CLI is kept.
        #expect(line(.api("Credit balance is too low")) == "Couldn't finish: Credit balance is too low")
        #expect(line(.rateLimited(resetsAt: nil), step: "Reading a.md") == "Your plan's usage limit is reached.")
        #expect(line(.rateLimited(resetsAt: t0)).hasPrefix("Your plan's usage limit is reached. It resets at "))
    }

    @Test func permissionMakesItWaitAndResolvingResumes() {
        var trail = Trail(startedAt: t0)
        trail.apply(.step(TrailStep(id: "b", kind: .bash, verb: "Running", object: "swift")), at: at(1))
        let ask = PermissionAsk(id: "p", title: "Run swift test", toolName: "Bash", detail: .command("swift test"), tier: .needsClick)
        trail.apply(.permissionRequested(ask), at: at(1.1))
        #expect(trail.phase == .needsYou)
        #expect(trail.live == "Waiting for you")
        trail.apply(.permissionResolved(id: "p"), at: at(1.2))
        #expect(trail.phase == .working)
        #expect(trail.live == "Running swift")
    }

    @Test func steerAndRetryAreRowsButNotSteps() {
        var trail = Trail(startedAt: t0)
        trail.apply(read("a", "a.md"), at: at(1))
        trail.steer("Only look at March", at: at(2))
        trail.apply(.retrying(attempt: 1, delayMS: 12_000, reason: "overloaded"), at: at(3))
        #expect(trail.stepCount == 1)
        #expect(trail.rows.count == 3)
        #expect(trail.rows[2].content == .retry(attempt: 1, until: at(15), reason: "overloaded"))
        #expect(trail.live == "Waiting to retry")
    }

    @Test func thinkingIsOneRowThatClosesWhenAStepStarts() {
        var trail = Trail(startedAt: t0)
        trail.apply(.thinking(summary: nil), at: at(1))
        trail.apply(.thinking(summary: "Checking the TTL"), at: at(2))
        #expect(trail.rows.count == 1)
        trail.apply(read("a", "a.md"), at: at(9))
        #expect(trail.rows[0].status == .done)
        #expect(trail.rows[0].duration == 8)
        #expect(trail.rows[0].content == .thinking(summary: "Checking the TTL"))
    }

    @Test(arguments: [
        ("Reading", "Read"), ("Searching for", "Searched for"), ("Searching the web for", "Searched the web for"),
        ("Finding files", "Found files"), ("Updating the plan", "Updated the plan"), ("Asking you", "Asked you"),
        ("Unknown verb", "Unknown verb"),
    ])
    func pastTense(present: String, past: String) {
        #expect(TrailCopy.pastVerb(present) == past)
    }

    @Test func bashDescriptionsTakeTheirTense() {
        let step = TrailStep(id: "b", kind: .bash, verb: "Run the auth tests")
        #expect(TrailCopy.presentLine(step) == "Running the auth tests")
        #expect(TrailCopy.pastLine(step) == "Ran the auth tests")
        let odd = TrailStep(id: "c", kind: .bash, verb: "Auth test sweep")
        #expect(TrailCopy.presentLine(odd) == "Auth test sweep")
    }

    @Test func clock() {
        #expect(TrailCopy.clock(0) == "0:00")
        #expect(TrailCopy.clock(41.9) == "0:41")
        #expect(TrailCopy.clock(250) == "4:10")
        #expect(TrailCopy.clock(3725) == "1:02:05")
    }

    @Test func connectorNames() {
        #expect(TrailCopy.connector("claude_ai_Slack") == "Slack")
        #expect(TrailCopy.connector("notion") == "Notion")
    }
}
