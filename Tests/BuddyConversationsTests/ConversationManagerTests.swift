import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

/// A manager over an in-memory index, a manual clock, fake session files and a screenshot
/// folder inside `dir`.
struct Harness {
    let index: ConversationIndex
    let clock = ManualConversationClock(t0)
    let files = FakeSessionFiles()
    let screenshots: URL
    let manager: ConversationManager

    init(dir: URL) throws {
        index = try ConversationIndex(url: nil)
        screenshots = dir.appending(path: "shots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        let counter = Counter()
        manager = ConversationManager(
            index: index, sessionFiles: files, screenshotDirectory: screenshots, clock: clock,
            makeID: { counter.next() })
    }

    /// Prepares and finishes one question; returns the saved record.
    @discardableResult
    func ask(_ utterance: String, project: String? = nil, update: TurnUpdate = TurnUpdate(lastLane: .quick)) async throws
        -> (PreparedConversation, ConversationRecord)
    {
        let prepared = try await manager.prepare(projectFolder: project)
        let record = try #require(try await manager.finish(id: prepared.id, update: update, utterance: utterance))
        return (prepared, record)
    }
}

@Suite("ConversationManager")
struct ConversationManagerTests {
    @Test("the row is created at the first finish, titled from the first utterance")
    func firstFinishCreatesRow() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let p = try await h.manager.prepare(projectFolder: nil)
            #expect(p.fresh == .first)
            #expect(p.record == nil)
            #expect(p.headerLabel == "new")
            #expect(p.chips.isEmpty)
            #expect(try await h.manager.list().isEmpty)
            #expect(try await h.index.record(id: p.id) == nil)

            h.clock.advance(3)
            let record = try #require(try await h.manager.finish(
                id: p.id, update: TurnUpdate(quickSessionID: "q1", lastLane: .quick),
                utterance: "  How do I fix this?  \nsecond line"))
            #expect(record.id == p.id)
            #expect(record.title == "How do I fix this?")
            #expect(record.turns == 1)
            #expect(record.quickSessionID == "q1")
            #expect(record.lastLane == .quick)
            #expect(record.lastUsed == t0.addingTimeInterval(3))
            #expect(try await h.manager.list().map(\.id) == [p.id])

            let next = try await h.manager.prepare(projectFolder: nil)
            #expect(next.id == p.id)
            #expect(next.fresh == nil)
            #expect(next.headerLabel == "continuing · 1")
            _ = try await h.manager.finish(id: p.id, update: TurnUpdate(), utterance: "Another title")
            let third = try await h.manager.prepare(projectFolder: nil)
            #expect(third.headerLabel == "continuing · 2")
            #expect(third.record?.title == "How do I fix this?")
        }
    }

    @Test("titles: first line, trimmed, 60 characters at most, Untitled when blank", arguments: [
        ("Short question", "Short question"),
        ("\tTabs and spaces \t", "Tabs and spaces"),
        ("first\nsecond", "first"),
        (String(repeating: "a", count: 60), String(repeating: "a", count: 60)),
        (String(repeating: "b", count: 61), String(repeating: "b", count: 59) + "…"),
        (String(repeating: "c", count: 200), String(repeating: "c", count: 59) + "…"),
        ("", "Untitled"),
        ("   ", "Untitled"),
        ("\n\n", "Untitled"),
    ])
    func titles(utterance: String, expected: String) async throws {
        #expect(ConversationManager.title(from: utterance) == expected)
        #expect(ConversationManager.title(from: utterance).count <= 60)
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let (_, record) = try await h.ask(utterance)
            #expect(record.title == expected)
        }
    }

    @Test("the colour shown while pending is the colour saved")
    func pendingColour() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            for expected in [ConversationColor.ember, .mist, .sage, .amber, .ember] {
                let p = try await h.manager.newConversation()
                #expect(p.color == expected)
                let record = try #require(try await h.manager.finish(id: p.id, update: TurnUpdate(), utterance: "q"))
                #expect(record.color == p.color)
                let again = try await h.manager.prepare(projectFolder: nil)
                #expect(again.color == expected)
            }
        }
    }

    @Test("after the idle timeout the next question is a new conversation with a resume chip")
    func idle() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let (_, a) = try await h.ask("first")
            h.clock.advance(30 * 60 + 1)
            let p = try await h.manager.prepare(projectFolder: nil)
            #expect(p.fresh == .idle)
            #expect(p.id != a.id)
            #expect(p.record == nil)
            #expect(p.chips == [.resume(a.id)])
            #expect(p.color == .mist)
            #expect(p.headerLabel == "new")
        }
    }

    @Test("⌘N offers back for 8 s; go back returns the previous conversation")
    func newAndGoBack() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let (_, a) = try await h.ask("first")
            h.clock.advance(10)
            let n = try await h.manager.newConversation()
            #expect(n.fresh == .requested)
            #expect(n.id != a.id)
            #expect(n.headerLabel == "new")
            #expect(n.chips == [.back(to: a.id, until: t0.addingTimeInterval(18))])
            h.clock.advance(5)
            #expect(try await h.manager.goBack()?.id == a.id)
            let p = try await h.manager.prepare(projectFolder: nil)
            #expect(p.id == a.id)
            #expect(p.fresh == nil)
            // The abandoned pending conversation was never saved.
            #expect(try await h.manager.list().map(\.id) == [a.id])
        }
    }

    @Test("go back after the window is nil")
    func goBackLate() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            try await h.ask("first")
            let n = try await h.manager.newConversation()
            h.clock.advance(9)
            #expect(try await h.manager.goBack() == nil)
            #expect(try await h.manager.prepare(projectFolder: nil).id == n.id)
        }
    }

    @Test("switchTo makes an old conversation current and touches it")
    func switchTo() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let (_, a) = try await h.ask("first", project: "/p", update: TurnUpdate(lastLane: .deep, deepFolder: "/p"))
            h.clock.advance(1)
            _ = try await h.manager.newConversation()
            let (_, b) = try await h.ask("second")
            #expect(try await h.manager.list().map(\.id) == [b.id, a.id])
            h.clock.advance(1)
            #expect(try await h.manager.switchTo(a.id)?.id == a.id)
            #expect(try await h.manager.list().map(\.id) == [a.id, b.id])
            let p = try await h.manager.prepare(projectFolder: "/p")
            #expect(p.id == a.id)
            #expect(p.fresh == nil)
            #expect(try await h.manager.switchTo("nope") == nil)
        }
    }

    @Test("temporary conversations never reach the persistent index")
    func temporary() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let (_, a) = try await h.ask("persistent one")
            try await h.manager.setTemporary(true)
            #expect(await h.manager.isTemporary)
            let p = try await h.manager.prepare(projectFolder: nil)
            #expect(p.fresh == .first)
            #expect(p.id != a.id)
            _ = try await h.manager.finish(id: p.id, update: TurnUpdate(), utterance: "secret one")
            #expect(try await h.manager.list().map(\.title) == ["secret one"])
            #expect(try await h.manager.search("persistent").isEmpty)
            #expect(try await h.index.list().map(\.id) == [a.id])
            #expect(try await h.index.record(id: p.id) == nil)

            try await h.manager.setTemporary(false)
            #expect(await !h.manager.isTemporary)
            #expect(try await h.manager.list().map(\.id) == [a.id])
            #expect(try await h.index.record(id: p.id) == nil)
            #expect(try await h.manager.search("secret").isEmpty)
            #expect(try await h.manager.prepare(projectFolder: nil).fresh == .first)
        }
    }

    @Test("Forget: summary, row, screenshots only inside the folder, all sessions, fresh start")
    func forget() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let (_, a) = try await h.ask(
                "remember me", update: TurnUpdate(quickSessionID: "q1", deepSessionID: "d1", lastLane: .deep))
            try await h.manager.recordResearchJob(ResearchJobRecord(sessionID: "r1", reportPath: "/r/1.md"), conversation: a.id)
            try await h.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: "/r/2.md"), conversation: a.id)

            let inside1 = try makeFile(h.screenshots.appending(path: "1.png"))
            let inside2 = try makeFile(h.screenshots.appending(path: "sub/2.png"))
            let outside = try makeFile(dir.appending(path: "elsewhere/keep.png"))
            let escape = try makeFile(dir.appending(path: "escape.png"))
            let escapePath = h.screenshots.path + "/../escape.png"
            for path in [inside1.path, inside2.path, outside.path, escapePath] {
                try await h.manager.recordScreenshot(path, conversation: a.id)
            }
            // Ignored for a conversation that doesn't exist.
            try await h.manager.recordScreenshot(inside1.path, conversation: "nope")

            // Keep a second conversation to check it survives.
            _ = try await h.manager.newConversation()
            let (_, b) = try await h.ask("other", update: TurnUpdate(quickSessionID: "qb"))
            _ = try await h.manager.switchTo(a.id)

            let request = try #require(try await h.manager.prepareForget(a.id))
            #expect(request.id == a.id)
            #expect(request.title == "remember me")
            #expect(request.sessionCount == 3)
            #expect(request.screenshotCount == 4)
            #expect(h.files.deletedSessions.isEmpty)
            #expect(exists(inside1))

            let report = try #require(try await h.manager.forget(request))
            #expect(Set(report.screenshotsDeleted) == [inside1.path, inside2.path])
            #expect(Set(report.screenshotsSkipped) == [outside.path, escapePath])
            #expect(!exists(inside1))
            #expect(!exists(inside2))
            #expect(exists(outside))
            #expect(exists(escape))
            #expect(h.files.deletedSessions == [["q1", "d1", "r1"]])
            #expect(report.sessions == SessionDeletion(deleted: ["q1", "d1", "r1"]))

            #expect(try await h.index.record(id: a.id) == nil)
            #expect(try await h.manager.list().map(\.id) == [b.id])
            #expect(try await h.manager.prepareForget(a.id) == nil)
            #expect(try await h.manager.forget(request) == nil)
            #expect(h.files.deletedSessions.count == 1)

            let next = try await h.manager.prepare(projectFolder: nil)
            #expect(next.fresh == .first)
            #expect(next.id != a.id)
            #expect(next.id != b.id)
        }
    }
}
