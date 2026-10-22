import BuddyConversations
import BuddyCore
import Foundation
import Observation

/// The Conversations window's state: history or search results, the selection, and
/// Forget's two-step confirmation.
@Observable
public final class ConversationHistoryModel {
    public private(set) var records: [ConversationRecord] = []
    public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    public var selection: ConversationRecord.ID?
    public private(set) var isLoading = false
    public private(set) var canLoadMore = false
    /// A list has been read: from then on an empty `records` means "none", not "not read yet".
    private var hasLoaded = false
    /// Shows "No conversations yet" (or no matches). Not tied to `isLoading`: each reload (the
    /// window becoming key, a search, a toggle) would otherwise swap the empty state for a blank
    /// list and back, so it blinked.
    public var showsEmptyState: Bool { records.isEmpty && hasLoaded }
    /// A user-facing line when something failed (never an error dump).
    public private(set) var problem: String?
    /// Waiting for the user to confirm (Privacy: "after a confirmation").
    public var pendingForget: ForgetRequest?
    /// What just happened ("Resumed …", "Forgot …"): one true line.
    public private(set) var notice: String?
    /// The conversation the next question continues, marked in the list.
    public private(set) var currentID: String?
    /// The manager's real state, not the preference: the banner shows only what's true.
    public private(set) var isTemporary = false

    private let source: any ConversationHistorySource
    private var temporaryTask: Task<Void, Never>?
    private let onResume: (ConversationRecord) -> Void
    private var searchTask: Task<Void, Never>?
    /// Where the next history page starts in the index (rows forgotten here don't shift it wrongly).
    private var nextOffset = 0
    /// Bumped whenever `records` is replaced, so a page that was in flight isn't appended to it.
    private var generation = 0
    static let pageSize = 50
    static let searchDelay: Duration = .milliseconds(200)

    public init(source: any ConversationHistorySource, onResume: @escaping (ConversationRecord) -> Void = { _ in }) {
        self.source = source
        self.onResume = onResume
    }

    public var selected: ConversationRecord? { records.first { $0.id == selection } }
    /// The selected conversation's turns, oldest first, for the detail pane. Nil while they load or
    /// with nothing selected.
    public private(set) var shownTurns: [TranscriptTurn]?
    @ObservationIgnored private var turnsFor: String?

    /// Reads the selected conversation's turns. Only looks: the next question still goes where it
    /// went before (Resume switches).
    public func loadTurns() async {
        guard let id = selection else {
            turnsFor = nil
            shownTurns = nil
            return
        }
        turnsFor = id
        shownTurns = nil
        let turns = await source.turns(id)
        guard turnsFor == id else { return }  // a newer selection took over
        shownTurns = turns
    }

    /// Posted (on the main thread) when a conversation gains a turn, e.g. one continued in the
    /// overlay while this window is open: the window reloads, and the detail follows.
    public static let turnsChanged = Notification.Name("LumiConversationTurnsChanged")

    /// Re-reads the shown conversation's turns in place: the old ones stay until the new ones
    /// arrive, so a refresh never shows Loading.
    private func refreshTurns() async {
        guard let id = selection, turnsFor == id, shownTurns != nil else { return }
        let turns = await source.turns(id)
        guard turnsFor == id else { return }
        shownTurns = turns
    }

    // MARK: Loading and search

    public func reload() async {
        searchTask?.cancel()
        isTemporary = await source.isTemporary()
        currentID = await source.currentID()
        await load(query: query)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    public func loadMore() async {
        guard canLoadMore, trimmedQuery.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let started = generation
        do {
            let page = try await source.list(limit: Self.pageSize, offset: nextOffset)
            // A search or reload replaced the list meanwhile: this page belongs to the old one.
            guard started == generation, trimmedQuery.isEmpty else { return }
            let shown = Set(records.map(\.id))
            records += page.filter { !shown.contains($0.id) }
            nextOffset += page.count
            canLoadMore = page.count == Self.pageSize
        } catch {
            problem = "Couldn't load more conversations."
        }
    }

    /// The toggle changed: applies `on` after any earlier change finishes, skipping changes
    /// that were superseded meanwhile, so flipping it quickly ends on the latest value.
    public func requestTemporary(_ on: Bool) {
        let previous = temporaryTask
        previous?.cancel()
        temporaryTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.setTemporary(on)
        }
    }

    private var retentionTask: Task<Void, Never>?

    /// A retention change: prune, then show the result. A newer change replaces an older one.
    public func requestRetention(_ days: Int) {
        retentionTask?.cancel()
        retentionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            try? await self.source.prune(retentionDays: days)
            guard !Task.isCancelled else { return }
            await self.reload()
        }
    }

    /// Waits for a pending retention change (tests).
    func retentionSettled() async { await retentionTask?.value }

    /// Waits for pending temporary-mode changes (tests).
    func temporarySettled() async { await temporaryTask?.value }

    /// Applies the temporary-mode toggle to the manager, then shows the list it now reads.
    public func setTemporary(_ on: Bool) async {
        var failure: String?
        do {
            try await source.setTemporary(on)
        } catch {
            failure = on ? "Couldn't turn on temporary mode." : "Couldn't turn off temporary mode."
        }
        await reload()
        if let failure { problem = failure }  // after the reload, which would clear it
    }

    /// Waits for the pending debounced search, if any (tests).
    func searchSettled() async { await searchTask?.value }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled else { return }
            await self?.load(query: q)
        }
    }

    private func load(query q: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            let result = trimmed.isEmpty
                ? try await source.list(limit: Self.pageSize, offset: 0)
                : try await source.search(trimmed)
            guard q == query else { return }  // a newer query is on its way
            let before = selected
            records = result
            hasLoaded = true
            generation += 1
            nextOffset = trimmed.isEmpty ? result.count : 0
            canLoadMore = trimmed.isEmpty && result.count == Self.pageSize
            problem = nil
            if let s = selection, !result.contains(where: { $0.id == s }) { selection = nil }
            // The shown conversation gained turns (continued in the overlay): show them.
            if let before, let now = selected, now.turns != before.turns || now.lastUsed != before.lastUsed {
                await refreshTurns()
            }
        } catch {
            problem = "Couldn't read the conversation history."
        }
    }

    // MARK: Actions

    public func resume(_ record: ConversationRecord) async {
        clearStatus()
        do {
            guard let current = try await source.resume(record.id) else {
                await reload()  // after the reload, which clears the status line
                problem = "“\(record.title)” is no longer in the history."
                return
            }
            // Visibly resumed: the row is marked current, moves to the top (it was just used),
            // and the line says what happens next.
            onResume(current)
            await reload()
            currentID = current.id
            notice = Self.resumedNotice(current.title)
        } catch {
            problem = "Couldn't resume “\(record.title)”."
        }
    }

    static func resumedNotice(_ title: String) -> String {
        "Next question continues “\(title)”."
    }

    /// Step one: show what would be deleted.
    public func askToForget(_ record: ConversationRecord) async {
        clearStatus()
        await ask(id: record.id, title: record.title)
    }

    private func ask(id: String, title: String) async {
        do {
            pendingForget = try await source.prepareForget(id)
            if pendingForget == nil { await reload() }  // already gone
        } catch {
            problem = "Couldn't prepare to forget “\(title)”."
        }
    }

    /// Step two, after the user confirmed. The dialog passes the request it showed: dismissing it
    /// clears `pendingForget` before this runs.
    public func confirmForget(_ shown: ForgetRequest? = nil) async {
        guard let request = shown ?? pendingForget else { return }
        pendingForget = nil
        do {
            guard let report = try await source.forget(request) else {
                // It changed while the question was showing: ask again with fresh numbers
                // (by id, so it works wherever the row is, even pages down).
                await ask(id: request.id, title: request.title)
                return
            }
            if records.contains(where: { $0.id == request.id }), trimmedQuery.isEmpty { nextOffset -= 1 }
            records.removeAll { $0.id == request.id }
            if selection == request.id { selection = nil }
            if currentID == request.id { currentID = nil }  // the next question starts fresh
            notice = Self.forgotNotice(request.title, report)
        } catch {
            problem = "Couldn't forget “\(request.title)”."
        }
    }

    public func cancelForget() { pendingForget = nil }

    private func clearStatus() {
        problem = nil
        notice = nil
    }

    /// Says what Forget actually did, not just that it ran: files it had to leave are counted.
    static func forgotNotice(_ title: String, _ report: ForgetReport) -> String {
        let left = report.screenshotsSkipped.count + report.sessions.skipped.count
        guard left > 0 else { return "Forgot “\(title)”." }
        return "Forgot “\(title)”, but \(left) file\(left == 1 ? "" : "s") couldn't be removed."
    }

    /// The confirmation's message: exactly what will be deleted.
    public static func forgetMessage(_ r: ForgetRequest) -> String {
        var parts = ["its entry in the history"]
        if r.screenshotCount > 0 { parts.append("\(r.screenshotCount) screenshot\(r.screenshotCount == 1 ? "" : "s")") }
        // How Claude Code stores it is plumbing; the user sees "its saved conversation".
        if r.sessionCount > 0 { parts.append("its saved conversation") }
        // Counted per Research job, and a cancelled or running job has no report yet: no number.
        if r.reportCount > 0 { parts.append("its research reports") }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "This deletes \(list). It can't be undone."
    }
}
