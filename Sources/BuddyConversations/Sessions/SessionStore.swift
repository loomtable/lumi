import BuddyCore
import Foundation

/// A Lumi session as the index stores it: v1 conversations and v2 sessions share the row.
public typealias SessionRecord = ConversationRecord

/// The v2 session store over the conversation index (migration 2). It extends the index rather
/// than replacing it, so Forget, retention, temporary mode and screenshot links keep working.
/// One instance per index: the shell makes a new one when temporary mode swaps the index.
public actor SessionStore {
    public let index: ConversationIndex
    private let files: any SessionFileStore
    private let home: String

    public init(index: ConversationIndex, files: any SessionFileStore = ClaudeSessionFiles(),
                home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.index = index
        self.files = files
        self.home = FolderTrustPath.normalize(home)
    }

    public func create(_ id: SessionID, title: String, origin: SessionOrigin?, harness: Harness, at date: Date) async throws(IndexError) -> SessionRecord {
        try await index.createSession(id: id.rawValue, title: title, origin: origin, harness: harness, at: date)
    }

    public func record(id: SessionID) async throws(IndexError) -> SessionRecord? {
        try await index.record(id: id.rawValue)
    }

    /// Most recently used first; archived sessions only when asked for.
    public func recent(limit: Int, includeArchived: Bool) async throws(IndexError) -> [SessionRecord] {
        var out: [SessionRecord] = []
        var offset = 0
        while out.count < limit {
            let page = try await index.list(limit: limit, offset: offset)
            out += includeArchived ? page : page.filter { !$0.archived }
            guard page.count == limit else { break }
            offset += limit
        }
        return Array(out.prefix(limit))
    }

    /// The router's input: sessions used since `date`, newest first, at most 50.
    public func routingCandidates(since date: Date) async throws(IndexError) -> [SessionRoutingInfo] {
        try await index.routingCandidates(since: date, limit: 50)
    }

    public func addClaudeSession(_ claude: UUID, role: ClaudeRole, cwd: URL, to id: SessionID, at date: Date) async throws(IndexError) {
        try await index.addClaudeSession(claude.uuidString.lowercased(), role: role, cwd: FolderTrustPath.normalize(cwd.path),
                                         conversation: id.rawValue, at: date)
    }

    /// A directory the session works in (passed again as `--add-dir` on every launch). Home is
    /// never one: it isn't a project.
    public func addDirectory(_ dir: URL, to id: SessionID, at date: Date) async throws(IndexError) {
        let path = FolderTrustPath.normalize(dir.path)
        guard path != home, path != "/" else { return }
        try await index.addDirectory(path, conversation: id.rawValue, at: date)
    }

    /// Claude Code reported the session missing: forget it, so the next turn starts a new one.
    public func removeClaudeSession(_ claude: String, from id: SessionID) async throws(IndexError) {
        try await index.removeClaudeSession(claude, conversation: id.rawValue)
    }

    public func directories(of id: SessionID) async throws(IndexError) -> [URL] {
        try await index.directories(of: id.rawValue).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func recordUserTurn(uuid: String, kind: TurnKind, shown: String, session: UUID, in id: SessionID, at date: Date) async throws(IndexError) {
        try await index.recordUserTurn(
            UserTurnRecord(uuid: uuid, sessionID: session.uuidString.lowercased(), kind: kind, shown: shown, at: date),
            conversation: id.rawValue)
    }

    public func userTurns(of id: SessionID) async throws(IndexError) -> [UserTurnRecord] {
        try await index.userTurns(of: id.rawValue)
    }

    /// An edited prompt: that user turn and every later one are forgotten, and the recap is rebuilt
    /// from the turns kept. The next voice turn carries the full rules again, since they may have
    /// gone with the dropped turns. Returns the dropped turns, oldest first; empty when `uuid` isn't
    /// one of the session's.
    public func rewind(to uuid: String, in id: SessionID) async throws(IndexError) -> [UserTurnRecord] {
        let turns = try await index.userTurns(of: id.rawValue)
        guard let at = turns.firstIndex(where: { $0.uuid == uuid }) else { return [] }
        let dropped = Array(turns[at...])
        try await index.removeUserTurns(dropped.map(\.uuid), conversation: id.rawValue)
        let recap = turns[..<at].filter { $0.kind != .steer && $0.kind != .relay }.compactMap { turn in
            turn.answerPreview.map { ContextPacket.Conversation.recapEntry(question: turn.shown, answer: $0) }
        }
        try await index.setRecap(Array(recap.suffix(ContextPacket.Conversation.maxPrevious)), id: id.rawValue)
        try await index.setVoiceRulesNeeded(true, id: id.rawValue)
        return dropped
    }

    /// The turn finished: the recap (last three entries) and the preview persist, so a relaunch or
    /// Continue has them.
    public func finishTurn(_ id: SessionID, answerPreview: String, recap: [String], at date: Date, lane: Mode?,
                           userTurn: Bool = true) async throws(IndexError) {
        try await index.finishSessionTurn(
            id: id.rawValue, answerPreview: String(answerPreview.prefix(Self.previewLimit)),
            recap: Array(recap.suffix(ContextPacket.Conversation.maxPrevious)), at: date, lane: lane, userTurn: userTurn)
    }

    public static let previewLimit = 600

    public func setStatus(_ status: PersistedStatus?, for id: SessionID) async throws(IndexError) {
        try await index.setStatus(status, id: id.rawValue)
    }

    /// The first question's words as the title until the first automatic one (`setTopic`).
    @discardableResult
    public func setProvisionalTopic(_ topic: SessionTopic, for id: SessionID) async throws(IndexError) -> Bool {
        try await index.setProvisionalTopic(id: id.rawValue, title: topic.title, symbol: topic.symbol)
    }

    /// Turn 1 sets the title and symbol; the turn-3 `refinement` may change the title only. A user
    /// rename locks both. Returns whether it applied.
    @discardableResult
    public func setTopic(_ topic: SessionTopic, for id: SessionID, refinement: Bool) async throws(IndexError) -> Bool {
        guard let record = try await index.record(id: id.rawValue) else { return false }
        // A refinement is turn 3's; turn 1's topic arrives first. Either way at most two.
        if refinement, record.retitles == 0 { return false }
        if !refinement, record.retitles > 0 { return false }
        return try await index.applyTopic(id: id.rawValue, title: topic.title, symbol: topic.symbol)
    }

    public func setPinned(_ pinned: Bool, for id: SessionID) async throws(IndexError) {
        try await index.setPinned(pinned, id: id.rawValue)
    }

    public func setArchived(_ archived: Bool, for id: SessionID) async throws(IndexError) {
        try await index.setArchived(archived, id: id.rawValue)
    }

    /// The user's title: it never changes automatically again.
    public func rename(_ id: SessionID, to title: String) async throws(IndexError) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try await index.renameLocked(id: id.rawValue, title: clean)
    }

    public func setHarness(_ harness: Harness, for id: SessionID) async throws(IndexError) {
        try await index.setHarness(harness, id: id.rawValue)
    }

    public func setContextKey(_ key: ContextKey?, for id: SessionID) async throws(IndexError) {
        try await index.setContextKey(key, id: id.rawValue)
    }

    /// The next voice turn sends the full rules: a new session, or one just compacted.
    public func voiceRulesNeeded(_ id: SessionID) async -> Bool {
        (try? await index.record(id: id.rawValue))?.voiceRulesNeeded ?? true
    }

    /// `sent`: a full-rules turn finished (clear); false marks them needed again (a compaction).
    public func markVoiceRules(sent: Bool, for id: SessionID) async {
        try? await index.setVoiceRulesNeeded(!sent, id: id.rawValue)
    }

    /// Deletes Claude Code's files for these sessions (Forget of a session the index no longer has).
    public func deleteSessionFiles(_ ids: [String]) -> SessionDeletion {
        files.deleteSessions(ids)
    }
}

/// Path normalisation shared with folder trust: standardised, no trailing slash.
enum FolderTrustPath {
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = URL(fileURLWithPath: p).standardizedFileURL.path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
