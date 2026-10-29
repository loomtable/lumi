import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("SummonRouter")
struct SummonRouterTests {
    static let home = "/Users/me"
    let policy = RoutingPolicy(home: SummonRouterTests.home)
    let now = t0.addingTimeInterval(10_000)
    let a = SessionID(rawValue: "s_a"), b = SessionID(rawValue: "s_b"), c = SessionID(rawValue: "s_c")
    let numbers = ContextKey(bundleID: "com.apple.Numbers", target: "/d/burn.numbers")
    let safari = ContextKey(bundleID: "com.apple.Safari", target: "example.com/trip")

    func info(_ id: SessionID, ago: TimeInterval, key: ContextKey? = nil, dirs: [String] = [], title: String? = nil,
              archived: Bool = false) -> SessionRoutingInfo {
        SessionRoutingInfo(id: id, title: title ?? id.rawValue, harness: .open, contextKey: key,
                           lastUsed: now.addingTimeInterval(-ago), archived: archived, directories: dirs)
    }

    func input(_ source: SummonInput.Source = .talkKey, kind: TurnKind = .voice, command: SummonInput.Command? = nil,
               key: ContextKey? = nil, project: String? = nil, trusted: Bool = false,
               page: (SessionID, PageKind)? = nil, panel: [SessionID: Date] = [:], current: SessionID? = nil,
               busy: Set<SessionID> = []) -> SummonInput {
        SummonInput(source: source, kind: kind, command: command, contextKey: key, project: project, projectTrusted: trusted,
                    visiblePage: page.map { (id: $0.0, kind: $0.1) }, panelShownAt: panel, current: current, busy: busy, now: now)
    }

    func route(_ i: SummonInput, _ candidates: [SessionRoutingInfo]) -> RouteDecision {
        SummonRouter.route(i, candidates: candidates, policy: policy)
    }

    // MARK: 1. Explicit

    @Test func anExplicitCommandOrPickWins() {
        let all = [info(a, ago: 10), info(b, ago: 20_000)]
        #expect(route(input(command: .newSession, current: a), all) == .newSession(kind: .voice))
        #expect(route(input(command: .continueSession(b), current: a), all) == .continueSession(b, kind: .voice))
        #expect(route(input(.composer(b), kind: .typed, current: a), all) == .continueSession(b, kind: .typed))
        #expect(route(input(.switcherPick(b), current: a), all).session == b)
        #expect(route(input(.action(b), kind: .action, current: a), all) == .continueSession(b, kind: .action))
        #expect(route(input(.newSession, current: a), all) == .newSession(kind: .voice))
        // A page on screen doesn't override a pick.
        #expect(route(input(.switcherPick(b), page: (a, .panel), current: a), all).session == b)
    }

    // MARK: 2. Owner rule

    /// V-07: a composer's mic speaks into that composer's page, even when another page is key.
    @Test func aComposersMicGoesIntoItsOwnPageAsVoiceInPage() {
        let all = [info(a, ago: 10), info(b, ago: 20_000)]
        #expect(route(input(.composer(b), page: (a, .studio), current: a), all) == .continueSession(b, kind: .voiceInPage))
    }

    @Test func theTalkKeyGoesIntoTheVisiblePageAsVoiceInPage() {
        let all = [info(a, ago: 10), info(b, ago: 5_000)]
        #expect(route(input(page: (b, .studio), current: a), all) == .continueSession(b, kind: .voiceInPage))
        // Even when the page's session is long idle.
        #expect(route(input(page: (b, .panel)), [info(b, ago: 90_000)]) == .continueSession(b, kind: .voiceInPage))
        // The text box is a typed ask: not the owner rule.
        #expect(route(input(.textBox, kind: .typed, page: (b, .panel), current: a), all) == .continueSession(a, kind: .typed))
    }

    // MARK: Busy (V-02)

    /// A second question while the first still runs starts its own session: the panel, context and
    /// current rules skip the busy one, so the first is never cut off. A pick still reaches it.
    @Test func aSessionStillRunningAVoiceTurnIsNotContinuedByDefault() {
        let all = [info(a, ago: 10, key: numbers), info(b, ago: 20, key: numbers)]
        #expect(route(input(key: numbers, current: a), all) == .continueSession(a, kind: .voice))
        #expect(route(input(key: numbers, current: a, busy: [a]), all) == .continueSession(b, kind: .voice))
        #expect(route(input(current: a, busy: [a]), [info(a, ago: 10)]) == .newSession(kind: .voice))
        #expect(route(input(panel: [a: now.addingTimeInterval(-5)], busy: [a]), [info(a, ago: 10)]) == .newSession(kind: .voice))
        #expect(route(input(.switcherPick(a), current: a, busy: [a]), all).session == a)
        #expect(route(input(page: (a, .panel), busy: [a]), all) == .continueSession(a, kind: .voiceInPage))
    }

    // MARK: 3–5

    @Test func aSessionThePanelShowedRecentlyIsContinued() {
        let all = [info(a, ago: 10), info(b, ago: 3_000), info(c, ago: 3_000)]
        let panel = [b: now.addingTimeInterval(-60), c: now.addingTimeInterval(-90)]
        #expect(route(input(panel: panel, current: a), all).session == b)
        #expect(route(input(panel: [b: now.addingTimeInterval(-121)], current: a), all).session == a)
    }

    @Test func theSameAppAndDocumentContinue() {
        let all = [info(a, ago: 10, key: safari), info(b, ago: 600, key: numbers, title: "Q3 burn model")]
        #expect(route(input(key: numbers, current: a), all) == .continueSession(b, kind: .voice))
        #expect(route(input(key: safari, current: a), all) == .continueSession(a, kind: .voice))
        // Too old, or archived: not by context.
        #expect(route(input(key: numbers, current: a), [info(a, ago: 10), info(b, ago: 1_801, key: numbers)]).session == a)
        #expect(route(input(key: numbers, current: a), [info(a, ago: 10), info(b, ago: 60, key: numbers, archived: true)]).session == a)
    }

    @Test func theCurrentSessionContinuesUntilIdleThenANewOneStarts() {
        #expect(route(input(current: a), [info(a, ago: 1_799)]) == .continueSession(a, kind: .voice))
        #expect(route(input(current: a), [info(a, ago: 1_801, title: "Trip")]) == .newSession(kind: .voice))
        #expect(route(input(), []) == .newSession(kind: .voice))
        // A clock that jumped backwards isn't idle.
        #expect(route(input(current: a), [info(a, ago: -500)]).session == a)
    }

    // QA R12: an archived session is out of the strip, so recency doesn't continue it.
    @Test func archivedSessionsAreSkippedByRecencyButNotByAPickOrItsPage() {
        let gone = info(b, ago: 30, archived: true)
        #expect(route(input(panel: [b: now.addingTimeInterval(-20)], current: a), [info(a, ago: 3_000), gone]) == .newSession(kind: .voice),
                "rule 3 skips it (and a is idle)")
        #expect(route(input(current: b), [gone]) == .newSession(kind: .voice), "rule 5 skips it")
        #expect(route(input(.switcherPick(b), current: a), [gone]).session == b, "a pick still reaches it")
        #expect(route(input(page: (b, .studio)), [gone]) == .continueSession(b, kind: .voiceInPage), "and so does its page")
    }

    // MARK: Projects never split

    @Test func aDifferentTrustedProjectIsAbsorbedAndAnUntrustedOneOffered() {
        let all = [info(a, ago: 60, dirs: ["/Users/me/Developer/lumi"])]
        #expect(route(input(project: "/Users/me/Developer/other", trusted: true, current: a), all)
                == .absorb(a, dir: "/Users/me/Developer/other", kind: .voice))
        #expect(route(input(project: "/Users/me/Downloads/repo", trusted: false, current: a), all)
                == .offerAbsorb(a, dir: "/Users/me/Downloads/repo", kind: .voice))
        // Its own project, or a subfolder of it: plain continue.
        #expect(route(input(project: "/Users/me/Developer/lumi/app/", trusted: true, current: a), all)
                == .continueSession(a, kind: .voice))
        // A sibling with a shared prefix is another project.
        #expect(route(input(project: "/Users/me/Developer/lumi-site", trusted: true, current: a), all).session == a)
        if case .absorb = route(input(project: "/Users/me/Developer/lumi-site", trusted: true, current: a), all) {} else {
            Issue.record("lumi-site is not inside lumi")
        }
    }

    @Test func homeIsNeverAProject() {
        let all = [info(a, ago: 60, dirs: [])]
        #expect(route(input(project: Self.home, trusted: true, current: a), all) == .continueSession(a, kind: .voice))
        #expect(route(input(project: Self.home + "/", trusted: true, current: a), all) == .continueSession(a, kind: .voice))
    }

    // MARK: Regressions from the owner's index (01 §2)

    /// Oct 25: conversation A ran Deep in home from a browser; two minutes later a question with
    /// ~/Developer/lumi in front split off a new conversation B. Now it stays in A and adds the repo.
    @Test func oct25DeepInHomeThenARepoInFrontStaysInTheSameSession() {
        let conversationA = info(a, ago: 128, key: safari, dirs: [Self.home], title: "Conv A")
        let decision = route(input(key: ContextKey(bundleID: "com.googlecode.iterm2", target: "~/Developer/lumi"),
                                   project: "/Users/me/Developer/lumi", trusted: true, current: a), [conversationA])
        #expect(decision == .absorb(a, dir: "/Users/me/Developer/lumi", kind: .voice))
    }

    /// Oct 26–27: conversation C (15 turns, Deep in home) got interrupted by a one-turn
    /// conversation D for a trusted acme-app folder. Now C continues and absorbs the folder.
    @Test func oct26DeepInHomeThenATrustedFolderAbsorbsInsteadOfSplitting() {
        let conversationC = info(c, ago: 300, dirs: [Self.home], title: "Conv C")
        let project = "/Users/me/Developer/acme/acme-app"
        #expect(route(input(project: project, trusted: true, current: c), [conversationC])
                == .absorb(c, dir: project, kind: .voice))
        // And the follow-up from home again (a browser) simply continues.
        #expect(route(input(key: safari, current: c), [info(c, ago: 30, dirs: [Self.home, project])]).session == c)
    }

    @Test func fiftyCandidatesDecideInUnderAMillisecond() {
        let many = (0..<50).map { info(SessionID(rawValue: "s_\($0)"), ago: TimeInterval($0 * 60), key: ContextKey(bundleID: "b\($0)")) }
        let started = ContinuousClock.now
        for _ in 0..<100 { _ = route(input(key: ContextKey(bundleID: "b49"), project: "/x/y", trusted: true, current: many[0].id), many) }
        #expect(ContinuousClock.now - started < .milliseconds(100), "100 decisions under 100 ms")
    }
}
