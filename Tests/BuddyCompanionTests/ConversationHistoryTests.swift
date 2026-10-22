import BuddyBridge
@testable import BuddyConversations
import BuddyCore
import Foundation
import SwiftUI
import Testing
@testable import BuddyCompanion

private struct Failure: Error {}

/// What the list showed at one moment, read from inside the fake source.
@MainActor private final class Seen { var emptyState: Bool? }


/// Records calls and answers from canned data.
private actor FakeHistorySource: ConversationHistorySource {
    var all: [ConversationRecord]
    var failing = false
    /// `forget` answers nil this many times (the conversation "changed").
    var staleForgets = 0
    var resumeAnswer: ConversationRecord?? = .none
    private(set) var searches: [String] = []
    private(set) var listCalls: [(limit: Int, offset: Int)] = []
    private(set) var forgotten: [String] = []
    private(set) var prepared: [String] = []
    private(set) var temporary = false
    private(set) var prunes: [Int] = []
    func prune(retentionDays: Int) async throws {
        prunes.append(retentionDays)
        all.removeAll { $0.title.hasPrefix("Old") }
    }
    var current: String?
    func set(current: String?) { self.current = current }
    func currentID() async -> String? { current }
    var report = ForgetReport(screenshotsDeleted: [], screenshotsMissing: [], screenshotsSkipped: [], sessions: SessionDeletion())
    func set(report: ForgetReport) { self.report = report }
    /// Runs inside `list`, before it answers (to interleave a search with a page in flight).
    var duringList: (@Sendable () async -> Void)?

    init(_ records: [ConversationRecord]) { all = records }

    func set(failing: Bool) { self.failing = failing }
    func set(staleForgets: Int) { self.staleForgets = staleForgets }
    func set(resumeAnswer: ConversationRecord?) { self.resumeAnswer = .some(resumeAnswer) }
    func set(duringList: (@Sendable () async -> Void)?) { self.duringList = duringList }
    func remove(_ id: String) { all.removeAll { $0.id == id } }

    func isTemporary() async -> Bool { temporary }
    var temporaryFails = false
    func set(temporaryFails: Bool) { self.temporaryFails = temporaryFails }
    func setTemporary(_ on: Bool) async throws {
        if failing || temporaryFails { throw Failure() }
        temporary = on
    }

    func list(limit: Int, offset: Int) async throws -> [ConversationRecord] {
        listCalls.append((limit, offset))
        if failing { throw Failure() }
        let answer = Array(all.dropFirst(offset).prefix(limit))
        if let hook = duringList {
            duringList = nil
            await hook()
        }
        return answer
    }

    func search(_ query: String) async throws -> [ConversationRecord] {
        searches.append(query)
        if failing { throw Failure() }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var turnsByID: [String: [TranscriptTurn]] = [:]
    func set(turns: [TranscriptTurn], for id: String) { turnsByID[id] = turns }
    /// A turn asked in the overlay: the index row and its turns both grow.
    func add(_ turn: TranscriptTurn, to id: String) {
        turnsByID[id, default: []].append(turn)
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].turns += 1
        all[i].lastUsed = all[i].lastUsed.addingTimeInterval(60)
    }
    /// Held until released, to interleave two selections.
    var holdTurns: CheckedContinuation<Void, Never>?
    var holding = false
    func set(holding: Bool) { self.holding = holding }
    func releaseTurns() { holdTurns?.resume(); holdTurns = nil }
    private(set) var turnsReads = 0
    func turns(_ id: String) async -> [TranscriptTurn] {
        turnsReads += 1
        if holding, id == "c1" { await withCheckedContinuation { holdTurns = $0 } }
        return turnsByID[id] ?? []
    }

    func resume(_ id: String) async throws -> ConversationRecord? {
        if failing { throw Failure() }
        if case .some(let answer) = resumeAnswer { return answer }
        return all.first { $0.id == id }
    }

    func prepareForget(_ id: String) async throws -> ForgetRequest? {
        prepared.append(id)
        if failing { throw Failure() }
        guard let r = all.first(where: { $0.id == id }) else { return nil }
        return ForgetRequest(id: r.id, title: r.title, sessionCount: r.sessionIDs.count, screenshotCount: 2)
    }

    func forget(_ request: ForgetRequest) async throws -> ForgetReport? {
        if failing { throw Failure() }
        if staleForgets > 0 {
            staleForgets -= 1
            return nil
        }
        forgotten.append(request.id)
        all.removeAll { $0.id == request.id }
        if current == request.id { current = nil }
        return report
    }
}

private func record(_ n: Int, title: String? = nil, quick: String? = nil, deep: String? = nil,
                    lane: Mode? = nil, folder: String? = nil, turns: Int = 0) -> ConversationRecord {
    ConversationRecord(id: "c\(n)", title: title ?? "Conversation \(n)", color: .forIndex(n),
                       created: Date(timeIntervalSince1970: 0), lastUsed: Date(timeIntervalSince1970: Double(n)),
                       quickSessionID: quick, deepSessionID: deep, lastLane: lane, projectFolder: folder, turns: turns)
}

@Suite("ConversationHistoryModel")
@MainActor
struct ConversationHistoryModelTests {
    private func make(_ records: [ConversationRecord], onResume: @escaping (ConversationRecord) -> Void = { _ in })
        -> (ConversationHistoryModel, FakeHistorySource) {
        let source = FakeHistorySource(records)
        let model = ConversationHistoryModel(source: source, onResume: onResume)
        return (model, source)
    }

    /// Waits past the search debounce.
    @Test("reload lists the first page")
    func reload() async {
        let (model, source) = make((1...3).map { record($0) })
        await model.reload()
        #expect(model.records.map(\.id) == ["c1", "c2", "c3"])
        #expect(!model.canLoadMore)
        #expect(!model.isLoading)
        #expect(await source.listCalls.first?.limit == ConversationHistoryModel.pageSize)
    }

    @Test("the empty state holds through a reload instead of blinking")
    func emptyStateSteadyDuringReload() async {
        let (model, source) = make([])
        #expect(!model.showsEmptyState)  // not read yet: no "No conversations yet" before the first list
        await model.reload()
        #expect(model.showsEmptyState)
        let seen = Seen()
        await source.set(duringList: { @MainActor in seen.emptyState = model.showsEmptyState })
        await model.reload()  // the window became key again
        #expect(seen.emptyState == true)
        #expect(model.showsEmptyState)
    }

    @Test("pages of 50 until a short page")
    func paging() async {
        let (model, source) = make((1...120).map { record($0) })
        await model.reload()
        #expect(model.records.count == 50)
        #expect(model.canLoadMore)
        await model.loadMore()
        #expect(model.records.count == 100)
        await model.loadMore()
        #expect(model.records.count == 120)
        #expect(!model.canLoadMore)
        await model.loadMore()
        #expect(await source.listCalls.map(\.offset) == [0, 50, 100])
    }

    @Test("a failed page keeps what's shown and says so")
    func pagingFailure() async {
        let (model, source) = make((1...60).map { record($0) })
        await model.reload()
        await source.set(failing: true)
        await model.loadMore()
        #expect(model.records.count == 50)
        #expect(model.problem == "Couldn't load more conversations.")
    }

    @Test("a failed read says so")
    func readFailure() async {
        let (model, source) = make([record(1)])
        await source.set(failing: true)
        await model.reload()
        #expect(model.problem == "Couldn't read the conversation history.")
        await source.set(failing: false)
        await model.reload()
        #expect(model.problem == nil)
    }

    @Test("typing searches once, after the debounce, trimmed")
    func search() async throws {
        let (model, source) = make([record(1, title: "Fix the build"), record(2, title: "Dinner ideas")])
        await model.reload()
        model.query = "b"
        model.query = "bu"
        model.query = " build "
        await model.searchSettled()
        #expect(await source.searches == ["build"])
        #expect(model.records.map(\.id) == ["c1"])
        #expect(!model.canLoadMore)
    }

    @Test("clearing the search lists again")
    func clearSearch() async throws {
        let (model, source) = make([record(1, title: "Fix the build"), record(2, title: "Dinner ideas")])
        model.query = "dinner"
        await model.searchSettled()
        #expect(model.records.map(\.id) == ["c2"])
        model.query = ""
        await model.searchSettled()
        #expect(model.records.count == 2)
        #expect(await source.searches == ["dinner"])
    }

    @Test("a selection that's filtered out is cleared")
    func selectionCleared() async throws {
        let (model, _) = make([record(1, title: "Fix the build"), record(2, title: "Dinner ideas")])
        await model.reload()
        model.selection = "c2"
        #expect(model.selected?.id == "c2")
        model.query = "build"
        await model.searchSettled()
        #expect(model.selection == nil)
    }

    @Test("resume switches and hands the record to the shell")
    func resume() async {
        var resumed: [String] = []
        let (model, _) = make([record(1)], onResume: { resumed.append($0.id) })
        await model.reload()
        await model.resume(model.records[0])
        #expect(resumed == ["c1"])
    }

    @Test("resuming one that's gone reloads instead")
    func resumeGone() async {
        var resumed = 0
        let (model, source) = make([record(1), record(2)], onResume: { _ in resumed += 1 })
        await model.reload()
        await source.set(resumeAnswer: nil)
        await model.resume(model.records[0])
        #expect(resumed == 0)
        #expect(await source.listCalls.count == 2)
    }

    @Test("a failed resume says which one")
    func resumeFailure() async {
        let (model, source) = make([record(1, title: "Dinner")])
        await model.reload()
        await source.set(failing: true)
        await model.resume(model.records[0])
        #expect(model.problem == "Couldn't resume “Dinner”.")
    }

    @Test("Resume visibly resumes: the row is current and the line says what happens next")
    func resumeMarksCurrent() async {
        var resumed: [String] = []
        let (model, _) = make([record(1, title: "Dinner"), record(2)], onResume: { resumed.append($0.id) })
        await model.reload()
        #expect(model.currentID == nil)
        await model.resume(model.records[0])
        #expect(model.currentID == "c1")
        #expect(model.notice == "Next question continues “Dinner”.")
        #expect(resumed == ["c1"])
    }

    @Test("a conversation that's gone says so instead of silently reloading")
    func resumeGoneSaysSo() async {
        let (model, source) = make([record(1, title: "Dinner")])
        await model.reload()
        await source.set(resumeAnswer: nil)
        await source.remove("c1")
        await model.resume(model.records[0])
        #expect(model.problem == "“Dinner” is no longer in the history.")
        #expect(model.records.isEmpty)
    }

    @Test("the current conversation is read from the source on load")
    func currentOnLoad() async {
        let (model, source) = make([record(1), record(2)])
        await source.set(current: "c2")
        await model.reload()
        #expect(model.currentID == "c2")
    }

    @Test("forgetting the current conversation clears it, so the next question starts fresh")
    func forgetCurrent() async {
        let (model, source) = make([record(1, title: "Dinner")])
        await source.set(current: "c1")
        await model.reload()
        await model.askToForget(model.records[0])
        await model.confirmForget()
        #expect(model.currentID == nil)
        #expect(model.records.isEmpty)
    }

    @Test("selecting a conversation shows its turns; nothing selected shows none")
    func showsTurns() async {
        let (model, source) = make([record(1, title: "Dinner"), record(2)])
        let turn = TranscriptTurn(question: "what's for dinner?", block: BuddyBlock(say: "Pasta.", shape: .chip), mode: .quick, model: .haiku)
        await source.set(turns: [turn], for: "c1")
        await model.reload()
        model.selection = "c1"
        await model.loadTurns()
        #expect(model.shownTurns == [turn])
        model.selection = "c2"
        await model.loadTurns()
        #expect(model.shownTurns == [], "no saved turns")
        model.selection = nil
        await model.loadTurns()
        #expect(model.shownTurns == nil)
        #expect(model.currentID == nil, "looking never resumes")
    }

    @Test("a slow read for an earlier selection never replaces the newer one's turns")
    func newerSelectionWins() async {
        let (model, source) = make([record(1), record(2)])
        let second = TranscriptTurn(question: "q2", block: BuddyBlock(say: "a2", shape: .chip), mode: .quick, model: .haiku)
        await source.set(turns: [second], for: "c2")
        await source.set(holding: true)
        await model.reload()
        model.selection = "c1"
        let slow = Task { await model.loadTurns() }
        while await source.holdTurns == nil { await Task.yield() }
        model.selection = "c2"
        await model.loadTurns()
        await source.releaseTurns()
        await slow.value
        #expect(model.shownTurns == [second])
    }

    @Test("the detail pane reads the selected conversation once and settles, through window-key reloads")
    func detailSettles() async throws {
        let (model, source) = make([record(1), record(2)])
        let turn = TranscriptTurn(question: "q", block: BuddyBlock(say: "a", shape: .chip), mode: .quick, model: .haiku)
        await source.set(turns: [turn], for: "c1")
        await model.reload()
        model.selection = "c1"
        var preferences = ConversationsPreferences()
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 800, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ConversationsWindow(
            model: model, preferences: Binding(get: { preferences }, set: { preferences = $0 })))
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var sawLoadingAfterTurns = false
        func pump() async throws {
            for _ in 0..<15 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
                if model.shownTurns == nil, await source.turnsReads > 0 { sawLoadingAfterTurns = true }
            }
        }
        try await pump()
        for _ in 0..<2 {  // another window became key: the list reloads, the detail stays
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await pump()
        }
        // The split view used to make each Loading/transcript swap a new pane whose task read again.
        #expect(await source.turnsReads == 1)
        #expect(model.shownTurns == [turn])
        #expect(!sawLoadingAfterTurns)
    }

    @Test("a turn added to the shown conversation appears in the open window, without Loading")
    func detailFollowsNewTurns() async throws {
        let (model, source) = make([record(1), record(2)])
        let first = TranscriptTurn(question: "q1", block: BuddyBlock(say: "a1", shape: .chip), mode: .quick, model: .haiku)
        let second = TranscriptTurn(question: "q2", block: BuddyBlock(say: "a2", shape: .chip), mode: .quick, model: .haiku)
        await source.set(turns: [first], for: "c1")
        await model.reload()
        model.selection = "c1"
        var preferences = ConversationsPreferences()
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 800, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ConversationsWindow(
            model: model, preferences: Binding(get: { preferences }, set: { preferences = $0 })))
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var sawLoading = false
        func pump() async throws {
            for _ in 0..<15 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
                if model.shownTurns == nil, await source.turnsReads > 0 { sawLoading = true }
            }
        }
        try await pump()
        #expect(model.shownTurns == [first])
        // Continued in the overlay while this window stays key: no window-key reload comes.
        await source.add(second, to: "c1")
        NotificationCenter.default.post(name: ConversationHistoryModel.turnsChanged, object: nil)
        try await pump()
        #expect(model.shownTurns == [first, second])
        #expect(!sawLoading)
        // A reload with nothing new doesn't read the turns again.
        let reads = await source.turnsReads
        await model.reload()
        #expect(await source.turnsReads == reads)
    }

    @Test("the dialog's Forget still forgets after the dismissal cleared the pending request")
    func forgetAfterDismissal() async {
        let (model, _) = make([record(1, title: "Dinner")])
        await model.reload()
        await model.askToForget(model.records[0])
        let shown = try! #require(model.pendingForget)
        model.cancelForget()  // what closing the dialog does, before the button's Task runs
        await model.confirmForget(shown)
        #expect(model.records.isEmpty)
        #expect(model.notice?.hasPrefix("Forgot “Dinner”") == true)
    }

    @Test("Forget reports what it couldn't remove, not just that it ran")
    func forgetReportsLeftovers() async {
        let (model, source) = make([record(1, title: "Dinner")])
        await source.set(report: ForgetReport(screenshotsDeleted: ["a"], screenshotsMissing: [], screenshotsSkipped: ["b"],
                                              sessions: SessionDeletion(deleted: ["s1"], skipped: ["s2"])))
        await model.reload()
        await model.askToForget(model.records[0])
        await model.confirmForget()
        #expect(model.notice == "Forgot “Dinner”, but 2 files couldn't be removed.")
    }

    @Test("the confirmation never mentions Claude Code's plumbing")
    func forgetWording() {
        let message = ConversationHistoryModel.forgetMessage(ForgetRequest(id: "c", title: "t", sessionCount: 2, screenshotCount: 1))
        #expect(message == "This deletes its entry in the history, 1 screenshot and its saved conversation. It can't be undone.")
        #expect(!message.contains("Claude Code") && !message.contains("session"))
    }

    @Test("the confirmation lists the research reports it deletes")
    func forgetWordingReports() {
        func message(sessions: Int, shots: Int, reports: Int) -> String {
            var r = ForgetRequest(id: "c", title: "t", sessionCount: sessions, screenshotCount: shots)
            r.reportCount = reports
            return ConversationHistoryModel.forgetMessage(r)
        }
        #expect(message(sessions: 1, shots: 2, reports: 1)
                == "This deletes its entry in the history, 2 screenshots, its saved conversation and its research reports. It can't be undone.")
        #expect(message(sessions: 0, shots: 0, reports: 3) == "This deletes its entry in the history and its research reports. It can't be undone.")
        #expect(message(sessions: 0, shots: 0, reports: 0) == "This deletes its entry in the history. It can't be undone.")
    }

    @Test("a retention change prunes, then reloads, so removed rows disappear")
    func retentionReloads() async {
        let (model, source) = make([record(1, title: "Old one"), record(2, title: "Recent")])
        await model.reload()
        #expect(model.records.count == 2)
        model.requestRetention(30)
        model.requestRetention(7)          // a newer change replaces the older one
        await model.retentionSettled()
        #expect(await source.prunes.last == 7)
        #expect(model.records.map(\.title) == ["Recent"])
    }

    @Test("Forget asks first, and Cancel deletes nothing")
    func forgetCancel() async {
        let (model, source) = make([record(1, title: "Dinner", quick: "q-1", deep: "d-1")])
        await model.reload()
        await model.askToForget(model.records[0])
        #expect(model.pendingForget == ForgetRequest(id: "c1", title: "Dinner", sessionCount: 2, screenshotCount: 2))
        model.cancelForget()
        #expect(model.pendingForget == nil)
        #expect(await source.forgotten.isEmpty)
        #expect(model.records.count == 1)
    }

    @Test("confirming forgets, removes the row and says so")
    func forgetConfirm() async {
        let (model, source) = make([record(1, title: "Dinner"), record(2)])
        await model.reload()
        model.selection = "c1"
        await model.askToForget(model.records[0])
        await model.confirmForget()
        #expect(await source.forgotten == ["c1"])
        #expect(model.records.map(\.id) == ["c2"])
        #expect(model.selection == nil)
        #expect(model.pendingForget == nil)
        #expect(model.notice == "Forgot “Dinner”.")
    }

    @Test("confirm without a question does nothing")
    func confirmWithoutAsk() async {
        let (model, source) = make([record(1)])
        await model.reload()
        await model.confirmForget()
        #expect(await source.forgotten.isEmpty)
    }

    @Test("if it changed meanwhile, ask again with fresh numbers")
    func forgetStale() async {
        let (model, source) = make([record(1, title: "Dinner")])
        await model.reload()
        await model.askToForget(model.records[0])
        await source.set(staleForgets: 1)
        await model.confirmForget()
        #expect(await source.forgotten.isEmpty)
        #expect(await source.prepared == ["c1", "c1"])
        #expect(model.pendingForget?.id == "c1")
        #expect(model.records.count == 1)
        await model.confirmForget()
        #expect(await source.forgotten == ["c1"])
    }

    @Test("forgetting one that's already gone reloads")
    func forgetGone() async {
        let (model, source) = make([record(1), record(2)])
        await model.reload()
        let gone = record(9)
        await model.askToForget(gone)
        #expect(model.pendingForget == nil)
        #expect(await source.listCalls.count == 2)
    }

    @Test("Forget failures say which one")
    func forgetFailures() async {
        let (model, source) = make([record(1, title: "Dinner")])
        await model.reload()
        await model.askToForget(model.records[0])
        await source.set(failing: true)
        await model.confirmForget()
        #expect(model.problem == "Couldn't forget “Dinner”.")
        await model.askToForget(model.records[0])
        #expect(model.problem == "Couldn't prepare to forget “Dinner”.")
    }

    @Test("paging after a Forget doesn't skip the row that moved up")
    func pagingAfterForget() async {
        let (model, source) = make((1...120).map { record($0) })
        await model.reload()
        await model.askToForget(model.records[3])
        await model.confirmForget()
        #expect(model.records.count == 49)
        await model.loadMore()
        #expect(await source.listCalls.last?.offset == 49)
        // c51 used to be row 51; after the forget it's row 50 and must still appear.
        #expect(model.records.map(\.id).contains("c51"))
        #expect(Set(model.records.map(\.id)).count == model.records.count)
    }

    @Test("a page in flight isn't added to search results")
    func loadMoreRacesSearch() async {
        let (model, source) = make((1...120).map { record($0, title: $0 == 7 ? "Dinner" : nil) })
        await model.reload()
        await source.set(duringList: { @MainActor in
            model.query = "dinner"
            await model.searchSettled()
        })
        await model.loadMore()
        #expect(model.records.map(\.id) == ["c7"])
    }

    @Test("re-asking works for a row beyond the first page")
    func forgetStaleDeep() async {
        let (model, source) = make((1...80).map { record($0) })
        await model.reload()
        await model.loadMore()
        let deep = model.records[70]
        await model.askToForget(deep)
        await source.set(staleForgets: 1)
        await model.confirmForget()
        #expect(model.pendingForget?.id == deep.id)
    }

    @Test("a whitespace query still pages the history")
    func whitespacePaging() async {
        let (model, source) = make((1...60).map { record($0) })
        model.query = "  "
        await model.searchSettled()
        #expect(model.canLoadMore)
        await model.loadMore()
        #expect(model.records.count == 60)
        #expect(await source.searches.isEmpty)
    }

    @Test("the temporary banner follows the manager, and the toggle applies it")
    func temporary() async {
        let (model, source) = make([record(1)])
        await model.reload()
        #expect(!model.isTemporary)
        await model.setTemporary(true)
        #expect(model.isTemporary)
        #expect(await source.isTemporary())
        await source.set(temporaryFails: true)
        await model.setTemporary(false)
        #expect(model.problem == "Couldn't turn off temporary mode.")
        #expect(model.isTemporary)  // still on: the banner stays truthful
    }

    @Test("flipping temporary mode quickly ends on the latest value")
    func temporaryLatestWins() async {
        let (model, source) = make([record(1)])
        model.requestTemporary(true)
        model.requestTemporary(false)
        model.requestTemporary(true)
        model.requestTemporary(false)
        await model.temporarySettled()
        #expect(await source.isTemporary() == false)
        #expect(!model.isTemporary)
        model.requestTemporary(true)
        await model.temporarySettled()
        #expect(model.isTemporary)
    }

    @Test("status lines clear on the next action")
    func statusClears() async {
        let (model, source) = make([record(1), record(2)])
        await model.reload()
        await model.askToForget(model.records[0])
        await model.confirmForget()
        #expect(model.notice != nil)
        await model.askToForget(model.records[0])
        #expect(model.notice == nil)
        _ = source
    }

    @Test("the confirmation lists exactly what is deleted")
    func forgetMessage() {
        func message(_ sessions: Int, _ shots: Int) -> String {
            ConversationHistoryModel.forgetMessage(ForgetRequest(id: "c", title: "t", sessionCount: sessions, screenshotCount: shots))
        }
        #expect(message(0, 0) == "This deletes its entry in the history. It can't be undone.")
        #expect(message(1, 1) == "This deletes its entry in the history, 1 screenshot and its saved conversation. It can't be undone.")
        #expect(message(3, 0) == "This deletes its entry in the history and its saved conversation. It can't be undone.")
        #expect(message(0, 2) == "This deletes its entry in the history and 2 screenshots. It can't be undone.")
    }
}

@Suite("Conversations window")
@MainActor
struct ConversationsWindowTests {
    @Test("rows show when, turns, folder and lane")
    func rowDetail() {
        let detail = ConversationRow.detail(record(1, lane: .deep, folder: "/Users/me/web", turns: 3))
        #expect(detail.hasSuffix(" · 3 turns · web · Deep"))
        #expect(ConversationRow.detail(record(1, turns: 1)).hasSuffix(" · 1 turn"))
        #expect(!ConversationRow.detail(record(1, folder: "")).contains("· ·"))
    }

    @Test("each conversation colour is distinct, in light and dark, and has a spoken name")
    func colours() {
        for dark in [false, true] {
            let resolved = ConversationColor.allCases.map { ConversationDotColor.components($0, dark: dark) }
            #expect(Set(resolved).count == ConversationColor.allCases.count)
        }
        // Ember is #D9622F in light, #FF8A5B in dark.
        let ember = ConversationDotColor.components(.ember, dark: false)
        #expect(abs(ember[0] - 0xD9 / 255.0) < 0.01 && abs(ember[1] - 0x62 / 255.0) < 0.01)
        #expect(abs(ConversationDotColor.components(.ember, dark: true)[0] - 1.0) < 0.01)
        #expect(Set(ConversationColor.allCases.map(ConversationDotColor.name)).count == ConversationColor.allCases.count)
    }

    @Test("Settings opens the shell's Conversations window")
    func windowID() {
        #expect(ConversationHistoryView.windowID == "conversations")
        #expect(ConversationHistoryView.recentCount == 5)
    }

    @Test("the window builds with and without a manager")
    func builds() {
        var prefs = ConversationsPreferences()
        let binding = Binding(get: { prefs }, set: { prefs = $0 })
        _ = ConversationsWindow(manager: nil, preferences: binding).body
        let model = ConversationHistoryModel(source: FakeHistorySource([record(1)]))
        _ = ConversationsWindow(model: model, preferences: binding).body
    }
}
