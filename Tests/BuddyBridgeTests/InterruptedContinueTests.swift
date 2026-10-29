import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

/// Lumi quits (SIGTERM) mid-turn, then "Continue" resumes with `--resume <id>` and
/// `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1` (recorded: interrupted-sigterm → interrupted-continue).
struct InterruptedContinueTests {
    @Test func killedMidTurnReportsAnInterruptedProcess() throws {
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .typed, userUUID: nil)
        var events = try Fixture.events("interrupted-sigterm.jsonl").flatMap { mapper.map($0) }
        #expect(events.turnsStarted.count == 1)
        #expect(events.turnsEnded.isEmpty)
        #expect(mapper.isTurnOpen)
        events += mapper.processEnded(status: 143)
        #expect(events.last == .processEnded(status: 143, midTurn: true))
        #expect(!mapper.isTurnOpen)
    }

    @Test func continueResumesTheSameTurnUnderItsOriginalUUID() throws {
        let original = try #require(try Fixture.events("interrupted-sigterm.jsonl").compactMap {
            if case .userEcho(let u) = $0 { u.uuid } else { nil }
        }.first)
        // A fresh process: the host registers the interrupted turn before writing initialize.
        var mapper = SessionEventMapper()
        mapper.beginTurn(kind: .voice, userUUID: original)
        let events = try Fixture.events("interrupted-continue.jsonl").flatMap { mapper.map($0) }
        // The CLI's lifecycle line names a new command uuid; the turn keeps the original one.
        #expect(events.turnsStarted.map(\.0) == [original])
        #expect(events.turnsStarted.map(\.1) == [.voice])
        #expect(events.turnsEnded.count == 1)
        #expect(events.turnsEnded.first?.isError == false)
        #expect(events.steps.map(\.kind) == [.bash])
        #expect(events.runStates.last == .idle)
    }

    @Test func idleProcessEndIsNotMidTurn() {
        var mapper = SessionEventMapper()
        _ = mapper.map(.sessionState("idle"))
        #expect(mapper.processEnded(status: 0) == [.processEnded(status: 0, midTurn: false)])
    }

    @Test func pendingAsksAreVoidWhenTheProcessEnds() {
        var mapper = SessionEventMapper()
        _ = mapper.map(.controlRequest(id: "r1", request: PermissionWire.parse(["subtype": "can_use_tool", "tool_name": "Bash",
                                                                                 "input": ["command": "ls"]])))
        #expect(mapper.hasPendingRequests)
        let events = mapper.processEnded(status: 1)
        #expect(events.first == .permissionResolved(id: "r1"))
        #expect(!mapper.hasPendingRequests)
    }
}
