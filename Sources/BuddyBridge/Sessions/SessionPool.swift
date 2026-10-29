import BuddyCore
import Foundation

public enum PoolError: Error, Sendable, Equatable {
    /// The session has no live process (and the call doesn't launch one).
    case notLive
    case launchFailed(String)
    /// `claude` kept dying at boot; restarts used up (the amber chip, with its stderr).
    case unavailable(String)
    /// `--resume` named a session Claude Code no longer has (deleted, or past `cleanupPeriodDays`).
    /// The caller starts a new Claude session, seeded with Lumi's recap.
    case sessionNotFound
    /// A project change while the session is working: absorb waits for the turn to end.
    case busy
    /// After `shutdownAll`.
    case closed
}

/// A process starting or stopping, for the trace log (the latency run reads these).
public enum PoolLifecycle: Sendable, Equatable {
    /// Spawn to `initialize` answered. `resumed`: `--resume` (else `--session-id`).
    case launched(SessionID, resumed: Bool, startup: Duration)
    /// The process was stopped; `idle`: how long the session had been unused.
    case suspended(SessionID, idle: Duration, reason: SuspendReason)
}

/// One event of any session, for the read model that follows every session (`LiveSessions`).
public struct PoolEvent: Sendable, Equatable {
    public var id: SessionID
    public var event: SessionEvent
}

public enum SuspendReason: String, Sendable, Equatable {
    case idle, cap, memoryPressure, absorb, released
}

/// One process per live open session (02 §D1). Sessions outlive their processes: an idle one is
/// suspended (its JSONL stays) and resumed with `--resume` on the next message. At most one
/// process ever holds a Claude session id (a per-session gate around launch, respawn and suspend).
/// Never suspends a session that is working, needs the user, has a teammate running, is pinned or
/// is on screen (`SuspendPolicy`).
public actor SessionPool {
    private let caps: PoolCaps
    private let makeSpec: @Sendable (SessionLaunch) -> LaunchSpec
    private let makeTransport: TransportFactory
    private let makeMapper: MapperFactory
    private let restart: RestartPolicy
    private let hostsPermissions: @Sendable () -> Bool
    private let ledger: ProcessLedger?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async -> Void
    private let suspendGrace: Duration
    private let lifecycle: (@Sendable (PoolLifecycle) -> Void)?

    private var live: [SessionID: SessionProcess] = [:]
    private var gates: [SessionID: AsyncGate] = [:]
    private var lastUsed: [SessionID: ContinuousClock.Instant] = [:]
    private var pinned: Set<SessionID> = []
    private var onScreen: Set<SessionID> = []
    /// Claude sessions that exist on disk (a process reported `system/init` for them): relaunches
    /// use `--resume` whatever the caller passed.
    private var created: Set<UUID> = []
    /// Claude ids minted for a launch that ended before the CLI wrote anything (a prelaunch then a
    /// suspend, a failed first launch): there is no JSONL to `--resume`, so they start fresh (QA E1).
    private var uncreated: Set<UUID> = []
    /// A launch with new folders that came while the session worked: applied once it's idle (QA E5/E6).
    private var pendingLaunch: [SessionID: SessionLaunch] = [:]
    /// The interrupted turn a Continue resumes, for the process start (QA E11).
    private var resuming: [SessionID: (kind: TurnKind, uuid: String?)] = [:]
    /// An edited prompt's parent (`rewind`): launches of that Claude session resume there until the
    /// CLI takes a user line.
    private var rewinds: [SessionID: (claude: UUID, at: String)] = [:]
    private var subscribers: [SessionID: [UUID: AsyncStream<SessionEvent>.Continuation]] = [:]
    private var everything: [UUID: AsyncStream<PoolEvent>.Continuation] = [:]
    /// Per-turn streams (`turn`): the session's events plus where a line folded into a running turn.
    private var turnWatchers: [SessionID: [UUID: AsyncStream<SessionProcess.Output>.Continuation]] = [:]
    /// Processes the pool stopped to relaunch the session (a new folder, a new Claude session): they
    /// were free, so their exit never cuts off a turn; one waiting on the new process carries on.
    private var replaced: Set<ObjectIdentifier> = []
    private var latest: [SessionID: Latest] = [:]
    private var closed = false
    /// The sweep and memory-pressure loops, cancelled by `shutdownAll` and deinit.
    private let background = Shared<[Task<Void, Never>]>([])

    /// What a new subscriber is told first: the current state and any open asks.
    private struct Latest {
        var runState: RunState?
        var asks: [String: SessionEvent] = [:]
    }

    static let defaultMapper: MapperFactory = { dirs in SessionEventMapper(sessionDirs: dirs) }

    /// `spec`: the launch for a session (`LaunchSpec.open` with the user's settings).
    /// `memoryPressure`: one value per system warning; idle sessions are suspended, LRU first.
    /// `hostsPermissions`: off, permission prompts are declined at once (the stub until the
    /// permission host ships). `ledger`: records process groups for the orphan sweep at launch.
    public init(caps: PoolCaps, spec: @escaping @Sendable (SessionLaunch) -> LaunchSpec,
                transport: @escaping TransportFactory = { try ProcessTransport(spec: $0) },
                memoryPressure: AsyncStream<Void>? = nil, restart: RestartPolicy = RestartPolicy(),
                hostsPermissions: @escaping @Sendable () -> Bool = { false }, ledger: ProcessLedger? = nil,
                sweepEvery: Duration? = .seconds(30), lifecycle: (@Sendable (PoolLifecycle) -> Void)? = nil) {
        self.init(caps: caps, spec: spec, transport: transport, mapper: Self.defaultMapper, memoryPressure: memoryPressure,
                  restart: restart, hostsPermissions: hostsPermissions, ledger: ledger, sweepEvery: sweepEvery,
                  lifecycle: lifecycle)
    }

    init(caps: PoolCaps, spec: @escaping @Sendable (SessionLaunch) -> LaunchSpec, transport: @escaping TransportFactory,
         mapper: @escaping MapperFactory, memoryPressure: AsyncStream<Void>? = nil, restart: RestartPolicy = RestartPolicy(),
         hostsPermissions: @escaping @Sendable () -> Bool = { false }, ledger: ProcessLedger? = nil,
         sweepEvery: Duration? = nil, suspendGrace: Duration = .seconds(1),
         lifecycle: (@Sendable (PoolLifecycle) -> Void)? = nil,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.caps = caps
        self.makeSpec = spec
        self.makeTransport = transport
        self.makeMapper = mapper
        self.restart = restart
        self.hostsPermissions = hostsPermissions
        self.ledger = ledger
        self.now = now
        self.sleep = sleep
        self.suspendGrace = suspendGrace
        self.lifecycle = lifecycle
        var tasks: [Task<Void, Never>] = []
        if let memoryPressure {
            tasks.append(Task { [weak self] in
                for await _ in memoryPressure { await self?.sweep(pressure: true) }
            })
        }
        if let sweepEvery {
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: sweepEvery)
                    await self?.sweep(pressure: false)
                }
            })
        }
        background.withLock { $0 = tasks }
    }

    deinit {
        background.withLock { $0.forEach { $0.cancel() } }
    }

    // MARK: - Events

    /// One long-lived stream per Lumi session, across turns, processes and resumes. Any number of
    /// subscribers; each first gets the current run state and any open asks.
    public func events(for id: SessionID) -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        let key = UUID()
        if let l = latest[id] {
            if let state = l.runState { continuation.yield(.runState(state)) }
            for ask in l.asks.keys.sorted() { if let e = l.asks[ask] { continuation.yield(e) } }
        }
        subscribers[id, default: [:]][key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id, key) }
        }
        return stream
    }

    /// Every session's events, from now on (background sessions included).
    public func allEvents() -> AsyncStream<PoolEvent> {
        let (stream, continuation) = AsyncStream<PoolEvent>.makeStream()
        let key = UUID()
        everything[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribeAll(key) }
        }
        return stream
    }

    private func publishFold(_ id: SessionID, _ uuid: String) {
        for c in (turnWatchers[id] ?? [:]).values { c.yield(.folded(uuid: uuid)) }
    }

    private func watchTurns(of id: SessionID) -> AsyncStream<SessionProcess.Output> {
        let (stream, continuation) = AsyncStream<SessionProcess.Output>.makeStream()
        let key = UUID()
        if let state = latest[id]?.runState { continuation.yield(.event(.runState(state))) }
        turnWatchers[id, default: [:]][key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unwatchTurns(id, key) }
        }
        return stream
    }

    private func unwatchTurns(_ id: SessionID, _ key: UUID) {
        turnWatchers[id]?[key] = nil
        if turnWatchers[id]?.isEmpty == true { turnWatchers[id] = nil }
    }

    private func unsubscribeAll(_ key: UUID) {
        everything[key] = nil
    }

    private func unsubscribe(_ id: SessionID, _ key: UUID) {
        subscribers[id]?[key] = nil
        if subscribers[id]?.isEmpty == true { subscribers[id] = nil }
    }

    private func publish(_ id: SessionID, _ event: SessionEvent, from source: SessionProcess? = nil) {
        // A process stopped to relaunch the session wasn't mid-turn by the pool's own check, even if
        // its mapper still held a turn open (no result came): reported as cut off, it would end the
        // turn now waiting on the new process (a hand-off) with no answer.
        // The entry goes with the process's exit (while it's still alive, so its id isn't reused).
        var event = event
        if case .processEnded(let status, let midTurn) = event, let source, replaced.remove(ObjectIdentifier(source)) != nil,
           midTurn {
            event = .processEnded(status: status, midTurn: false)
        }
        var l = latest[id] ?? Latest()
        switch event {
        case .runState(let state):
            l.runState = state
            if state == .idle {
                lastUsed[id] = now()
                if pendingLaunch[id] != nil { Task { await self.applyPendingLaunch(id) } }
            }
        case .permissionRequested(let ask):
            l.asks[ask.id] = event
        case .questionAsked(let q):
            l.asks[q.id] = event
        case .permissionResolved(let ask):
            l.asks[ask] = nil
        case .processEnded:
            l = Latest()
        case .turnStarted(let uuid, _):
            lastUsed[id] = now()
            // The edited prompt is in: from now on, plain `--resume` continues its branch.
            if uuid != nil { rewinds[id] = nil }
        case .turnEnded:
            lastUsed[id] = now()
        default:
            break
        }
        latest[id] = l
        for c in (subscribers[id] ?? [:]).values { c.yield(event) }
        for c in everything.values { c.yield(PoolEvent(id: id, event: event)) }
        for c in (turnWatchers[id] ?? [:]).values { c.yield(.event(event)) }
    }

    // MARK: - Turns

    /// Boots the process without sending (the Panel or text box opened): hides the ~0.8 s start.
    public func prelaunch(_ id: SessionID, _ launch: SessionLaunch) async {
        guard !closed else { return }
        let gate = gate(for: id)
        await gate.enter()
        _ = try? await process(for: id, launch)
        await gate.leave()
        lastUsed[id] = now()
        await enforceCaps(keep: id)
    }

    /// Sends one user turn, launching or resuming the process as needed. Returns the user message
    /// uuid written (the replay echo and `result.user_message_uuids` carry it).
    /// `speak`: run the say extractor (nil: voice turns only).
    @discardableResult
    /// `priority: "now"`: aborts the running tool and runs this line as its own turn (probe 4).
    public func send(_ input: TurnInput, kind: TurnKind, to id: SessionID, launch: SessionLaunch,
                     speak: Bool? = nil, priority: String? = nil) async throws(PoolError) -> String {
        guard !closed else { throw .closed }
        let uuid = UUID().uuidString.lowercased()
        let gate = gate(for: id)
        await gate.enter()
        do {
            let p = try await process(for: id, launch)
            lastUsed[id] = now()
            try await p.send(input, kind: kind, uuid: uuid, speak: speak, priority: priority)
        } catch {
            await gate.leave()
            throw error
        }
        await gate.leave()
        await enforceCaps(keep: id)
        return uuid
    }

    /// One turn as a stream: subscribes, sends, and yields the session's events until this turn
    /// ends (`.turnEnded`, or `.processEnded` mid-turn). A line the CLI folded into a turn already
    /// running (no `turnStarted` of its own) ends with that turn. A send that fails ends the stream
    /// with a failed `turnEnded`. Finishing early (the consumer stops) doesn't cancel the turn.
    /// `sent`: called with the user message uuid once the line is written.
    public func turn(_ input: TurnInput, kind: TurnKind, to id: SessionID, launch: SessionLaunch,
                     speak: Bool? = nil, priority: String? = nil,
                     sent: (@Sendable (String) async -> Void)? = nil) -> AsyncStream<SessionEvent> {
        let watched = watchTurns(of: id)
        let (stream, out) = AsyncStream<SessionEvent>.makeStream()
        let relay = Task {
            let uuid: String
            do throws(PoolError) {
                uuid = try await self.send(input, kind: kind, to: id, launch: launch, speak: speak, priority: priority)
            } catch {
                out.yield(.turnEnded(TurnEnd(kind: kind, markdown: "", isError: true, error: Self.failure(error))))
                out.finish()
                return
            }
            await sent?(uuid)
            // Only this turn's events. A turn the CLI starts on its own (a background teammate
            // handed back, probe 5) may run before ours: it reaches the page and the session's status
            // through `events(for:)` and `allEvents()`, never this stream, or it would be presented
            // as the answer to the user's question (QA R20).
            var ours = false
            for await output in watched {
                let event: SessionEvent
                switch output {
                case .folded(let folded):
                    if folded == uuid { ours = true }
                    continue
                case .event(let e):
                    event = e
                }
                switch event {
                case .turnStarted(let started, _):
                    if started == uuid { ours = true }
                    if ours { out.yield(event) }
                case .turnEnded:
                    guard ours else { continue }
                    out.yield(event)
                    out.finish()
                    return
                case .processEnded(_, let midTurn):
                    out.yield(event)
                    if midTurn || ours { out.finish(); return }
                default:
                    if ours || !Self.isTurnContent(event) { out.yield(event) }
                }
            }
            out.finish()
        }
        out.onTermination = { _ in relay.cancel() }
        return stream
    }

    /// Events that belong to one turn (as opposed to the session's state, retries and limits).
    static func isTurnContent(_ event: SessionEvent) -> Bool {
        switch event {
        case .runState, .retrying, .rateLimit, .launched, .initialized, .processEnded: false
        default: true
        }
    }

    /// A Continue found no interrupted turn to resume.
    public static let nothingToResume = "nothing_to_resume"

    static func failure(_ error: PoolError) -> SessionFailure {
        switch error {
        case .unavailable(let detail): SessionFailure(reason: .unavailable(detail), retryable: true)
        case .launchFailed(let detail): SessionFailure(reason: .unavailable(detail), retryable: true)
        case .sessionNotFound: SessionFailure(reason: .unavailable("session_not_found"), retryable: false)
        case .notLive, .busy, .closed: SessionFailure(reason: .crashed, retryable: true)
        }
    }

    /// Continue on an Interrupted session (Lumi quit mid-turn): relaunches with
    /// `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1`, so the CLI picks the turn up as soon as it starts,
    /// with no user line. The turn keeps its kind and uuid (`kind`, `uuid`: the interrupted line's).
    /// The stream ends with that turn, like `turn`.
    public func resume(_ id: SessionID, launch: SessionLaunch, kind: TurnKind, uuid: String?) -> AsyncStream<SessionEvent> {
        var launch = launch
        launch.continueInterrupted = true
        launch.exists = true
        let watched = watchTurns(of: id)
        let (stream, out) = AsyncStream<SessionEvent>.makeStream()
        let relay = Task {
            do throws(PoolError) {
                try await self.relaunchForResume(id, launch, kind: kind, uuid: uuid)
            } catch {
                out.yield(.turnEnded(TurnEnd(kind: kind, markdown: "", isError: true, error: Self.failure(error))))
                out.finish()
                return
            }
            var ours = false
            var launched = false
            var said = false
            for await output in watched {
                guard case .event(let event) = output else { continue }
                switch event {
                case .launched:
                    launched = true
                case .runState(.idle) where launched && !ours:
                    // Nothing to resume (QA R22): the CLI went idle with no turn. It ends as
                    // Interrupted again instead of spinning, and the process is released, so its
                    // pending resume can't attach to a later turn.
                    out.yield(.turnEnded(TurnEnd(kind: kind, markdown: "", isError: true,
                                                 error: SessionFailure(reason: .unavailable(Self.nothingToResume), retryable: true))))
                    out.finish()
                    _ = await self.suspend(id)
                    return
                case .turnStarted(let started, _):
                    if uuid == nil || started == uuid { ours = true }
                    if ours { out.yield(event) }
                case .turnEnded(let end):
                    guard ours else { continue }
                    // The CLI may run an empty turn instead (live, 2.1.312): no text, no steps, an empty
                    // result. Nothing was resumed either (QA R22).
                    if !said, !end.isError, end.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.yield(.turnEnded(TurnEnd(kind: kind, markdown: "", isError: true,
                                                     error: SessionFailure(reason: .unavailable(Self.nothingToResume), retryable: true))))
                        out.finish()
                        return
                    }
                    out.yield(event)
                    out.finish()
                    return
                case .processEnded:
                    out.yield(event)
                    out.finish()
                    return
                default:
                    if ours {
                        switch event {
                        case .text, .step, .say, .sayFirstSentence, .permissionRequested, .questionAsked: said = true
                        default: break
                        }
                    }
                    if ours || !Self.isTurnContent(event) { out.yield(event) }
                }
            }
            out.finish()
        }
        out.onTermination = { _ in relay.cancel() }
        return stream
    }

    /// U11's name for `resume`: Continue on an Interrupted session.
    public func continueInterrupted(_ id: SessionID, launch: SessionLaunch, kind: TurnKind = .typed,
                                    uuid: String? = nil) -> AsyncStream<SessionEvent> {
        resume(id, launch: launch, kind: kind, uuid: uuid)
    }

    private func relaunchForResume(_ id: SessionID, _ launch: SessionLaunch, kind: TurnKind, uuid: String?) async throws(PoolError) {
        guard !closed else { throw .closed }
        let gate = gate(for: id)
        await gate.enter()
        if let p = live[id] { await stop(p, id: id, reason: .released) }
        resuming[id] = (kind, uuid)
        do {
            _ = try await process(for: id, launch)
        } catch {
            resuming[id] = nil
            await gate.leave()
            throw error
        }
        resuming[id] = nil
        await gate.leave()
    }

    /// Hands one event to every subscriber as if the session had sent it (a failure the caller
    /// couldn't recover from, so the read model sees it).
    public func report(_ event: SessionEvent, for id: SessionID) {
        publish(id, event)
    }

    /// A message while the turn runs: the CLI queues it and folds it into the same turn at the
    /// next tool boundary (probe 3).
    @discardableResult
    public func steer(_ text: String, session id: SessionID, kind: TurnKind = .steer) async throws(PoolError) -> String {
        guard let p = live[id], await p.isAlive else { throw .notLive }
        let uuid = UUID().uuidString.lowercased()
        lastUsed[id] = now()
        try await p.send(TypedTurn.input(text: text, screen: nil), kind: kind, uuid: uuid)
        return uuid
    }

    /// Esc: the `interrupt` control request, then SIGTERM if the turn doesn't end in time.
    public func interrupt(_ id: SessionID) async {
        await live[id]?.interrupt()
    }

    /// The user's answer to a permission prompt. False when it's no longer pending.
    @discardableResult
    public func answer(_ requestID: String, _ decision: PermissionDecision, session id: SessionID) async -> Bool {
        await live[id]?.answer(requestID, decision) ?? false
    }

    /// The user's answers to AskUserQuestion: chosen labels per question text.
    @discardableResult
    public func answer(_ requestID: String, answers: [String: [String]], session id: SessionID) async -> Bool {
        await live[id]?.answer(requestID, answers: answers) ?? false
    }

    /// Stops one teammate or background job.
    public func stopTask(_ taskID: String, session id: SessionID) async {
        await live[id]?.stopTask(taskID)
    }

    /// A project change, between turns only: restarts the process with every directory
    /// (`launch.addDirs` plus `dir`), since resume doesn't restore `--add-dir`. With no live
    /// process there's nothing to do: the next launch passes them.
    public func absorb(_ dir: URL, session id: SessionID, launch: SessionLaunch) async throws(PoolError) {
        guard !closed else { throw .closed }
        var launch = launch
        if !launch.addDirs.contains(where: { $0.standardizedFileURL.path == dir.standardizedFileURL.path }) {
            launch.addDirs.append(dir)
        }
        let gate = gate(for: id)
        await gate.enter()
        guard let p = live[id], await p.isAlive else {
            await gate.leave()
            return
        }
        guard SuspendPolicy.canRespawn(await p.facts(pinned: false, onScreen: false)) else {
            // Working (or just finished, before `idle`): applied as soon as it's idle (QA E5).
            pendingLaunch[id] = launch
            await gate.leave()
            return
        }
        await stop(p, id: id, reason: .absorb)
        do {
            _ = try await process(for: id, launch)
        } catch {
            await gate.leave()
            throw error
        }
        await gate.leave()
    }

    // MARK: - Keeping warm

    /// Whether the session is working: a turn in flight, running, waiting on the user, or a task open.
    public func isWorking(_ id: SessionID) async -> Bool {
        guard let p = live[id], await p.isAlive else { return false }
        return !SuspendPolicy.canRespawn(await p.facts(pinned: false, onScreen: false))
    }

    /// The pinned sessions, all at once (from the read model).
    public func setPinned(_ ids: Set<SessionID>) {
        pinned = ids
    }

    public func setPinned(_ isPinned: Bool, _ id: SessionID) {
        if isPinned { pinned.insert(id) } else { pinned.remove(id) }
    }

    /// The sessions a Lumi page shows: never suspended while on screen.
    public func setOnScreen(_ ids: Set<SessionID>) {
        onScreen = ids
        for id in ids where live[id] != nil { lastUsed[id] = now() }
    }

    /// Releases the session's process now (Open in Terminal, Forget). Refused while it works or
    /// waits on the user; pinned and on-screen sessions may be released. Returns whether it stopped.
    @discardableResult
    public func suspend(_ id: SessionID) async -> Bool {
        let gate = gate(for: id)
        await gate.enter()
        var stopped = true
        if let p = live[id] {
            stopped = SuspendPolicy.canRespawn(await p.facts(pinned: false, onScreen: false))
            if stopped { await stop(p, id: id, reason: .released) }
        }
        await gate.leave()
        return stopped
    }

    /// Edit an earlier prompt: the session's process is relaunched now, resuming the conversation
    /// at `parent`, the message before that prompt (`--resume-session-at`), so the next prompt
    /// replaces it and everything after. Claude Code keeps the old turns in the file as a side
    /// branch; the reader follows the new one. Relaunches keep the resume point until the CLI takes
    /// a user line. False, with the conversation as it was, while the session works or when the
    /// CLI refuses the resume point.
    public func rewind(_ id: SessionID, launch: SessionLaunch, to parent: String) async -> Bool {
        guard !closed else { return false }
        let gate = gate(for: id)
        await gate.enter()
        var ok = true
        if let p = live[id] {
            ok = SuspendPolicy.canRespawn(await p.facts(pinned: false, onScreen: false))
            if ok {
                replaced.insert(ObjectIdentifier(p))
                await stop(p, id: id, reason: .released)
            }
        }
        if ok {
            rewinds[id] = (launch.claudeSession, parent)
            do { _ = try await process(for: id, launch) } catch {
                rewinds[id] = nil
                ok = false
            }
        }
        await gate.leave()
        lastUsed[id] = now()
        return ok
    }

    /// Quit: interrupts running turns and stops every process. Returns the sessions that were
    /// mid-turn (shown as Interrupted · Continue).
    public func shutdownAll() async -> Set<SessionID> {
        closed = true
        background.withLock { $0.forEach { $0.cancel() } }
        // Interrupted only when the lead's own turn was in flight: a Continue resumes that turn. A
        // session where only teammates still worked ends idle, its teammates "didn't finish" (QA R22).
        var midTurn: Set<SessionID> = []
        var working: Set<SessionID> = []
        let processes = live
        for (id, p) in processes {
            if await p.leadTurnOpen { midTurn.insert(id) }
            if await p.facts(pinned: false, onScreen: false).openTasks > 0 { working.insert(id) }
        }
        // SIGTERM only, never `interrupt` first: an interrupt is recorded as the user's, and the
        // turn could no longer be continued with RESUME_INTERRUPTED_TURN (QA E2). SIGTERM too with
        // teammates running: with stdin closed, `-p` would wait up to 10 min for them. Idle sessions
        // get stdin closed, which ends them cleanly.
        let grace = suspendGrace
        await withTaskGroup(of: Void.self) { group in
            for (id, p) in processes {
                if midTurn.contains(id) || working.contains(id) {
                    group.addTask { await p.kill(); _ = await p.waitForExit() }
                } else {
                    group.addTask { await p.suspend(grace: grace) }
                }
            }
        }
        live = [:]
        return midTurn
    }

    public var liveCount: Int { live.count }

    func isLive(_ id: SessionID) -> Bool { live[id] != nil }

    // MARK: - Suspending

    /// Suspends what `SuspendPolicy` picks: idle past `caps.idleSuspend`, over the cap, or (under
    /// memory pressure) every idle session.
    func sweep(pressure: Bool) async {
        await enforceCaps(keep: nil, pressure: pressure)
    }

    private func enforceCaps(keep: SessionID?, pressure: Bool = false) async {
        var candidates: [SuspendPolicy.Candidate] = []
        for (id, p) in live {
            let f = await p.facts(pinned: pinned.contains(id), onScreen: onScreen.contains(id))
            candidates.append(.init(id: id, facts: f, lastUsed: lastUsed[id] ?? now()))
        }
        let victims = SuspendPolicy.victims(candidates, caps: caps, now: now(), pressure: pressure, keep: keep)
        for id in victims {
            let gate = gate(for: id)
            await gate.enter()
            // Re-checked under the gate: a message may have arrived meanwhile.
            if let p = live[id], SuspendPolicy.canSuspend(await p.facts(pinned: pinned.contains(id), onScreen: onScreen.contains(id))) {
                let reason: SuspendReason = pressure ? .memoryPressure
                    : now() - (lastUsed[id] ?? now()) >= caps.idleSuspend ? .idle : .cap
                await stop(p, id: id, reason: reason)
            }
            await gate.leave()
        }
    }

    /// Under the session's gate.
    private func stop(_ p: SessionProcess, id: SessionID, reason: SuspendReason) async {
        let idle = lastUsed[id].map { now() - $0 } ?? .zero
        await p.suspend(grace: suspendGrace)
        lifecycle?(.suspended(id, idle: idle, reason: reason))
        await noteCreated(p)
        if live[id] === p { live[id] = nil }
    }

    /// A process that reported `system/init` created its Claude session: from now on, `--resume`.
    private func noteCreated(_ p: SessionProcess) async {
        let claude = p.launch.claudeSession
        if await p.initialized {
            created.insert(claude)
            uncreated.remove(claude)
        } else if !p.launch.exists, !created.contains(claude) {
            uncreated.insert(claude)
        }
    }

    /// The launch that came while the session worked, now that it's idle.
    private func applyPendingLaunch(_ id: SessionID) async {
        let gate = gate(for: id)
        await gate.enter()
        if let pending = pendingLaunch[id] {
            if let p = live[id], await p.isAlive, !SuspendPolicy.canRespawn(await p.facts(pinned: false, onScreen: false)) {
                // Still busy (a task opened): the next idle tries again.
            } else {
                pendingLaunch[id] = nil
                if live[id] != nil { _ = try? await process(for: id, pending) }
            }
        }
        await gate.leave()
    }

    // MARK: - Launching

    static func folders(of launch: SessionLaunch) -> Set<String> {
        Set(([launch.cwd] + launch.addDirs).map(\.standardizedFileURL.path))
    }

    private func gate(for id: SessionID) -> AsyncGate {
        if let g = gates[id] { return g }
        let g = AsyncGate()
        gates[id] = g
        return g
    }

    /// The session's live process, launched (or resumed) if there is none. Under the session's gate.
    /// A `claude` that dies at boot is restarted with backoff (`RestartPolicy`); a resume of a
    /// session the CLI no longer has throws `.sessionNotFound`, unless the pool itself chose
    /// `--resume`, when it starts the id fresh.
    private func process(for id: SessionID, _ requested: SessionLaunch) async throws(PoolError) -> SessionProcess {
        if let p = live[id], await p.isAlive {
            let otherSession = p.launch.claudeSession != requested.claudeSession
            let newFolders = Self.folders(of: p.launch) != Self.folders(of: requested)
            if !otherSession && !newFolders { return p }
            let free = SuspendPolicy.canRespawn(await p.facts(pinned: false, onScreen: false))
            if !free {
                // A different Claude session never lands in the running one's JSONL (QA E7).
                if otherSession { throw .busy }
                // The router absorbed a folder mid-turn: the running process keeps going and the
                // folders apply as soon as it's idle (02 §D8.4, QA E5/E6).
                pendingLaunch[id] = requested
                return p
            }
            pendingLaunch[id] = nil
            replaced.insert(ObjectIdentifier(p))
            await stop(p, id: id, reason: otherSession ? .released : .absorb)
        }
        var attempt = 0
        var forcedFresh = false
        while true {
            guard !closed else { throw .closed }
            var launch = requested
            launch.resumeAt = rewinds[id].flatMap { $0.claude == launch.claudeSession ? $0.at : nil }
            if uncreated.contains(launch.claudeSession) {
                launch.exists = false
            } else if !forcedFresh, created.contains(launch.claudeSession) {
                launch.exists = true
            }
            let began = ContinuousClock.now
            let p = try launchProcess(id, launch)
            let resumed = launch.continueInterrupted && launch.exists ? resuming[id] : nil
            await p.start(resumingTurn: resumed.map { $0.kind } ?? (launch.continueInterrupted ? .typed : nil),
                          resumedUUID: resumed?.uuid)
            if await p.ready() {
                lifecycle?(.launched(id, resumed: launch.exists, startup: .now - began))
                return p
            }
            // Every line it wrote is read before deciding why it died.
            if await p.exitStatus == nil { await p.kill() }
            _ = await p.waitForExit()
            if live[id] === p { live[id] = nil }
            if await p.missingSession {
                created.remove(launch.claudeSession)
                if launch.exists && !requested.exists && !forcedFresh {
                    forcedFresh = true
                    continue
                }
                throw .sessionNotFound
            }
            if launch.resumeAt != nil {
                // The CLI refused the edited prompt's resume point ("No message found"): no retry,
                // and later launches resume as before.
                rewinds[id] = nil
                throw .unavailable(p.transport.stderrTail)
            }
            attempt += 1
            guard let delay = restart.delay(beforeAttempt: attempt) else {
                throw .unavailable(p.transport.stderrTail)
            }
            publish(id, .retrying(attempt: attempt, delayMS: Int(delay.components.seconds * 1000), reason: "restarting"))
            await sleep(delay)
        }
    }

    private func launchProcess(_ id: SessionID, _ launch: SessionLaunch) throws(PoolError) -> SessionProcess {
        let transport: any ClaudeTransport
        do { transport = try makeTransport(makeSpec(launch)) } catch {
            throw .launchFailed(String(describing: error))
        }
        let pid = (transport as? ProcessTransport)?.pid
        if let pid { ledger?.record(pid) }
        let p = SessionProcess(id: id, launch: launch, transport: transport,
                               mapper: makeMapper(launch.addDirs + [launch.cwd]), hostsPermissions: hostsPermissions)
        live[id] = p
        Task { [weak self] in
            for await output in p.output {
                switch output {
                case .event(let event): await self?.publish(id, event, from: p)
                case .folded(let uuid): await self?.publishFold(id, uuid)
                }
            }
            await self?.ended(id, p, pid: pid)
        }
        return p
    }

    /// The process exited. If it died before taking a line it was sent (a crash at boot or just
    /// after), the lines go again to a restarted process; a crash mid-turn is reported, never
    /// retried: the turn may have had side effects.
    private func ended(_ id: SessionID, _ p: SessionProcess, pid: pid_t?) async {
        if let pid { ledger?.remove(pid) }
        await noteCreated(p)
        guard live[id] === p else { return }
        live[id] = nil
        let lost = await p.lostLines()
        guard !closed, await !p.stopping, !lost.isEmpty else { return }
        let gate = gate(for: id)
        await gate.enter()
        do {
            let fresh = try await process(for: id, p.launch)
            for line in lost {
                try await fresh.send(line.input, kind: line.kind, uuid: line.uuid, speak: line.speak)
            }
        } catch {
            let failure = SessionFailure(reason: .unavailable(p.transport.stderrTail), retryable: true)
            publish(id, .turnEnded(TurnEnd(kind: lost[0].kind, markdown: "", isError: true, error: failure)))
        }
        await gate.leave()
    }
}
