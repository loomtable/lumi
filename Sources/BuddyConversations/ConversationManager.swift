import BuddyCore
import Foundation

public protocol ConversationClock: Sendable {
    func now() -> Date
}

public struct SystemConversationClock: ConversationClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// What a finished question changes (from the bridge's `ConversationState` in `.done`).
public struct TurnUpdate: Sendable, Equatable {
    public var quickSessionID: String?
    public var deepSessionID: String?
    public var lastLane: Mode?
    /// The folder Deep ran in.
    public var deepFolder: String?

    public init(quickSessionID: String? = nil, deepSessionID: String? = nil, lastLane: Mode? = nil, deepFolder: String? = nil) {
        self.quickSessionID = quickSessionID
        self.deepSessionID = deepSessionID
        self.lastLane = lastLane
        self.deepFolder = deepFolder
    }
}

/// The conversation a question belongs to, ready for the bridge and the card header.
public struct PreparedConversation: Sendable, Equatable {
    public var id: String
    /// Nil until the first turn finishes and the conversation is saved.
    public var record: ConversationRecord?
    public var fresh: FreshReason?
    public var chips: [ConversationChip]
    /// The colour the card header shows. For a conversation not saved yet, the colour it will get
    /// on its first turn.
    public var color: ConversationColor

    /// "new" or "continuing · N".
    public var headerLabel: String {
        guard let record, record.turns > 0 else { return "new" }
        return "continuing · \(record.turns)"
    }
}

/// Shown before Forget, and handed back to confirm it.
public struct ForgetRequest: Sendable, Equatable {
    public let id: String
    public let title: String
    public let sessionCount: Int
    public let screenshotCount: Int
    /// Research reports (each job's folder) it would delete.
    public var reportCount = 0
}

public struct ForgetReport: Sendable, Equatable {
    public var screenshotsDeleted: [String]
    /// Already gone (e.g. swept after 24 h).
    public var screenshotsMissing: [String]
    /// Outside the screenshot folder, or could not be removed: left alone.
    public var screenshotsSkipped: [String]
    public var sessions: SessionDeletion
    /// Research job folders removed (each holds one report).
    public var reportsDeleted: [String] = []
}

/// Ties the conversation rules to the index ("Conversations"). Temporary mode keeps
/// conversations in memory only, so nothing reaches disk.
public actor ConversationManager {
    private var rules: ConversationRules
    /// The conversation the next question continues (the Conversations window marks it).
    public var currentConversationID: String? { rules.currentID }
    private let persistent: ConversationIndex
    private var temporaryIndex: ConversationIndex?
    private let sessionFiles: any SessionFileStore
    private let clock: any ConversationClock
    /// Only screenshots inside this folder are ever deleted.
    private let screenshotDirectory: URL
    /// Research reports live in a folder per job inside this one; only those folders are deleted.
    /// Nil: reports are left alone.
    private let reportsDirectory: URL?
    private let makeID: @Sendable () -> String
    /// Research jobs and screenshots from before a conversation's first turn was saved.
    private var pendingJobs: [String: [ResearchJobRecord]] = [:]
    private var pendingShots: [String: [String]] = [:]
    /// Forgotten while a question was still running: its late `finish` must not bring it back.
    private var forgotten: Set<String> = []
    /// Removed by retention while a question may still be running in it: its late `finish` must
    /// not recreate the row, and (unlike Forget) its sessions are kept.
    private var pruned: Set<String> = []

    public init(
        index: ConversationIndex, sessionFiles: any SessionFileStore = ClaudeSessionFiles(),
        screenshotDirectory: URL, reportsDirectory: URL? = nil, clock: any ConversationClock = SystemConversationClock(),
        policy: ConversationPolicy = ConversationPolicy(),
        makeID: @escaping @Sendable () -> String = { "c_" + UUID().uuidString.lowercased() }
    ) {
        self.persistent = index
        self.sessionFiles = sessionFiles
        self.screenshotDirectory = screenshotDirectory
        self.reportsDirectory = reportsDirectory
        self.clock = clock
        self.makeID = makeID
        rules = ConversationRules(policy: policy)
    }

    private var index: ConversationIndex { temporaryIndex ?? persistent }

    public var isTemporary: Bool { temporaryIndex != nil }

    /// Temporary mode: conversations from now on are kept in memory only and vanish when it is
    /// turned off. Turning it on or off starts fresh.
    /// Leaving temporary mode forgets every temporary conversation, including the Claude Code
    /// session files and screenshots it created, so nothing from it stays on disk.
    @discardableResult
    public func setTemporary(_ on: Bool) async throws(IndexError) -> [ForgetReport] {
        guard on != isTemporary else { return [] }
        var reports: [ForgetReport] = []
        if !on, let temporary = temporaryIndex {
            for record in try await temporary.list(limit: Int.max) {
                if let report = try await forgetRecord(record, in: temporary) { reports.append(report) }
            }
            for id in Set(pendingShots.keys).union(pendingJobs.keys) where try await temporary.record(id: id) == nil {
                forgotten.insert(id)   // a job still running in it deletes its report when it records
                reports.append(deleteFiles(shots: pendingShots[id] ?? [], sessions: pendingJobs[id]?.compactMap(\.sessionID) ?? [],
                                           reports: pendingJobs[id]?.map(\.reportPath) ?? []))
            }
            pendingShots = [:]
            pendingJobs = [:]
        }
        temporaryIndex = on ? try ConversationIndex(url: nil) : nil
        rules = ConversationRules(policy: rules.policy)
        return reports
    }

    public func setPolicy(_ policy: ConversationPolicy) {
        rules.policy = policy
    }

    // MARK: - Questions

    /// A question is starting with `projectFolder` in front.
    public func prepare(projectFolder: String?) async throws(IndexError) -> PreparedConversation {
        let (decision, chips) = rules.ask(projectFolder: projectFolder, at: clock.now(), newID: makeID())
        return try await prepared(decision, chips)
    }

    /// The question finished (`.done`). Saves the conversation on its first turn.
    public func finish(id: String, update: TurnUpdate, utterance: String) async throws(IndexError) -> ConversationRecord? {
        if pruned.contains(id) { return nil }
        if forgotten.contains(id) {
            // The user forgot it mid-question: delete what this last turn created, save nothing.
            _ = sessionFiles.deleteSessions([update.quickSessionID, update.deepSessionID].compactMap { $0 })
            return nil
        }
        let now = clock.now()
        // Deep's folder when it ran; otherwise the project that was in front (Quick-only turns).
        let project = update.deepFolder ?? (rules.currentID == id ? rules.currentProject : nil)
        if try await index.record(id: id) == nil {
            _ = try await index.create(id: id, title: Self.title(from: utterance), at: now, projectFolder: project)
            for job in pendingJobs.removeValue(forKey: id) ?? [] { try await index.addResearchJob(id: id, job) }
            for shot in pendingShots.removeValue(forKey: id) ?? [] { try await index.addScreenshot(id: id, path: shot) }
        }
        try await index.recordTurn(
            id: id, at: now, quickSessionID: update.quickSessionID, deepSessionID: update.deepSessionID,
            lastLane: update.lastLane, projectFolder: project)
        if rules.currentID == id { rules.turnFinished(at: now, projectFolder: project) }
        return try await index.record(id: id)
    }

    /// ⌘N, ＋ on the card, or "new topic".
    public func newConversation() async throws(IndexError) -> PreparedConversation {
        let (decision, chips) = rules.newConversation(at: clock.now(), newID: makeID())
        return try await prepared(decision, chips)
    }

    /// "↩ Back" or "go back". Nil once the window has closed.
    public func goBack() async throws(IndexError) -> ConversationRecord? {
        guard let id = rules.goBack(at: clock.now()) else { return nil }
        // Back in use, so retention counts from now.
        try await index.touch(id: id, at: clock.now())
        return try await index.record(id: id)
    }

    /// "Keep in the old one", "Resume '…'" or a pick from the Conversations window.
    public func switchTo(_ id: String) async throws(IndexError) -> ConversationRecord? {
        guard let record = try await index.record(id: id) else { return nil }
        rules.switchTo(id, project: record.projectFolder, at: clock.now())
        try await index.touch(id: id, at: clock.now())
        return record
    }

    /// One saved conversation, for the shell's chips.
    public func record(id: String) async throws(IndexError) -> ConversationRecord? {
        try await index.record(id: id)
    }

    /// A conversation saved before its first question was known ("Untitled") gets its title.
    public func retitle(_ id: String, from utterance: String) async throws(IndexError) {
        guard try await index.record(id: id) != nil else { return }
        try await index.rename(id: id, title: Self.title(from: utterance))
    }

    /// Kept in memory until the conversation's first turn is saved, then written.
    public func recordScreenshot(_ path: String, conversation id: String) async throws(IndexError) {
        if forgotten.contains(id) {
            // Forgotten while its turn was starting: delete it now (only inside the screenshot folder).
            _ = deleteFiles(shots: [path], sessions: [])
        } else if try await index.record(id: id) == nil {
            pendingShots[id, default: []].append(path)
        } else {
            try await index.addScreenshot(id: id, path: path)
        }
    }

    /// Kept in memory until the conversation's first turn is saved, then written.
    /// Called again when the job learns its session id: the same report replaces its row.
    public func recordResearchJob(_ job: ResearchJobRecord, conversation id: String) async throws(IndexError) {
        if forgotten.contains(id) {
            // Forgotten (or left with temporary mode) while the job ran: its report and session go now.
            _ = deleteFiles(shots: [], sessions: job.sessionID.map { [$0] } ?? [], reports: [job.reportPath])
        } else if pruned.contains(id) {
            // Removed by retention: its report goes with the row; sessions stay.
            _ = deleteFiles(shots: [], sessions: [], reports: [job.reportPath])
        } else if temporaryIndex != nil, try await index.record(id: id) == nil, try await persistent.record(id: id) != nil {
            // A saved conversation's job that ran on into temporary mode: kept with it.
            try await persistent.addResearchJob(id: id, job)
        } else if try await index.record(id: id) == nil {
            pendingJobs[id, default: []].removeAll { $0.reportPath == job.reportPath }
            pendingJobs[id, default: []].append(job)
        } else {
            try await index.addResearchJob(id: id, job)
        }
    }

    public func list(limit: Int = 50, offset: Int = 0) async throws(IndexError) -> [ConversationRecord] {
        try await index.list(limit: limit, offset: offset)
    }

    /// "The one about the empty list".
    public func search(_ query: String) async throws(IndexError) -> [ConversationRecord] {
        try await index.search(query)
    }

    // MARK: - Forget

    /// Step one: what would be deleted. Show it and ask; only `forget(_:)` deletes anything.
    public func prepareForget(_ id: String) async throws(IndexError) -> ForgetRequest? {
        guard let record = try await index.record(id: id) else { return nil }
        var request = ForgetRequest(
            id: id, title: record.title, sessionCount: record.sessionIDs.count,
            screenshotCount: try await index.screenshots(id: id).count)
        request.reportCount = record.researchJobs.count
        return request
    }

    /// Step two, after the user confirmed `request`: deletes the index row, its screenshots
    /// (only inside the screenshot folder) and its Claude Code session files. Returns nil, and
    /// deletes nothing, if the conversation changed since `request` was shown (ask again).
    public func forget(_ request: ForgetRequest) async throws(IndexError) -> ForgetReport? {
        guard let current = try await prepareForget(request.id), current == request,
              let record = try await index.record(id: request.id) else { return nil }
        return try await forgetRecord(record, in: index)
    }

    private func forgetRecord(_ record: ConversationRecord, in index: ConversationIndex) async throws(IndexError) -> ForgetReport? {
        let shots = try await index.delete(id: record.id)
        rules.forgot(record.id)
        // A question may still be running in it; its finish must not recreate the row.
        forgotten.insert(record.id)
        pendingJobs[record.id] = nil
        pendingShots[record.id] = nil
        return deleteFiles(shots: shots, sessions: record.sessionIDs, reports: record.researchJobs.map(\.reportPath))
    }

    // MARK: - Retention

    /// Settings › Conversations "Keep for": conversations not used since `date` leave the
    /// index, with their screenshots (only inside the screenshot folder). Their Claude Code
    /// session files stay: they are the user's own history in Claude Code, which only Forget
    /// deletes. The current conversation and the ↩ Back target are never pruned, and temporary
    /// conversations aren't touched (they vanish with temporary mode). Returns the removed ids.
    @discardableResult
    public func prune(unusedSince date: Date) async throws(IndexError) -> [String] {
        var removed: [String] = []
        for id in try await persistent.unusedSince(date) where !rules.referencedIDs(at: clock.now()).contains(id) {
            // Re-checked at the delete: a turn may have used it during the awaits above.
            guard !rules.referencedIDs(at: clock.now()).contains(id),
                  let jobs = try await persistent.record(id: id)?.researchJobs,
                  let shots = try await persistent.delete(id: id, ifUnusedSince: date) else { continue }
            pruned.insert(id)
            // Reports go with the row (they're Lumi's files); sessions stay, as above.
            _ = deleteFiles(shots: shots, sessions: [], reports: jobs.map(\.reportPath))
            removed.append(id)
        }
        return removed
    }

    private func deleteFiles(shots: [String], sessions: [String], reports: [String] = []) -> ForgetReport {
        var deleted: [String] = [], missing: [String] = [], skipped: [String] = []
        let folder = screenshotDirectory.resolvingSymlinksInPath().path + "/"
        for path in shots {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if !FileManager.default.fileExists(atPath: url.path) {
                missing.append(path)
            } else if url.path.hasPrefix(folder), (try? FileManager.default.removeItem(at: url)) != nil {
                deleted.append(path)
            } else {
                skipped.append(path)
            }
        }
        return ForgetReport(
            screenshotsDeleted: deleted, screenshotsMissing: missing, screenshotsSkipped: skipped,
            sessions: sessions.isEmpty ? SessionDeletion() : sessionFiles.deleteSessions(sessions),
            reportsDeleted: deleteReportFolders(reports))
    }

    /// Each report's job folder, only when it sits directly inside `reportsDirectory`.
    private func deleteReportFolders(_ reports: [String]) -> [String] {
        guard let root = reportsDirectory?.resolvingSymlinksInPath().standardizedFileURL.path else { return [] }
        var removed: [String] = []
        for path in Set(reports) {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard folder.deletingLastPathComponent().path == root,
                  (try? FileManager.default.removeItem(at: folder)) != nil else { continue }
            removed.append(folder.path)
        }
        return removed.sorted()
    }

    // MARK: - Helpers

    private func prepared(_ decision: ConversationRules.Decision, _ chips: [ConversationChip]) async throws(IndexError) -> PreparedConversation {
        let record = try await index.record(id: decision.conversationID)
        let fresh: FreshReason? = if case .startFresh(_, let reason) = decision { reason } else { nil }
        let color: ConversationColor
        if let record { color = record.color } else { color = try await index.nextColor() }
        return PreparedConversation(id: decision.conversationID, record: record, fresh: fresh, chips: chips, color: color)
    }

    /// The first utterance, trimmed to a short title.
    static func title(from utterance: String) -> String {
        let clean = utterance.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !clean.isEmpty else { return "Untitled" }
        return clean.count > 60 ? String(clean.prefix(59)) + "…" : clean
    }
}
