import AppKit
import BuddyCore
import Foundation

/// The capsule's phase. Every phase comes from a real tool event.
public enum ResearchPhase: String, Sendable, Equatable, Codable {
    /// Before the first tool call.
    case planning
    /// Web search calls.
    case searching
    /// Fetches, file reads and browser page loads.
    case reading
    /// Writing the report file.
    case writing
}

public enum ResearchState: Sendable, Equatable {
    case queued
    case running
    case done
    case failed(String)
    case cancelled
}

/// One research job as the capsule and the conversation index see it.
public struct ResearchJob: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let conversationID: String
    public let topic: String
    /// Markdown report the job writes, under Application Support/<bundle id>/reports. If the
    /// agent created its report under another name in that folder (with Write, successfully),
    /// this points there once done.
    public internal(set) var reportPath: URL
    public internal(set) var state: ResearchState = .queued
    public internal(set) var phase: ResearchPhase = .planning
    /// Distinct URLs fetched and files read so far ("Reading · 14 sources").
    public internal(set) var sourceCount = 0
    /// The live steps for the capsule's peek, newest last (at most `ResearchTracker.maxSteps`).
    public internal(set) var steps: [String] = []
    /// The Claude Code session, once the job has started (persisted by the conversation index).
    public internal(set) var sessionID: String?
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    /// The finished job's spoken line ("Your research on QT is ready").
    public internal(set) var say: String?
    /// The finished job's whole `buddy` block (rich, a findings summary): what opening the
    /// report from the capsule shows. Nil when the job ended without a valid block.
    public internal(set) var block: BuddyBlock?
    /// Claude Code crashed and the job is restarting ("Reconnecting").
    public internal(set) var reconnecting = false
    /// When the manager last confirmed this job's state after the Mac woke (after a
    /// full system sleep the capsule shows whether it finished).
    public internal(set) var checkedAt: Date?
}

/// Folds tool events into phase, sources and steps. Pure, so the capsule mapping is unit-tested
/// (every phase, count and progress value shown must come from a stream event).
///
/// - Planning until the first tool call; Searching on web searches; Reading on fetches, file and
///   browser page reads; Writing as soon as a Write or Edit starts streaming its input (a long
///   report streams for minutes inside that call).
/// - A source counts once its call succeeds: a 404, a denied fetch or a missing file isn't read.
public struct ResearchTracker: Sendable {
    public static let maxSteps = 20
    public let reportPath: String
    /// Paths that aren't research sources: Claude Code's own files, the plugin.
    public let ignoredPrefixes: [String]
    public private(set) var phase: ResearchPhase = .planning
    public private(set) var sources: Set<String> = []
    public private(set) var steps: [String] = []
    /// Reports the job created with Write directly in its folder (the agent may pick another name).
    /// Never project files: an edited README must not become "Report ready". With today's launch
    /// rules only `reportPath` is writable, so this is a fallback in case they ever widen.
    public private(set) var writtenReports: [String] = []
    public let reportsDir: String
    private var pending: [String: String] = [:]        // tool_use id → source it reads
    private var pendingWrites: [String: String] = [:]  // tool_use id → report it creates

    public init(reportPath: String, reportsDir: String? = nil, ignoredPrefixes: [String] = []) {
        self.reportPath = reportPath
        self.reportsDir = reportsDir ?? (reportPath as NSString).deletingLastPathComponent
        self.ignoredPrefixes = ignoredPrefixes
    }

    /// A tool's input has started streaming (main session).
    @discardableResult
    public mutating func starting(_ name: String) -> Bool {
        guard ["Write", "Edit", "MultiEdit"].contains(name), phase != .writing else { return false }
        phase = .writing
        return true
    }

    /// A complete tool call. Returns true when anything the capsule shows changed.
    @discardableResult
    public mutating func record(_ tool: StreamEvent.ToolUse) -> Bool {
        let before = phase
        let input = tool.input
        switch tool.name {
        case "WebSearch":
            phase = .searching
        case "WebFetch":
            phase = .reading
            if let url = input["url"].flatMap(Self.normalizedURL) { pending[tool.id] = url }
        case "Read":
            if let path = input["file_path"], path != reportPath, !ignoredPrefixes.contains(where: path.hasPrefix) {
                phase = .reading
                pending[tool.id] = path
            }
        case "Write", "Edit", "MultiEdit":
            phase = .writing
            if tool.name == "Write", let path = input["file_path"], path.hasSuffix(".md"),
               (path as NSString).deletingLastPathComponent == reportsDir {
                pendingWrites[tool.id] = path
            }
        default:
            // Browser tools (Playwright, Claude in Chrome) loading a page count as reading it.
            if tool.name.hasPrefix("mcp__"), tool.name.hasSuffix("navigate"),
               let url = input["url"].flatMap(Self.normalizedURL) {
                phase = .reading
                pending[tool.id] = url
            }
        }
        var stepAdded = false
        if let line = StatusMapper.status(for: tool) {
            steps.append(line)
            if steps.count > Self.maxSteps { steps.removeFirst(steps.count - Self.maxSteps) }
            stepAdded = true
        }
        return stepAdded || before != phase
    }

    /// A tool result: a successful read becomes a source.
    @discardableResult
    public mutating func result(id: String, isError: Bool) -> Bool {
        if let path = pendingWrites.removeValue(forKey: id), !isError {
            writtenReports.removeAll { $0 == path }
            writtenReports.append(path)
        }
        guard let source = pending.removeValue(forKey: id), !isError else { return false }
        return sources.insert(source).inserted
    }

    /// The same page with a different fragment, a trailing slash or http/https is one source.
    static func normalizedURL(_ string: String) -> String? {
        guard var c = URLComponents(string: string), c.scheme != nil, let host = c.host, !host.isEmpty else { return nil }
        c.fragment = nil
        c.scheme = c.scheme == "http" ? "https" : c.scheme?.lowercased()
        c.host = host.lowercased()
        if c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path == "/" { c.path = "" }
        return c.string
    }
}

/// Keeps the Mac from idle-sleeping while research runs; the display may still sleep (a job keeps
/// running through display sleep).
public protocol SleepGuard: Sendable {
    func begin(reason: String) -> any Sendable
    func end(_ token: any Sendable)
}

public struct ProcessInfoSleepGuard: SleepGuard {
    public init() {}

    public func begin(reason: String) -> any Sendable {
        ActivityToken(ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason))
    }

    public func end(_ token: any Sendable) {
        if let token = token as? ActivityToken { ProcessInfo.processInfo.endActivity(token.object) }
    }

    /// `beginActivity` returns an opaque NSObjectProtocol; it is only handed back to
    /// `endActivity`, never used across threads otherwise.
    struct ActivityToken: @unchecked Sendable {
        let object: any NSObjectProtocol
        init(_ object: any NSObjectProtocol) { self.object = object }
    }
}

/// Tells the manager the Mac woke from a full system sleep.
public protocol WakeSource: Sendable {
    func wakes() -> AsyncStream<Void>
}

/// `NSWorkspace.didWakeNotification`.
public struct WorkspaceWakeSource: WakeSource {
    public init() {}

    public func wakes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in continuation.yield() }
            let box = ObserverToken(token)
            continuation.onTermination = { _ in NSWorkspace.shared.notificationCenter.removeObserver(box.token) }
        }
    }

    /// The observer token is only handed back to `removeObserver`.
    struct ObserverToken: @unchecked Sendable {
        let token: any NSObjectProtocol
        init(_ token: any NSObjectProtocol) { self.token = token }
    }
}

/// What a research request carries.
public struct ResearchRequest: Sendable, Equatable {
    public var conversationID: String
    public var topic: String
    public var packet: ContextPacket

    public init(conversationID: String, topic: String, packet: ContextPacket) {
        self.conversationID = conversationID
        self.topic = topic
        self.packet = packet
    }
}

/// Runs Research jobs: a separate `claude -p` each, at most two at a time, the rest queued,
/// cancellable. Every change goes to each `subscribe()` stream (capsule, index).
public actor ResearchManager {
    public static let maxConcurrent = 2
    /// Jobs running at once: `maxConcurrent`, or 1 on a Mac with little memory.
    private let concurrent: Int
    private var held = false
    /// Finished jobs kept for the capsule and conversation list.
    public static let keepFinished = 50
    /// No stream event for this long fails the job (measured without system sleep, so a job
    /// survives the Mac sleeping). A hung child must not hold a slot or keep the Mac awake.
    public static let inactivity: Duration = .seconds(1800)

    private var subscribers: [UUID: AsyncStream<ResearchJob>.Continuation] = [:]
    private let makeSpec: @Sendable (_ jobDir: URL, _ reportPath: URL, _ resume: String?) -> LaunchSpec
    private let makeTransport: TransportFactory
    private let reportsDir: URL
    private let sleepGuard: any SleepGuard
    private let fileExists: @Sendable (URL) -> Bool
    private let createDirectory: @Sendable (URL) throws -> Void
    private let restart: RestartPolicy
    private let ignoredPrefixes: [String]
    private var jobs: [UUID: ResearchJob] = [:]
    private var order: [UUID] = []
    private var requests: [UUID: ResearchRequest] = [:]
    private var running: [UUID: (session: ClaudeSession?, task: Task<Void, Never>)] = [:]
    private var guardToken: (any Sendable)?
    /// Set once at the end of `init`; a box so the nonisolated init and deinit can reach it.
    private nonisolated let wakeTask = Shared<Task<Void, Never>?>(nil)

    /// Research never runs in a project: it reads arbitrary web pages, so each job runs in its own
    /// folder under `reportsDir` with no shell and no file access beyond it. `spec` builds that
    /// launch from the job folder and report path (`LaunchSpec.research`). `ignoredPrefixes`:
    /// paths whose reads aren't sources (e.g. `~/.claude/`, the plugin folder).
    public init(reportsDir: URL,
                spec makeSpec: @escaping @Sendable (_ jobDir: URL, _ reportPath: URL, _ resume: String?) -> LaunchSpec,
                sleepGuard: any SleepGuard = ProcessInfoSleepGuard(),
                wake: any WakeSource = WorkspaceWakeSource(),
                restart: RestartPolicy = RestartPolicy(),
                maxConcurrent: Int = ResearchManager.maxConcurrent,
                ignoredPrefixes: [String] = [],
                fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                createDirectory: @escaping @Sendable (URL) throws -> Void = {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                },
                transport: @escaping TransportFactory = { try ProcessTransport(spec: $0) }) {
        self.reportsDir = reportsDir
        self.makeSpec = makeSpec
        self.sleepGuard = sleepGuard
        self.restart = restart
        self.concurrent = max(1, maxConcurrent)
        self.ignoredPrefixes = ignoredPrefixes
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.makeTransport = transport
        let wakes = wake.wakes()
        let task = Task { [weak self] in
            for await _ in wakes {
                guard let self else { return }
                await self.checkAfterWake()
            }
        }
        wakeTask.withLock { $0 = task }
    }

    deinit { wakeTask.withLock { $0?.cancel() } }

    /// After a full system sleep: republishes every running job with `checkedAt = now`, so the
    /// capsule redraws. It changes no state and checks nothing else; a job whose process died
    /// while the Mac slept is settled when its stream ends, as at any other time.
    func checkAfterWake(now: Date = Date()) {
        for id in running.keys {
            guard var job = jobs[id] else { continue }
            job.checkedAt = now
            update(job)
        }
    }

    /// Every job change, for one consumer (the capsule, the conversation index…); each
    /// subscriber gets all updates. Starts with the current jobs.
    public func subscribe() -> AsyncStream<ResearchJob> {
        let (stream, continuation) = AsyncStream<ResearchJob>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        for job in all { continuation.yield(job) }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Queues a job and starts it when a slot is free. Returns the job as queued.
    public func start(_ request: ResearchRequest, now: Date = Date()) -> ResearchJob {
        let id = UUID()
        let job = ResearchJob(id: id, conversationID: request.conversationID, topic: request.topic,
                              reportPath: Self.jobDirectory(reportsDir, id).appendingPathComponent(Self.reportName(topic: request.topic, date: now, id: id)))
        jobs[id] = job
        order.append(id)
        requests[id] = request
        update(job)
        startQueued()
        return job
    }

    /// "stop research": every queued or running job of the conversation.
    public func cancelAll(conversation: String) async {
        // Queued first, without suspending, so stopping a running job can't start one of them.
        let mine = all.filter { $0.conversationID == conversation }
        for job in mine where job.state == .queued { cancelQueued(job.id) }
        for job in mine where job.state == .running { await cancel(job.id) }
    }

    private func cancelQueued(_ id: UUID) {
        guard var job = jobs[id], job.state == .queued else { return }
        job.state = .cancelled
        job.finishedAt = Date()
        requests[id] = nil
        update(job)
        prune()
    }

    public func cancel(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        switch job.state {
        case .queued:
            cancelQueued(id)
        case .running:
            let task = running[id]?.task
            task?.cancel()
            await running[id]?.session?.shutdown()
            // Return only once the job has settled (finish has run), so callers see a stable state.
            await task?.value
        default:
            break
        }
    }

    public func job(_ id: UUID) -> ResearchJob? { jobs[id] }
    public var all: [ResearchJob] { order.compactMap { jobs[$0] } }

    /// The prompt: the packet, the topic, and where the report goes.
    static func prompt(_ request: ResearchRequest, reportPath: URL) -> String {
        BuddyPrompt.body(request.packet) + """

        <research>\(BuddyPrompt.escape(request.topic))</research>
        Research this thoroughly. Use subagents to read sources in parallel. Write the report as \
        Markdown with the Write tool to exactly this path (it contains spaces): `\(reportPath.path)`. \
        Cite each source by URL or path. Then end with the buddy block: `shape` rich, `say` naming \
        what is ready, `card_html` with at most 5 bullets of findings.
        """
    }

    static let resumePrompt = "Claude Code restarted. Continue the research where you left off and finish the report at the same path."

    /// Each job's own folder: its working directory, the only place it can read, and where its
    /// report goes. Jobs can't see or overwrite each other's files.
    static func jobDirectory(_ reportsDir: URL, _ id: UUID) -> URL {
        reportsDir.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    static func reportName(topic: String, date: Date, id: UUID) -> String {
        let stamp = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let words = topic.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        var slug = ""
        for word in String(words).split(separator: " ").prefix(6) {
            let next = slug.isEmpty ? String(word) : slug + "-" + word
            if next.utf8.count > 60 { break }
            slug = next
        }
        if slug.isEmpty, let first = String(words).split(separator: " ").first {
            // One word longer than the cap: keep whole characters up to 60 bytes.
            for ch in first where slug.utf8.count + String(ch).utf8.count <= 60 { slug.append(ch) }
        }
        return "\(stamp)-\(slug.isEmpty ? "research" : slug)-\(id.uuidString.prefix(6).lowercased()).md"
    }

    /// Little memory: while a Deep question runs, queued jobs wait (running ones carry on), so
    /// Deep and Research rarely hold memory side by side. Never the other way round.
    public func setHeld(_ held: Bool) {
        self.held = held
        if !held { startQueued() }
    }

    private func startQueued() {
        while !held, running.count < concurrent,
              let next = order.first(where: { jobs[$0]?.state == .queued }) {
            launch(next)
        }
        holdSleepGuard()
    }

    private func launch(_ id: UUID) {
        guard var job = jobs[id], let request = requests[id] else { return }
        job.state = .running
        job.startedAt = Date()
        update(job)
        let reportPath = job.reportPath
        running[id] = (nil, Task {
            await self.run(id: id, request: request, reportPath: reportPath)
        })
    }

    private func run(id: UUID, request: ResearchRequest, reportPath: URL) async {
        do {
            try createDirectory(reportPath.deletingLastPathComponent())
        } catch {
            return finish(id, .failed("Couldn't create the reports folder: \(error.localizedDescription)"))
        }
        let jobDir = reportPath.deletingLastPathComponent()
        var tracker = ResearchTracker(reportPath: reportPath.path, reportsDir: jobDir.path, ignoredPrefixes: ignoredPrefixes)
        var input = TurnInput(text: Self.prompt(request, reportPath: reportPath))
        var attempt = 0
        var restarts = 0
        while true {
            if Task.isCancelled { return finish(id, .cancelled) }
            let session: ClaudeSession
            do {
                session = try await ClaudeSession.launch(makeSpec(jobDir, reportPath, jobs[id]?.sessionID),
                                                         transport: makeTransport)
            } catch {
                return finish(id, .failed("Claude Code didn't start: \(error.localizedDescription)"))
            }
            running[id]?.session = session
            if Task.isCancelled {
                await session.shutdown()
                return finish(id, .cancelled)
            }
            var outcome: ResearchState?
            var crashed = false
            for await event in await session.ask(input, inactivity: Self.inactivity) {
                guard var job = jobs[id] else { break }
                var changed = false
                if job.reconnecting, Self.isProgress(event) {
                    // Back after a restart and making progress again (not just started: a child
                    // that crashes right after init must still run out of restarts).
                    job.reconnecting = false
                    attempt = 0
                    changed = true
                }
                switch event {
                case .initialized(let info) where !info.sessionID.isEmpty && job.sessionID != info.sessionID:
                    job.sessionID = info.sessionID
                    changed = true
                case .toolStarting(let name):
                    changed = tracker.starting(name)
                case .toolUse(let tool, _):
                    changed = tracker.record(tool)
                case .toolResult(let toolID, let isError):
                    changed = tracker.result(id: toolID, isError: isError)
                case .finished(let result):
                    if let written = reportFile(expected: reportPath, tracker: tracker) {
                        job.reportPath = written
                        job.say = result.extraction.block?.say
                        job.block = result.extraction.block
                        outcome = .done
                    } else {
                        outcome = .failed("The job finished without writing its report.")
                    }
                    changed = true
                case .failed(.cancelled):
                    outcome = .cancelled
                case .failed(.processExited) where job.sessionID != nil:
                    crashed = true
                case .failed(let error):
                    outcome = .failed(Self.describe(error))
                default:
                    break
                }
                if changed {
                    job.phase = tracker.phase
                    job.sourceCount = tracker.sources.count
                    job.steps = tracker.steps
                    update(job)
                }
            }
            await session.shutdown()
            if Task.isCancelled, outcome != .done { return finish(id, .cancelled) }
            if crashed {
                // restart with backoff; the session resumes with what it had read.
                attempt += 1
                restarts += 1
                guard restarts <= Self.maxTotalRestarts, let wait = restart.delay(beforeAttempt: attempt) else {
                    return finish(id, .failed("Claude Code stopped \(restarts) times while researching."))
                }
                if var job = jobs[id] {
                    job.reconnecting = true
                    update(job)
                }
                try? await Task.sleep(for: wait)
                input = TurnInput(text: Self.resumePrompt)
                continue
            }
            return finish(id, outcome ?? .cancelled)
        }
    }

    /// The report: at the path given, or else a report the job created in the reports folder.
    private func reportFile(expected: URL, tracker: ResearchTracker) -> URL? {
        if fileExists(expected) { return expected }
        return tracker.writtenReports.reversed().map { URL(fileURLWithPath: $0) }.first(where: fileExists)
    }

    /// Progress after a restart: a tool call that succeeded. Streamed text doesn't count (a
    /// resumed turn says something at once), nor does a failed or denied call.
    static func isProgress(_ event: TurnEvent) -> Bool {
        switch event {
        case .toolResult(_, isError: false), .finished: true
        default: false
        }
    }

    /// Restarts allowed per job in total, however much progress happens in between: a job that
    /// crashes the same way every time must still end.
    public static let maxTotalRestarts = 6

    static func describe(_ error: BridgeError) -> String {
        switch error {
        case .timedOut: "The job stopped responding for 30 minutes."
        case .turnFailed(let r): r.apiErrorStatus.map { "Claude Code reported an error (\($0))." } ?? "Claude Code reported an error."
        case .processExited(let status, _): "Claude Code exited (status \(status)) before the job started."
        case .launchFailed(let message): "Claude Code didn't start: \(message)"
        case .unavailable(let message): message
        case .busy, .cancelled: "The job was interrupted."
        case .sessionNotFound: "Claude Code no longer has this job's session."
        }
    }

    private func finish(_ id: UUID, _ state: ResearchState) {
        if var job = jobs[id] {
            job.state = state
            job.finishedAt = Date()
            job.reconnecting = false
            update(job)
        }
        running[id] = nil
        requests[id] = nil
        startQueued()
        prune()
    }

    private func update(_ job: ResearchJob) {
        jobs[job.id] = job
        for continuation in subscribers.values { continuation.yield(job) }
    }

    /// Keeps the newest finished jobs; queued and running ones always stay.
    private func prune() {
        let finished = order.filter { id in
            switch jobs[id]?.state {
            case .done?, .failed?, .cancelled?: true
            default: false
            }
        }
        for id in finished.dropLast(Self.keepFinished) {
            jobs[id] = nil
            order.removeAll { $0 == id }
        }
    }

    private func holdSleepGuard() {
        if running.isEmpty, let token = guardToken {
            sleepGuard.end(token)
            guardToken = nil
        } else if !running.isEmpty, guardToken == nil {
            guardToken = sleepGuard.begin(reason: "Lumi research")
        }
    }
}

extension LaunchSpec {
    /// The Research lane: the plugin's buddy-research agent, Opus at max effort, subagent output
    /// forwarded so their reads count as sources.
    ///
    /// It reads arbitrary web pages, so a page could try to steer it (prompt injection). Each job
    /// runs in its own folder and can reach only the web and that folder:
    /// - `--restricted`: no command-running tools, no user/project/local settings files (so none
    ///   of the user's allow rules or hooks), file tools confined to the working directory,
    ///   bypassPermissions refused (so no agent can escalate); `--tools` names the six it gets;
    /// - permission mode `dontAsk`: anything not allowed is denied, with no prompt;
    /// - allowed: web search and fetch, general-purpose subagents (which inherit these rules),
    ///   Read in the job folder, and Edit/Write of the job's report file only (Write is governed
    ///   by Edit rules; `//` anchors an absolute path); denied outright: Bash, NotebookEdit, and
    ///   writing CLAUDE.md, CLAUDE.local.md or .claude/ anywhere it could be loaded from;
    /// - no MCP servers, no skills (the buddy rules are appended), no auto memory.
    /// What still loads: Claude Code's own system prompt, the user's CLAUDE.md files from home and
    /// above the job folder (their own instructions; read-only to the job), and the buddy plugin.
    public static func research(executable: URL, jobDir: URL, reportPath: URL, plugin: URL, resume: String? = nil,
                                config: ModeConfig = .default(for: .research),
                                environment: [String: String]) -> LaunchSpec {
        var spec = LaunchSpec(executable: executable, workingDirectory: jobDir, mode: .research, config: config,
                              pluginDirectory: plugin, resumeSessionID: resume, agent: "buddy:buddy-research",
                              appendSystemPromptFile: buddyAnswerSkill(in: plugin),
                              settings: researchSettings(jobDir: jobDir, reportPath: reportPath),
                              permissionMode: "dontAsk", environment: environment)
        spec.appendSystemPrompt = AnswerRules.text(for: [.quick, .deep], in: plugin)   // all of it, as before the split
        spec.strictMCPConfig = true
        spec.restricted = true
        spec.tools = researchTools
        spec.disableSlashCommands = true
        return spec
    }

    static let researchTools = ["WebSearch", "WebFetch", "Read", "Write", "Edit", "Agent"]

    static func researchSettings(jobDir: URL, reportPath: URL) -> String {
        let job = "/" + jobDir.path, reports = "/" + jobDir.deletingLastPathComponent().path
        var deny = ["Bash", "NotebookEdit"]
        for dir in [job, reports] {
            deny += ["Edit(\(dir)/CLAUDE.md)", "Edit(\(dir)/CLAUDE.local.md)", "Edit(\(dir)/.claude/**)"]
        }
        let settings: [String: Any] = [
            "permissions": [
                "allow": ["WebSearch", "WebFetch", "Agent(general-purpose)", "Read(\(job)/**)", "Edit(/\(reportPath.path))"],
                "deny": deny,
            ],
            "autoMemoryEnabled": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
