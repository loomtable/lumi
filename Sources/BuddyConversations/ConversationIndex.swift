import BuddyCore
import Foundation
import SQLite3

/// One row of the conversation index ("Conversation index"). Transcripts stay in
/// Claude Code's own session files; this only points at them.
public struct ConversationRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var color: ConversationColor
    public var created: Date
    public var lastUsed: Date
    public var quickSessionID: String?
    public var deepSessionID: String?
    /// The lane that answered last (follow-ups go there).
    public var lastLane: Mode?
    /// The folder Deep runs in for this conversation.
    public var projectFolder: String?
    /// Completed turns ("continuing · N").
    public var turns: Int
    /// Research jobs started from this conversation, oldest first.
    public var researchJobs: [ResearchJobRecord]

    public init(
        id: String, title: String, color: ConversationColor, created: Date, lastUsed: Date,
        quickSessionID: String? = nil, deepSessionID: String? = nil, lastLane: Mode? = nil,
        projectFolder: String? = nil, turns: Int = 0, researchJobs: [ResearchJobRecord] = []
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.created = created
        self.lastUsed = lastUsed
        self.quickSessionID = quickSessionID
        self.deepSessionID = deepSessionID
        self.lastLane = lastLane
        self.projectFolder = projectFolder
        self.turns = turns
        self.researchJobs = researchJobs
    }

    /// Every Claude Code session this conversation created (for Forget).
    public var sessionIDs: [String] {
        [quickSessionID, deepSessionID].compactMap { $0 } + researchJobs.compactMap(\.sessionID)
    }
}

/// One background Research job: its own `claude -p` session and its report.
public struct ResearchJobRecord: Sendable, Equatable {
    public var sessionID: String?
    public var reportPath: String

    public init(sessionID: String?, reportPath: String) {
        self.sessionID = sessionID
        self.reportPath = reportPath
    }
}

public enum IndexError: Error, Sendable, Equatable {
    case open(String)
    case sql(String)
}

/// The conversation index in SQLite (system SQLite3, WAL, versioned migrations). All access
/// goes through this actor.
public actor ConversationIndex {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "\(BuddyCore.folderName)/conversations.sqlite")
    }

    /// Schema changes, in order. `PRAGMA user_version` records how many have run.
    static let migrations: [String] = [
        """
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            color TEXT NOT NULL,
            created REAL NOT NULL,
            last_used REAL NOT NULL,
            quick_session TEXT,
            deep_session TEXT,
            last_lane TEXT,
            project_folder TEXT,
            turns INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX conversations_last_used ON conversations(last_used DESC);
        CREATE TABLE research_jobs (
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            session_id TEXT,
            report_path TEXT NOT NULL,
            PRIMARY KEY (conversation_id, report_path)
        );
        CREATE TABLE screenshots (
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            PRIMARY KEY (conversation_id, path)
        );
        CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        INSERT INTO meta (key, value) VALUES ('colors_assigned', 0);
        """,
    ]

    // Opened with SQLITE_OPEN_FULLMUTEX and used only from this actor; deinit is the one
    // nonisolated access, and it runs when nothing else can reach the actor.
    nonisolated(unsafe) private let db: OpaquePointer

    /// Opens (creating if needed) and migrates. Pass `nil` for an in-memory index (tests,
    /// temporary mode).
    public init(url: URL? = ConversationIndex.defaultURL) throws(IndexError) {
        var handle: OpaquePointer?
        let path: String
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            path = url.path
        } else {
            path = ":memory:"
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            sqlite3_close(handle)
            throw .open(message)
        }
        db = handle
        // busy_timeout first, so the WAL switch waits instead of failing if another process
        // holds the file.
        try Self.exec(db, "PRAGMA busy_timeout = 2000; PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try Self.migrate(db)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    public var schemaVersion: Int {
        (try? Self.scalar(db, "PRAGMA user_version")) ?? 0
    }

    // MARK: - Writes

    /// Creates a conversation with the next colour in rotation.
    public func create(id: String, title: String, at date: Date, projectFolder: String?) throws(IndexError) -> ConversationRecord {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            let index = try Self.scalar(db, "SELECT value FROM meta WHERE key = 'colors_assigned'")
            try Self.run(db, "UPDATE meta SET value = value + 1 WHERE key = 'colors_assigned'")
            let record = ConversationRecord(
                id: id, title: title, color: .forIndex(index), created: date, lastUsed: date, projectFolder: projectFolder)
            try Self.run(
                db,
                "INSERT INTO conversations (id, title, color, created, last_used, project_folder, turns) VALUES (?, ?, ?, ?, ?, ?, 0)",
                [.text(id), .text(title), .text(record.color.rawValue), .real(date.timeIntervalSince1970),
                 .real(date.timeIntervalSince1970), .optionalText(projectFolder)])
            try Self.exec(db, "COMMIT")
            return record
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    /// Records a finished turn: session IDs, lane, folder, use time, and one more turn.
    public func recordTurn(
        id: String, at date: Date, quickSessionID: String?, deepSessionID: String?, lastLane: Mode?,
        projectFolder: String?
    ) throws(IndexError) {
        try Self.run(
            db,
            """
            UPDATE conversations SET last_used = ?, turns = turns + 1,
                quick_session = COALESCE(?, quick_session), deep_session = COALESCE(?, deep_session),
                last_lane = COALESCE(?, last_lane), project_folder = COALESCE(?, project_folder)
            WHERE id = ?
            """,
            [.real(date.timeIntervalSince1970), .optionalText(quickSessionID), .optionalText(deepSessionID),
             .optionalText(lastLane?.rawValue), .optionalText(projectFolder), .text(id)])
    }

    public func touch(id: String, at date: Date) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET last_used = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .text(id)])
    }

    public func rename(id: String, title: String) throws(IndexError) {
        try Self.run(db, "UPDATE conversations SET title = ? WHERE id = ?", [.text(title), .text(id)])
    }

    public func addResearchJob(id: String, _ job: ResearchJobRecord) throws(IndexError) {
        try Self.run(
            db, "INSERT OR REPLACE INTO research_jobs (conversation_id, session_id, report_path) VALUES (?, ?, ?)",
            [.text(id), .optionalText(job.sessionID), .text(job.reportPath)])
    }

    public func addScreenshot(id: String, path: String) throws(IndexError) {
        try Self.run(db, "INSERT OR IGNORE INTO screenshots (conversation_id, path) VALUES (?, ?)", [.text(id), .text(path)])
    }

    /// Removes the row and its research-job/screenshot rows. Returns the screenshot paths it had, for
    /// the caller to delete.
    public func delete(id: String) throws(IndexError) -> [String] {
        let shots = try Self.strings(db, "SELECT path FROM screenshots WHERE conversation_id = ?", [.text(id)])
        try Self.run(db, "DELETE FROM conversations WHERE id = ?", [.text(id)])
        return shots
    }

    /// Retention: removes the row only if it still hasn't been used since `date`, checked and
    /// deleted in one step. Returns its screenshot paths, or nil if it was used meanwhile (or is gone).
    public func delete(id: String, ifUnusedSince date: Date) throws(IndexError) -> [String]? {
        guard let record = try record(id: id), record.lastUsed < date else { return nil }
        return try delete(id: id)
    }

    /// Ids of conversations not used since `date` (retention, default 90 days in Settings).
    public func unusedSince(_ date: Date) throws(IndexError) -> [String] {
        try Self.strings(db, "SELECT id FROM conversations WHERE last_used < ?", [.real(date.timeIntervalSince1970)])
    }

    // MARK: - Reads

    public func record(id: String) throws(IndexError) -> ConversationRecord? {
        try records("WHERE id = ?", [.text(id)]).first
    }

    /// Most recently used first.
    public func list(limit: Int = 50, offset: Int = 0) throws(IndexError) -> [ConversationRecord] {
        try records("ORDER BY last_used DESC LIMIT ? OFFSET ?", [.int(limit), .int(offset)])
    }

    /// Titles containing every word of `query` (words of two or more characters; "a" would match
    /// everything), case-insensitive, most recent first ("the one about the empty list").
    public func search(_ query: String, limit: Int = 10) throws(IndexError) -> [ConversationRecord] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        let clause = words.map { _ in "title LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
        let params = words.map { Bind.text("%" + Self.escapeLike($0) + "%") }
        return try records("WHERE \(clause) ORDER BY last_used DESC LIMIT ?", params + [.int(limit)])
    }

    /// The colour the next new conversation will get.
    public func nextColor() throws(IndexError) -> ConversationColor {
        .forIndex(try Self.scalar(db, "SELECT value FROM meta WHERE key = 'colors_assigned'"))
    }

    public func screenshots(id: String) throws(IndexError) -> [String] {
        try Self.strings(db, "SELECT path FROM screenshots WHERE conversation_id = ?", [.text(id)])
    }

    private func records(_ tail: String, _ params: [Bind]) throws(IndexError) -> [ConversationRecord] {
        let sql = """
            SELECT id, title, color, created, last_used, quick_session, deep_session, last_lane, project_folder, turns
            FROM conversations \(tail)
            """
        var out: [ConversationRecord] = []
        try Self.query(db, sql, params) { s in
            out.append(ConversationRecord(
                id: Self.text(s, 0) ?? "", title: Self.text(s, 1) ?? "",
                color: ConversationColor(rawValue: Self.text(s, 2) ?? "") ?? .ember,
                created: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
                quickSessionID: Self.text(s, 5), deepSessionID: Self.text(s, 6),
                lastLane: Self.text(s, 7).flatMap(Mode.init(rawValue:)), projectFolder: Self.text(s, 8),
                turns: Int(sqlite3_column_int64(s, 9))))
        }
        for i in out.indices {
            var jobs: [ResearchJobRecord] = []
            try Self.query(
                db, "SELECT session_id, report_path FROM research_jobs WHERE conversation_id = ? ORDER BY rowid",
                [.text(out[i].id)]
            ) { s in jobs.append(ResearchJobRecord(sessionID: Self.text(s, 0), reportPath: Self.text(s, 1) ?? "")) }
            out[i].researchJobs = jobs
        }
        return out
    }

    // MARK: - SQLite helpers

    enum Bind: Sendable {
        case text(String), optionalText(String?), real(Double), int(Int)
    }

    /// SQLITE_TRANSIENT: SQLite copies bound strings before the call returns.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func migrate(_ db: OpaquePointer) throws(IndexError) {
        guard try scalar(db, "PRAGMA user_version") < migrations.count else { return }
        for (i, sql) in migrations.enumerated() {
            try exec(db, "BEGIN IMMEDIATE")
            do {
                // Re-read inside the write lock: another process may have migrated meanwhile.
                guard try scalar(db, "PRAGMA user_version") == i else {
                    try exec(db, "COMMIT")
                    continue
                }
                try exec(db, sql)
                try exec(db, "PRAGMA user_version = \(i + 1)")
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws(IndexError) {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw .sql(message)
        }
    }

    static func prepare(_ db: OpaquePointer, _ sql: String, _ params: [Bind]) throws(IndexError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .sql(String(cString: sqlite3_errmsg(db)))
        }
        for (i, p) in params.enumerated() {
            let index = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, transient)
            case .optionalText(let s?): sqlite3_bind_text(statement, index, s, -1, transient)
            case .optionalText(nil): sqlite3_bind_null(statement, index)
            case .real(let d): sqlite3_bind_double(statement, index, d)
            case .int(let n): sqlite3_bind_int64(statement, index, sqlite3_int64(n))
            }
        }
        return statement
    }

    static func run(_ db: OpaquePointer, _ sql: String, _ params: [Bind] = []) throws(IndexError) {
        let s = try prepare(db, sql, params)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw .sql(String(cString: sqlite3_errmsg(db))) }
    }

    static func query(
        _ db: OpaquePointer, _ sql: String, _ params: [Bind], row: (OpaquePointer) throws(IndexError) -> Void
    ) throws(IndexError) {
        let s = try prepare(db, sql, params)
        defer { sqlite3_finalize(s) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw .sql(String(cString: sqlite3_errmsg(db))) }
            try row(s)
        }
    }

    static func scalar(_ db: OpaquePointer, _ sql: String) throws(IndexError) -> Int {
        var value = 0
        try query(db, sql, []) { value = Int(sqlite3_column_int64($0, 0)) }
        return value
    }

    static func strings(_ db: OpaquePointer, _ sql: String, _ params: [Bind]) throws(IndexError) -> [String] {
        var out: [String] = []
        try query(db, sql, params) { if let t = text($0, 0) { out.append(t) } }
        return out
    }

    static func text(_ s: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(s, column).map { String(cString: $0) }
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
