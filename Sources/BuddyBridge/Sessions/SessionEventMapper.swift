import BuddyCore
import Foundation

/// Turns one open session's `StreamEvent`s into UI-ready `SessionEvent`s.
///
/// Stateful and not thread-safe: one per live process, owned by that process's actor (never main).
/// It holds the turn in progress, the say extractor of a voice turn, the tool-id → step map, the
/// teammate table and the pending permission requests. Pure: no I/O and no clock.
///
/// Turn rules, from claude 2.1.312 (docs/v2-sessions 10 "Probe results"):
/// - A turn opens on the first of: the replay echo of a user line, `command_lifecycle` `started`,
///   or main-session output, and closes on `result`. A user line echoed while a turn is open is a
///   steer folded into it (no new `turnStarted`).
/// - The CLI starts turns on its own (a background agent handed back, `/compact`, a resumed
///   interrupted turn), with no echo. Such a turn takes the oldest `beginTurn` still waiting, else
///   `.typed` (a background answer is never spoken).
/// - Subagent output and task events keep arriving after `result`; they never open a turn.
public struct SessionEventMapper: Sendable {
    /// The session's directories, for `ApprovalTier.classify`.
    public var sessionDirs: [URL]

    private struct Expected: Sendable {
        var uuid: String?
        var kind: TurnKind
        var speak: Bool
    }

    private struct Turn: Sendable {
        var uuid: String?
        var kind: TurnKind
        var speak: Bool
        var say = SayStreamExtractor()
        var text = ""
        var lastStep: String?
        var contextTokens: Int?
        var errorCode: String?
    }

    private struct Teammate: Sendable {
        var name: String?
    }

    private var expected: [Expected] = []
    private var turn: Turn?
    private var lastInit: InitSummary?
    private var runState: RunState?
    private var sawPartials = false
    private var seenSteps: Set<String> = []
    /// Agent tool_use id → the name and description its input gave.
    private var agentNames: [String: String] = [:]
    /// Tool use id → tool name, to refine an edit step when its result arrives.
    private var toolNames: [String: String] = [:]
    private var teammates: [String: Teammate] = [:]
    private var pending: [String: CanUseTool] = [:]
    private var lastResetsAt: Date?

    public init(sessionDirs: [URL] = []) {
        self.sessionDirs = sessionDirs
    }

    // MARK: - Host calls

    /// Call just before writing a user line (or before `initialize` when resuming an interrupted
    /// turn with `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1`, passing the original uuid).
    /// `speak`: run the say extractor (voice turns; voice-in-page turns with "Speak answers" on).
    public mutating func beginTurn(kind: TurnKind, userUUID: String?, speak: Bool? = nil) {
        expected.append(Expected(uuid: userUUID, kind: kind, speak: speak ?? (kind == .voice)))
    }

    /// The permission request behind a pending ask, to build the reply with `PermissionWire`.
    public func request(_ id: String) -> CanUseTool? { pending[id] }

    /// Call after writing the reply to a permission request or question.
    public mutating func answered(_ id: String) -> [SessionEvent] {
        pending.removeValue(forKey: id) == nil ? [] : [.permissionResolved(id: id)]
    }

    /// The process exited. Pending asks are void; a turn still open was cut off.
    public mutating func processEnded(status: Int32) -> [SessionEvent] {
        let midTurn = turn != nil || runState == .running || runState == .requiresAction
        var out = pending.keys.sorted().map { SessionEvent.permissionResolved(id: $0) }
        pending = [:]
        turn = nil
        runState = nil
        teammates = [:]
        expected = []
        out.append(.processEnded(status: status, midTurn: midTurn))
        return out
    }

    /// True while a background teammate or job the mapper reported is still running.
    public var hasRunningTasks: Bool { !teammates.isEmpty }
    public var hasPendingRequests: Bool { !pending.isEmpty }
    public var isTurnOpen: Bool { turn != nil }

    // MARK: - Mapping

    public mutating func map(_ event: StreamEvent) -> [SessionEvent] {
        switch event {
        case .initialized(let info):
            let summary = InitSummary(
                sessionID: info.sessionID.nilIfEmpty, model: info.model.nilIfEmpty, cwd: info.cwd.nilIfEmpty,
                permissionMode: info.permissionMode.nilIfEmpty, version: info.version, capabilities: info.capabilities,
                mcpServers: info.mcpServers.map { .init(name: $0.name, status: $0.status) }, commands: info.commands)
            // init repeats every turn; report it when something changed.
            guard summary != lastInit else { return [] }
            lastInit = summary
            return [.initialized(summary)]

        case .sessionState(let raw):
            guard let state = RunState(rawValue: raw) else { return [] }
            runState = state
            return [.runState(state)]

        case .userEcho(let echo):
            return openTurn(uuid: echo.uuid.nilIfEmpty)

        case .commandLifecycle(let uuid, "started"):
            return openTurn(uuid: uuid.nilIfEmpty)

        case .partial(let partial):
            sawPartials = true
            return mapPartial(partial)

        case .assistant(let blocks, let parent, let tokens, let error):
            return mapAssistant(blocks, parent: parent, tokens: tokens, error: error)

        case .toolResults(let results):
            return results.flatMap { mapResult($0) }

        case .controlRequest(let id, .canUseTool(let ask)):
            pending[id] = ask
            if ask.toolName == "AskUserQuestion", !ask.questions.isEmpty {
                return [.questionAsked(question(id, ask))]
            }
            return [.permissionRequested(permission(id, ask))]

        case .controlCancel(let id):
            return pending.removeValue(forKey: id) == nil ? [] : [.permissionResolved(id: id)]

        case .taskStarted(let t):
            guard let kind = Self.teammateKind(t) else { return [] }
            let name = t.toolUseID.flatMap { agentNames[$0] }
            teammates[t.taskID] = Teammate(name: name)
            return [.task(.started(taskID: t.taskID, toolUseID: t.toolUseID, name: name, description: t.description, kind: kind))]

        case .taskProgress(let p):
            guard teammates[p.taskID] != nil else { return [] }
            return [.task(.progress(taskID: p.taskID, lastTool: p.lastToolName, line: p.description, steps: p.toolUses))]

        case .taskNotification(let n):
            guard teammates.removeValue(forKey: n.taskID) != nil else { return [] }
            return [.task(.ended(taskID: n.taskID, status: TaskEnd(rawValue: n.status) ?? .failed, summary: n.summary))]

        case .compactBoundary:
            return [.compacted]

        case .commandOutput(let output):
            // A slash command's output is its answer (QA S-01): one line as text, more as a block.
            var out = turn == nil ? openTurn(uuid: nil) : []
            let shown = output.contains("\n") ? "```\n\(output)\n```" : output
            if turn?.text.isEmpty == false { turn?.text += "\n\n" }
            turn?.text += shown
            out.append(.text(shown, subagent: nil))
            return out

        case .apiRetry(let r):
            return [.retrying(attempt: r.attempt, delayMS: r.retryDelayMS, reason: r.error)]

        case .rateLimit(let r):
            if r.resetsAt != nil { lastResetsAt = r.resetsAt }
            return [.rateLimit(status: r.status, resetsAt: r.resetsAt)]

        case .result(let r):
            var out = turn == nil ? openTurn(uuid: r.userMessageUUIDs.first) : []
            out.append(endTurn(r))
            return out

        case .controlRequest, .controlResponse, .commandLifecycle, .status, .backgroundTasks, .heartbeat,
             .system, .taskUpdated, .permissionDenied, .other:
            // .controlRequest of .elicitation / .other: the process replies at once (PermissionWire.autoReply).
            return []
        }
    }

    // MARK: - Turns

    private mutating func openTurn(uuid: String?) -> [SessionEvent] {
        guard turn == nil else {
            // A steer, folded into the open turn: it no longer waits for a turn of its own.
            if let uuid { expected.removeAll { $0.uuid == uuid } }
            return []
        }
        let match = uuid.flatMap { u in expected.firstIndex { $0.uuid == u } } ?? (expected.isEmpty ? nil : 0)
        let e = match.map { expected.remove(at: $0) }
        let t = Turn(uuid: e?.uuid ?? uuid, kind: e?.kind ?? .typed, speak: e?.speak ?? false)
        turn = t
        return [.turnStarted(userUUID: t.uuid, kind: t.kind)]
    }

    private mutating func endTurn(_ r: StreamEvent.TurnResult) -> SessionEvent {
        let t = turn ?? Turn(uuid: nil, kind: .typed, speak: false)
        turn = nil
        // Steers the CLI folded in no longer wait for a turn of their own.
        expected.removeAll { e in e.uuid.map(r.userMessageUUIDs.contains) ?? false }
        // A slash command's result is "": its printed output is the answer.
        let raw = r.text.flatMap { $0.isEmpty ? nil : $0 } ?? t.text
        var markdown = raw
        var block: BuddyBlock?
        if t.kind == .voice {
            let extraction = BuddyBlockExtractor.extract(from: raw)
            block = extraction.block
            markdown = extraction.prose
        }
        // The user's interrupt ends a turn with `aborted_*`: not a failure.
        let interrupted = r.terminalReason?.hasPrefix("aborted") == true
        let failed = r.isError && !interrupted
        return .turnEnded(TurnEnd(
            kind: t.kind, markdown: markdown, block: block, isError: failed,
            error: failed ? failure(r, code: t.errorCode, lastStep: t.lastStep) : nil,
            contextTokens: t.contextTokens, costUSD: r.costUSD, deniedTools: r.deniedTools))
    }

    private func failure(_ r: StreamEvent.TurnResult, code: String?, lastStep: String?) -> SessionFailure {
        let detail = code ?? r.errors.first ?? r.terminalReason ?? r.subtype
        return switch code {
        case "rate_limit": SessionFailure(reason: .rateLimited(resetsAt: lastResetsAt), lastStep: lastStep, retryable: true)
        case "authentication_failed": SessionFailure(reason: .auth, lastStep: lastStep, retryable: false)
        case "billing_error", "model_not_found": SessionFailure(reason: .api(detail), lastStep: lastStep, retryable: false)
        default: SessionFailure(reason: .api(detail), lastStep: lastStep, retryable: true)
        }
    }

    // MARK: - Output

    private mutating func mapPartial(_ p: StreamEvent.Partial) -> [SessionEvent] {
        switch p {
        case .messageStart:
            let out = turn == nil ? openTurn(uuid: nil) : []
            // `say` belongs to the final message; earlier messages (before tool calls) reset it.
            turn?.say = SayStreamExtractor()
            if turn?.text.isEmpty == false { turn?.text += "\n\n" }
            return out
        case .blockStart(_, .thinking):
            return [.thinking(summary: nil)]
        case .textDelta(_, let delta):
            var out = turn == nil ? openTurn(uuid: nil) : []
            turn?.text += delta
            out.append(.text(delta, subagent: nil))
            out += speech(delta)
            return out
        default:
            return []
        }
    }

    private mutating func mapAssistant(_ blocks: [StreamEvent.ContentBlock], parent: String?, tokens: Int?, error: String?) -> [SessionEvent] {
        var out: [SessionEvent] = []
        if parent == nil {
            if turn == nil { out += openTurn(uuid: nil) }
            if let tokens, tokens > 0 { turn?.contextTokens = tokens }
            turn?.errorCode = error
        }
        for block in blocks {
            switch block {
            case .toolUse(let tool):
                out += step(tool, subagent: parent)
            case .text(let text) where parent != nil:
                out.append(.text(text, subagent: parent))
            case .text(let text) where !sawPartials:
                // Without --include-partial-messages the whole text comes here once.
                if turn?.text.isEmpty == false { turn?.text += "\n\n" }
                turn?.text += text
                out.append(.text(text, subagent: nil))
                turn?.say = SayStreamExtractor()
                out += speech(text)
            case .thinking where !sawPartials && parent == nil:
                out.append(.thinking(summary: nil))
            default:
                break
            }
        }
        return out
    }

    private mutating func speech(_ delta: String) -> [SessionEvent] {
        guard turn?.speak == true else { return [] }
        return (turn?.say.append(delta) ?? []).map {
            switch $0 {
            case .firstSentence(let s): .sayFirstSentence(s)
            case .complete(let s): .say(s)
            }
        }
    }

    private mutating func step(_ tool: StreamEvent.ToolUse, subagent: String?) -> [SessionEvent] {
        guard seenSteps.insert(tool.id).inserted else { return [] }
        toolNames[tool.id] = tool.name
        if tool.name == "Agent" || tool.name == "Task" {
            agentNames[tool.id] = tool.input["name"] ?? tool.input["description"]
        }
        guard let d = StatusMapper.step(for: tool) else { return [] }
        if subagent == nil { turn?.lastStep = d.line }
        return [.step(TrailStep(id: tool.id, kind: Self.kind(d), verb: d.verb, object: d.object,
                                subagent: subagent, detail: Self.detail(tool)))]
    }

    private mutating func mapResult(_ r: StreamEvent.ToolResult) -> [SessionEvent] {
        guard seenSteps.contains(r.toolUseID) else { return [] }
        var out: [SessionEvent] = [.stepFinished(id: r.toolUseID, isError: r.isError, preview: r.preview)]
        // An edit's result carries the real hunks (context lines, MultiEdit): the same step again,
        // with the better diff. Consumers replace a step by id.
        if let edit = r.edit, !edit.hunks.isEmpty, let name = toolNames[r.toolUseID],
           let d = StatusMapper.step(for: .init(id: r.toolUseID, name: name, input: ["file_path": edit.path])) {
            let old = edit.hunks.flatMap { $0.lines.filter { !$0.hasPrefix("+") } }.map { String($0.dropFirst()) }
            let new = edit.hunks.flatMap { $0.lines.filter { !$0.hasPrefix("-") } }.map { String($0.dropFirst()) }
            out.append(.step(TrailStep(id: r.toolUseID, kind: Self.kind(d), verb: d.verb, object: d.object,
                                       subagent: r.parentToolUseID,
                                       detail: .diff(path: edit.path, old: old.joined(separator: "\n"), new: new.joined(separator: "\n")))))
        }
        return out
    }

    // MARK: - Asks

    private func permission(_ id: String, _ ask: CanUseTool) -> PermissionAsk {
        let input = ask.stringInput
        let file = (input["file_path"] ?? input["notebook_path"]).map { URL(fileURLWithPath: $0).lastPathComponent }
        let title: String
        let detail: PermissionDetail
        switch ask.toolName {
        case "Edit", "MultiEdit", "NotebookEdit":
            title = "Edit \(file ?? "a file")"
            detail = .diff(path: input["file_path"] ?? input["notebook_path"] ?? "", old: input["old_string"] ?? "", new: input["new_string"] ?? "")
        case "Write":
            title = "Write \(file ?? "a file")"
            detail = .diff(path: input["file_path"] ?? "", old: "", new: StreamEvent.clip(input["content"] ?? "", bytes: Self.detailLimit))
        case "Bash", "PowerShell":
            // The CLI's description already starts with a verb ("Run the tests"): use it whole.
            if let d = (ask.description ?? input["description"]).flatMap({ $0.isEmpty ? nil : $0 }) {
                title = StatusMapper.clip(d, 60)
            } else {
                title = "Run \(StatusMapper.clip(input["command"] ?? "a command", 60))"
            }
            detail = .command(input["command"] ?? "")
        case "WebFetch":
            let url = input["url"].flatMap(URL.init(string:))
            title = "Open \(url?.host() ?? "a web page")"
            detail = url.map(PermissionDetail.url) ?? .plain(input["url"] ?? "")
        default:
            let step = StatusMapper.step(for: .init(id: id, name: ask.toolName, input: input))
            title = ask.title ?? step.map { "\($0.verb) \($0.object ?? "")".trimmingCharacters(in: .whitespaces) } ?? ask.toolName
            detail = .plain(ask.description ?? ask.decisionReason ?? ask.displayName ?? ask.toolName)
        }
        // default_to_no: never a spoken yes, whatever the tool (11-REUSE §4a).
        let tier: ApprovalTier = ask.defaultToNo
            ? .needsClick
            : ApprovalTier.classify(tool: ask.toolName, input: input, sessionDirs: sessionDirs)
        return PermissionAsk(id: id, title: title, toolName: ask.toolName, detail: detail, tier: tier, asker: asker(ask))
    }

    private func question(_ id: String, _ ask: CanUseTool) -> QuestionAsk {
        QuestionAsk(id: id, items: ask.questions.map { q in
            .init(question: q.question, header: q.header ?? "", options: q.options.map { .init(label: $0.label, description: $0.description) },
                  multiSelect: q.multiSelect)
        }, asker: asker(ask))
    }

    private func asker(_ ask: CanUseTool) -> String? {
        guard let agent = ask.agentID else { return nil }
        return teammates[agent]?.name ?? "Teammate"
    }

    // MARK: - Pure helpers

    static let detailLimit = 8 * 1024

    /// Teammates are subagents; a background shell the main session started is a background job.
    /// Foreground Bash and a subagent's own Bash also emit task events, and are neither.
    static func teammateKind(_ t: StreamEvent.TaskStarted) -> TaskKind? {
        switch t.taskType {
        case TaskKind.agent.rawValue: .agent
        case TaskKind.remote.rawValue: .remote
        case TaskKind.bash.rawValue where t.isBackgrounded && t.parentTaskID == nil: .bash
        default: nil
        }
    }

    /// A transcript line's tool steps and results, mapped as the live stream maps them, for a lane
    /// read back from a subagent's JSONL file. `lane`: the teammate's Agent tool use id.
    public static func historyEvents(_ event: StreamEvent, lane: String?) -> [SessionEvent] {
        switch event {
        case .assistant(let blocks, _, _, _):
            return blocks.compactMap { block -> SessionEvent? in
                guard case .toolUse(let tool) = block, let d = StatusMapper.step(for: tool) else { return nil }
                return .step(TrailStep(id: tool.id, kind: kind(d), verb: d.verb, object: d.object, subagent: lane, detail: detail(tool)))
            }
        case .toolResults(let results):
            return results.map { .stepFinished(id: $0.toolUseID, isError: $0.isError, preview: $0.preview) }
        default:
            return []
        }
    }

    static func kind(_ d: StepDescription) -> StepKind {
        switch d.kind {
        case .read: .read
        case .search: .search
        case .edit: .edit
        case .write: .write
        case .bash: .bash
        case .web: .web
        case .mcp: .mcp(server: d.mcpServer ?? d.object ?? "")
        case .agent: .agent
        case .plan: .plan
        case .ask: .ask
        case .screen: .screen
        case .other: .other
        }
    }

    static func detail(_ tool: StreamEvent.ToolUse) -> StepDetail? {
        let input = tool.input
        switch tool.name {
        case "Edit":
            guard let old = input["old_string"], let new = input["new_string"] else { return nil }
            return .diff(path: input["file_path"], old: old, new: new)
        case "Write":
            guard let content = input["content"] else { return nil }
            return .diff(path: input["file_path"], old: "", new: StreamEvent.clip(content, bytes: detailLimit))
        case "Bash", "PowerShell":
            guard let command = input["command"] else { return nil }
            return .command(description: input["description"], command: command)
        case "TodoWrite":
            let todos = raw(tool)?.objects("todos").compactMap { t -> StepDetail.Todo? in
                guard let content = t.string("content") else { return nil }
                return .init(content: content, state: t.string("status").flatMap(StepDetail.Todo.State.init(rawValue:)) ?? .pending)
            }
            return todos.map(StepDetail.todos)
        case "AskUserQuestion":
            let items = raw(tool)?.objects("questions").map { q in
                QuestionAsk.Item(question: q.string("question") ?? "", header: q.string("header") ?? "",
                                 options: q.objects("options").map { .init(label: $0.string("label") ?? "", description: $0.string("description")) },
                                 multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            return items.map { .question(QuestionAsk(id: tool.id, items: $0)) }
        default:
            return nil
        }
    }

    private static func raw(_ tool: StreamEvent.ToolUse) -> [String: Any]? {
        tool.rawInput.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}

extension SessionEvent {
    /// Merges adjacent `.text` events of the same lane, for delivering one batch per frame.
    public static func coalesce(_ events: [SessionEvent]) -> [SessionEvent] {
        var out: [SessionEvent] = []
        for e in events {
            if case .text(let next, let lane) = e, case .text(let prev, let prevLane)? = out.last, lane == prevLane {
                out[out.count - 1] = .text(prev + next, subagent: lane)
            } else {
                out.append(e)
            }
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
