import BuddyCore
import Foundation
import SQLite3
import Testing
@testable import BuddyConversations

/// Migration 2 over a v1 file built here with the v1 schema (never the owner's real index).
@Suite("SessionStore migration")
struct SessionStoreMigrationTests {
    static let quick = "11111111-1111-4111-8111-111111111111"
    static let deep = "22222222-2222-4222-8222-222222222222"
    static let quick2 = "33333333-3333-4333-8333-333333333333"

    /// A v1 index file: migration 1 only, user_version 1, three conversations.
    static func makeV1(_ url: URL) throws {
        var handle: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws { try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        try exec(ConversationIndex.migrations[0])
        try exec("PRAGMA user_version = 1")
        let t = t0.timeIntervalSince1970
        try exec("""
            INSERT INTO conversations (id, title, color, created, last_used, quick_session, deep_session, last_lane, project_folder, turns)
            VALUES ('c_quick', 'Quick one', 'ember', \(t), \(t + 10), '\(quick)', NULL, 'quick', '/Users/me/repo', 2),
                   ('c_deep', 'Deep one', 'mist', \(t), \(t + 20), '\(quick2)', '\(deep)', 'deep', '/Users/me/Developer/lumi', 5),
                   ('c_empty', 'Empty', 'sage', \(t), \(t + 30), NULL, NULL, NULL, NULL, 0);
            INSERT INTO research_jobs (conversation_id, session_id, report_path) VALUES ('c_deep', NULL, '/r/1/report.md');
            INSERT INTO screenshots (conversation_id, path) VALUES ('c_deep', '/s/1.jpg');
            UPDATE meta SET value = 3 WHERE key = 'colors_assigned';
            """)
    }

    @Test("a v1 file migrates to 2 keeping every row, and backfills Claude sessions and harness")
    func migratesV1() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "conversations.sqlite")
            try Self.makeV1(url)
            let index = try ConversationIndex(url: url)
            #expect(await index.schemaVersion == 2)
            #expect(ConversationIndex.migrations.count == 2)

            let quick = try #require(try await index.record(id: "c_quick"))
            #expect(quick.title == "Quick one" && quick.turns == 2 && quick.color == .ember)
            #expect(quick.harness == .quick)
            #expect(quick.claudeSessions.map(\.sessionID) == [Self.quick])
            #expect(quick.claudeSessions.first?.role == .quick)
            #expect(quick.recap.isEmpty && quick.lastDeepAnswer == nil && quick.voiceRulesNeeded)
            #expect(!quick.pinned && !quick.archived && !quick.titleLocked && quick.retitles == 0)

            let deep = try #require(try await index.record(id: "c_deep"))
            #expect(deep.harness == .legacy)
            #expect(Set(deep.claudeSessions.map(\.sessionID)) == [Self.quick2, Self.deep])
            #expect(deep.deepSessions == ["/Users/me/Developer/lumi": Self.deep])
            #expect(deep.lastDeepFolder == "/Users/me/Developer/lumi")
            #expect(deep.researchJobs.count == 1)
            #expect(Set(deep.sessionIDs) == [Self.quick2, Self.deep])
            #expect(try await index.screenshots(id: "c_deep") == ["/s/1.jpg"])

            let empty = try #require(try await index.record(id: "c_empty"))
            #expect(empty.harness == .legacy && empty.claudeSessions.isEmpty)

            // The colour rotation carries on from v1.
            #expect(try await index.nextColor() == .amber)
            #expect(rawScalar(url, "PRAGMA user_version") == "2")
            #expect(rawScalar(url, "SELECT count(*) FROM claude_sessions") == "3")
        }
    }

    @Test("reopening a migrated file doesn't migrate again")
    func idempotent() async throws {
        try await withTempDir { dir in
            let url = dir.appending(path: "conversations.sqlite")
            try Self.makeV1(url)
            _ = try ConversationIndex(url: url)
            let again = try ConversationIndex(url: url)
            #expect(await again.schemaVersion == 2)
            #expect(rawScalar(url, "SELECT count(*) FROM claude_sessions") == "3")
        }
    }

    @Test("a v1 turn after the migration keeps a Deep session per folder and persists when Deep answered")
    func perFolderDeepSessions() async throws {
        let index = try ConversationIndex(url: nil)
        _ = try await index.create(id: "c", title: "T", at: t0, projectFolder: nil)
        #expect(try await index.record(id: "c")?.harness == .quick)
        let a = "44444444-4444-4444-8444-444444444444", b = "55555555-5555-4555-8555-555555555555"
        try await index.recordTurn(id: "c", at: t0.addingTimeInterval(1), quickSessionID: nil, deepSessionID: a,
                                   lastLane: .deep, projectFolder: "/p/one", deepFolder: "/p/one")
        try await index.recordTurn(id: "c", at: t0.addingTimeInterval(2), quickSessionID: nil, deepSessionID: b,
                                   lastLane: .deep, projectFolder: "/p/two", deepFolder: "/p/two")
        let record = try #require(try await index.record(id: "c"))
        #expect(record.deepSessions == ["/p/one": a, "/p/two": b])
        #expect(record.lastDeepFolder == "/p/two")
        #expect(record.harness == .legacy)
        #expect(record.lastDeepAnswer == t0.addingTimeInterval(2))
        #expect(record.sessionIDs == [b, a])
    }

    @Test("forgetting a session deletes every Claude session it owns, and cascades its rows")
    func forgetCoversClaudeSessions() async throws {
        try await withTempDir { dir in
            let files = FakeSessionFiles()
            let index = try ConversationIndex(url: nil)
            let manager = ConversationManager(index: index, sessionFiles: files, screenshotDirectory: dir)
            let store = SessionStore(index: index, files: files, home: "/Users/me")
            let id = SessionID(rawValue: "s_1")
            _ = try await store.create(id, title: "Trip", origin: nil, harness: .open, at: t0)
            let open = UUID(), other = UUID()
            try await store.addClaudeSession(open, role: .open, cwd: URL(filePath: "/Users/me"), to: id, at: t0)
            try await store.addClaudeSession(other, role: .open, cwd: URL(filePath: "/Users/me/repo"), to: id, at: t0)
            try await store.recordUserTurn(uuid: "u1", kind: .typed, shown: "hi", session: open, in: id, at: t0)
            try await store.addDirectory(URL(filePath: "/Users/me/repo"), to: id, at: t0)
            let request = try #require(try await manager.prepareForget(id.rawValue))
            #expect(request.sessionCount == 2)
            _ = try #require(try await manager.forget(request))
            #expect(Set(files.deletedSessions.flatMap { $0 }) == [open.uuidString.lowercased(), other.uuidString.lowercased()])
            #expect(try await index.claudeSessions(of: id.rawValue).isEmpty)
            #expect(try await index.userTurns(of: id.rawValue).isEmpty)
            #expect(try await index.directories(of: id.rawValue).isEmpty)
        }
    }
}

@Suite("SessionStore")
struct SessionStoreTests {
    private func store() throws -> (SessionStore, ConversationIndex) {
        let index = try ConversationIndex(url: nil)
        return (SessionStore(index: index, files: FakeSessionFiles(), home: "/Users/me"), index)
    }

    @Test("a new session stores its origin, harness and context key")
    func create() async throws {
        let (store, _) = try store()
        let origin = SessionOrigin(key: ContextKey(bundleID: "com.apple.Numbers", target: "/d/burn.numbers"), appName: "Numbers")
        let id = SessionID.new()
        let record = try await store.create(id, title: "Q3 burn", origin: origin, harness: .open, at: t0)
        #expect(record.harness == .open && record.origin == origin && record.voiceRulesNeeded)
        let candidates = try await store.routingCandidates(since: t0.addingTimeInterval(-1))
        #expect(candidates.map(\.id) == [id])
        #expect(candidates.first?.contextKey == origin.key)
    }

    @Test("directories never include home, and come back in order")
    func directories() async throws {
        let (store, _) = try store()
        let id = SessionID.new()
        _ = try await store.create(id, title: "T", origin: nil, harness: .open, at: t0)
        try await store.addDirectory(URL(filePath: "/Users/me/"), to: id, at: t0)
        try await store.addDirectory(URL(filePath: "/Users/me/b/"), to: id, at: t0)
        try await store.addDirectory(URL(filePath: "/Users/me/a"), to: id, at: t0.addingTimeInterval(1))
        try await store.addDirectory(URL(filePath: "/Users/me/b"), to: id, at: t0.addingTimeInterval(2))
        #expect(try await store.directories(of: id).map(\.path) == ["/Users/me/b", "/Users/me/a"])
        #expect(try await store.routingCandidates(since: t0).first?.directories == ["/Users/me/b", "/Users/me/a"])
    }

    @Test("finishing a turn persists the recap, the preview and Deep's time")
    func finish() async throws {
        let (store, _) = try store()
        let id = SessionID.new()
        _ = try await store.create(id, title: "T", origin: nil, harness: .open, at: t0)
        try await store.recordUserTurn(uuid: "u1", kind: .voice, shown: "what is this", session: UUID(), in: id, at: t0)
        try await store.finishTurn(id, answerPreview: "It's a chart.", recap: ["a", "b", "c", "d"], at: t0.addingTimeInterval(5), lane: .deep)
        let record = try #require(try await store.record(id: id))
        #expect(record.recap == ["b", "c", "d"])
        #expect(record.turns == 1 && record.finishedAt == t0.addingTimeInterval(5))
        #expect(record.lastDeepAnswer == t0.addingTimeInterval(5))
        #expect(try await store.userTurns(of: id).map(\.answerPreview) == ["It's a chart."])
    }

    @Test("titles change at most twice, the symbol once, and never after a rename")
    func topics() async throws {
        let (store, _) = try store()
        let id = SessionID.new()
        _ = try await store.create(id, title: "Login", origin: nil, harness: .open, at: t0)
        #expect(!(try await store.setTopic(SessionTopic(title: "Fix OAuth"), for: id, refinement: true)), "no refinement before turn 1")
        #expect(try await store.setTopic(SessionTopic(title: "Login bug", symbol: "hammer"), for: id, refinement: false))
        #expect(!(try await store.setTopic(SessionTopic(title: "Again"), for: id, refinement: false)))
        #expect(try await store.setTopic(SessionTopic(title: "Fix OAuth redirect", symbol: "globe"), for: id, refinement: true))
        var record = try #require(try await store.record(id: id))
        #expect(record.title == "Fix OAuth redirect" && record.symbol == "hammer" && record.retitles == 2)
        #expect(!(try await store.setTopic(SessionTopic(title: "Third"), for: id, refinement: true)))

        let other = SessionID.new()
        _ = try await store.create(other, title: "x", origin: nil, harness: .open, at: t0)
        try await store.rename(other, to: "  My title ")
        #expect(!(try await store.setTopic(SessionTopic(title: "Model title"), for: other, refinement: false)))
        record = try #require(try await store.record(id: other))
        #expect(record.title == "My title" && record.titleLocked)
    }

    @Test("pin, archive, status and the voice-rules ledger persist; recent skips archived")
    func flags() async throws {
        let (store, _) = try store()
        let a = SessionID.new(), b = SessionID.new()
        _ = try await store.create(a, title: "A", origin: nil, harness: .open, at: t0)
        _ = try await store.create(b, title: "B", origin: nil, harness: .open, at: t0.addingTimeInterval(1))
        try await store.setPinned(true, for: a)
        try await store.setArchived(true, for: b)
        try await store.setStatus(.interrupted, for: a)
        #expect(await store.voiceRulesNeeded(a))
        await store.markVoiceRules(sent: true, for: a)
        #expect(!(await store.voiceRulesNeeded(a)))
        await store.markVoiceRules(sent: false, for: a)
        #expect(await store.voiceRulesNeeded(a))
        let ra = try #require(try await store.record(id: a))
        #expect(ra.pinned && ra.status == .interrupted)
        #expect(try await store.recent(limit: 10, includeArchived: false).map(\.id) == [a.rawValue])
        #expect(try await store.recent(limit: 10, includeArchived: true).map(\.id) == [b.rawValue, a.rawValue])
    }

    @Test("an edited prompt drops it and every later turn, rebuilds the recap and asks for the voice rules again")
    func rewind() async throws {
        let (store, _) = try store()
        let id = SessionID.new()
        _ = try await store.create(id, title: "Trip", origin: nil, harness: .open, at: t0)
        let claude = UUID()
        for (i, uuid) in ["u1", "u2", "u3"].enumerated() {
            let at = t0.addingTimeInterval(Double(i))
            try await store.recordUserTurn(uuid: uuid, kind: .typed, shown: "q\(i + 1)", session: claude, in: id, at: at)
            try await store.finishTurn(id, answerPreview: "a\(i + 1)", recap: ["old"], at: at, lane: .deep)
        }
        await store.markVoiceRules(sent: true, for: id)
        #expect(try await store.rewind(to: "nope", in: id).isEmpty)
        #expect(try await store.userTurns(of: id).count == 3, "an unknown prompt changes nothing")

        let dropped = try await store.rewind(to: "u2", in: id)
        #expect(dropped.map(\.uuid) == ["u2", "u3"])
        #expect(try await store.userTurns(of: id).map(\.uuid) == ["u1"])
        let record = try #require(try await store.record(id: id))
        #expect(record.recap == [ContextPacket.Conversation.recapEntry(question: "q1", answer: "a1")])
        #expect(await store.voiceRulesNeeded(id))
    }
}
