import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

/// Recorded streams (claude 2.1.312) through the mapper into the one teammate model: every lane
/// stays from its spawn to the merged answer, across the lead's interim answers and the CLI's
/// hand-back turns, and its state only moves forward.
struct TeamReplayTests {
    struct Frame {
        var event: SessionEvent
        var roster: TeamRoster
    }

    func replay(_ fixture: String) throws -> [Frame] {
        var roster = TeamRoster()
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        return try MapperRun.events(fixture, turns: [(.typed, nil)]).enumerated().map { i, e in
            roster.apply(e, at: t0.addingTimeInterval(Double(i)))
            return Frame(event: e, roster: roster)
        }
    }

    /// No lane vanishes or moves back while the team is live; it never settles while one works.
    func checkSteady(_ frames: [Frame]) {
        var seen: [String: Int] = [:]
        for f in frames {
            #expect(!f.roster.members.contains { $0.state.isRunning } || f.roster.isLive)
            for (key, rank) in seen {
                let m = f.roster.members.first { $0.id == key }
                #expect(m != nil, "lane \(key) vanished at \(f.event)")
                #expect((m.map { $0.state.isRunning ? 0 : 1 } ?? 0) >= rank, "lane \(key) moved back at \(f.event)")
            }
            for m in f.roster.members { seen[m.id] = m.state.isRunning ? 0 : 1 }
        }
    }

    @Test func aBackgroundTeammateStaysThroughTheInterimAnswer() throws {
        let frames = try replay("task-agent.jsonl")
        checkSteady(frames)
        let ends = frames.indices.filter { if case .turnEnded = frames[$0].event { true } else { false } }
        #expect(ends.count == 2)
        // "The scout agent is running in the background…": the lane stays, still working.
        #expect(frames[ends[0]].roster.isLive && frames[ends[0]].roster.live.map(\.state) == [.working])
        #expect(frames[ends[0]].roster.live.first?.liveLine == "Running Print hi via echo")
        // The CLI's hand-back turn answers: then the team folds away.
        let last = try #require(frames.last?.roster)
        #expect(!last.isLive && last.members.map(\.name) == ["scout"] && last.members[0].state == .done)
        #expect(last.members[0].steps == 1)
    }

    @Test func theHandBackKeepsTheLastStepNotTheBrief() throws {
        let frames = try replay("background-subagent.jsonl")
        checkSteady(frames)
        let ended = try #require(frames.firstIndex { if case .task(.ended) = $0.event { true } else { false } })
        #expect(frames[ended - 1].roster.members.first?.liveLine == "Reading note.txt")
        #expect(frames[ended - 1].roster.members.first?.steps == 2)
        #expect(frames.last?.roster.isLive == false)
    }

    @Test func aCappedSpawnAppearsWhenItStarts() throws {
        let frames = try replay("task-agent-cap.jsonl")
        checkSteady(frames)
        let last = try #require(frames.last?.roster)
        #expect(last.members.map(\.name) == ["alpha", "beta"], "the refused first beta never shows")
        #expect(last.members.map(\.state) == [.done, .done] && !last.isLive)
        // Live the whole way from alpha's spawn to "A: A B: B".
        let first = try #require(frames.firstIndex { $0.roster.isLive })
        let live = frames[first..<(frames.count - 2)].allSatisfy { $0.roster.isLive }
        #expect(live)
    }
}
