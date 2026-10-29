import BuddyCore
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Studio sidebar grouping")
struct SidebarGroupingTests {
    typealias F = StudioFixtures

    func group(_ s: [SessionSnapshot], search: String = "") -> SidebarGrouping {
        SidebarGrouping(s, now: F.now, calendar: F.calendar, search: search)
    }

    func ids(_ g: SidebarGrouping, _ group: SidebarGrouping.Group) -> [String] { g.rows(group).map(\.id.rawValue) }

    @Test func nowHoldsOnlyRunningAndBlockedNeedsYouFirst() {
        let g = group([
            F.session("idle"),
            F.session("work-old", status: F.thinking(for: 30), ago: 300),
            F.session("blocked-new", status: F.needsYou(since: 10)),
            F.session("work-new", status: F.thinking(for: 5), ago: 5),
            F.session("blocked-old", status: F.needsYou(since: 600)),
            F.session("done", status: .done(at: F.now, unread: true)),
        ])
        #expect(ids(g, .now) == ["blocked-old", "blocked-new", "work-new", "work-old"])
        #expect(ids(g, .today) == ["idle", "done"])
    }

    @Test func teammatesNestOnlyUnderNowRows() {
        let mates = [TeammateSnapshot(id: "t1", toolUseID: "u1", name: "Researcher", state: .working)]
        let handedBack = [TeammateSnapshot(id: "t1", toolUseID: "u1", name: "Researcher", state: .done)]
        let g = group([
            F.session("running", status: F.thinking(for: 3), teammates: mates),
            F.session("finished", status: .done(at: F.now, unread: false), teammates: handedBack),
        ])
        #expect(g.rows(.now).first?.teammates.map(\.name) == ["Researcher"])
        #expect(g.rows(.today).first?.teammates.isEmpty == true, "they go with the parent once its team is over")
    }

    /// The owner (Oct 29): lanes "come and go". The lead's interim answer ("I've started three
    /// teammates") left the session done, so it dropped out of Now and its teammates vanished
    /// until the next hand-back turn. A team still at work keeps it in Now.
    @Test func aSessionWhoseTeamStillWorksStaysInNowBetweenTheLeadsAnswers() {
        let team = [TeammateSnapshot(id: "t1", toolUseID: "u1", name: "Scout", state: .done),
                    TeammateSnapshot(id: "t2", toolUseID: "u2", name: "Writer", state: .working),
                    TeammateSnapshot(id: "t3", toolUseID: "u3", name: "Critic", state: .working)]
        let g = group([F.session("lead-answered", status: .done(at: F.now, unread: true), teammates: team)])
        #expect(ids(g, .now) == ["lead-answered"])
        #expect(g.rows(.now).first?.teammates.map(\.name) == ["Scout", "Writer", "Critic"])
        #expect(g.rows(.now).first?.trailing == .progress(done: 1, total: 3))
    }

    @Test func pinnedComeBeforeDateGroupsButRunningStaysInNow() {
        let g = group([
            F.session("pin-old", pinned: true, ago: 30 * F.day),
            F.session("pin-run", status: F.thinking(for: 1), pinned: true),
            F.session("plain"),
        ])
        #expect(ids(g, .now) == ["pin-run"])
        #expect(ids(g, .pinned) == ["pin-old"])
        #expect(g.sections.map(\.group) == [.now, .pinned, .today])
    }

    @Test func dateGroupsFollowCalendarDays() {
        // 15:00 now: 14 h ago is today, 16 h ago is yesterday.
        let g = group([
            F.session("today", ago: 14 * F.hour),
            F.session("yesterday", ago: 16 * F.hour),
            F.session("week", ago: 3 * F.day),
            F.session("edge", ago: 7 * F.day + 14 * F.hour),
            F.session("older", ago: 8 * F.day + 14 * F.hour),
        ])
        #expect(ids(g, .today) == ["today"])
        #expect(ids(g, .yesterday) == ["yesterday"])
        #expect(ids(g, .previous7Days) == ["week", "edge"])
        #expect(ids(g, .older) == ["older"])
    }

    @Test func archivedGoLastInTheirOwnGroupAndEmptyGroupsDrop() {
        // QA S-15: archived sessions stay reachable, in a group of their own, never in ↑/↓.
        let g = group([F.session("gone", archived: true), F.session("here"),
                       F.session("old", archived: true, ago: 3 * F.day)])
        #expect(g.sections.map(\.group) == [.today, .archived])
        #expect(ids(g, .archived) == ["gone", "old"])
        #expect(g.allRows.map(\.id.rawValue) == ["here"])
        #expect(group([F.session("here")]).sections.map(\.group) == [.today])
    }

    @Test func searchKeepsMatchingTitlesInAnyGroup() {
        let g = group([
            F.session("a", "Q3 variance", status: F.thinking(for: 2)),
            F.session("b", "Trip to Lisbon", pinned: true),
            F.session("c", "q3 notes", ago: 3 * F.day),
        ], search: "  Q3 ")
        #expect(g.allRows.map(\.id.rawValue) == ["a", "c"])
    }

    @Test func searchAlsoFindsTheLastAnswer() {
        // QA S-16: what was said, not only the title.
        var lisbon = F.session("b", "New session")
        lisbon.lastSay = "Flights to Lisbon are cheapest on Tuesdays."
        let g = group([F.session("a", "Q3 variance"), lisbon], search: "lisbon")
        #expect(g.allRows.map(\.id.rawValue) == ["b"])
    }

    @Test func trailingSaysWhatEachRowIsDoing() {
        let g = group([
            F.session("ask", status: F.needsYou(since: 5)),
            F.session("steps", status: F.thinking(for: 9, progress: StepProgress(done: 4, total: 9))),
            F.session("clock", status: F.thinking(for: 112)),
            F.session("unread", status: .done(at: F.now, unread: true), ago: 1),
            F.session("failed", status: .failed(SessionFailure(reason: .crashed, retryable: true)), ago: 2),
            F.session("stopped", status: .interrupted(at: F.now), ago: 3),
            F.session("read", status: .done(at: F.now, unread: false), ago: 4),
        ])
        let trailing = Dictionary(uniqueKeysWithValues: g.allRows.map { ($0.id.rawValue, $0.trailing) })
        #expect(trailing["ask"] == .needsYou)
        #expect(trailing["steps"] == .progress(done: 4, total: 9))
        #expect(trailing["clock"] == .elapsed(112))
        #expect(trailing["unread"] == .unread)
        #expect(trailing["failed"] == .failed)
        #expect(trailing["stopped"] == .interrupted)
        #expect(trailing["read"] == .time(F.now.addingTimeInterval(-4)))
    }

    @Test func clockFormat() {
        #expect(SidebarGrouping.clock(112) == "1:52")
        #expect(SidebarGrouping.clock(5) == "0:05")
        #expect(SidebarGrouping.clock(3725) == "1:02:05")
    }
}
