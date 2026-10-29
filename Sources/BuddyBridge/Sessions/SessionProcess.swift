import BuddyCore
import Foundation

/// What `SessionProcess` drives on the session's event mapper: `SessionEventMapper`
/// (engine-control), or a test double.
protocol SessionEventMapping: Sendable {
    /// Just before a user line is written (or before `initialize` when resuming an interrupted turn).
    mutating func beginTurn(kind: TurnKind, userUUID: String?, speak: Bool?)
    /// The permission request behind a pending ask.
    func request(_ id: String) -> CanUseTool?
    /// After the reply to a permission request or question was written.
    mutating func answered(_ id: String) -> [SessionEvent]
    /// The process exited.
    mutating func processEnded(status: Int32) -> [SessionEvent]
    var hasRunningTasks: Bool { get }
    var hasPendingRequests: Bool { get }
    var isTurnOpen: Bool { get }
    mutating func map(_ event: StreamEvent) -> [SessionEvent]
}

typealias MapperFactory = @Sendable (_ sessionDirs: [URL]) -> any SessionEventMapping

extension SessionEventMapper: SessionEventMapping {}

/// A live `claude` process holding one open Claude session: always reading, with a control channel
/// both ways. Unlike `ClaudeSession` it has no one-turn-per-stream model: an open session emits
/// events after `result` (background teammates, a turn the CLI starts on its own), and a control
/// request can arrive mid-turn. Every line is parsed and mapped on this actor, never on main.
actor SessionProcess {
    nonisolated let id: SessionID
    nonisolated let launch: SessionLaunch
    /// What the process tells the pool, in stream order.
    enum Output: Sendable, Equatable {
        case event(SessionEvent)
        /// The CLI took this line into a turn already running: what follows answers it too.
        case folded(uuid: String)
    }

    /// The mapped stream, for the pool to fan out. Finishes after `.processEnded`.
    nonisolated let output: AsyncStream<Output>
    nonisolated let transport: any ClaudeTransport

    private let out: AsyncStream<Output>.Continuation
    private var mapper: any SessionEventMapping
    /// Whether permission prompts reach the user; off, they're denied at once with a note.
    private let hostsPermissions: @Sendable () -> Bool
    private let interruptGrace: Duration
    private let batchWindow: Duration

    private(set) var runState: RunState?
    /// A user line was written and the session hasn't reported `idle` since.
    private(set) var turnInFlight = false
    /// The CLI reports `session_state_changed` (it may not, on an older CLI).
    private var sawRunState = false
    /// User lines written whose replay echo hasn't come back: lost if the process dies now.
    private var unechoed: [Written] = []
    /// Lines the mapper was told about.
    private var begun: Set<String> = []
    /// A Continue: the CLI resumes the interrupted turn with no user line; its `result` ends it.
    private var resumingInterrupted = false
    /// Teammates and background jobs reported started and not yet ended (from the mapped events).
    private var openTasks: [String] = []
    /// `system/init` arrived: the Claude session exists on disk from here on.
    private(set) var initialized = false
    /// A boot that failed on `--resume` of a session the CLI no longer has.
    private(set) var missingSession = false
    private(set) var exitStatus: Int32?
    /// Asked to stop (suspend, absorb, quit): its end is no crash.
    private(set) var stopping = false

    private var startup: (requestID: String, waiters: [CheckedContinuation<Void, Never>], timeout: Task<Void, Never>)?
    /// How start-up ended: answered, timed out while running (both true), or the process died.
    private var startedUp: Bool?
    /// Control requests Lumi sent. With `--replay-user-messages` the CLI also echoes Lumi's own
    /// replies to *its* requests; a `control_response` for any other id is ignored.
    private var sent: Set<String> = []
    private var interruptKiller: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var batch: [SessionEvent] = []
    private var flush: Task<Void, Never>?

    struct Written: Sendable, Equatable {
        var uuid: String
        var input: TurnInput
        var kind: TurnKind
        var speak: Bool?
    }

    static let startupGrace: Duration = .seconds(5)
    static let startupPrefix = "startup-"
    static let missingSessionMarker = "No conversation found with session ID"
    static let hostOffMessage = "Lumi isn't taking permission prompts yet, so this was declined."

    init(id: SessionID, launch: SessionLaunch, transport: any ClaudeTransport, mapper: any SessionEventMapping,
         hostsPermissions: @escaping @Sendable () -> Bool, interruptGrace: Duration = .seconds(2),
         batchWindow: Duration = .milliseconds(16)) {
        self.id = id
        self.launch = launch
        self.transport = transport
        self.mapper = mapper
        self.hostsPermissions = hostsPermissions
        self.interruptGrace = interruptGrace
        self.batchWindow = batchWindow
        (output, out) = AsyncStream<Output>.makeStream()
    }

    /// Starts reading and the `initialize` handshake. `resumingTurn`: the kind of the interrupted
    /// turn a Continue resumes (the CLI picks it up as soon as `initialize` is written).
    func start(resumingTurn: TurnKind? = nil, resumedUUID: String? = nil) {
        guard pump == nil else { return }
        let lines = transport.lines
        pump = Task {
            for await line in lines { self.handle(line) }
            await self.transportEnded()
        }
        emit([.launched(resumed: launch.exists)])
        if let kind = resumingTurn, launch.exists, launch.continueInterrupted {
            mapper.beginTurn(kind: kind, userUUID: resumedUUID, speak: nil)
            turnInFlight = true
            resumingInterrupted = true
        }
        beginStartup()
    }

    private func beginStartup() {
        guard transport.answersStartupHandshake else { return }
        let requestID = Self.startupPrefix + UUID().uuidString
        let grace = Self.startupGrace
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.settleStartup(nil)
        }
        startup = (requestID, [], timeout)
        sent.insert(requestID)
        let line = ClaudeSession.controlLine(requestID: requestID, subtype: "initialize")
        Task { do { try await transport.send(line) } catch { settleStartup(false) } }
    }

    /// `answered`: true when `claude` answered, false when it died; nil on the grace running out.
    private func settleStartup(_ answered: Bool?) {
        guard let s = startup else { return }
        startup = nil
        startedUp = answered ?? (exitStatus == nil)
        s.timeout.cancel()
        s.waiters.forEach { $0.resume() }
    }

    /// Waits until `claude` has started up (answered `initialize`), exited, or the grace ran out.
    /// True while it's still running.
    func ready() async -> Bool {
        if startup != nil { await withCheckedContinuation { startup?.waiters.append($0) } }
        return (startedUp ?? true) && exitStatus == nil
    }

    var isAlive: Bool { exitStatus == nil && !stopping }

    // MARK: - Input

    /// Writes one user line with Lumi's uuid. `speak`: run the say extractor (nil: voice turns only).
    func send(_ input: TurnInput, kind: TurnKind, uuid: String, speak: Bool? = nil, priority: String? = nil) async throws(PoolError) {
        guard exitStatus == nil, !stopping else { throw .notLive }
        // The mapper hears of the turn only when the CLI takes the line (`takeLine`): a turn the CLI
        // starts on its own before that must not be given this line's uuid and kind (QA R20).
        unechoed.append(Written(uuid: uuid, input: input, kind: kind, speak: speak))
        turnInFlight = true
        do {
            try await transport.send(Self.userLine(input, uuid: uuid, priority: priority))
        } catch {
            throw .notLive
        }
    }

    /// The CLI took one of our lines: now the mapper may open (or fold) its turn.
    private func takeLine(_ uuid: String) {
        guard let line = unechoed.first(where: { $0.uuid == uuid }), begun.insert(uuid).inserted else { return }
        mapper.beginTurn(kind: line.kind, userUUID: uuid, speak: line.speak)
    }

    /// Lines written that the CLI never took (no echo): safe to send again after a crash at boot.
    func lostLines() -> [Written] { unechoed }

    /// Stops the running turn: the `interrupt` control request, then SIGTERM if it hasn't ended
    /// within the grace (SIGTERM alone leaves the turn with no result).
    func interrupt() async {
        guard exitStatus == nil, turnInFlight || runState == .running || runState == .requiresAction else { return }
        let requestID = "interrupt-" + UUID().uuidString
        sent.insert(requestID)
        let grace = interruptGrace
        interruptKiller?.cancel()
        interruptKiller = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.kill()
        }
        do { try await transport.send(ClaudeSession.controlLine(requestID: requestID, subtype: "interrupt")) } catch { kill() }
    }

    /// Answers a pending permission prompt. False when it isn't pending (answered, withdrawn).
    @discardableResult
    func answer(_ requestID: String, _ decision: PermissionDecision) async -> Bool {
        guard let request = mapper.request(requestID) else { return false }
        return await reply(requestID, PermissionWire.response(requestID, decision, for: request))
    }

    /// Answers AskUserQuestion: the chosen labels per question text.
    @discardableResult
    func answer(_ requestID: String, answers: [String: [String]]) async -> Bool {
        guard let request = mapper.request(requestID) else { return false }
        return await reply(requestID, PermissionWire.answers(requestID, answers, for: request))
    }

    private func reply(_ requestID: String, _ line: Data) async -> Bool {
        do { try await transport.send(line) } catch { return false }
        emit(mapper.answered(requestID))
        return true
    }

    /// Stops one teammate or background job.
    func stopTask(_ taskID: String) async {
        let requestID = "stop-" + UUID().uuidString
        sent.insert(requestID)
        try? await transport.send(Self.controlLine(requestID: requestID, ["subtype": "stop_task", "task_id": taskID]))
    }

    // MARK: - Stopping

    /// Suspends an idle process: closes stdin, then SIGTERM if it hasn't exited within `grace`.
    func suspend(grace: Duration = .seconds(1)) async {
        guard exitStatus == nil else { return }
        stopping = true
        transport.closeInput()
        let waiter = Task { await self.waitForExit() }
        let killer = Task { [transport] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            transport.terminate()
        }
        _ = await waiter.value
        killer.cancel()
    }

    /// SIGTERM now (the pool already interrupted, or the process must go).
    func kill() {
        stopping = true
        interruptKiller?.cancel()
        transport.terminate()
        transport.closeInput()
    }

    func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// The lead's own turn is open: a line not yet taken, a turn the mapper has open, or a resumed
    /// turn on its way. Teammates still working after the lead's answer don't count (QA R22).
    var leadTurnOpen: Bool { mapper.isTurnOpen || !unechoed.isEmpty || resumingInterrupted }

    func facts(pinned: Bool, onScreen: Bool) -> SuspendFacts {
        SuspendFacts(runState: runState, turnInFlight: turnInFlight, openTasks: mapper.hasRunningTasks ? 1 : 0,
                     pendingPermissions: mapper.hasPendingRequests ? 1 : 0, pinned: pinned, onScreen: onScreen)
    }

    // MARK: - Output

    private func handle(_ line: Data) {
        guard let event = StreamEvent(line: line) else { return }
        switch event {
        case .controlResponse(let requestID, let success):
            guard sent.remove(requestID) != nil else { return }   // the CLI echoing our own reply
            if requestID.hasPrefix(Self.startupPrefix) { settleStartup(true) }
            if requestID.hasPrefix("interrupt-"), !success { kill() }
            return
        case .controlRequest(let requestID, let request):
            if case .canUseTool(let ask) = request, !hostsPermissions() {
                let deny = PermissionWire.response(requestID, .deny(message: Self.hostOffMessage), for: ask)
                Task { try? await transport.send(deny) }
                return
            }
            // Elicitations are declined (no form UI yet) and any other subtype gets an error reply at
            // once: an unanswered request waits forever (02 §D8.2).
            if let reply = PermissionWire.autoReply(id: requestID, request: request) {
                Task { try? await transport.send(reply) }
                return
            }
        case .sessionState(let raw):
            sawRunState = true
            runState = RunState(rawValue: raw) ?? runState
            if runState == .idle {
                // Not while a line we wrote waits to be taken: an idle from the turn before it can
                // land in between, and a sweep would then suspend the session with that line unsent.
                // The result path has the same rule.
                if unechoed.isEmpty { turnInFlight = false }
                // A Continue that found nothing to resume (QA R22): the CLI went idle with no turn.
                if resumingInterrupted, !mapper.isTurnOpen { resumingInterrupted = false }
                interruptKiller?.cancel()
            }
        case .userEcho(let echo):
            if mapper.isTurnOpen, unechoed.contains(where: { $0.uuid == echo.uuid }) {
                // What streamed before the line isn't its answer: send it on its own.
                flushBatch()
                out.yield(.folded(uuid: echo.uuid))
            }
            takeLine(echo.uuid)
            unechoed.removeAll { $0.uuid == echo.uuid }
        case .commandLifecycle(let uuid, "started"):
            takeLine(uuid)
        case .initialized:
            initialized = true
        case .result(let r):
            // A result naming our line answers it, even if its echo never came.
            if !mapper.isTurnOpen { r.userMessageUUIDs.forEach(takeLine) }
            // Named in a result: taken, even with no echo, so no longer waiting to be.
            unechoed.removeAll { r.userMessageUUIDs.contains($0.uuid) }
            if r.errors.contains(where: { $0.contains(Self.missingSessionMarker) }) {
                // No turn: the CLI refused the resume at boot. The pool reports it as session_not_found.
                missingSession = true
                return
            }
            // An older CLI without session-state events: the result is all there is. A resumed turn
            // ends at its result too: nothing of ours is waiting (QA E2).
            if (!sawRunState || resumingInterrupted), !mapper.hasRunningTasks, unechoed.isEmpty {
                turnInFlight = false
                resumingInterrupted = false
            }
            if !sawRunState { interruptKiller?.cancel() }
        default:
            break
        }
        emit(mapper.map(event))
    }

    private func transportEnded() async {
        let status = await transport.exitStatus()
        if transport.stderrTail.contains(Self.missingSessionMarker) { missingSession = true }
        exitStatus = status
        settleStartup(false)
        interruptKiller?.cancel()
        // Teammates die with the process: they show as "didn't finish", not as still working.
        emit(openTasks.map { .task(.ended(taskID: $0, status: .stopped, summary: Self.didntFinish)) })
        emit(mapper.processEnded(status: status))
        flushBatch()
        out.finish()
        exitWaiters.forEach { $0.resume(returning: status) }
        exitWaiters = []
    }

    /// Text deltas are batched for up to one frame; anything else flushes them first, so order holds.
    static let didntFinish = "Didn't finish"

    private func emit(_ events: [SessionEvent]) {
        for event in events {
            switch event {
            case .task(.started(let taskID, _, _, _, _)): if !openTasks.contains(taskID) { openTasks.append(taskID) }
            case .task(.ended(let taskID, _, _)): openTasks.removeAll { $0 == taskID }
            default: break
            }
            if case .text = event {
                batch.append(event)
                if flush == nil {
                    let window = batchWindow
                    flush = Task { [weak self] in
                        try? await Task.sleep(for: window)
                        await self?.flushBatch()
                    }
                }
            } else {
                flushBatch()
                out.yield(.event(event))
            }
        }
    }

    private func flushBatch() {
        flush?.cancel()
        flush = nil
        guard !batch.isEmpty else { return }
        for event in SessionEvent.coalesce(batch) { out.yield(.event(event)) }
        batch = []
    }

    // MARK: - Lines

    /// One stream-json user line carrying Lumi's uuid (echoed back by `--replay-user-messages`).
    /// `priority: "now"` aborts the running tool and runs the line as its own turn (probe 4).
    static func userLine(_ input: TurnInput, uuid: String, priority: String? = nil) -> Data {
        var content: [[String: Any]] = input.images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": input.text])
        var message: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
        ]
        if let priority { message["priority"] = priority }
        var line = (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()
        line.append(0x0A)
        return line
    }

    static func controlLine(requestID: String, _ request: [String: Any]) -> Data {
        let object: [String: Any] = ["type": "control_request", "request_id": requestID, "request": request]
        var line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        line.append(0x0A)
        return line
    }

}
