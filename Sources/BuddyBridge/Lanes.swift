import BuddyCore
import Foundation

/// Crash restarts: after a crash, restart attempts wait 1 s, 2 s and 5 s; when the
/// third restart also fails, the lane reports `.unavailable` (the amber chip).
public struct RestartPolicy: Sendable, Equatable {
    public var delays: [Duration]

    public init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]) {
        self.delays = delays
    }

    /// The wait before restart attempt `attempt` (1-based); nil once attempts are used up.
    public func delay(beforeAttempt attempt: Int) -> Duration? {
        attempt >= 1 && attempt <= delays.count ? delays[attempt - 1] : nil
    }
}

public typealias TransportFactory = @Sendable (LaunchSpec) throws -> any ClaudeTransport

/// FIFO mutual exclusion across awaits. Lanes pick and launch sessions under it, so two
/// questions can't both take the spare or both replace the live process.
actor AsyncGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard locked else {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// Thrown by a lane's session picker after `shutdown()`.
struct LaneClosed: Error {}

/// Runs one question through a lane: pick or launch the session (under the gate), send, and
/// forward events. If `claude` dies before answering anything (a crash at boot: logged out,
/// broken flag, missing plugin), it restarts with backoff and sends again, showing
/// `.reconnecting`. A crash mid-turn is reported, not retried: the turn may have had side
/// effects, and the CLI writes no result for it. Cancelling the running Task (Esc) stops it at
/// any point: in backoff, waiting for the gate, launching, or answering.
struct LaneDriver: Sendable {
    let gate: AsyncGate
    let restart: RestartPolicy

    func run(input: TurnInput, deadline: Duration?, inactivity: Duration?,
             to out: AsyncStream<TurnEvent>.Continuation,
             forgetSession: @Sendable () async -> Void = {},
             select: @Sendable (_ afterCrash: Bool) async throws -> ClaudeSession) async {
        func cancelled() {
            out.yield(.failed(.cancelled))
            out.finish()
        }
        var attempt = 0
        while true {
            if Task.isCancelled { return cancelled() }
            if attempt > 0 {
                guard let wait = restart.delay(beforeAttempt: attempt) else {
                    out.yield(.failed(.unavailable("Claude Code stopped \(attempt) times in a row")))
                    out.finish()
                    return
                }
                out.yield(.reconnecting(attempt: attempt))
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return cancelled() }
            }
            await gate.enter()
            if Task.isCancelled {
                await gate.leave()
                return cancelled()
            }
            let session: ClaudeSession
            do {
                session = try await select(attempt > 0)
            } catch is LaneClosed {
                await gate.leave()
                return cancelled()
            } catch {
                await gate.leave()
                attempt += 1
                continue
            }
            // The send happens outside the gate: a child that stops reading stdin must not
            // block other questions, and the session itself refuses a second turn.
            await gate.leave()
            let events = await session.ask(input, deadline: deadline, inactivity: inactivity)
            if Task.isCancelled { await session.cancel() }

            var answered = false
            var bootCrash = false
            var ended = false
            // Iteration also stops when this Task is cancelled (Esc, or the caller dropped the stream).
            for await event in events {
                // A resumed session that no longer exists: retrying the same ID can only fail again.
                if !answered, event.isMissingSession {
                    await forgetSession()
                    out.yield(.failed(.sessionNotFound))
                    out.finish()
                    return
                }
                if case .failed(.processExited) = event, !answered, !Task.isCancelled {
                    bootCrash = true
                    continue
                }
                answered = true
                switch event {
                case .finished, .failed: ended = true
                default: break
                }
                out.yield(event)
            }
            if Task.isCancelled, !ended {
                await session.cancel()
                return cancelled()
            }
            guard bootCrash else {
                out.finish()
                return
            }
            attempt += 1
        }
    }
}

/// The per-conversation bookkeeping both lanes share: the running question's Task (so Esc can
/// stop it anywhere) and sessions retired mid-answer (so cancel and shutdown still reach them).
struct LaneBook {
    var drivers: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    var retired: [(conversation: String, session: ClaudeSession)] = []
    var isShutDown = false
}

/// The Quick lane: Haiku in the home folder.
///
/// One process holds one session, so the lane keeps the current conversation's process plus a
/// spare that has already booted, for the next new conversation (⌘N). Earlier conversations
/// come back with `--resume <quickSessionId>`, a cold start of about 0.7 s (S4). A process that
/// dies while idle is replaced on the next question.
public actor QuickLane {
    private var baseSpec: LaunchSpec
    /// Sessions whose process `reload` retired: the conversation's next turn resumes them in a
    /// process from the new spec.
    private var resumeAfterReload: [String: String] = [:]
    /// A conversation whose question was running at `reload`: its process is retired when that
    /// question ends, so a turn between picking its session and sending isn't cut off.
    private var reloadWhenIdle: Set<String> = []
    private let makeTransport: TransportFactory
    private let driver: LaneDriver
    private var spare: ClaudeSession?
    private var active: (conversation: String, session: ClaudeSession)?
    private var book = LaneBook()
    private var idle: IdleTimer
    /// False on a Mac with little memory: no spare beside the current process once a question
    /// ends, and none relaunched after one is taken (`prewarm` on the buddy key brings it back).
    private let keepSpare: Bool

    /// `idleAfter`: with no question for this long, the spare and the current process stop (the
    /// conversation resumes its session next time; `prewarm` brings a spare back). Nil keeps them.
    public init(spec: LaunchSpec, restart: RestartPolicy = RestartPolicy(),
                transport: @escaping TransportFactory = { try ProcessTransport(spec: $0) },
                idleAfter: Duration? = nil, keepSpare: Bool = true,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.baseSpec = spec.resuming(nil)
        self.makeTransport = transport
        self.driver = LaneDriver(gate: AsyncGate(), restart: restart)
        self.idle = IdleTimer(after: idleAfter, sleep: sleep)
        self.keepSpare = keepSpare
    }

    /// Boots the spare. Call at app launch; the lane calls it again after taking the spare.
    public func prewarm() async {
        idle.cancel()   // a countdown already waiting at the gate mustn't stop this spare
        await driver.gate.enter()
        let spareAlive = await spare?.isAlive ?? false
        if !spareAlive, !book.isShutDown {
            spare = try? await ClaudeSession.launch(baseSpec, transport: makeTransport)
        }
        await driver.gate.leave()
        if book.drivers.isEmpty { armIdle() }
    }

    /// Little memory: the question is over, so the spare launched on its key press goes.
    private func dropSpare() async {
        await driver.gate.enter()
        if book.drivers.isEmpty {
            await spare?.shutdown()
            spare = nil
        }
        await driver.gate.leave()
    }

    private func armIdle() {
        idle.arm { [weak self] g in await self?.idleExpired(g) }
    }

    /// No question for `idleAfter`: free the processes. Nothing relaunches until `prewarm` or a turn.
    private func idleExpired(_ g: Int) async {
        await driver.gate.enter()
        if idle.isCurrent(g), book.drivers.isEmpty, !book.isShutDown {
            await spare?.shutdown()
            spare = nil
            if let current = active { await retireForReload(current) }
        }
        await driver.gate.leave()
    }

    /// Sends a turn for a conversation. `resumeSessionID` is the conversation's stored
    /// quickSessionId, nil for a new conversation. Cancelling the task that iterates the stream
    /// cancels the question.
    public func ask(conversation: String, resumeSessionID: String?, input: TurnInput,
                    deadline: Duration? = .seconds(60)) -> AsyncStream<TurnEvent> {
        let (stream, out) = AsyncStream<TurnEvent>.makeStream()
        let id = UUID()
        let driver = driver
        idle.cancel()
        let task = Task {
            await driver.run(input: input, deadline: deadline, inactivity: nil, to: out,
                             forgetSession: { await self.forgetSession(of: conversation) }) { afterCrash in
                try await self.session(for: conversation, resumeSessionID: resumeSessionID, afterCrash: afterCrash)
            }
            await self.driverFinished(conversation: conversation, id: id)
        }
        book.drivers[conversation] = (id, task)
        out.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Claude Code no longer has the conversation's session: drop the process holding it and any
    /// pending resume, so the next turn can't come back to it.
    private func forgetSession(of conversation: String) async {
        if let current = active, current.conversation == conversation {
            await current.session.shutdown()
            active = nil
        }
        resumeAfterReload[conversation] = nil
    }

    /// The Claude Code session the conversation's Quick turns run in, once known.
    public func sessionID(for conversation: String) async -> String? {
        guard let active, active.conversation == conversation else { return nil }
        return await active.session.sessionID
    }

    /// The conversation's next turn goes to the process that ran its last one. False when a new
    /// process will resume the session (crash, reload, another conversation in between): then
    /// nothing is assumed from the history it reloads.
    public func isLive(conversation: String) async -> Bool {
        guard let active, active.conversation == conversation, !reloadWhenIdle.contains(conversation),
              resumeAfterReload[conversation] == nil else { return false }
        return await active.session.isAlive
    }

    /// Esc: stops the conversation's question wherever it is.
    public func cancel(conversation: String) async {
        book.drivers[conversation]?.task.cancel()
        if let active, active.conversation == conversation { await active.session.cancel() }
        for r in book.retired where r.conversation == conversation { await r.session.cancel() }
    }

    /// Settings › Models or "Repair plugin": every Quick process restarts from `spec` (nil keeps
    /// the current spec, for a fresh plugin). The current conversation's process is retired, so
    /// an answer in flight finishes; its next turn resumes the same session in a new process.
    /// The spare is replaced at once.
    public func reload(spec: LaunchSpec? = nil) async {
        await driver.gate.enter()
        if let spec { baseSpec = spec.resuming(nil) }
        await spare?.shutdown()
        spare = nil
        if let current = active {
            if book.drivers[current.conversation] != nil {
                reloadWhenIdle.insert(current.conversation)
            } else {
                await retireForReload(current)
            }
        }
        if !book.isShutDown {
            spare = try? await ClaudeSession.launch(baseSpec, transport: makeTransport)
        }
        await driver.gate.leave()
        if book.drivers.isEmpty { armIdle() }
    }

    /// Called under the gate only.
    private func retireForReload(_ current: (conversation: String, session: ClaudeSession)) async {
        if let id = await current.session.sessionID { resumeAfterReload[current.conversation] = id }
        await current.session.retire()
        book.retired.append(current)
        active = nil
    }

    public func shutdown() async {
        book.isShutDown = true
        idle.cancel()
        for d in book.drivers.values { d.task.cancel() }
        await driver.gate.enter()
        await spare?.shutdown()
        await active?.session.shutdown()
        for r in book.retired { await r.session.shutdown() }
        spare = nil
        active = nil
        book.retired = []
        await driver.gate.leave()
    }

    private func driverFinished(conversation: String, id: UUID) async {
        guard book.drivers[conversation]?.id == id else { return }
        book.drivers[conversation] = nil
        if book.drivers.isEmpty { armIdle() }
        if !keepSpare, book.drivers.isEmpty { await dropSpare() }
        guard reloadWhenIdle.remove(conversation) != nil else { return }
        await driver.gate.enter()
        if let current = active, current.conversation == conversation, book.drivers[conversation] == nil {
            await retireForReload(current)
        }
        await driver.gate.leave()
    }

    /// Called under the gate only.
    private func session(for conversation: String, resumeSessionID: String?, afterCrash: Bool) async throws -> ClaudeSession {
        guard !book.isShutDown else { throw LaneClosed() }
        await pruneRetired()
        // A reload waiting for this conversation's last question: its next turn moves now.
        if reloadWhenIdle.remove(conversation) != nil, let current = active, current.conversation == conversation {
            await retireForReload(current)
        }
        if let current = active, current.conversation == conversation {
            if await current.session.isAlive { return current.session }
            // Crashed or cancelled: come back in the same Claude Code session.
            let resume = await current.session.sessionID ?? resumeSessionID
            return try await launch(conversation: conversation, resume: resume)
        }
        if let previous = active {
            // Let the other conversation's answer finish; its process stops afterwards.
            await previous.session.retire()
            book.retired.append(previous)
            active = nil
        }
        let reloaded = resumeAfterReload[conversation]
        let resumeSessionID = resumeSessionID ?? reloaded
        if resumeSessionID == nil, !afterCrash, let warm = spare, await warm.isAlive {
            spare = nil
            active = (conversation, warm)
            if keepSpare { Task { await self.prewarm() } }
            return warm
        }
        let session = try await launch(conversation: conversation, resume: resumeSessionID)
        // Dropped only once a process is running it, so a failed launch's retry still resumes.
        resumeAfterReload[conversation] = nil
        return session
    }

    private func pruneRetired() async {
        var keep: [(conversation: String, session: ClaudeSession)] = []
        for r in book.retired where await r.session.isAlive { keep.append(r) }
        book.retired = keep
    }

    private func launch(conversation: String, resume: String?) async throws -> ClaudeSession {
        let session = try await ClaudeSession.launch(baseSpec.resuming(resume), transport: makeTransport)
        active = (conversation, session)
        return session
    }
}

/// The Deep lane: Opus in the resolved project folder.
///
/// Decided after S4: Deep starts only on handoff (never at summon) and there is no
/// pool. The lane keeps the last conversation's Deep process alive for its follow-ups and
/// replaces it for any other conversation or folder. It only takes a `DeepFolder`, which only
/// `FolderTrust` makes.
public actor DeepLane {
    /// No stream event for this long fails the turn. Tools can run quietly for minutes; a child
    /// that has stopped reading or writing must not hold the lane forever.
    public static let defaultInactivity: Duration = .seconds(600)

    private let makeSpec: @Sendable (_ folder: URL, _ resume: String?) -> LaunchSpec
    private let makeTransport: TransportFactory
    private let driver: LaneDriver
    private let inactivity: Duration
    private var live: (conversation: String, folder: DeepFolder, session: ClaudeSession)?
    private var book = LaneBook()
    /// Sessions `reload` retired, resumed by that conversation's next turn in the same folder.
    private var resumeAfterReload: [String: (folder: DeepFolder, session: String)] = [:]
    /// A conversation whose question was running at `reload` (see QuickLane).
    private var reloadWhenIdle: Set<String> = []
    private var idle: IdleTimer
    /// Told when the lane goes from idle to answering (true) and back (false).
    private let onBusy: (@Sendable (Bool) async -> Void)?
    /// Each signal waits for the one before, so they arrive in the order the lane changed.
    private var busyTail: Task<Void, Never>?

    /// `idleAfter`: with no question for this long, the Deep process stops (200–400 MB); the next
    /// hand-off resumes the conversation's session. Nil keeps it.
    public init(spec makeSpec: @escaping @Sendable (_ folder: URL, _ resume: String?) -> LaunchSpec,
                restart: RestartPolicy = RestartPolicy(), inactivity: Duration = DeepLane.defaultInactivity,
                transport: @escaping TransportFactory = { try ProcessTransport(spec: $0) },
                idleAfter: Duration? = nil,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                onBusy: (@Sendable (Bool) async -> Void)? = nil) {
        self.makeSpec = makeSpec
        self.makeTransport = transport
        self.inactivity = inactivity
        self.driver = LaneDriver(gate: AsyncGate(), restart: restart)
        self.idle = IdleTimer(after: idleAfter, sleep: sleep)
        self.onBusy = onBusy
    }

    /// `resumeSessionID` is the conversation's deepSessionId. Timing in the outcome starts at
    /// the send, so it includes the cold start a handoff pays (the pill shows "Handing to Deep").
    public func ask(conversation: String, folder: DeepFolder, resumeSessionID: String?,
                    input: TurnInput) -> AsyncStream<TurnEvent> {
        let (stream, out) = AsyncStream<TurnEvent>.makeStream()
        let id = UUID()
        let driver = driver, inactivity = inactivity
        idle.cancel()
        if book.drivers.isEmpty { signalBusy(true) }
        let task = Task {
            await driver.run(input: input, deadline: nil, inactivity: inactivity, to: out,
                             forgetSession: { await self.forgetSession(of: conversation) }) { _ in
                try await self.session(conversation: conversation, folder: folder, resume: resumeSessionID)
            }
            await self.driverFinished(conversation: conversation, id: id)
        }
        book.drivers[conversation] = (id, task)
        out.onTermination = { _ in task.cancel() }
        return stream
    }

    /// See `QuickLane.forgetSession(of:)`.
    private func forgetSession(of conversation: String) async {
        if let current = live, current.conversation == conversation {
            await current.session.shutdown()
            live = nil
        }
        resumeAfterReload[conversation] = nil
    }

    public func sessionID(for conversation: String) async -> String? {
        guard let live, live.conversation == conversation else { return nil }
        return await live.session.sessionID
    }

    /// See `QuickLane.isLive`; Deep's process is also per folder.
    public func isLive(conversation: String, folder: DeepFolder) async -> Bool {
        guard let live, live.conversation == conversation, live.folder == folder, !reloadWhenIdle.contains(conversation),
              resumeAfterReload[conversation] == nil else { return false }
        return await live.session.isAlive
    }

    public func cancel(conversation: String) async {
        book.drivers[conversation]?.task.cancel()
        if let live, live.conversation == conversation { await live.session.cancel() }
        for r in book.retired where r.conversation == conversation { await r.session.cancel() }
    }

    /// Settings › Models or "Repair plugin": the live Deep process is retired (an answer in
    /// flight finishes), and the conversation's next handoff resumes its session in a process
    /// from the spec closure, which reads the current settings.
    public func reload() async {
        await driver.gate.enter()
        if let current = live {
            if book.drivers[current.conversation] != nil {
                reloadWhenIdle.insert(current.conversation)
            } else {
                await retireForReload(current)
            }
        }
        await driver.gate.leave()
    }

    /// Called under the gate only.
    private func retireForReload(_ current: (conversation: String, folder: DeepFolder, session: ClaudeSession)) async {
        if let id = await current.session.sessionID {
            resumeAfterReload[current.conversation] = (current.folder, id)
        }
        await current.session.retire()
        book.retired.append((current.conversation, current.session))
        live = nil
    }

    public func shutdown() async {
        book.isShutDown = true
        idle.cancel()
        for d in book.drivers.values { d.task.cancel() }
        await driver.gate.enter()
        await live?.session.shutdown()
        for r in book.retired { await r.session.shutdown() }
        live = nil
        book.retired = []
        await driver.gate.leave()
    }

    private func driverFinished(conversation: String, id: UUID) async {
        guard book.drivers[conversation]?.id == id else { return }
        book.drivers[conversation] = nil
        if book.drivers.isEmpty {
            idle.arm { [weak self] g in await self?.idleExpired(g) }
            signalBusy(false)
        }
        guard reloadWhenIdle.remove(conversation) != nil else { return }
        await driver.gate.enter()
        if let current = live, current.conversation == conversation, book.drivers[conversation] == nil {
            await retireForReload(current)
        }
        await driver.gate.leave()
    }

    /// Queued behind the previous signal, without suspending, so a question ending as another
    /// starts can't deliver its `false` after the new `true`.
    private func signalBusy(_ busy: Bool) {
        guard let onBusy else { return }
        let previous = busyTail
        busyTail = Task {
            await previous?.value
            await onBusy(busy)
        }
    }

    /// No question for `idleAfter`: the Deep process stops; the next hand-off resumes its session.
    private func idleExpired(_ g: Int) async {
        await driver.gate.enter()
        if idle.isCurrent(g), book.drivers.isEmpty, !book.isShutDown, let current = live { await retireForReload(current) }
        await driver.gate.leave()
    }

    /// Called under the gate only.
    private func session(conversation: String, folder: DeepFolder, resume: String?) async throws -> ClaudeSession {
        guard !book.isShutDown else { throw LaneClosed() }
        var keep: [(conversation: String, session: ClaudeSession)] = []
        for r in book.retired where await r.session.isAlive { keep.append(r) }
        book.retired = keep
        if reloadWhenIdle.remove(conversation) != nil, let current = live, current.conversation == conversation {
            await retireForReload(current)
        }
        if let current = live, current.conversation == conversation, current.folder == folder {
            if await current.session.isAlive { return current.session }
            let resumeID = await current.session.sessionID ?? resume
            return try await launch(conversation: conversation, folder: folder, resume: resumeID)
        }
        if let previous = live {
            await previous.session.retire()
            book.retired.append((previous.conversation, previous.session))
            live = nil
        }
        var resume = resume
        if let reloaded = resumeAfterReload[conversation], reloaded.folder == folder {
            resume = resume ?? reloaded.session
        }
        let session = try await launch(conversation: conversation, folder: folder, resume: resume)
        // Another folder's session is never resumed; either way the entry is used up.
        resumeAfterReload[conversation] = nil
        return session
    }

    private func launch(conversation: String, folder: DeepFolder, resume: String?) async throws -> ClaudeSession {
        let session = try await ClaudeSession.launch(makeSpec(folder.url, resume), transport: makeTransport)
        live = (conversation, folder, session)
        return session
    }
}

/// One idle countdown per lane: armed when the last question ends, cancelled by the next one.
/// Each arm or cancel starts a new generation; a countdown whose expiry waited at the gate while
/// that happened sees `isCurrent` false and does nothing. Lane actor state.
struct IdleTimer {
    private let after: Duration?
    private let sleep: @Sendable (Duration) async -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(after: Duration?, sleep: @escaping @Sendable (Duration) async -> Void) {
        self.after = after
        self.sleep = sleep
    }

    mutating func arm(_ fire: @escaping @Sendable (Int) async -> Void) {
        cancel()
        guard let after else { return }
        let sleep = sleep, current = generation
        task = Task {
            await sleep(after)
            guard !Task.isCancelled else { return }
            await fire(current)
        }
    }

    mutating func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }

    func isCurrent(_ g: Int) -> Bool { g == generation }
}
