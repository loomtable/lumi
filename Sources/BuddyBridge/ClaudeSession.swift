import BuddyCore
import Foundation

/// What one turn sends: the text (question plus packet) and any images (the screenshot), sent
/// inline as base64 so Claude doesn't spend a tool round trip reading a file.
public struct TurnInput: Sendable, Equatable {
    public struct Image: Sendable, Equatable {
        public var data: Data
        /// `image/png`, `image/jpeg`, …
        public var mediaType: String

        public init(data: Data, mediaType: String) {
            self.data = data
            self.mediaType = mediaType
        }
    }

    public var text: String
    public var images: [Image]

    public init(text: String, images: [Image] = []) {
        self.text = text
        self.images = images
    }

    /// One `--input-format stream-json` user line, newline-terminated.
    public var streamJSONLine: Data {
        var content: [[String: Any]] = images.map { image in
            ["type": "image",
             "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text])
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
        ]
        // Only strings, arrays and dictionaries: serialization cannot fail.
        var line = (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()
        line.append(0x0A)
        return line
    }
}

/// What the UI sees during a turn.
public enum TurnEvent: Sendable, Equatable {
    /// The lane is restarting a crashed `claude` (attempt 1…3): show "Reconnecting".
    case reconnecting(attempt: Int)
    /// `system/init` for this turn: model, permission mode in effect, plugin errors.
    case initialized(StreamEvent.InitInfo)
    /// The pill's status line, from a real event (see `StatusMapper`).
    case status(String)
    /// A tool call, from the main session or a forwarded subagent (`subagent` is its parent
    /// tool_use id). Research counts phases and sources from these.
    case toolUse(StreamEvent.ToolUse, subagent: String?)
    /// A main-session tool call has started streaming its input (its full input arrives with
    /// `.toolUse`). Research shows "Writing" from here while a long report streams into Write.
    case toolStarting(name: String)
    /// A tool call's result came back; failed calls (403, missing file, denied) have `isError`.
    case toolResult(id: String, isError: Bool)
    /// Streamed answer text (main session only).
    case text(String)
    /// The first sentence of `say`, the moment it has streamed: start speaking (it
    /// sets send → first spoken word).
    case sayFirstSentence(String)
    /// All of `say`, once streamed: speak the rest after the first sentence.
    case say(String)
    case retrying(StreamEvent.APIRetry)
    case rateLimit(StreamEvent.RateLimit)
    case finished(TurnOutcome)
    case failed(BridgeError)
    /// Claude Code isn't running the way it was asked: see `PermissionNotice`. Sent before the
    /// turn's `.finished`/`.failed`, so the app can show one true line.
    case permissionNotice(PermissionNotice)
    /// A hand-off turn's open-session event the app's permission host follows: an approval or
    /// question asked, its answer, and the turn's end. The host answers it on any surface.
    case hostEvent(SessionEvent)
}

public enum PermissionNotice: Sendable, Equatable {
    /// `system/init` reports a different permission mode than the launch asked for (`auto` falls
    /// back silently when the account can't use it). Reported once per process.
    case modeDiffers(requested: String, actual: String)
    /// Tool calls Claude Code denied during the turn (`result.permission_denials`).
    case denied(tools: [String])
}

public struct TurnOutcome: Sendable, Equatable {
    public var result: StreamEvent.TurnResult
    public var extraction: BuddyBlockExtractor.Extraction
    public var timing: TurnTiming
}

/// Measured from `ask`, so handoff → Deep first token is recorded for real (M1 ask).
public struct TurnTiming: Sendable, Equatable {
    /// How long the question waited for a just-launched process to start up, before being sent.
    public var startupWait: Duration?
    public var firstEvent: Duration?
    public var firstText: Duration?
    /// When `say`'s first sentence had streamed: the first spoken word can start here.
    public var firstSentence: Duration?
    public var say: Duration?
    public var result: Duration?
}

public enum BridgeError: Error, Sendable, Equatable {
    case busy
    case processExited(status: Int32, stderr: String)
    case launchFailed(String)
    case timedOut
    case cancelled
    /// `result.is_error`: the CLI ran the turn but it failed (unknown model, API error, …).
    case turnFailed(StreamEvent.TurnResult)
    /// Restarts used up (amber chip with details).
    case unavailable(String)
    /// `--resume` named a session Claude Code no longer has (deleted or expired). The lane forgets
    /// it; the caller starts fresh with the full recap.
    case sessionNotFound
}

extension TurnEvent {
    /// The CLI exits at boot with "No conversation found with session ID: …" when `--resume` names a
    /// session it no longer has (CLI 2.1.299: a result with `errors` on stdout, the same line on
    /// stderr, exit 1, no init). Depending on timing the lane sees the result or the exit.
    var isMissingSession: Bool {
        let marker = "No conversation found with session ID"
        switch self {
        case .failed(.turnFailed(let r)): return r.errors.contains { $0.contains(marker) }
        case .failed(.processExited(_, let stderr)): return stderr.contains(marker)
        default: return false
        }
    }
}

/// One `claude` process holding one Claude Code session (S4: a process can't switch
/// sessions). Takes one turn at a time.
public actor ClaudeSession {
    public nonisolated let spec: LaunchSpec
    public private(set) var sessionID: String?
    public private(set) var lastInit: StreamEvent.InitInfo?
    public private(set) var isAlive = true
    public var isBusy: Bool { turn != nil }

    private nonisolated let transport: any ClaudeTransport
    private var turn: Turn?
    /// An interrupt in flight: the aborted turn's events are dropped until its `result`, and the next
    /// question waits for that, so it can't mistake the old result for its own.
    private var interrupt: (requestID: String, waiters: [CheckedContinuation<Void, Never>], killer: Task<Void, Never>)?
    /// How long an interrupted turn may take to end before the process is killed instead.
    private let interruptGrace: Duration
    /// The `initialize` handshake sent at launch: questions wait until `claude` has answered it,
    /// that is, until it has started up (hooks, plugins) and reads stdin.
    private var startup: (requestID: String, waiters: [CheckedContinuation<Void, Never>], timeout: Task<Void, Never>)?
    /// Longest a question waits for start-up; then it's sent anyway.
    static let startupGrace: Duration = .seconds(5)
    static let startupPrefix = "startup-"
    private var pump: Task<Void, Never>?
    private var retiring = false
    /// The mode mismatch is reported once per process, not on every turn's init.
    private var reportedModeDiffers = false
    /// Background tasks running in the session (from `background_tasks_changed`).
    private var backgroundTasks = 0

    private struct Turn {
        let id = UUID()
        let started = ContinuousClock.now
        let continuation: AsyncStream<TurnEvent>.Continuation
        var deadline: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        /// Suspending clock: time the Mac spends asleep doesn't count as the child being idle.
        var lastEvent = SuspendingClock.now
        var timing = TurnTiming()
        var say = SayStreamExtractor()
        var text = ""
        /// A result that came while background subagents were still running (2.1.296: the Agent
        /// tool backgrounds them, and the session runs a follow-up turn when they hand back).
        var heldResult: StreamEvent.TurnResult?
        /// The main session's context size at its latest API call.
        var contextTokens: Int?
        var compacted = false
        var errorCode: String?

        func elapsed() -> Duration { ContinuousClock.now - started }
    }

    public init(spec: LaunchSpec, transport: any ClaudeTransport, interruptGrace: Duration = .seconds(2)) {
        self.spec = spec
        self.transport = transport
        self.sessionID = spec.resumeSessionID
        self.interruptGrace = interruptGrace
    }

    deinit {
        transport.terminate()
        transport.closeInput()
    }

    /// Starts `claude` for `spec`. The process boots (hooks, MCP) while it waits for input.
    public static func launch(_ spec: LaunchSpec, transport make: TransportFactory = { try ProcessTransport(spec: $0) }) async throws -> ClaudeSession {
        let session = ClaudeSession(spec: spec, transport: try make(spec))
        await session.start()
        return session
    }

    /// The pump and the start-up handshake, in one hop.
    private func start() {
        startPump()
        beginStartup()
    }

    /// Asks `claude` to `initialize`; it answers once it has started up, about 0.6 s after launch
    /// (measured, 2.1.300). A question sent before then waited on that start-up inside its turn:
    /// about 1.8 s on a spare taken just after launch (Oct 15 diagnosis).
    func beginStartup(grace: Duration = ClaudeSession.startupGrace) {
        guard transport.answersStartupHandshake, startup == nil else { return }
        let id = Self.startupPrefix + UUID().uuidString
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.settleStartup()
        }
        startup = (id, [], timeout)
        let line = Self.controlLine(requestID: id, subtype: "initialize")
        Task {
            do { try await transport.send(line) } catch { settleStartup() }
        }
    }

    /// Start-up finished (any answer, even an error, means it reads stdin), failed or timed out.
    private func settleStartup() {
        guard let s = startup else { return }
        startup = nil
        s.timeout.cancel()
        for waiter in s.waiters { waiter.resume() }
    }

    func startPump() {
        guard pump == nil else { return }
        let lines = transport.lines
        // Strong self: the pump ends when the transport does, and `shutdown` guarantees that.
        pump = Task {
            for await line in lines { self.handle(line) }
            await self.transportEnded()
        }
    }

    /// Sends one turn. The stream always ends with exactly one `.finished` or `.failed`.
    /// `deadline` caps the whole turn (Quick). `inactivity` fails the turn when nothing has come
    /// back for that long (Deep: tools can run for minutes, but a child that stops reading or
    /// writing must not wedge the lane).
    public func ask(_ input: TurnInput, deadline: Duration? = nil, inactivity: Duration? = nil) async -> AsyncStream<TurnEvent> {
        // A just-launched process is still starting up: sent now, the question would wait on it.
        var startupWait: Duration?
        if startup != nil {
            let began = ContinuousClock.now
            await withCheckedContinuation { startup?.waiters.append($0) }
            startupWait = .now - began
        }
        // An interrupted turn is still ending: its result must not be read as this question's.
        if interrupt != nil { await withCheckedContinuation { interrupt?.waiters.append($0) } }
        let (stream, continuation) = AsyncStream<TurnEvent>.makeStream()
        startPump()
        guard isAlive, !retiring else {
            continuation.yield(.failed(.processExited(status: -1, stderr: transport.stderrTail)))
            continuation.finish()
            return stream
        }
        guard turn == nil else {
            continuation.yield(.failed(.busy))
            continuation.finish()
            return stream
        }
        // Esc while it waited: the question was never sent, so the warm process stays.
        if Task.isCancelled {
            continuation.yield(.failed(.cancelled))
            continuation.finish()
            return stream
        }
        var newTurn = Turn(continuation: continuation)
        newTurn.timing.startupWait = startupWait
        if let deadline {
            let id = newTurn.id
            newTurn.deadline = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled else { return }
                await self?.expire(turn: id)
            }
        }
        if let inactivity {
            let id = newTurn.id
            newTurn.watchdog = Task { [weak self] in
                var wait = inactivity
                while !Task.isCancelled {
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled, let self else { return }
                    guard let idle = await self.idleTime(turn: id) else { return }
                    if idle >= inactivity {
                        await self.expire(turn: id)
                        return
                    }
                    wait = inactivity - idle
                }
            }
        }
        turn = newTurn
        do {
            try await transport.send(input.streamJSONLine)
        } catch {
            isAlive = false
            fail(.processExited(status: -1, stderr: transport.stderrTail))
            shutdown()
        }
        return stream
    }

    /// Esc while thinking. The turn ends as `.cancelled` at once. A CLI that supports interrupts
    /// (`interrupt_receipt_v1`) is asked to stop the turn and keeps running, still warm for the next
    /// question; if it refuses, or the turn hasn't ended within `interruptGrace`, or the CLI is older,
    /// the process is killed and the lane comes back with `--resume`. Does nothing when no turn is
    /// running, so the warm process survives an Esc after the answer. Returns whether a turn was cancelled.
    @discardableResult
    public func cancel() -> Bool {
        guard turn != nil else { return false }
        fail(.cancelled)
        guard isAlive, interrupt == nil, lastInit?.capabilities.contains("interrupt_receipt_v1") == true else {
            shutdown()
            return true
        }
        let id = UUID().uuidString
        let grace = interruptGrace
        let killer = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.endInterrupt(id, kill: true)
        }
        interrupt = (id, [], killer)
        let line = Self.interruptLine(requestID: id)
        Task {
            do { try await transport.send(line) } catch { endInterrupt(id, kill: true) }
        }
        return true
    }

    static func interruptLine(requestID: String) -> Data {
        controlLine(requestID: requestID, subtype: "interrupt")
    }

    static func controlLine(requestID: String, subtype: String) -> Data {
        let request: [String: Any] = ["type": "control_request", "request_id": requestID, "request": ["subtype": subtype]]
        var line = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        line.append(0x0A)
        return line
    }

    /// The interrupted turn ended (`kill: false`), or the interrupt failed or ran out of time.
    private func endInterrupt(_ id: String, kill: Bool) {
        guard interrupt?.requestID == id else { return }
        settleInterrupt()
        if kill { shutdown() }
    }

    private func settleInterrupt() {
        guard let pending = interrupt else { return }
        interrupt = nil
        pending.killer.cancel()
        pending.waiters.forEach { $0.resume() }
    }

    /// The lane has moved on to another conversation: let a running turn finish, then stop.
    public func retire() {
        if turn == nil { shutdown() } else { retiring = true }
    }

    /// Stops the process. A running turn fails with `.cancelled`.
    public func shutdown() {
        fail(.cancelled)
        isAlive = false
        settleStartup()
        settleInterrupt()
        // Terminate first: a write blocked on a full pipe then fails with EPIPE, and the
        // queued close runs after it.
        transport.terminate()
        transport.closeInput()
    }

    private func idleTime(turn id: UUID) -> Duration? {
        guard let t = turn, t.id == id else { return nil }
        return SuspendingClock.now - t.lastEvent
    }

    private func expire(turn id: UUID) {
        guard turn?.id == id else { return }
        fail(.timedOut)
        shutdown()
    }

    private func handle(_ line: Data) {
        guard let event = StreamEvent(line: line) else { return }
        switch event {
        case .backgroundTasks(let count):
            backgroundTasks = count
        case .initialized(let info):
            lastInit = info
            if !info.sessionID.isEmpty { sessionID = info.sessionID }
        case .result(let r):
            if !r.sessionID.isEmpty { sessionID = r.sessionID }
        case .controlResponse(let id, _) where id.hasPrefix(Self.startupPrefix):
            // Even a reply after the grace: it's no event of the turn in progress.
            settleStartup()
            return
        default:
            break
        }
        if let pending = interrupt {
            switch event {
            case .controlResponse(let id, let success) where id == pending.requestID:
                if !success { endInterrupt(id, kill: true) }
            case .result:
                endInterrupt(pending.requestID, kill: false)   // the aborted turn's end; the process lives on
            default:
                break   // the rest of the aborted turn
            }
            return
        }
        guard var t = turn else { return }
        // A heartbeat isn't progress: a tool that hangs sends one every 30 s, and counting them kept
        // the inactivity watchdog from ever firing.
        if case .heartbeat = event { return }
        t.lastEvent = SuspendingClock.now
        if t.timing.firstEvent == nil { t.timing.firstEvent = t.elapsed() }

        switch event {
        case .initialized(let info):
            t.continuation.yield(.initialized(info))
            if !reportedModeDiffers, !info.permissionMode.isEmpty, info.permissionMode != spec.permissionMode {
                reportedModeDiffers = true
                t.continuation.yield(.permissionNotice(.modeDiffers(requested: spec.permissionMode, actual: info.permissionMode)))
            }
        case .partial(.blockStart(_, .toolUse(_, let name))):
            t.continuation.yield(.toolStarting(name: name))
        case .toolResults(let results):
            for r in results { t.continuation.yield(.toolResult(id: r.toolUseID, isError: r.isError)) }
        case .partial(.messageStart):
            // `say` belongs to the final message; earlier messages (before tool calls) reset.
            t.say = SayStreamExtractor()
        case .partial(.textDelta(_, let delta)):
            if t.timing.firstText == nil { t.timing.firstText = t.elapsed() }
            t.text += delta
            t.continuation.yield(.text(delta))
            for speech in t.say.append(delta) {
                switch speech {
                case .firstSentence(let sentence):
                    t.timing.firstSentence = t.elapsed()
                    t.continuation.yield(.sayFirstSentence(sentence))
                case .complete(let say):
                    t.timing.say = t.elapsed()
                    t.continuation.yield(.say(say))
                }
            }
        case .assistant(let blocks, let parent, let tokens, let error):
            for case .toolUse(let tool) in blocks { t.continuation.yield(.toolUse(tool, subagent: parent)) }
            if parent == nil, let tokens, tokens > 0 { t.contextTokens = tokens }
            // The latest main reply decides: a later normal reply clears an earlier error code.
            if parent == nil { t.errorCode = error }
        case .compactBoundary:
            t.compacted = true
        case .apiRetry(let r):
            t.continuation.yield(.retrying(r))
        case .rateLimit(let r):
            t.continuation.yield(.rateLimit(r))
        case .result(let r) where !r.isError && backgroundTasks > 0:
            // Not done: subagents are still working in the background, and the session will
            // continue on its own when they hand back. Keep the turn open.
            t.heldResult = r
            t.continuation.yield(.status(backgroundTasks == 1 ? "Waiting on a subagent" : "Waiting on \(backgroundTasks) subagents"))
            turn = t
            return
        case .result(var r):
            if (r.text ?? "").isEmpty, let held = t.heldResult { r.text = held.text }
            r.contextTokens = t.contextTokens
            r.compacted = t.compacted
            r.errorCode = t.errorCode
            t.timing.result = t.elapsed()
            if !r.deniedTools.isEmpty { t.continuation.yield(.permissionNotice(.denied(tools: r.deniedTools))) }
            turn = nil
            t.deadline?.cancel()
            t.watchdog?.cancel()
            if r.isError {
                t.continuation.yield(.failed(.turnFailed(r)))
            } else {
                // `result` holds the final message text; the streamed text also has earlier
                // messages of the turn (before tool calls).
                let extraction = BuddyBlockExtractor.extract(from: r.text ?? t.text)
                t.continuation.yield(.finished(TurnOutcome(result: r, extraction: extraction, timing: t.timing)))
            }
            t.continuation.finish()
            if retiring { shutdown() }
            return
        default:
            break
        }
        if let status = StatusMapper.status(for: event) {
            t.continuation.yield(.status(status))
        }
        turn = t
    }

    private func transportEnded() async {
        isAlive = false
        settleStartup()
        settleInterrupt()
        guard turn != nil else { return }
        let status = await transport.exitStatus()
        fail(.processExited(status: status, stderr: transport.stderrTail))
    }

    private func fail(_ error: BridgeError) {
        guard let t = turn else { return }
        turn = nil
        t.deadline?.cancel()
        t.watchdog?.cancel()
        t.continuation.yield(.failed(error))
        t.continuation.finish()
    }
}
