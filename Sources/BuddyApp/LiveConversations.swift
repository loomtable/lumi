import BuddyBridge
import BuddyCompanion
import BuddyConversations
import BuddyCore
import Foundation

/// The coordinator's conversations over BuddyConversations' index: continue by
/// default, fresh after the idle limit or for another project, ⌘N, and every turn saved with its
/// Claude Code session ids so a conversation resumes after relaunch and Forget can delete them.
///
/// The index keeps no transcripts, so the last three Q/A texts live in memory; the cascade
/// sends a lane only the ones its session hasn't seen. A turn is saved once both halves have arrived, in either order: its session ids
/// (`update`, from `.done`) and its question (`recordTurn`, when the answer is shown). A turn whose
/// answer wasn't shown by the next `prepare` or `startNew` is saved then, so its session ids are
/// never lost; if its question still arrives later, the "Untitled" row takes it as its title.
///
/// Port contract: calls take effect in the order they are made, even though they suspend (a
/// question asked right after ⌘N lands in the new conversation; a late `update` can't overtake a
/// newer call), and `current` reflects each call's change by the time it returns. Resume and
/// temporary mode go through the same queue, so nothing slips into the wrong index.
@MainActor
public final class LiveConversations: ConversationPort {
    public private(set) var current: ConversationTurn?

    public let manager: ConversationManager
    /// Told whether the last save failed (true) or worked (false), so the problem line is true.
    private var onSaveProblem: @MainActor (Bool) -> Void
    private var previous: [String: [String]] = [:]
    /// Session ids from `.done` not saved yet, and shown questions waiting for their ids.
    private var unsaved: [String: ConversationState] = [:]
    private var questions: [String: String] = [:]
    /// Saved before their question arrived: titled "Untitled" until it does.
    private var untitled: Set<String> = []
    /// Every conversation id handed out since the last switch of index.
    private var known: Set<String> = []
    /// Conversations from the other index (before a temporary-mode switch): late calls for
    /// them are ignored, so nothing is written to the wrong index.
    private var retired: Set<String> = []
    /// Each conversation's shown turns, oldest first, for full screen: recorded as they're shown,
    /// and read back from Claude Code's session files the first time a saved conversation returns.
    private var turns: [String: [TranscriptTurn]] = [:]
    private let reader: TranscriptReader?
    private var loading: Set<String> = []
    /// Forgotten this run: a detail read that was under way when Forget ran returns nothing.
    private var forgotten: Set<String> = []
    /// Bumped on every temporary-mode switch, so a slow read can't land in the other index.
    private var indexGeneration = 0
    /// The last call queued; each call waits for it before running.
    private var tail: Task<Void, Never>?

    public static let saveFailed = "Conversation history couldn't be saved."

    /// `reader`: where earlier turns come from after a relaunch (nil: in-session turns only).
    public init(manager: ConversationManager, reader: TranscriptReader? = TranscriptReader(),
                onSaveProblem: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.manager = manager
        self.reader = reader
        self.onSaveProblem = onSaveProblem
    }

    /// Where save failures and recoveries are reported (AppRuntime's problems).
    public func setSaveProblemHandler(_ handler: @escaping @MainActor (Bool) -> Void) {
        onSaveProblem = handler
    }

    // MARK: ConversationPort

    public func prepare(project: String?) async -> ConversationTurn {
        await serial { await self.performPrepare(project: project) }
    }

    public func update(_ state: ConversationState) async {
        await serial { await self.performUpdate(state) }
        turnsChanged()
    }

    public func recordTurn(conversationID id: String, question: String, answer: String) async -> ConversationTurn? {
        defer { turnsChanged() }
        return await serial { await self.performRecordTurn(conversationID: id, question: question, answer: answer) }
    }

    /// A shown answer with what full screen needs: also appended to the conversation's turns.
    public func record(_ turn: TranscriptTurn, conversationID id: String) async -> ConversationTurn? {
        defer { turnsChanged() }
        return await serial {
            let result = await self.performRecordTurn(conversationID: id, question: turn.question, answer: turn.block.say)
            guard !self.retired.contains(id) else { return result }
            self.turns[id, default: []].append(turn)
            guard var updated = result else { return nil }
            updated.turns = self.turns[id] ?? []
            self.current = updated
            return updated
        }
    }

    @discardableResult
    public func startNew() async -> ConversationTurn {
        await serial { await self.performStartNew() }
    }

    public func goBack() async -> ConversationTurn? {
        await serial { await self.performGoBack() }
    }

    public func switchTo(_ id: String) async -> ConversationTurn? {
        await serial { (try? await self.performResume(id).get()) == nil ? nil : self.current }
    }

    /// The summon screenshot a turn of `id` was asked with, so Forget deletes it. Kept by the
    /// manager until the conversation's first turn is saved; one that arrives after Forget is
    /// deleted at once. A conversation from the other index (before a temporary-mode switch)
    /// isn't linked: its screenshot goes with the 24 h sweep.
    public func recordScreenshot(_ path: String, conversationID id: String) async {
        await serial {
            guard !self.retired.contains(id) else { return }
            try? await self.manager.recordScreenshot(path, conversation: id)
        }
    }

    /// A Research job of a conversation, so Forget, retention and leaving temporary mode delete
    /// its report and session. Passed on even for a conversation from the other index: the
    /// manager keeps it with its saved row, or deletes it if that conversation is gone.
    public func recordResearchJob(_ job: ResearchJob) async {
        await serial {
            try? await self.manager.recordResearchJob(
                ResearchJobRecord(sessionID: job.sessionID, reportPath: job.reportPath.path), conversation: job.conversationID)
        }
    }

    // MARK: The shell's calls

    /// "Resume" from the Conversations window: that conversation is current from the next question.
    /// Nil: it's gone. Throws when the index couldn't be read, so the window can say so.
    @discardableResult
    public func resume(_ id: String) async throws -> ConversationRecord? {
        try await serial { await self.performResume(id) }.get()
    }

    /// The conversation the next question continues, for the window's "current" mark.
    public func currentID() async -> String? {
        await serial { self.current?.state.id }
    }

    /// The Conversations window's detail: a conversation's shown turns, oldest first. This run's
    /// turns when it has them all, else Claude Code's session files read off the main actor, ahead
    /// of any recorded meanwhile. Temporary mode: memory only. Empty for an unknown id.
    public func transcript(_ id: String) async -> [TranscriptTurn] {
        let generation = indexGeneration
        let recent = retired.contains(id) ? [] : turns[id] ?? []
        // Recorded this run, or already merged with what the session files had.
        if !recent.isEmpty, !loading.contains(id) { return recent }
        guard let reader, !(await manager.isTemporary), let record = try? await manager.record(id: id) else { return recent }
        let earlier = await Task.detached(priority: .userInitiated) { reader.turns(for: record) }.value
        // A temporary-mode switch or Forget since then: those turns aren't this index's any more.
        guard generation == indexGeneration, !forgotten.contains(id), !retired.contains(id) else { return [] }
        // Turns recorded (or merged in) while the files were read.
        let latest = turns[id] ?? []
        return earlier.filter { old in !latest.contains { $0.question == old.question && $0.block == old.block } } + latest
    }

    /// "Forget this" from the Conversations window. Nil, and nothing deleted, when it changed
    /// since `request` was shown. A forgotten conversation leaves memory too: if it was current,
    /// the next question starts fresh instead of resuming its deleted session.
    public func forget(_ request: ForgetRequest) async throws -> ForgetReport? {
        try await serial { () async -> Result<ForgetReport?, IndexError> in
            let result: Result<ForgetReport?, IndexError>
            do throws(IndexError) { result = .success(try await self.manager.forget(request)) } catch { result = .failure(error) }
            if case .success(.some) = result { self.drop(request.id) }
            return result
        }.get()
    }

    /// Settings › Conversations › Temporary, from Settings or the Conversations window. Turns
    /// waiting to be saved are saved first when going temporary, and dropped when leaving it.
    public func setTemporary(_ on: Bool) async throws {
        let result: Result<Void, IndexError> = await serial { await self.performSetTemporary(on) }
        try result.get()
    }

    /// Runs `body` after every call made before it has finished.
    private func serial<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Bodies (run one at a time)

    private func performPrepare(project: String?) async -> ConversationTurn {
        await saveStale()
        do {
            let prepared = try await manager.prepare(projectFolder: project)
            await loadTurns(prepared.record)
            return adopt(prepared, notice: await notice(for: prepared.chips))
        } catch {
            return failedOver(fresh: false)
        }
    }

    private func performUpdate(_ state: ConversationState) async {
        guard !retired.contains(state.id) else { return }
        unsaved[state.id] = state
        if current?.state.id == state.id { current?.state = state }
        if let question = questions.removeValue(forKey: state.id) { await save(state.id, question: question) }
    }

    private func performRecordTurn(conversationID id: String, question: String, answer: String) async -> ConversationTurn? {
        guard !retired.contains(id) else { return nil }
        previous[id] = Array(((previous[id] ?? [])
            + [ContextPacket.Conversation.recapEntry(question: question, answer: answer)]).suffix(ContextPacket.Conversation.maxPrevious))
        if unsaved[id] != nil {
            await save(id, question: question)
        } else if untitled.remove(id) != nil {
            // Saved by `saveStale` before its question came: it gets its real title now.
            try? await manager.retitle(id, from: question)
        } else {
            questions[id] = question
        }
        guard var turn = current, turn.state.id == id else { return nil }
        turn.turn += 1
        turn.previous = previous[id] ?? []
        current = turn
        return turn
    }

    private func performStartNew() async -> ConversationTurn {
        await saveStale()
        do {
            let prepared = try await manager.newConversation()
            return adopt(prepared, notice: await notice(for: prepared.chips))
        } catch {
            return failedOver(fresh: true)
        }
    }

    private func performResume(_ id: String) async -> Result<ConversationRecord?, IndexError> {
        await saveStale()
        do throws(IndexError) {
            guard let record = try await manager.switchTo(id) else { return .success(nil) }
            await become(record)
            return .success(record)
        } catch {
            return .failure(error)
        }
    }

    /// A forgotten conversation leaves memory: its recap and turns, and `current` if it was. Its
    /// unsaved session ids stay, and late updates still reach `manager.finish`, which deletes the
    /// session files a question still running in it creates (and saves nothing).
    private func drop(_ id: String) {
        forgotten.insert(id)
        untitled.remove(id)
        previous[id] = nil
        turns[id] = nil
        loading.remove(id)
        if current?.state.id == id { current = nil }
    }

    private func performGoBack() async -> ConversationTurn? {
        await saveStale()
        guard let record = try? await manager.goBack() else { return nil }
        await become(record)
        return current
    }

    /// `record` is current from the next question, with its stored sessions.
    private func become(_ record: ConversationRecord) async {
        await loadTurns(record)
        var state = ConversationState(id: record.id)
        state.quickSessionID = record.quickSessionID
        state.deepSessionID = record.deepSessionID
        state.lastLane = record.lastLane
        state.deepFolder = record.projectFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        retired.remove(record.id)
        known.insert(record.id)
        current = ConversationTurn(state: state, color: record.color, turn: record.turns, previous: previous[record.id] ?? [],
                                   turns: turns[record.id] ?? [])
    }

    private func performSetTemporary(_ on: Bool) async -> Result<Void, IndexError> {
        guard on != (await manager.isTemporary) else { return .success(()) }
        if on {
            // Leaving the saved index: its waiting turns are saved there first.
            await saveStale()
        } else {
            // Leaving temporary mode: nothing from it may reach disk.
            unsaved = [:]
        }
        retired.formUnion(known)
        retired.formUnion(questions.keys)
        known = []
        questions = [:]
        untitled = []
        previous = [:]
        turns = [:]
        loading = []
        indexGeneration += 1
        current = nil
        do {
            try await manager.setTemporary(on)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: Helpers

    /// Tells an open Conversations window to re-read, so its detail shows the new turn.
    private func turnsChanged() {
        NotificationCenter.default.post(name: ConversationHistoryModel.turnsChanged, object: nil)
    }

    private func adopt(_ prepared: PreparedConversation, notice: ConversationNotice? = nil) -> ConversationTurn {
        // Within a session the cached state is newer than the index (Go deeper's last answer).
        let state = current?.state.id == prepared.id ? current!.state : prepared.bridgeState
        let turn = ConversationTurn(state: state, color: prepared.color, turn: prepared.record?.turns ?? current?.turn ?? 0,
                                    previous: previous[prepared.id] ?? [], turns: turns[prepared.id] ?? [], notice: notice)
        // The current index handed it out, so it belongs to this index again.
        retired.remove(prepared.id)
        known.insert(prepared.id)
        current = turn
        return turn
    }

    /// The Back or Resume chip for a fresh start, when the conversation left behind was saved
    /// (one that never finished a turn has no row to go back to). "Keep in the old one" isn't
    /// offered yet.
    private func notice(for chips: [ConversationChip]) async -> ConversationNotice? {
        for chip in chips {
            switch chip {
            case .back(let id, _):
                if let record = try? await manager.record(id: id) { return .back(title: record.title) }
            case .resume(let id):
                if let record = try? await manager.record(id: id) {
                    return .resume(id: id, title: record.title, lastUsed: record.lastUsed)
                }
            case .keepInOld:
                break
            }
        }
        return nil
    }

    /// A saved conversation returning for the first time this session (continued after relaunch,
    /// or resumed): its earlier turns come from Claude Code's session files, read off the main actor.
    /// Never waited on: the question goes at once; the earlier turns join when they're read,
    /// ahead of any recorded meanwhile.
    private func loadTurns(_ record: ConversationRecord?) async {
        guard let record, turns[record.id] == nil, !loading.contains(record.id), let reader else { return }
        loading.insert(record.id)
        let generation = indexGeneration
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { reader.turns(for: record) }.value
            self?.loaded(loaded, for: record.id, generation: generation)
        }
    }

    private func loaded(_ earlier: [TranscriptTurn], for id: String, generation: Int) {
        loading.remove(id)
        // A temporary-mode switch since then: those turns belong to the other index.
        guard generation == indexGeneration, !retired.contains(id) else { return }
        let recent = turns[id] ?? []
        let merged = earlier.filter { old in !recent.contains { $0.question == old.question && $0.block == old.block } } + recent
        turns[id] = merged
        if current?.state.id == id { current?.turns = merged }
    }

    /// The index can't be read: the question still goes, in a conversation kept in memory. After
    /// a failed ⌘N it is a new one, so the card never shows the old conversation as the new one.
    private func failedOver(fresh: Bool) -> ConversationTurn {
        onSaveProblem(true)
        if !fresh, let current { return current }
        let turn = ConversationTurn(state: ConversationState(id: "c_" + UUID().uuidString.lowercased()),
                                    color: current?.color ?? .ember, turn: 0, previous: [])
        current = turn
        return turn
    }

    private func save(_ id: String, question: String) async {
        guard let state = unsaved.removeValue(forKey: id) else { return }
        do {
            _ = try await manager.finish(id: id, update: TurnUpdate(state), utterance: question)
            if question.isEmpty { untitled.insert(id) }
            onSaveProblem(false)
        } catch {
            onSaveProblem(true)
        }
    }

    /// Turns whose answer wasn't shown yet: saved with what is known.
    private func saveStale() async {
        for id in Array(unsaved.keys) { await save(id, question: questions.removeValue(forKey: id) ?? "") }
    }
}

/// The Conversations window's source: reads straight from the index, while Resume, Forget and
/// temporary mode go through `LiveConversations`, so they keep the port's call order.
public struct LiveHistorySource: ConversationHistorySource {
    private let manager: ConversationManager
    private let conversations: LiveConversations

    public init(conversations: LiveConversations) {
        self.manager = conversations.manager
        self.conversations = conversations
    }

    public func list(limit: Int, offset: Int) async throws -> [ConversationRecord] {
        try await manager.list(limit: limit, offset: offset)
    }

    public func search(_ query: String) async throws -> [ConversationRecord] { try await manager.search(query) }
    public func resume(_ id: String) async throws -> ConversationRecord? { try await conversations.resume(id) }
    public func currentID() async -> String? { await conversations.currentID() }
    /// The window's prune on a "Keep for" change, before it reloads: the same rule as AppRuntime's
    /// (idempotent with it; never the current conversation or the ↩ Back target).
    public func prune(retentionDays days: Int) async throws {
        try await manager.prune(unusedSince: Date().addingTimeInterval(-TimeInterval(days) * 86_400))
    }
    public func prepareForget(_ id: String) async throws -> ForgetRequest? { try await manager.prepareForget(id) }
    public func forget(_ request: ForgetRequest) async throws -> ForgetReport? { try await conversations.forget(request) }
    public func turns(_ id: String) async -> [TranscriptTurn] { await conversations.transcript(id) }
    public func isTemporary() async -> Bool { await manager.isTemporary }
    public func setTemporary(_ on: Bool) async throws { try await conversations.setTemporary(on) }
}
