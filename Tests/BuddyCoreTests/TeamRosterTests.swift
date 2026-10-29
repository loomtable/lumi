import Foundation
import Testing
@testable import BuddyCore

/// The owner (Oct 29): teammate lanes "keep glitching, come and go". One entry per teammate from
/// start to finish, states only forward, the team live until the lead answers after it.
struct TeamRosterTests {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    static func started(_ task: String, _ tool: String, _ name: String, brief: String = "Look into it") -> SessionEvent {
        .task(.started(taskID: task, toolUseID: tool, name: name, description: brief, kind: .agent))
    }
    static func progress(_ task: String, _ line: String?, steps: Int?) -> SessionEvent {
        .task(.progress(taskID: task, lastTool: "Read", line: line, steps: steps))
    }
    static func ended(_ task: String, _ status: TaskEnd = .completed) -> SessionEvent {
        .task(.ended(taskID: task, status: status, summary: "ok"))
    }
    static let answer = SessionEvent.turnEnded(TurnEnd(kind: .typed, markdown: "Done."))

    @Test func aTeamStaysLiveAcrossTheLeadsInterimAnswersAndSettlesAfterTheMergedOne() {
        var r = TeamRoster()
        r.apply(.turnStarted(userUUID: "u1", kind: .typed), at: at(0))
        for (i, name) in ["Scout", "Analyst", "Writer"].enumerated() { r.apply(Self.started("t\(i)", "tu\(i)", name), at: at(2)) }
        #expect(r.isLive && r.members.map(\.name) == ["Scout", "Analyst", "Writer"])
        r.apply(Self.answer, at: at(3))   // "I've started three teammates."
        #expect(r.isLive && r.live.count == 3, "the lead's interim answer doesn't hide the team")
        r.apply(Self.ended("t0"), at: at(10))
        r.apply(.turnStarted(userUUID: nil, kind: .typed), at: at(10))   // the CLI's hand-back turn
        r.apply(Self.answer, at: at(11))
        #expect(r.isLive && TeamRoster.summary(of: r.members) == "1 of 3 done")
        r.apply(Self.ended("t1"), at: at(20))
        r.apply(Self.ended("t2", .failed), at: at(21))
        #expect(r.isLive, "still live until the lead answers")
        r.apply(.turnStarted(userUUID: nil, kind: .typed), at: at(21))
        r.apply(Self.answer, at: at(25))
        #expect(!r.isLive && r.live.isEmpty)
        #expect(r.members.count == 3, "the team stays readable (inspector)")
        #expect(r.members.map(\.state) == [.done, .done, .failed])
        #expect(r.members[0].elapsed(at: at(99)) == 8)
    }

    @Test func lateRepeatedAndOutOfOrderEventsNeverMoveATeammateBack() {
        var r = TeamRoster()
        r.apply(Self.started("t1", "tu1", "Scout", brief: "Read the note"), at: at(0))
        r.apply(Self.progress("t1", "Reading note.txt", steps: 3), at: at(1))
        r.apply(Self.progress("t1", "Searching", steps: 2), at: at(2))
        #expect(r.members[0].steps == 3, "a stale count never lowers it")
        // At hand-back the CLI repeats the brief as the line: the last step stays.
        r.apply(Self.progress("t1", "Read the note", steps: 4), at: at(3))
        #expect(r.members[0].liveLine == "Searching" && r.members[0].steps == 4)
        r.apply(Self.ended("t1"), at: at(4))
        r.apply(Self.progress("t1", "Reading more", steps: 9), at: at(5))
        r.apply(Self.started("t1", "tu1", "Scout"), at: at(6))
        r.apply(Self.ended("t1", .failed), at: at(7))
        #expect(r.members.count == 1)
        #expect(r.members[0].state == .done && r.members[0].liveLine == nil && r.members[0].endedAt == at(4))
        // Events for tasks it never saw, and background shells, add nothing.
        r.apply(Self.progress("ghost", "Reading", steps: 1), at: at(8))
        r.apply(Self.ended("ghost"), at: at(8))
        r.apply(.task(.started(taskID: "b1", toolUseID: "tb", name: nil, description: "npm test", kind: .bash)), at: at(8))
        #expect(r.members.map(\.id) == ["t1"])
    }

    @Test func aGapWithNoEventsKeepsTheTeammateWorking() {
        var r = TeamRoster()
        r.apply(Self.started("t1", "tu1", "Scout"), at: at(0))
        r.apply(Self.answer, at: at(1))
        // Ten minutes of nothing: no idle timeout hides it.
        r.apply(.runState(.running), at: at(600))
        #expect(r.live.map(\.state) == [.working])
        #expect(r.members[0].elapsed(at: at(600)) == 600)
    }

    @Test func theNextTeamAfterTheAnswerStartsFresh() {
        var r = TeamRoster()
        r.apply(Self.started("t1", "tu1", "Scout"), at: at(0))
        r.apply(Self.ended("t1"), at: at(1))
        r.apply(Self.answer, at: at(2))
        r.apply(.turnStarted(userUUID: "u2", kind: .typed), at: at(3))
        r.apply(Self.started("t2", "tu2", "Writer"), at: at(4))
        #expect(r.members.map(\.name) == ["Writer"] && r.isLive)
    }

    @Test func theUsersNextTurnSettlesATeamThatHandedBackWithNoAnswer() {
        var r = TeamRoster()
        r.apply(Self.started("t1", "tu1", "Scout"), at: at(0))
        r.apply(Self.answer, at: at(1))
        r.apply(Self.ended("t1"), at: at(5))
        #expect(r.isLive)
        r.apply(.turnStarted(userUUID: "u2", kind: .steer), at: at(6))
        #expect(r.isLive, "a steer isn't a new turn")
        r.apply(.turnStarted(userUUID: "u2", kind: .typed), at: at(6))
        #expect(!r.isLive)
    }

    @Test func teammatesDieWithTheProcess() {
        var r = TeamRoster()
        r.apply(Self.started("t0", "tu0", "Scout"), at: at(0))
        r.apply(Self.started("t1", "tu1", "Writer"), at: at(0))
        r.apply(.processEnded(status: 9, midTurn: true), at: at(3))
        #expect(r.members.map(\.state) == [.stopped, .stopped] && !r.isLive)
    }

    @Test func askersNeedYouAndGoBackToWorking() {
        var r = TeamRoster()
        r.apply(Self.started("t1", "tu1", "Scout"), at: at(0))
        r.waiting(on: ["Scout"])
        #expect(r.members[0].state == .needsYou)
        r.waiting(on: [])
        #expect(r.members[0].state == .working)
        r.apply(Self.ended("t1"), at: at(1))
        r.waiting(on: ["Scout"])
        #expect(r.members[0].state == .done, "an ended teammate never needs you")
    }

    @Test func adoptingTheStoresCopyOnlyMovesForward() {
        var r = TeamRoster()
        r.apply(Self.started("t1", "tu1", "Scout"), at: at(0))
        r.apply(Self.ended("t1"), at: at(1))
        r.adopt(TeammateSnapshot(id: "t1", toolUseID: "tu1", name: "Scout", state: .working, steps: 7), live: true)
        #expect(r.members[0].state == .done && r.members[0].steps == 0)
        r.adopt(TeammateSnapshot(id: "t2", toolUseID: "tu2", name: "Writer", state: .working), live: true)
        #expect(r.members.map(\.id) == ["t1", "t2"])
    }

    /// Running 0, ended 1: a state only climbs.
    static func rank(_ state: TeammateSnapshot.State) -> Int { state.isRunning ? 0 : 1 }

    /// Three teammates' streams interleaved every which way, with the lead's interim answers in
    /// between: after every event, no lane has vanished while the team is live, no state moved
    /// back, and the team never settles while anyone works.
    @Test func randomInterleavingsKeepEveryLaneAndOnlyMoveForward() {
        var rng = SplitMix(seed: 0x1a2e5)
        for _ in 0..<300 {
            var queues: [[SessionEvent]] = (0..<3).map { i in
                var q = [Self.started("t\(i)", "tu\(i)", "M\(i)")]
                for s in 1...Int.random(in: 1...6, using: &rng) {
                    // Duplicated and stale progress on purpose.
                    q.append(Self.progress("t\(i)", "Step \(s)", steps: Bool.random(using: &rng) ? s : max(0, s - 2)))
                }
                q.append(Self.ended("t\(i)", [.completed, .failed, .stopped].randomElement(using: &rng)!))
                if Bool.random(using: &rng) { q.append(Self.ended("t\(i)")) }
                if Bool.random(using: &rng) { q.append(Self.progress("t\(i)", "late", steps: 99)) }
                return q
            }
            // The lead starts all three at once; everything after that interleaves.
            var r = TeamRoster()
            for i in 0..<3 { r.apply(queues[i].removeFirst(), at: at(0)) }
            var seen: [String: Int] = [:]
            var t = 0.0
            while queues.contains(where: { !$0.isEmpty }) {
                t += 1
                if Int.random(in: 0..<5, using: &rng) == 0 { r.apply(Self.answer, at: at(t)); continue }
                let i = queues.indices.filter { !queues[$0].isEmpty }.randomElement(using: &rng)!
                r.apply(queues[i].removeFirst(), at: at(t))
                let running = r.members.contains { $0.state.isRunning }
                #expect(!running || r.isLive, "never settled while someone works")
                for (key, rank) in seen {
                    let member = r.members.first { $0.id == key }
                    #expect(member != nil, "lane \(key) vanished")
                    #expect(Self.rank(member?.state ?? .working) >= rank, "lane \(key) moved back")
                }
                for m in r.members { seen[m.id] = Self.rank(m.state) }
            }
            r.apply(Self.answer, at: at(t + 1))
            #expect(!r.isLive && r.members.count == 3 && r.members.allSatisfy { !$0.state.isRunning })
        }
    }

    /// Inspire #4: each teammate's latest step or progress, for its quiet age.
    @Test func eachTeammateKeepsItsLatestEventTime() {
        var r = TeamRoster()
        r.apply(Self.started("t1", "tu1", "Scout"), at: at(0))
        r.apply(Self.started("t2", "tu2", "Writer"), at: at(0))
        #expect(r.members.map(\.lastEventAt) == [at(0), at(0)])
        r.apply(.step(TrailStep(id: "s", kind: .read, verb: "Reading", object: "a.md", subagent: "tu2")), at: at(40))
        r.apply(Self.progress("t1", "Searching", steps: 1), at: at(50))
        #expect(r.members.map(\.lastEventAt) == [at(50), at(40)])
    }
}

/// A small seeded generator, so a failure replays.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
