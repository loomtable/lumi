@testable import BuddyApp
import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation
import Synchronization
import Testing

/// A titler whose answer the test decides, and when.
private final class FakeTitler: SessionTitler {
    let asked = Mutex<[(question: String, answer: String)]>([])
    let reply: SessionTopic?
    let gate: AsyncStream<Void>?
    private let open: AsyncStream<Void>.Continuation?

    init(_ reply: SessionTopic?, gated: Bool = false) {
        self.reply = reply
        if gated {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            gate = stream
            open = continuation
        } else {
            gate = nil
            open = nil
        }
    }

    var calls: Int { asked.withLock { $0.count } }
    func release() { open?.yield(); open?.finish() }

    func topic(question: String, answer: String) async -> SessionTopic? {
        asked.withLock { $0.append((question, answer)) }
        if let gate { for await _ in gate { break } }
        return reply
    }
}

/// Issue #2 (round 3): a typed session stayed "New session". The first question names it at once;
/// the first answer refines it in the background. A rename always wins.
@MainActor
struct SessionTitlingTests {
    private func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try await condition()
    }

    /// Home's composer: a new session with no words yet, then its first typed turn.
    private func typedSession(_ h: LiveSessionsTests.Harness, _ question: String) async throws -> SessionID {
        let plan = await h.sessions.plan(SummonInput(source: .newSession, kind: .typed, command: .newSession, now: Date()), packet: nil)
        #expect(try await h.index.record(id: plan.id.rawValue)?.title == "New session")
        await h.sessions.recordSent(userUUID: "u1", kind: .typed, shown: question, claudeSession: try #require(plan.launch).claudeSession,
                                    in: plan.id)
        return plan.id
    }

    private func answer(_ h: LiveSessionsTests.Harness, _ id: SessionID, _ text: String, block: BuddyBlock? = nil) {
        h.sessions.apply(.turnStarted(userUUID: "u1", kind: .typed), to: id)
        h.sessions.apply(.turnEnded(TurnEnd(kind: block == nil ? .typed : .voice, markdown: text, block: block)), to: id)
    }

    @Test func theFirstQuestionNamesATypedSessionAtOnce() async throws {
        let h = try LiveSessionsTests.Harness()
        let id = try await typedSession(h, "Find good restaurants in Munich for Friday")
        let record = try #require(try await h.index.record(id: id.rawValue))
        #expect(record.title == "Find good restaurants")
        #expect(record.symbol == "fork.knife")
        #expect(record.retitles == 0, "provisional: the first automatic title still applies")
        #expect(h.sessions.snapshots.first { $0.id == id }?.title == "Find good restaurants")
    }

    @Test func theFirstAnswerRefinesTheTitleInTheBackground() async throws {
        let h = try LiveSessionsTests.Harness()
        let titler = FakeTitler(SessionTopic(title: "Munich restaurants", symbol: "fork.knife"))
        h.sessions.titler = titler
        let id = try await typedSession(h, "Find good restaurants in Munich for Friday")
        answer(h, id, "Here are five places: Tantris, Brenner, …")
        #expect(try await eventually { try await h.index.record(id: id.rawValue)?.title == "Munich restaurants" })
        let record = try #require(try await h.index.record(id: id.rawValue))
        #expect(record.symbol == "fork.knife" && record.retitles == 1)
        #expect(titler.asked.withLock { $0.first?.question } == "Find good restaurants in Munich for Friday")
        #expect(titler.asked.withLock { $0.first?.answer } == "Here are five places: Tantris, Brenner, …")
        #expect(try await eventually { h.sessions.snapshots.first { $0.id == id }?.title == "Munich restaurants" })

        answer(h, id, "Brenner takes walk-ins.")
        try await Task.sleep(for: .milliseconds(20))
        #expect(titler.calls == 1, "once per session")
    }

    @Test func aRenameWhileTitlingWins() async throws {
        let h = try LiveSessionsTests.Harness()
        let titler = FakeTitler(SessionTopic(title: "Munich restaurants", symbol: "fork.knife"), gated: true)
        h.sessions.titler = titler
        let id = try await typedSession(h, "Find good restaurants in Munich")
        answer(h, id, "Five places.")
        #expect(try await eventually { titler.calls == 1 })
        await h.sessions.rename(id, to: "Friday dinner")
        titler.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await h.index.record(id: id.rawValue)?.title == "Friday dinner")
    }

    @Test func aFailedOrInvalidTitleKeepsTheProvisionalOne() async throws {
        for reply in [nil, SessionTopic(title: "Restaurants!"), SessionTopic(title: "x")] as [SessionTopic?] {
            let h = try LiveSessionsTests.Harness()
            let titler = FakeTitler(reply)
            h.sessions.titler = titler
            let id = try await typedSession(h, "Find good restaurants in Munich")
            answer(h, id, "Five places.")
            #expect(try await eventually { titler.calls == 1 })
            try await Task.sleep(for: .milliseconds(30))
            let record = try #require(try await h.index.record(id: id.rawValue))
            #expect(record.title == "Find good restaurants" && record.retitles == 0)
        }
    }

    @Test func aVoiceAnswerWithATopicIsNotAskedAgain() async throws {
        let h = try LiveSessionsTests.Harness()
        let titler = FakeTitler(SessionTopic(title: "Wrong title here"))
        h.sessions.titler = titler
        let id = try await typedSession(h, "plan a trip to Lisbon")
        let block = BuddyBlock(say: "Three days.", shape: .chip, topic: SessionTopic(title: "Trip to Lisbon", symbol: "airplane"))
        answer(h, id, "Three days.", block: block)
        #expect(try await eventually { try await h.index.record(id: id.rawValue)?.title == "Trip to Lisbon" })
        try await Task.sleep(for: .milliseconds(20))
        #expect(titler.calls == 0)
    }

    @Test func aRenamedSessionIsNeverRetitled() async throws {
        let h = try LiveSessionsTests.Harness()
        let titler = FakeTitler(SessionTopic(title: "Munich restaurants"))
        h.sessions.titler = titler
        let plan = await h.sessions.plan(SummonInput(source: .newSession, kind: .typed, command: .newSession, now: Date()), packet: nil)
        await h.sessions.rename(plan.id, to: "Dinner")
        await h.sessions.recordSent(userUUID: "u1", kind: .typed, shown: "Find good restaurants in Munich",
                                    claudeSession: try #require(plan.launch).claudeSession, in: plan.id)
        answer(h, plan.id, "Five places.")
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await h.index.record(id: plan.id.rawValue)?.title == "Dinner")
        #expect(titler.calls == 0)
    }

    // The live titler: what it runs and what it reads back.
    @Test func claudeTitlerAsksHaikuWithNoToolsAndReadsItsJSON() async {
        let seen = Mutex<[String]>([])
        let titler = ClaudeTitler(claude: URL(fileURLWithPath: "/bin/claude"), environment: [:]) { _, args, _ in
            seen.withLock { $0 = args }
            return (0, "```json\n{\"title\": \"Munich restaurants\", \"symbol\": \"fork.knife\"}\n```")
        }
        let topic = await titler.topic(question: String(repeating: "q", count: 900), answer: String(repeating: "a", count: 900))
        #expect(topic == SessionTopic(title: "Munich restaurants", symbol: "fork.knife"))
        let args = seen.withLock { $0 }
        #expect(Array(args.prefix(14)) == ["-p", "--model", "haiku", "--output-format", "text", "--no-session-persistence",
                                          "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
                                          "--setting-sources", "project,local", "--settings", #"{"disableAllHooks": true}"#])
        let folder = ClaudeTitler.emptyFolder()
        #expect(folder.path.hasPrefix(FileManager.default.temporaryDirectory.path), "runs outside any project")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true)
        let prompt = args.last ?? ""
        #expect(!prompt.contains(String(repeating: "q", count: ClaudeTitler.maxQuestion + 1)), "only the start of the question")
        #expect(!prompt.contains(String(repeating: "a", count: ClaudeTitler.maxAnswer + 1)), "only the start of the answer")
        #expect(ClaudeTitler.parse("no json") == nil)
        let failing = ClaudeTitler(claude: URL(fileURLWithPath: "/bin/claude"), environment: [:]) { _, _, _ in (1, "{\"title\": \"A b\"}") }
        #expect(await failing.topic(question: "q", answer: "a") == nil, "a failed run names nothing")
    }
}
