import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("ConversationIndex")
struct ConversationIndexTests {
    // MARK: Migrations and storage

    @Test("a fresh in-memory index is migrated to the latest schema")
    func freshMigrates() async throws {
        let index = try ConversationIndex(url: nil)
        #expect(await index.schemaVersion == ConversationIndex.migrations.count)
        #expect(ConversationIndex.migrations.count >= 1)
    }

    @Test("reopening an existing file keeps data, version and colour rotation")
    func reopenDoesNotRemigrate() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "nested/conversations.sqlite")
            do {
                let index = try ConversationIndex(url: url)
                _ = try await index.create(id: "a", title: "Alpha", at: t0, projectFolder: "/p")
                try await index.recordTurn(
                    id: "a", at: t0.addingTimeInterval(5), quickSessionID: "q1", deepSessionID: nil,
                    lastLane: .quick, projectFolder: nil)
                #expect(await index.schemaVersion == ConversationIndex.migrations.count)
            }
            #expect(rawScalar(url, "PRAGMA user_version") == "\(ConversationIndex.migrations.count)")

            let again = try ConversationIndex(url: url)
            #expect(await again.schemaVersion == ConversationIndex.migrations.count)
            let record = try #require(try await again.record(id: "a"))
            #expect(record.title == "Alpha")
            #expect(record.turns == 1)
            #expect(record.quickSessionID == "q1")
            #expect(record.projectFolder == "/p")
            // The meta row was not re-inserted: the rotation carries on.
            #expect(try await again.nextColor() == .mist)
            #expect(try await again.list().count == 1)
        }
    }

    @Test("a file index runs in WAL mode")
    func walMode() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "conversations.sqlite")
            let index = try ConversationIndex(url: url)
            _ = try await index.create(id: "a", title: "Alpha", at: t0, projectFolder: nil)
            #expect(rawScalar(url, "PRAGMA journal_mode")?.lowercased() == "wal")
            #expect(exists(URL(fileURLWithPath: url.path + "-wal")))
            _ = index
        }
    }

    // MARK: Colours

    @Test("colours rotate ember, mist, sage, amber, ember and nextColor predicts each")
    func colourRotation() async throws {
        let index = try ConversationIndex(url: nil)
        let expected: [ConversationColor] = [.ember, .mist, .sage, .amber, .ember, .mist]
        for (i, colour) in expected.enumerated() {
            #expect(try await index.nextColor() == colour)
            let record = try await index.create(id: "c\(i)", title: "T\(i)", at: t0, projectFolder: nil)
            #expect(record.color == colour)
            #expect(try await index.record(id: "c\(i)")?.color == colour)
        }
    }

    // MARK: Turns

    @Test("recordTurn counts turns, moves last_used and never erases a stored value with nil")
    func recordTurnCoalesce() async throws {
        let index = try ConversationIndex(url: nil)
        let created = try await index.create(id: "a", title: "Alpha", at: t0, projectFolder: nil)
        #expect(created.turns == 0)
        #expect(created.lastUsed == t0)

        let t1 = t0.addingTimeInterval(10)
        try await index.recordTurn(id: "a", at: t1, quickSessionID: "q1", deepSessionID: nil, lastLane: .quick, projectFolder: nil)
        var r = try #require(try await index.record(id: "a"))
        #expect(r.turns == 1)
        #expect(r.lastUsed == t1)
        #expect(r.created == t0)
        #expect(r.quickSessionID == "q1")
        #expect(r.deepSessionID == nil)
        #expect(r.lastLane == .quick)

        let t2 = t0.addingTimeInterval(20)
        try await index.recordTurn(id: "a", at: t2, quickSessionID: nil, deepSessionID: "d1", lastLane: .deep, projectFolder: "/x")
        r = try #require(try await index.record(id: "a"))
        #expect(r.turns == 2)
        #expect(r.quickSessionID == "q1")
        #expect(r.deepSessionID == "d1")
        #expect(r.lastLane == .deep)
        #expect(r.projectFolder == "/x")

        let t3 = t0.addingTimeInterval(30)
        try await index.recordTurn(id: "a", at: t3, quickSessionID: nil, deepSessionID: nil, lastLane: nil, projectFolder: nil)
        r = try #require(try await index.record(id: "a"))
        #expect(r.turns == 3)
        #expect(r.lastUsed == t3)
        #expect(r.quickSessionID == "q1")
        #expect(r.deepSessionID == "d1")
        #expect(r.lastLane == .deep)
        #expect(r.projectFolder == "/x")
        #expect(r.sessionIDs == ["q1", "d1"])
    }

    // MARK: Reads

    @Test("list is most recently used first, with limit and offset")
    func listOrdering() async throws {
        let index = try ConversationIndex(url: nil)
        _ = try await index.create(id: "a", title: "A", at: t0, projectFolder: nil)
        _ = try await index.create(id: "b", title: "B", at: t0.addingTimeInterval(10), projectFolder: nil)
        _ = try await index.create(id: "c", title: "C", at: t0.addingTimeInterval(20), projectFolder: nil)
        #expect(try await index.list().map(\.id) == ["c", "b", "a"])
        try await index.touch(id: "a", at: t0.addingTimeInterval(30))
        #expect(try await index.list().map(\.id) == ["a", "c", "b"])
        #expect(try await index.list(limit: 2).map(\.id) == ["a", "c"])
        #expect(try await index.list(limit: 2, offset: 1).map(\.id) == ["c", "b"])
        #expect(try await index.list(limit: 2, offset: 3).isEmpty)
    }

    @Test("search ANDs words, ignores case and treats LIKE wildcards literally")
    func search() async throws {
        let index = try ConversationIndex(url: nil)
        let titles = [
            "Fix the empty list bug", "Empty fridge", "List of groceries", "50% off sale", "500 items",
            "snake_case names", "snakeXcase names", #"C:\temp folder"#, "Ctemp folder",
        ]
        for (i, title) in titles.enumerated() {
            _ = try await index.create(id: "c\(i)", title: title, at: t0.addingTimeInterval(Double(i)), projectFolder: nil)
        }
        #expect(try await index.search("empty list").map(\.title) == ["Fix the empty list bug"])
        #expect(try await index.search("list   EMPTY").map(\.title) == ["Fix the empty list bug"])
        #expect(try await index.search("EMPTY").map(\.title) == ["Empty fridge", "Fix the empty list bug"])
        #expect(try await index.search("50%").map(\.title) == ["50% off sale"])
        #expect(try await index.search("%%").isEmpty)
        #expect(try await index.search("e_c").map(\.title) == ["snake_case names"])
        #expect(try await index.search("__").isEmpty)
        #expect(try await index.search(#":\temp"#).map(\.title) == [#"C:\temp folder"#])
        #expect(try await index.search("empty nothing").isEmpty)
        #expect(try await index.search("   ").isEmpty)
        #expect(try await index.search("folder").count == 2)
    }

    // MARK: Research jobs, screenshots, delete

    @Test("research jobs and screenshots round-trip and are removed by delete")
    func jobsAndScreenshotsCascade() async throws {
        let index = try ConversationIndex(url: nil)
        _ = try await index.create(id: "a", title: "A", at: t0, projectFolder: nil)
        _ = try await index.create(id: "b", title: "B", at: t0, projectFolder: nil)
        try await index.addResearchJob(id: "a", ResearchJobRecord(sessionID: "r1", reportPath: "/r/1.md"))
        try await index.addResearchJob(id: "a", ResearchJobRecord(sessionID: nil, reportPath: "/r/2.md"))
        try await index.addResearchJob(id: "b", ResearchJobRecord(sessionID: "rb", reportPath: "/r/b.md"))
        try await index.addScreenshot(id: "a", path: "/s/1.png")
        try await index.addScreenshot(id: "a", path: "/s/2.png")
        try await index.addScreenshot(id: "a", path: "/s/1.png")  // duplicate ignored
        try await index.addScreenshot(id: "b", path: "/s/b.png")

        let a = try #require(try await index.record(id: "a"))
        #expect(a.researchJobs == [
            ResearchJobRecord(sessionID: "r1", reportPath: "/r/1.md"),
            ResearchJobRecord(sessionID: nil, reportPath: "/r/2.md"),
        ])
        #expect(a.sessionIDs == ["r1"])
        #expect(Set(try await index.screenshots(id: "a")) == ["/s/1.png", "/s/2.png"])

        let removed = try await index.delete(id: "a")
        #expect(Set(removed) == ["/s/1.png", "/s/2.png"])
        #expect(removed.count == 2)
        #expect(try await index.record(id: "a") == nil)
        #expect(try await index.screenshots(id: "a").isEmpty)

        // Recreating the id shows the child rows went with it.
        _ = try await index.create(id: "a", title: "A again", at: t0, projectFolder: nil)
        #expect(try await index.record(id: "a")?.researchJobs == [])
        #expect(try await index.screenshots(id: "a").isEmpty)

        // The other conversation is untouched.
        #expect(try await index.record(id: "b")?.researchJobs.map(\.sessionID) == ["rb"])
        #expect(try await index.screenshots(id: "b") == ["/s/b.png"])
        #expect(try await index.delete(id: "missing") == [])
    }

    @Test("unusedSince returns conversations last used strictly before the date")
    func unusedSince() async throws {
        let index = try ConversationIndex(url: nil)
        _ = try await index.create(id: "old", title: "Old", at: t0, projectFolder: nil)
        _ = try await index.create(id: "new", title: "New", at: t0.addingTimeInterval(100), projectFolder: nil)
        #expect(try await index.unusedSince(t0.addingTimeInterval(50)) == ["old"])
        #expect(try await index.unusedSince(t0).isEmpty)
        #expect(Set(try await index.unusedSince(t0.addingTimeInterval(101))) == ["old", "new"])
        try await index.touch(id: "old", at: t0.addingTimeInterval(200))
        #expect(try await index.unusedSince(t0.addingTimeInterval(150)) == ["new"])
    }

    @Test("SQL-looking titles and ids are stored verbatim")
    func injectionTitles() async throws {
        let index = try ConversationIndex(url: nil)
        let evil = "'; DROP TABLE conversations; --"
        let evil2 = #"Robert"); DELETE FROM meta; -- \ % _"#
        _ = try await index.create(id: "x'y", title: evil, at: t0, projectFolder: "/it's")
        _ = try await index.create(id: "z", title: evil2, at: t0, projectFolder: nil)
        try await index.rename(id: "z", title: evil2 + "!")
        #expect(try await index.record(id: "x'y")?.title == evil)
        #expect(try await index.record(id: "x'y")?.projectFolder == "/it's")
        #expect(try await index.record(id: "z")?.title == evil2 + "!")
        #expect(try await index.list().count == 2)
        #expect(try await index.search("DROP TABLE").map(\.id) == ["x'y"])
        #expect(try await index.nextColor() == .sage)
    }
}
