import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation

/// Where one user turn goes, decided before anything is sent: the Lumi session, its harness and,
/// for an open session, how to launch or resume its `claude` process.
public struct SessionTurnPlan: Sendable, Equatable {
    public var id: SessionID
    public var harness: Harness
    public var kind: TurnKind
    /// Nil for a Quick turn (the cascade runs it).
    public var launch: SessionLaunch?
    /// A Quick or v1 session continued as an open one: its recap, for the first message.
    public var seed: String?
    /// An untrusted project in front: "Add <repo> to this session?".
    public var offerDirectory: String?
}

/// The v2 sessions over the SessionStore: the read model every surface uses (`SessionsPort`), the
/// live status folded from each session's events, and the turn planner the router runs. A session
/// is a row of the conversation index, so v1 conversations list, open and Continue as sessions.
///
/// Calls that write go through one queue, in the order they're made.
@MainActor
public final class LiveSessions: SessionsPort {
    public private(set) var current: SessionID?
    public private(set) var snapshots: [SessionSnapshot] = []
    /// When the Panel last showed each session, at show and at hide (router rule 3).
    public private(set) var panelShownAt: [SessionID: Date] = [:]
    /// The Lumi pages showing each session (`pageShown` / `pageHidden`).
    private var pages: [SessionID: Set<PageKind>] = [:]
    /// Sessions a page or the Glance shows: a finished turn there is already seen, and the pool
    /// never suspends them.
    public var onScreen: Set<SessionID> { Set(pages.keys).union(glanceSession.map { [$0] } ?? []) }
    /// The session whose voice turn the Glance shows now (its pill, approval card or answer). A turn
    /// moved to the background (V-02) isn't shown, so its answer lands unread.
    public var glanceSession: SessionID? {
        didSet {
            guard glanceSession != oldValue else { return }
            if let glanceSession { markSeen(glanceSession) }
            publish()
        }
    }
    /// Settings › Teammates.
    public var maxSubagents = 3
    /// A typed ask runs in an open session only with a page to render its Markdown in
    /// (`LumiFeatures.panel`). Off, typed asks stay on the v1 path (Quick, then Deep), whose answers
    /// the Glance shows (QA R4).
    public var typedOpensSessions = false
    /// Names a session after its first answer when the answer carried no topic (typed turns never
    /// do). Nil: the provisional title from the question stays.
    public var titler: (any SessionTitler)?
    /// Sessions titled (or tried) this run: one call each at most.
    private var titling: Set<SessionID> = []
    public var policy: RoutingPolicy
    /// A session was forgotten or archived: whatever still waits to show it goes (QA gate 4.6).
    public var onGone: (@MainActor (SessionID) -> Void)?

    private var store: SessionStore
    private let manager: ConversationManager
    private let clock: @MainActor () -> Date
    private let trust: @Sendable () -> FolderTrust
    private let home: URL
    private let reader: TranscriptReader?
    private var records: [SessionID: SessionRecord] = [:]
    private var order: [SessionID] = []
    private var activity: [SessionID: SessionActivity] = [:]
    /// The user's words of each session's latest turn, for its recap entry.
    private var lastShown: [SessionID: String] = [:]
    /// Sessions whose running turn the CLI started itself (`turnStarted` without a user uuid).
    private var autoTurn: Set<SessionID> = []
    /// Open Claude sessions minted but not yet acknowledged by Claude Code (no `system/init` or
    /// replayed user turn yet). Recorded, and the harness flipped, only once acknowledged: until
    /// then every plan launches the same id as new, with the same seed (QA R7).
    private var pendingOpen: [SessionID: PendingOpen] = [:]

    struct PendingOpen {
        var claudeSession: UUID
        var cwd: URL
        var seed: String?
    }
    private var subscribers: [UUID: AsyncStream<[SessionSnapshot]>.Continuation] = [:]
    private var tail: Task<Void, Never>?

    public static let listLimit = 50

    public init(store: SessionStore, manager: ConversationManager, policy: RoutingPolicy = RoutingPolicy(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                trust: @escaping @Sendable () -> FolderTrust, reader: TranscriptReader? = TranscriptReader(),
                clock: @escaping @MainActor () -> Date = Date.init) {
        self.store = store
        self.reader = reader
        self.manager = manager
        self.policy = policy
        self.home = home
        self.trust = trust
        self.clock = clock
    }

    /// Temporary mode swapped the index: sessions from now on live in the new one.
    public func setStore(_ store: SessionStore) async {
        await serial {
            self.store = store
            self.records = [:]
            self.order = []
            self.activity = [:]
            self.pendingOpen = [:]
            self.current = nil
        }
        await reload()
    }

    /// Reads the most recent sessions; a stored status shows until live events replace it.
    public func reload() async {
        await serial {
            guard let recent = try? await self.store.recent(limit: Self.listLimit, includeArchived: true) else { return }
            self.records = Dictionary(recent.map { (SessionID(rawValue: $0.id), $0) }, uniquingKeysWith: { a, _ in a })
            self.order = recent.map { SessionID(rawValue: $0.id) }
            for record in recent where self.activity[SessionID(rawValue: record.id)] == nil {
                var state = SessionActivity(status: SessionStatus(persisted: record.status, finishedAt: record.finishedAt))
                // The last answer's preview, so a relaunched peek still has a line to show: an open
                // turn's, else a Quick turn's from the recap (Quick turns have no user-turn row).
                let preview = (try? await self.store.userTurns(of: SessionID(rawValue: record.id)))?.last { $0.answerPreview != nil }?.answerPreview
                    ?? record.recap.last.flatMap(ContextPacket.Conversation.recapAnswer)
                state.lastSay = preview.flatMap { SessionSnapshot.lastSay(say: nil, markdown: $0) }
                self.activity[SessionID(rawValue: record.id)] = state
            }
        }
        publish()
    }

    // MARK: SessionsPort

    public func changes() -> AsyncStream<[SessionSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SessionSnapshot].self)
        let key = UUID()
        continuation.yield(snapshots)
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[key] = nil } }
        return stream
    }

    public func setCurrent(_ id: SessionID) async {
        current = id
        markSeen(id)
        publish()
    }

    public func setPinned(_ pinned: Bool, for id: SessionID) async {
        await write(id) { try await $0.setPinned(pinned, for: id) }
    }

    /// Archiving the current session leaves no current one: the next summon doesn't continue a
    /// session the strip no longer shows (QA R12).
    public func setArchived(_ archived: Bool, for id: SessionID) async {
        if archived, current == id { current = nil }
        await write(id) { try await $0.setArchived(archived, for: id) }
        if archived { onGone?(id) }
    }

    public func rename(_ id: SessionID, to title: String) async {
        await write(id) { try await $0.rename(id, to: title) }
    }

    /// Deletes the row (cascading its Claude sessions, directories and user turns), its screenshots
    /// and every Claude session's files.
    public func forget(_ id: SessionID) async throws {
        let manager = manager
        let result: Result<Void, IndexError> = await serial {
            do throws(IndexError) {
                if let request = try await manager.prepareForget(id.rawValue) { _ = try await manager.forget(request) }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
        // A minted session that may have reached Claude Code without being acknowledged.
        if let pending = pendingOpen.removeValue(forKey: id) {
            _ = await store.deleteSessionFiles([pending.claudeSession.uuidString.lowercased()])
        }
        records[id] = nil
        activity[id] = nil
        lastShown[id] = nil
        order.removeAll { $0 == id }
        if current == id { current = nil }
        publish()
        onGone?(id)
    }

    public func apply(_ event: SessionEvent, to id: SessionID) {
        if case .turnStarted(let userUUID, _) = event {
            if userUUID == nil { autoTurn.insert(id) } else { autoTurn.remove(id) }
        }
        switch event {
        case .initialized, .turnStarted(userUUID: .some, kind: _): acknowledgeOpen(id)
        case .turnEnded(let end) where end.error?.reason == .unavailable(Self.sessionNotFound): claudeSessionLost(id)
        default: break
        }
        var state = activity[id] ?? SessionActivity()
        let effects = state.apply(event, at: clock(), onScreen: onScreen.contains(id))
        activity[id] = state
        publish()
        guard !effects.isEmpty else { return }
        // A turn the CLI starts itself (a background agent's report, no user line) gets no recap
        // entry: it would repeat the user's last question (QA R17).
        let auto = autoTurn.contains(id)
        persist(effects, for: id, shown: auto ? nil : lastShown[id], at: clock(), userTurn: !auto)
    }

    /// A Quick (cascade) turn's answer. It goes through the same reducer and effects as an open
    /// session's turn end, so both paths finish a turn in one place: last line, status, preview,
    /// topic and title. The cascade's own port already saved the turn (its count, recap and time),
    /// so that write isn't repeated, and no open Claude session received the voice rules.
    public func finishCascadeTurn(_ id: SessionID, kind: TurnKind, question: String, block: BuddyBlock) {
        lastShown[id] = question
        autoTurn.remove(id)
        var state = activity[id] ?? SessionActivity()
        let effects = state.apply(.turnEnded(TurnEnd(kind: kind, markdown: block.say, block: block)), at: clock(),
                                  onScreen: onScreen.contains(id))
        activity[id] = state
        publish()
        persist(effects, for: id, shown: question, at: clock(), cascade: true)
    }

    /// The session was seen (its page opened, its tile picked, its ask on the Glance): its answer
    /// is read and its ask acknowledged.
    public func markSeen(_ id: SessionID) {
        guard var state = activity[id] else { return }
        let effects = state.markSeen()
        guard state != activity[id] else { return }
        activity[id] = state
        publish()
        guard !effects.isEmpty else { return }
        persist(effects, for: id, shown: nil, at: clock())
    }

    // MARK: Questions in flight

    /// A question was sent in `id` (`ProgressBoard`): the session runs from now, so every surface
    /// shows it running before its turn starts, and for a Quick turn that never starts one.
    public func queryBegan(_ id: SessionID, line: String?) {
        var state = activity[id] ?? SessionActivity()
        state.queryBegan(line: line, at: clock())
        activity[id] = state
        publish()
    }

    /// A Quick turn's live line.
    public func queryLine(_ id: SessionID, _ line: String) {
        guard var state = activity[id], state.liveLine != line else { return }
        state.queryLine(line, at: clock())
        activity[id] = state
        publish()
    }

    /// The question's stream ended; one that never started a turn runs no more.
    public func queryEnded(_ id: SessionID) {
        guard var state = activity[id] else { return }
        state.queryEnded()
        guard state != activity[id] else { return }
        activity[id] = state
        publish()
    }

    /// A Lumi page (the Panel, Studio's column) started showing `id`: it's seen, kept warm, and a
    /// summon soon after continues it.
    public func pageShown(_ id: SessionID, kind: PageKind) {
        pages[id, default: []].insert(kind)
        if kind == .panel { panelShownAt[id] = clock() }
        markSeen(id)
        publish()
    }

    /// That page stopped showing `id` (closed, minimised, another session).
    public func pageHidden(_ id: SessionID, kind: PageKind) {
        pages[id]?.remove(kind)
        if pages[id]?.isEmpty == true { pages[id] = nil }
        if kind == .panel { panelShownAt[id] = clock() }
        publish()
    }

    /// Quick handed off (QA R11): the conversation's open session, resumed or minted, so the
    /// hand-off continues there instead of in the Deep lane. Nil for a v1 Deep (legacy)
    /// conversation, or one this store doesn't have: the Deep lane takes it as before.
    public func handoffLaunch(conversation id: String) async -> (SessionID, SessionLaunch)? {
        let session = SessionID(rawValue: id)
        return await serial {
            guard let record = try? await self.store.record(id: session), record.harness != .legacy else { return nil }
            let (launch, _) = await self.openLaunch(for: record, forceNew: false)
            await self.refresh(session)
            return (session, launch)
        }
    }

    /// Quit: the sessions that were mid-turn show "Interrupted · Continue" next launch.
    public func markInterrupted(_ ids: Set<SessionID>) async {
        let now = clock()
        for id in ids {
            var state = activity[id] ?? SessionActivity(status: .thinking(since: now, progress: nil))
            if state.turnStartedAt == nil { state.turnStartedAt = now }
            let effects = state.interrupt(at: now)
            activity[id] = state
            persist(effects, for: id, shown: nil, at: now)
        }
        publish()
        await serial {}
    }

    /// A session's page history, oldest first: v1 turns and open-session turns, read from Claude
    /// Code's files off the main actor. Empty when the session or its files are gone.
    public func transcript(_ id: SessionID) async -> [TranscriptTurn] {
        guard let reader, let record = try? await store.record(id: id) else { return [] }
        let users = (try? await store.userTurns(of: id)) ?? []
        return await Task.detached(priority: .userInitiated) { reader.turns(for: record, userTurns: users) }.value
    }

    /// The last user turn sent in `id`, skipping steers and relays (they fold into a turn), for a
    /// page opened while that turn still runs (QA U7).
    public func lastSentTurn(_ id: SessionID) async -> UserTurnRecord? {
        let users = (try? await store.userTurns(of: id)) ?? []
        return users.last { $0.kind != .steer && $0.kind != .relay }
    }

    // MARK: Editing a prompt

    /// Where an edited prompt's Claude session goes back to.
    public enum Rewind: Sendable, Equatable {
        /// Resume it at the message before the prompt (`SessionPool.rewind`).
        case resume(claude: UUID, at: String)
        /// It was the session's first prompt: the next turn starts a new Claude session.
        case fresh
    }

    /// Where an edited prompt (`uuid`) takes the Claude session back to. Read-only. Nil when it
    /// can't go back: the prompt isn't the session's, its file is gone, or a compaction came after it.
    public func rewindPoint(_ id: SessionID, prompt uuid: String) async -> Rewind? {
        guard let reader, let turn = (try? await store.userTurns(of: id))?.first(where: { $0.uuid == uuid }),
              let claude = UUID(uuidString: turn.sessionID),
              let parent = await Task.detached(operation: { reader.promptParent(uuid, session: turn.sessionID) }).value
        else { return nil }
        guard case .message(let at) = parent else { return .fresh }
        return .resume(claude: claude, at: at)
    }

    /// The edit went ahead: the store forgets the prompt and every later turn. On `.fresh` the old
    /// Claude session leaves the Lumi session (its file stays until Claude Code's cleanup), so the
    /// next turn mints a new one.
    public func commitRewind(_ id: SessionID, prompt uuid: String, _ rewind: Rewind) async -> Bool {
        let store = store
        let from: Date? = await serial {
            guard let dropped = try? await store.rewind(to: uuid, in: id), let first = dropped.first else { return nil }
            if rewind == .fresh { try? await store.removeClaudeSession(first.sessionID, from: id) }
            return first.at
        }
        guard let from else { return false }
        if rewind == .fresh { pendingOpen[id] = nil }
        // The dropped turns' team leaves the session's live roster, so no page is seeded with it again.
        activity[id]?.dropTeam(startedSince: from)
        await refresh(id)
        return true
    }

    // MARK: Planning a turn

    /// Routes one summon (SummonRouter) and makes the session ready: created, its project absorbed,
    /// its open Claude session minted or resumed. The session becomes current.
    public func plan(_ input: SummonInput, packet: ContextPacket?) async -> SessionTurnPlan {
        let since = input.now.addingTimeInterval(-7 * 86_400)
        let candidates = (try? await store.routingCandidates(since: since)) ?? []
        let decision = SummonRouter.route(input, candidates: candidates, policy: policy)
        let plan = await serial { await self.materialize(decision, input: input, packet: packet) }
        current = plan.id
        publish()
        return plan
    }

    /// The user turn as sent (its replayed uuid keys the transcript), and its words for the recap.
    /// The session's first user turn also names it at once, from the question's words (a typed
    /// session starts as "New session": it has no words until its composer sends some).
    public func recordSent(userUUID: String, kind: TurnKind, shown: String, claudeSession: UUID, in id: SessionID) async {
        lastShown[id] = shown
        let store = store, now = clock()
        let named = await serial { () async -> Bool in
            try? await store.recordUserTurn(uuid: userUUID, kind: kind, shown: shown, session: claudeSession, in: id, at: now)
            guard let record = try? await store.record(id: id), !record.titleLocked, record.retitles == 0,
                  (try? await store.userTurns(of: id))?.count == 1 else { return false }
            let topic = LocalTopic.from(utterance: shown, originBundleID: record.origin?.key.bundleID)
            guard topic.title != LocalTopic.placeholder, topic.title != record.title || record.symbol == nil else { return false }
            return (try? await store.setProvisionalTopic(topic, for: id)) == true
        }
        if named { await refresh(id) }
    }

    /// Continue on a Quick or v1 session (or one Claude Code no longer has): a new open Claude
    /// session under the same Lumi session, seeded with its recap. Never a `--resume` of Quick.
    public func continueAsOpen(_ id: SessionID) async -> SessionTurnPlan? {
        await serial {
            guard let record = try? await self.store.record(id: id) else { return nil }
            let (launch, seed) = await self.openLaunch(for: record, forceNew: true)
            return SessionTurnPlan(id: id, harness: .open, kind: .typed, launch: launch, seed: seed)
        }
    }

    /// A turn typed in a session's own composer (Panel, Studio): its open Claude session, resumed,
    /// or minted (seeded with the recap) when it has none yet. The session becomes current.
    public func composerPlan(_ id: SessionID) async -> SessionTurnPlan? {
        let plan: SessionTurnPlan? = await serial {
            guard let record = try? await self.store.record(id: id) else { return nil }
            let (launch, seed) = await self.openLaunch(for: record, forceNew: false)
            await self.refresh(id)
            return SessionTurnPlan(id: id, harness: .open, kind: .typed, launch: launch, seed: seed)
        }
        if plan != nil {
            current = id
            publish()
        }
        return plan
    }

    /// The session's open Claude session as recorded (acknowledged by Claude Code), and the folder
    /// it runs in. Read-only: unlike `launch(for:)`, it never mints one and never makes the session
    /// current, so the inspector and teammate lanes can read it freely.
    public func openClaudeSession(of id: SessionID) async -> (id: UUID, cwd: URL)? {
        guard let record = try? await store.record(id: id),
              let open = record.claudeSessions.last(where: { $0.role == .open }),
              let uuid = UUID(uuidString: open.sessionID) else { return nil }
        return (uuid, open.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home)
    }

    /// The folders a session works in, its running folder first, for the composer's `@` files and
    /// project skills. Read-only, like `openClaudeSession(of:)`.
    public func folders(of id: SessionID) async -> [URL] {
        var out = await openClaudeSession(of: id).map { [$0.cwd] } ?? []
        for dir in (try? await store.directories(of: id)) ?? [] where !out.contains(where: { $0.path == dir.path }) { out.append(dir) }
        return out
    }

    /// `composerPlan`'s launch alone, for callers that don't need the seed.
    public func launch(for id: SessionID) async -> SessionLaunch? {
        await composerPlan(id)?.launch
    }

    private func materialize(_ decision: RouteDecision, input: SummonInput, packet: ContextPacket?) async -> SessionTurnPlan {
        let now = input.now
        let kind = decision.kind
        guard let id = decision.session, let record = try? await store.record(id: id) else {
            return await create(kind: kind, input: input, packet: packet)
        }
        var offer: String?
        switch decision {
        case .absorb(_, let dir, _): try? await store.addDirectory(URL(fileURLWithPath: dir, isDirectory: true), to: id, at: now)
        case .offerAbsorb(_, let dir, _): offer = dir
        default: break
        }
        if let key = input.contextKey, key.stored != record.contextKey { try? await store.setContextKey(key, for: id) }
        // Spoken questions start on Quick in every session, open ones too: Quick hands off into the
        // session's open Claude session (`handoffLaunch`), and the cascade goes straight there for a
        // close follow-up to its last answer (`deepIsCurrent`). One hand-off never keeps a session on
        // the slower lane (V-06, as in v1). Typed asks stay on Quick while there's no page for Markdown.
        if kind == .voice || (kind == .typed && !typedOpensSessions) {
            await refresh(id)
            return SessionTurnPlan(id: id, harness: .quick, kind: kind, launch: nil, seed: nil, offerDirectory: offer)
        }
        let (launch, seed) = await openLaunch(for: record, forceNew: false)
        await refresh(id)
        return SessionTurnPlan(id: id, harness: .open, kind: kind, launch: launch, seed: seed, offerDirectory: offer)
    }

    /// A new session: spoken summons start on Quick, typed asks start open (lead), unless there's no
    /// page for them.
    private func create(kind: TurnKind, input: SummonInput, packet: ContextPacket?) async -> SessionTurnPlan {
        let id = SessionID.new()
        let origin = packet.flatMap(SessionOrigin.from)
        let topic = LocalTopic.from(utterance: packet?.utterance ?? "", originBundleID: origin?.key.bundleID)
        let harness: Harness = kind == .voice || (kind == .typed && !typedOpensSessions) ? .quick : .open
        guard let record = try? await store.create(id, title: topic.title, origin: origin, harness: harness, at: input.now) else {
            return SessionTurnPlan(id: id, harness: harness, kind: kind, launch: nil, seed: nil)
        }
        if let project = input.project, input.projectTrusted {
            try? await store.addDirectory(URL(fileURLWithPath: project, isDirectory: true), to: id, at: input.now)
        }
        var plan = SessionTurnPlan(id: id, harness: harness, kind: kind, launch: nil, seed: nil)
        if harness == .open { plan.launch = await openLaunch(for: record, forceNew: false).0 }
        await refresh(id)
        return plan
    }

    /// The open Claude session to resume, or a new one (recorded at once, so at most one id is ever
    /// minted per session). It resumes in the folder it was created in, which is where Claude Code
    /// keeps its file; a new one starts in the first trusted directory, else home.
    private func openLaunch(for record: SessionRecord, forceNew: Bool) async -> (SessionLaunch, String?) {
        let id = SessionID(rawValue: record.id)
        let dirs = (try? await store.directories(of: id)) ?? []
        if !forceNew, let open = record.claudeSessions.last(where: { $0.role == .open }), let uuid = UUID(uuidString: open.sessionID) {
            let cwd = open.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home
            return (SessionLaunch(claudeSession: uuid, exists: true, cwd: cwd, addDirs: dirs.filter { $0.path != cwd.path },
                                  maxSubagents: maxSubagents), nil)
        }
        // Minted before but never started: the same id, still new, still seeded.
        let pending = pendingOpen[id] ?? {
            let trust = trust()
            let cwd = dirs.first { trust.isTrusted($0, rule: .folderOrAncestor) } ?? home
            // Its last turns, so the new session picks up the thread: a Quick or v1 session continued,
            // or an open one whose Claude session was lost. A brand-new session has none.
            let seed = record.recap.isEmpty ? nil : record.recap.joined(separator: "\n\n")
            return PendingOpen(claudeSession: UUID(), cwd: cwd, seed: seed)
        }()
        pendingOpen[id] = pending
        return (SessionLaunch(claudeSession: pending.claudeSession, exists: false, cwd: pending.cwd,
                              addDirs: dirs.filter { $0.path != pending.cwd.path }, maxSubagents: maxSubagents), pending.seed)
    }

    /// What the pool reports when `--resume` names a session Claude Code no longer has.
    public static let sessionNotFound = "session_not_found"

    /// Claude Code no longer has the session's open Claude session (QA E1: its file was removed
    /// by the 30-day cleanup, or never written). It's forgotten, so the next turn mints a new one
    /// under the same Lumi session, seeded with the recap, instead of failing for good.
    public func claudeSessionLost(_ id: SessionID) {
        pendingOpen[id] = nil
        let store = store
        enqueue {
            guard let open = (try? await store.record(id: id))?.claudeSessions.last(where: { $0.role == .open }) else { return }
            try? await store.removeClaudeSession(open.sessionID, from: id)
            await self.refresh(id)
        }
    }

    /// Claude Code started the minted session (`system/init`, or the replayed first user turn):
    /// it's recorded now, so later plans resume it and Forget deletes it.
    private func acknowledgeOpen(_ id: SessionID) {
        guard let pending = pendingOpen.removeValue(forKey: id) else { return }
        let store = store, now = clock()
        enqueue {
            try? await store.addClaudeSession(pending.claudeSession, role: .open, cwd: pending.cwd, to: id, at: now)
            if (try? await store.record(id: id))?.harness != .open { try? await store.setHarness(.open, for: id) }
            await self.refresh(id)
        }
    }

    // MARK: Helpers

    private func write(_ id: SessionID, _ body: @escaping @Sendable (SessionStore) async throws -> Void) async {
        let store = store
        await serial { try? await body(store) }
        await refresh(id)
    }

    /// Queued at once, behind every earlier write, so a later event's effect never lands first.
    /// `cascade`: a Quick turn, whose row the cascade's port already updated.
    private func persist(_ effects: [SessionActivity.Effect], for id: SessionID, shown: String?, at now: Date,
                         userTurn: Bool = true, cascade: Bool = false) {
        let store = store
        enqueue {
            for effect in effects {
                switch effect {
                case .finishTurn(let preview):
                    if !cascade {
                        let previous = (try? await store.record(id: id))?.recap ?? []
                        let entry = shown.map { ContextPacket.Conversation.recapEntry(question: $0, answer: preview) }
                        try? await store.finishTurn(id, answerPreview: preview, recap: previous + (entry.map { [$0] } ?? []),
                                                    at: now, lane: nil, userTurn: userTurn)
                    }
                    // The first answer with no topic of its own (typed, or a voice turn without one).
                    let hasTopic = effects.contains { if case .topic = $0 { true } else { false } }
                    if userTurn, !hasTopic, let shown { await self.title(id, question: shown, answer: preview) }
                case .status(let status):
                    try? await store.setStatus(status, for: id)
                case .topic(let topic):
                    guard let record = try? await store.record(id: id) else { continue }
                    let fallback = SessionTopic(title: record.title, symbol: record.symbol)
                    let valid = TopicValidator.validate(topic, fallback: fallback)
                    if valid != fallback { _ = try? await store.setTopic(valid, for: id, refinement: record.retitles > 0) }
                case .voiceRules(let needed):
                    if !cascade { await store.markVoiceRules(sent: !needed, for: id) }
                }
            }
            await self.refresh(id)
        }
    }

    /// Asks the titler in the background (the answer has already shown), then applies a valid
    /// topic as the session's first automatic title. A rename meanwhile wins; a failure keeps the
    /// provisional title.
    private func title(_ id: SessionID, question: String, answer: String) async {
        guard let titler, !titling.contains(id), let record = try? await store.record(id: id),
              !record.titleLocked, record.retitles == 0 else { return }
        titling.insert(id)
        Task {
            guard let proposed = await titler.topic(question: question, answer: answer) else { return }
            self.enqueue {
                let store = self.store
                guard let record = try? await store.record(id: id) else { return }
                let fallback = SessionTopic(title: record.title, symbol: record.symbol)
                let valid = TopicValidator.validate(proposed, fallback: fallback)
                if valid != fallback, (try? await store.setTopic(valid, for: id, refinement: false)) == true { await self.refresh(id) }
            }
        }
    }

    /// Re-reads one row into the read model.
    private func refresh(_ id: SessionID) async {
        guard let record = try? await store.record(id: id) else { return }
        records[id] = record
        if !order.contains(id) { order.insert(id, at: 0) }
        order.sort { (records[$0]?.lastUsed ?? .distantPast) > (records[$1]?.lastUsed ?? .distantPast) }
        publish()
    }

    private func publish() {
        snapshots = order.compactMap { id in records[id].map { snapshot($0, activity[id]) } }
        for subscriber in subscribers.values { subscriber.yield(snapshots) }
    }

    private func snapshot(_ record: SessionRecord, _ activity: SessionActivity?) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionID(rawValue: record.id), title: record.title, symbol: record.symbol, color: record.color,
            origin: record.origin, harness: record.harness,
            status: activity?.status ?? SessionStatus(persisted: record.status, finishedAt: record.finishedAt),
            teammates: activity?.teammates ?? [], teamLive: activity?.team.isLive ?? false, pinned: record.pinned, archived: record.archived, lastUsed: record.lastUsed,
            finishedAt: activity?.finishedAt ?? record.finishedAt, liveLine: activity?.liveLine, turns: record.turns,
            ranFor: activity?.ranFor, lastSay: activity?.lastSay, lastEventAt: activity?.lastEventAt)
    }

    /// Queues `body` behind every earlier call without waiting for it.
    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await body()
        }
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
}
