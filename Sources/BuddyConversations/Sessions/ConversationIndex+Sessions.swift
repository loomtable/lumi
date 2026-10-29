import BuddyCore
import Foundation
import SQLite3

/// One user turn as Lumi sent it: the replayed message's uuid keys the transcript.
public struct UserTurnRecord: Sendable, Equatable {
    public var uuid: String
    public var sessionID: String
    public var kind: TurnKind
    /// What the page shows for the user's turn (the transcript or typed text, an action's label).
    public var shown: String
    public var answerPreview: String?
    public var at: Date

    public init(uuid: String, sessionID: String, kind: TurnKind, shown: String, answerPreview: String? = nil, at: Date) {
        self.uuid = uuid
        self.sessionID = sessionID
        self.kind = kind
        self.shown = shown
        self.answerPreview = answerPreview
        self.at = at
    }
}

/// What the summon router reads per session (no transcripts, no I/O).
public struct SessionRoutingInfo: Sendable, Equatable {
    public var id: SessionID
    public var title: String
    public var harness: Harness
    public var contextKey: ContextKey?
    public var lastUsed: Date
    public var archived: Bool
    /// Its project folder and every directory added to it, standardised.
    public var directories: [String]

    public init(id: SessionID, title: String, harness: Harness, contextKey: ContextKey? = nil, lastUsed: Date,
                archived: Bool = false, directories: [String] = []) {
        self.id = id
        self.title = title
        self.harness = harness
        self.contextKey = contextKey
        self.lastUsed = lastUsed
        self.archived = archived
        self.directories = directories
    }
}

extension ContextKey {
    /// How the index stores it: the bundle ID, a newline, then the target. Matched exactly.
    public var stored: String { bundleID + "\n" + (target ?? "") }

    public init?(stored: String?) {
        guard let stored, let cut = stored.firstIndex(of: "\n") else { return nil }
        let target = String(stored[stored.index(after: cut)...])
        self.init(bundleID: String(stored[..<cut]), target: target.isEmpty ? nil : target)
    }
}

// The v2 session columns and tables (migration 2). Same actor, same connection.
extension ConversationIndex {
    // MARK: Session rows

    /// A new session row with the next colour, ready for its first turn.
    public func createSession(
        id: String, title: String, origin: SessionOrigin?, harness: Harness, at date: Date
    ) throws(IndexError) -> ConversationRecord {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            let index = try Self.scalar(db, "SELECT value FROM meta WHERE key = 'colors_assigned'")
            try Self.run(db, "UPDATE meta SET value = value + 1 WHERE key = 'colors_assigned'")
            try Self.run(
                db,
                """
                INSERT INTO conversations (id, title, color, created, last_used, turns, harness, origin, context_key)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
                """,
                [.text(id), .text(title), .text(ConversationColor.forIndex(index).rawValue),
                 .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970), .text(harness.rawValue),
                 .optionalText(origin.flatMap(Self.json)), .optionalText(origin?.key.stored)])
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
        guard let record = try record(id: id) else { throw .sql("session \(id) vanished") }
        return record
    }

    public func setHarness(_ harness: Harness, id: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET harness = ? WHERE id = ?", [.text(harness.rawValue), .text(id)])
    }

    /// A finished turn of a v2 session: one more turn, the recap, and the answer's preview on the
    /// turn's user row (the latest one).
    /// `userTurn` false: a turn the CLI started itself, whose answer doesn't belong to the user's row.
    public func finishSessionTurn(id: String, answerPreview: String, recap: [String], at date: Date, lane: Mode?,
                                  userTurn: Bool = true) throws(IndexError) {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            try Self.run(
                db,
                """
                UPDATE conversations SET last_used = ?, finished_at = ?, turns = turns + 1, recap = ?,
                    last_lane = COALESCE(?, last_lane),
                    last_deep_answer = CASE WHEN ? = 'deep' THEN ? ELSE last_deep_answer END
                WHERE id = ?
                """,
                [.real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970), .optionalText(Self.json(recap)),
                 .optionalText(lane?.rawValue), .optionalText(lane?.rawValue), .real(date.timeIntervalSince1970), .text(id)])
            if userTurn { try Self.run(
                db,
                """
                UPDATE user_turns SET answer_preview = ? WHERE uuid =
                    (SELECT uuid FROM user_turns WHERE conversation_id = ? ORDER BY at DESC, rowid DESC LIMIT 1)
                """,
                [.text(answerPreview), .text(id)]) }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    /// The recap and the time Deep answered, for a v1 conversation's turn (its row's turn count is
    /// `recordTurn`'s).
    public func setRecap(_ recap: [String], id: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET recap = ? WHERE id = ?", [.optionalText(Self.json(recap)), .text(id)])
    }

    public func setStatus(_ status: PersistedStatus?, id: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET status = ? WHERE id = ?", [.optionalText(status?.rawValue), .text(id)])
    }

    public func setPinned(_ pinned: Bool, id: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .text(id)])
    }

    public func setArchived(_ archived: Bool, id: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET archived = ? WHERE id = ?", [.int(archived ? 1 : 0), .text(id)])
    }

    /// The user's own title: locks both title and symbol for good.
    public func renameLocked(id: String, title: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET title = ?, title_locked = 1 WHERE id = ?", [.text(title), .text(id)])
    }

    /// The provisional title from the first question (and a symbol when it has none), shown until
    /// the first automatic title. Counts as no retitle; ignored once renamed or titled.
    @discardableResult
    public func setProvisionalTopic(id: String, title: String, symbol: String?) throws(IndexError) -> Bool {
        guard let record = try record(id: id), !record.titleLocked, record.retitles == 0 else { return false }
        try Self.run(db, "UPDATE conversations SET title = ?, symbol = ? WHERE id = ?",
                     [.text(title), .optionalText(record.symbol ?? symbol), .text(id)])
        return true
    }

    /// An automatic title (and, the first time only, symbol). Ignored once the user renamed it or
    /// after two automatic titles. Returns whether it applied.
    @discardableResult
    public func applyTopic(id: String, title: String, symbol: String?) throws(IndexError) -> Bool {
        guard let record = try record(id: id), !record.titleLocked, record.retitles < 2 else { return false }
        let newSymbol = record.retitles == 0 ? (symbol ?? record.symbol) : record.symbol
        try Self.run(
            db, "UPDATE conversations SET title = ?, symbol = ?, retitles = retitles + 1 WHERE id = ?",
            [.text(title), .optionalText(newSymbol), .text(id)])
        return true
    }

    public func setVoiceRulesNeeded(_ needed: Bool, id: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET voice_rules_needed = ? WHERE id = ?", [.int(needed ? 1 : 0), .text(id)])
    }

    // MARK: Claude sessions, directories, user turns

    public func addClaudeSession(_ sessionID: String, role: ClaudeRole, cwd: String?, conversation id: String, at date: Date) throws(IndexError) {
        try insertClaudeSession(sessionID, conversation: id, role: role, cwd: cwd, at: date)
    }

    func insertClaudeSession(_ sessionID: String, conversation id: String, role: ClaudeRole, cwd: String?, at date: Date) throws(IndexError) {
        try Self.run(
            db,
            "INSERT OR IGNORE INTO claude_sessions (session_id, conversation_id, role, cwd, created) VALUES (?, ?, ?, ?, ?)",
            [.text(sessionID), .text(id), .text(role.rawValue), .optionalText(cwd), .real(date.timeIntervalSince1970)])
    }

    /// Claude Code no longer has this session (its file is gone): it leaves the conversation.
    public func removeClaudeSession(_ sessionID: String, conversation id: String) throws(IndexError) {
        try Self.run(db, "DELETE FROM claude_sessions WHERE session_id = ? AND conversation_id = ?", [.text(sessionID), .text(id)])
    }

    /// Oldest first.
    public func claudeSessions(of id: String) throws(IndexError) -> [ClaudeSessionRecord] {
        var out: [ClaudeSessionRecord] = []
        try Self.query(
            db, "SELECT session_id, role, cwd, created FROM claude_sessions WHERE conversation_id = ? ORDER BY created, rowid",
            [.text(id)]
        ) { s in
            guard let sessionID = Self.text(s, 0), let role = Self.text(s, 1).flatMap(ClaudeRole.init(rawValue:)) else { return }
            out.append(ClaudeSessionRecord(sessionID: sessionID, role: role, cwd: Self.text(s, 2),
                                           created: Date(timeIntervalSince1970: sqlite3_column_double(s, 3))))
        }
        return out
    }

    public func addDirectory(_ path: String, conversation id: String, at date: Date) throws(IndexError) {
        try Self.run(
            db, "INSERT OR IGNORE INTO session_dirs (conversation_id, path, added) VALUES (?, ?, ?)",
            [.text(id), .text(path), .real(date.timeIntervalSince1970)])
    }

    /// In the order they were added.
    public func directories(of id: String) throws(IndexError) -> [String] {
        try Self.strings(db, "SELECT path FROM session_dirs WHERE conversation_id = ? ORDER BY added, rowid", [.text(id)])
    }

    public func recordUserTurn(_ turn: UserTurnRecord, conversation id: String) throws(IndexError) {
        try Self.run(
            db,
            """
            INSERT OR REPLACE INTO user_turns (uuid, conversation_id, session_id, kind, shown, answer_preview, at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(turn.uuid), .text(id), .text(turn.sessionID), .text(turn.kind.rawValue), .text(turn.shown),
             .optionalText(turn.answerPreview), .real(turn.at.timeIntervalSince1970)])
    }

    /// An edited prompt replaces these turns.
    public func removeUserTurns(_ uuids: [String], conversation id: String) throws(IndexError) {
        for uuid in uuids {
            try Self.run(db, "DELETE FROM user_turns WHERE uuid = ? AND conversation_id = ?", [.text(uuid), .text(id)])
        }
    }

    /// Oldest first.
    public func userTurns(of id: String) throws(IndexError) -> [UserTurnRecord] {
        var out: [UserTurnRecord] = []
        try Self.query(
            db,
            "SELECT uuid, session_id, kind, shown, answer_preview, at FROM user_turns WHERE conversation_id = ? ORDER BY at, rowid",
            [.text(id)]
        ) { s in
            guard let uuid = Self.text(s, 0), let session = Self.text(s, 1),
                  let kind = Self.text(s, 2).flatMap(TurnKind.init(rawValue:)) else { return }
            out.append(UserTurnRecord(uuid: uuid, sessionID: session, kind: kind, shown: Self.text(s, 3) ?? "",
                                      answerPreview: Self.text(s, 4), at: Date(timeIntervalSince1970: sqlite3_column_double(s, 5))))
        }
        return out
    }

    // MARK: Routing

    /// Sessions used since `date`, newest first, at most `limit`: the router's candidates.
    public func routingCandidates(since date: Date, limit: Int = 50) throws(IndexError) -> [SessionRoutingInfo] {
        var out: [SessionRoutingInfo] = []
        try Self.query(
            db,
            """
            SELECT id, title, harness, context_key, last_used, archived, project_folder FROM conversations
            WHERE last_used >= ? ORDER BY last_used DESC LIMIT ?
            """,
            [.real(date.timeIntervalSince1970), .int(limit)]
        ) { s in
            out.append(SessionRoutingInfo(
                id: SessionID(rawValue: Self.text(s, 0) ?? ""), title: Self.text(s, 1) ?? "",
                harness: Self.text(s, 2).flatMap(Harness.init(rawValue:)) ?? .legacy,
                contextKey: ContextKey(stored: Self.text(s, 3)),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                archived: sqlite3_column_int64(s, 5) != 0,
                directories: Self.text(s, 6).map { [$0] } ?? []))
        }
        for i in out.indices {
            for dir in try directories(of: out[i].id.rawValue) where !out[i].directories.contains(dir) {
                out[i].directories.append(dir)
            }
        }
        return out
    }

    /// The context key a session was last asked from: set when it's used from another app.
    public func setContextKey(_ key: ContextKey?, id: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET context_key = ? WHERE id = ?", [.optionalText(key?.stored), .text(id)])
    }

    // MARK: Helpers

    /// The migration 2 columns, from column `first` of `records`' select on.
    static func readSessionColumns(_ s: OpaquePointer, from first: Int32, into record: inout ConversationRecord) {
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, first + i)) }
        func date(_ i: Int32) -> Date? {
            sqlite3_column_type(s, first + i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, first + i))
        }
        record.harness = text(s, first).flatMap(Harness.init(rawValue:)) ?? .legacy
        record.symbol = text(s, first + 1)
        record.origin = text(s, first + 2).flatMap { try? JSONDecoder().decode(SessionOrigin.self, from: Data($0.utf8)) }
        record.contextKey = text(s, first + 3)
        record.pinned = int(4) != 0
        record.archived = int(5) != 0
        record.titleLocked = int(6) != 0
        record.retitles = int(7)
        record.status = text(s, first + 8).flatMap(PersistedStatus.init(rawValue:))
        record.finishedAt = date(9)
        record.lastDeepAnswer = date(10)
        record.recap = text(s, first + 11).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        record.voiceRulesNeeded = int(12) != 0
    }

    static func json(_ value: some Encodable) -> String? {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
