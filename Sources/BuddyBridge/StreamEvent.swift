import Foundation

/// One line of Claude Code's `--output-format stream-json`, reduced to what the bridge uses.
///
/// Shapes were recorded from claude 2.1.296 and 2.1.312 (fixtures under
/// `Tests/BuddyBridgeTests/Fixtures`; open-session findings in docs/v2-sessions 10 "Probe results"). Unknown types and subtypes decode to `.other` so a newer
/// CLI never breaks the stream.
public enum StreamEvent: Sendable, Equatable {
    /// `system/init`. Sent ~30 ms after the first stdin message (not at spawn), then again on
    /// every turn with refreshed MCP status and tools.
    case initialized(InitInfo)
    /// `system/status`, e.g. "requesting".
    case status(String)
    /// `system/api_retry`.
    case apiRetry(APIRetry)
    /// `stream_event` (needs `--include-partial-messages`). Main session only.
    case partial(Partial)
    /// A complete assistant message. `parentToolUseID` is set for forwarded subagent output.
    /// `contextTokens`: what that API call read (input + cache read + cache write), i.e. the
    /// session's context size at that point.
    /// `error`: Claude Code's code for a failed turn, on its synthetic reply (`authentication_failed`,
    /// `rate_limit`, `overloaded`, `model_not_found`, `billing_error`, …); nil normally.
    case assistant(blocks: [ContentBlock], parentToolUseID: String?, contextTokens: Int? = nil, error: String? = nil)
    /// Tool results fed back to the model.
    case toolResults([ToolResult])
    case rateLimit(RateLimit)
    /// End of a turn. Check `isError`, not `subtype`: an unknown model reports `success`.
    case result(TurnResult)
    /// `system/background_tasks_changed`: background tasks (subagents the Agent tool started in
    /// the background) still running. A turn isn't over while this is above zero.
    case backgroundTasks(count: Int)
    /// `tool_progress` with `heartbeat: true`: a tool is still running, sent every 30 s whether or
    /// not it is getting anywhere (a stdio MCP tool that never replies sends them for ~28 h).
    case heartbeat
    /// Any other `system` subtype (hook_started, thinking_tokens, commands_changed, …).
    case system(subtype: String)
    /// `control_response`: the CLI's answer to a control request we wrote (an interrupt).
    /// With `--replay-user-messages` the CLI also echoes our own responses to *its* requests, so
    /// match `requestID` against ids we sent.
    case controlResponse(requestID: String, success: Bool)
    /// `control_request` from the CLI: a permission prompt (`--permission-prompt-tool stdio`), an
    /// MCP elicitation, or a subtype we don't handle (answer those with `PermissionWire.error`).
    case controlRequest(id: String, request: ControlRequest)
    /// `control_cancel_request`: the CLI withdrew its own pending request. Drop the card; no reply.
    case controlCancel(requestID: String)
    /// `system/session_state_changed` (`CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1`): `idle`, `running`
    /// or `requires_action`. Repeats; treat each as the current state.
    case sessionState(String)
    /// `system/task_started`. Foreground Bash emits these too (`local_bash`, not backgrounded).
    case taskStarted(TaskStarted)
    case taskProgress(TaskProgress)
    /// `system/task_updated`: a status patch (`completed`, …) ahead of the notification.
    case taskUpdated(taskID: String, status: String?)
    case taskNotification(TaskNotification)
    /// `system/compact_boundary`: earlier turns are now a summary.
    case compactBoundary(Compaction)
    /// A user line echoed by `--replay-user-messages` (`isReplay: true`): our message as delivered.
    /// A steer written mid-turn echoes when the CLI takes it (at the next tool boundary).
    case userEcho(UserEcho)
    /// `command_lifecycle`: one user message's progress (`queued`, `started`, `completed`, `cancelled`).
    case commandLifecycle(uuid: String, state: String)
    /// `system/permission_denied`: a prompt nobody could answer (no permission host).
    case permissionDenied(PermissionDenial)
    /// A slash command's printed output (`/context`, `/cost`, `/compact`…): a replayed user line
    /// whose string content wraps it in `<local-command-stdout>` or `<local-command-stderr>`.
    case commandOutput(String)
    case other(type: String)

    public struct InitInfo: Sendable, Equatable {
        public var sessionID: String
        public var model: String
        public var cwd: String
        /// The mode actually in effect. `auto` silently falls back when unavailable.
        public var permissionMode: String
        public var version: String?
        /// Absent in the stream when there are none; empty here.
        public var pluginErrors: [PluginError]
        public var plugins: [String]
        public var mcpServers: [MCPServer]
        /// Features this CLI supports (`interrupt_receipt_v1`, …); empty on CLIs before 2.1.205.
        public var capabilities: [String] = []
        /// What `/` can run in this session: `slash_commands` and `skills`, by name.
        public var commands: [String] = []
    }

    public struct PluginError: Sendable, Equatable {
        public var plugin: String
        public var type: String
        public var message: String
        public var path: String?
    }

    public struct MCPServer: Sendable, Equatable {
        public var name: String
        /// `connected`, `needs-auth`, `failed`, `pending` or `disabled`.
        public var status: String
        /// Where it's defined: `user`, `project`, `local`, `plugin`, `claudeai` (a claude.ai connector),
        /// `dynamic` (`--mcp-config`). Nil from a CLI that doesn't say.
        public var source: String? = nil
    }

    public struct APIRetry: Sendable, Equatable {
        public var attempt: Int
        public var maxRetries: Int?
        public var retryDelayMS: Int?
        public var errorStatus: Int?
        /// `rate_limit`, `overloaded`, `authentication_failed`, `billing_error`, …
        public var error: String?
    }

    public enum Partial: Sendable, Equatable {
        case messageStart
        case blockStart(index: Int, block: BlockStart)
        case textDelta(index: Int, text: String)
        case thinkingDelta(index: Int)
        case inputJSONDelta(index: Int, json: String)
        case blockStop(index: Int)
        case messageStop
        case other(String)
    }

    public enum BlockStart: Sendable, Equatable {
        case text
        case thinking
        case toolUse(id: String, name: String)
        case other(String)
    }

    public enum ContentBlock: Sendable, Equatable {
        case text(String)
        case thinking
        case toolUse(ToolUse)
        case other(String)
    }

    public struct ToolUse: Sendable, Equatable {
        public var id: String
        public var name: String
        /// Top-level string fields of the tool input (file_path, command, description, url,
        /// query, pattern, …). Enough to describe the step without keeping arbitrary JSON.
        public var input: [String: String]
        /// The whole input as JSON (Edit's old/new strings, TodoWrite's todos, AskUserQuestion's
        /// questions), for detail tiles. Nil when the block had no input object.
        public var rawInput: Data?

        public init(id: String, name: String, input: [String: String], rawInput: Data? = nil) {
            self.id = id
            self.name = name
            self.input = input
            self.rawInput = rawInput
        }
    }

    public struct ToolResult: Sendable, Equatable {
        public var toolUseID: String
        public var isError: Bool
        /// The result's text, at most `previewLimit` UTF-8 bytes.
        public var preview: String? = nil
        /// The subagent's Agent tool_use id when a subagent ran the tool.
        public var parentToolUseID: String? = nil
        /// Edit / Write / MultiEdit: the change as unified-diff hunks (`tool_use_result.structuredPatch`).
        public var edit: FileEdit? = nil

        public static let previewLimit = 2048
    }

    public struct FileEdit: Sendable, Equatable {
        public var path: String
        /// Write of a new file: no hunks, the whole file is new.
        public var created: Bool
        public var hunks: [PatchHunk]
    }

    public struct PatchHunk: Sendable, Equatable {
        public var oldStart: Int
        public var oldLines: Int
        public var newStart: Int
        public var newLines: Int
        /// Prefixed lines: " " context, "-" removed, "+" added.
        public var lines: [String]
    }

    public struct TaskStarted: Sendable, Equatable {
        public var taskID: String
        public var toolUseID: String?
        public var description: String
        /// `local_agent` (a subagent), `local_bash` (a shell), `remote_agent`, …
        public var taskType: String
        public var subagentType: String?
        public var isBackgrounded: Bool
        /// Set when a subagent started it (its own Bash, a nested agent).
        public var parentTaskID: String?
    }

    public struct TaskProgress: Sendable, Equatable {
        public var taskID: String
        public var toolUseID: String?
        /// "Running <step>" while a tool runs.
        public var description: String?
        public var lastToolName: String?
        public var toolUses: Int?
        public var totalTokens: Int?
    }

    public struct TaskNotification: Sendable, Equatable {
        public var taskID: String
        public var toolUseID: String?
        /// `completed`, `failed` or `stopped`.
        public var status: String
        public var summary: String?
        public var outputFile: String?
    }

    public struct Compaction: Sendable, Equatable {
        /// `manual` (/compact) or `auto`.
        public var trigger: String?
        public var preTokens: Int?
        public var postTokens: Int?
    }

    public struct UserEcho: Sendable, Equatable {
        public var uuid: String
        /// The text blocks, joined with newlines.
        public var text: String
        public var imageCount: Int
    }

    public struct PermissionDenial: Sendable, Equatable {
        public var toolName: String
        public var toolUseID: String?
        public var message: String?
    }

    public struct RateLimit: Sendable, Equatable {
        /// `allowed`, `allowed_warning`, `rejected`.
        public var status: String
        public var limitType: String?
        public var resetsAt: Date?
        /// Utilisation 0…1 per window name (`five_hour`, `seven_day`).
        public var windows: [String: Double]
    }

    public struct TurnResult: Sendable, Equatable {
        public var subtype: String
        public var isError: Bool
        public var sessionID: String
        public var text: String?
        public var terminalReason: String?
        public var apiErrorStatus: Int?
        public var durationMS: Int?
        public var ttftMS: Int?
        public var costUSD: Double?
        public var permissionDenials: Int
        /// The tools in `permission_denials`, in order.
        public var deniedTools: [String] = []
        /// The main session's context size at its last API call this turn (see `.assistant`).
        public var contextTokens: Int? = nil
        /// Claude Code compacted the session during this turn (`system/compact_boundary`): earlier
        /// turns, images included, are now a summary.
        public var compacted = false
        /// Why a failed turn failed, from the synthetic reply's `error` (see `.assistant`).
        public var errorCode: String? = nil
        /// `errors`: why a failed result failed, as the CLI words it (e.g. a missing `--resume` session).
        public var errors: [String] = []
        /// The user messages this turn answered (`user_message_uuids`): the turn's own message plus any
        /// steer folded in. Empty for a turn the CLI started itself (a background agent handed back).
        public var userMessageUUIDs: [String] = []
    }
}

extension StreamEvent {
    /// Names from a list of strings or of `{name}` objects; other entries are skipped.
    static func names(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { ($0 as? String) ?? ($0 as? [String: Any])?["name"] as? String }
    }

    /// Parses one stream-json line. Returns nil only for lines that aren't a JSON object with a
    /// `type`; everything else maps to some case.
    public init?(line: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = o["type"] as? String else { return nil }
        let subtype = o["subtype"] as? String

        switch (type, subtype) {
        case ("system", "init"):
            self = .initialized(InitInfo(
                sessionID: o.string("session_id") ?? "",
                model: o.string("model") ?? "",
                cwd: o.string("cwd") ?? "",
                permissionMode: o.string("permissionMode") ?? "",
                version: o.string("claude_code_version"),
                pluginErrors: o.objects("plugin_errors").map {
                    PluginError(plugin: $0.string("plugin") ?? "", type: $0.string("type") ?? "",
                                message: $0.string("message") ?? "", path: $0.string("path"))
                },
                plugins: o.objects("plugins").compactMap { $0.string("name") },
                mcpServers: o.objects("mcp_servers").map {
                    MCPServer(name: $0.string("name") ?? "", status: $0.string("status") ?? "", source: $0.string("source"))
                },
                capabilities: (o["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? [],
                commands: Self.names(o["slash_commands"]) + Self.names(o["skills"])))
        case ("control_request", _):
            self = .controlRequest(id: o.string("request_id") ?? "",
                                   request: PermissionWire.parse(o["request"] as? [String: Any] ?? [:]))
        case ("control_cancel_request", _):
            self = .controlCancel(requestID: o.string("request_id") ?? "")
        case ("system", "session_state_changed"):
            self = .sessionState(o.string("state") ?? "")
        case ("system", "task_started"):
            self = .taskStarted(TaskStarted(
                taskID: o.string("task_id") ?? "", toolUseID: o.string("tool_use_id"),
                description: o.string("description") ?? "", taskType: o.string("task_type") ?? "",
                subagentType: o.string("subagent_type"), isBackgrounded: o["is_backgrounded"] as? Bool ?? false,
                parentTaskID: o.string("parent_task_id")))
        case ("system", "task_progress"):
            let usage = o["usage"] as? [String: Any] ?? [:]
            self = .taskProgress(TaskProgress(
                taskID: o.string("task_id") ?? "", toolUseID: o.string("tool_use_id"),
                description: o.string("description"), lastToolName: o.string("last_tool_name"),
                toolUses: usage.int("tool_uses"), totalTokens: usage.int("total_tokens")))
        case ("system", "task_updated"):
            self = .taskUpdated(taskID: o.string("task_id") ?? "",
                                status: (o["patch"] as? [String: Any])?.string("status"))
        case ("system", "task_notification"):
            self = .taskNotification(TaskNotification(
                taskID: o.string("task_id") ?? "", toolUseID: o.string("tool_use_id"),
                status: o.string("status") ?? "", summary: Self.taskSummary(o),
                outputFile: o.string("output_file").flatMap { $0.isEmpty ? nil : $0 }))
        case ("system", "compact_boundary"):
            let m = o["compact_metadata"] as? [String: Any] ?? [:]
            self = .compactBoundary(Compaction(trigger: m.string("trigger"), preTokens: m.int("pre_tokens"),
                                               postTokens: m.int("post_tokens")))
        case ("system", "permission_denied"):
            self = .permissionDenied(PermissionDenial(toolName: o.string("tool_name") ?? "",
                                                      toolUseID: o.string("tool_use_id"), message: o.string("message")))
        case ("command_lifecycle", _):
            self = .commandLifecycle(uuid: o.string("command_uuid") ?? "", state: o.string("state") ?? "")
        case ("control_response", _):
            let response = o["response"] as? [String: Any] ?? [:]
            self = .controlResponse(requestID: response["request_id"] as? String ?? "",
                                    success: (response["subtype"] as? String) == "success")
        case ("system", "status"):
            self = .status(o.string("status") ?? "")
        case ("system", "api_retry"):
            self = .apiRetry(APIRetry(
                attempt: o.int("attempt") ?? 0, maxRetries: o.int("max_retries"),
                retryDelayMS: o.int("retry_delay_ms"), errorStatus: o.int("error_status"),
                error: o.string("error")))
        case ("tool_progress", _) where o["heartbeat"] as? Bool == true:
            self = .heartbeat
        case ("system", "background_tasks_changed"):
            self = .backgroundTasks(count: (o["tasks"] as? [Any])?.count ?? 0)
        case ("system", let s?):
            self = .system(subtype: s)
        case ("stream_event", _):
            self = .partial(Self.partial(o["event"] as? [String: Any] ?? [:]))
        case ("assistant", _):
            let message = o["message"] as? [String: Any] ?? [:]
            let usage = message["usage"] as? [String: Any]
            let read = usage.map { u in
                ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap(u.int).reduce(0, +)
            }
            self = .assistant(blocks: message.objects("content").map(Self.contentBlock),
                              parentToolUseID: o.string("parent_tool_use_id"), contextTokens: read,
                              error: o.string("error"))
        case ("user", _) where o["isReplay"] as? Bool == true:
            // Array content is a message we wrote. String content is a slash command's output
            // (`<local-command-stdout>`), which is no user turn.
            let message = o["message"] as? [String: Any] ?? [:]
            guard let content = message["content"] as? [[String: Any]] else {
                self = (message["content"] as? String).flatMap(Self.commandOutput).map(StreamEvent.commandOutput) ?? .other(type: "user")
                return
            }
            self = .userEcho(UserEcho(
                uuid: o.string("uuid") ?? "",
                text: content.filter { $0.string("type") == "text" }.compactMap { $0.string("text") }.joined(separator: "\n"),
                imageCount: content.filter { $0.string("type") == "image" }.count))
        case ("user", _):
            let message = o["message"] as? [String: Any] ?? [:]
            let parent = o.string("parent_tool_use_id")
            let toolUseResult = o["tool_use_result"] as? [String: Any]
            let blocks = message.objects("content").filter { $0.string("type") == "tool_result" }
            self = .toolResults(blocks.map { b in
                ToolResult(toolUseID: b.string("tool_use_id") ?? "", isError: b["is_error"] as? Bool ?? false,
                           preview: Self.preview(b["content"]), parentToolUseID: parent,
                           // `tool_use_result` describes the line's only result.
                           edit: blocks.count == 1 ? toolUseResult.flatMap(Self.fileEdit) : nil)
            })
        case ("rate_limit_event", _):
            let info = o["rate_limit_info"] as? [String: Any] ?? [:]
            var windows: [String: Double] = [:]
            for (name, w) in info["unifiedWindows"] as? [String: Any] ?? [:] {
                if let u = (w as? [String: Any])?.double("utilization") { windows[name] = u }
            }
            self = .rateLimit(RateLimit(
                status: info.string("status") ?? "",
                limitType: info.string("rateLimitType"),
                resetsAt: info.double("resetsAt").map { Date(timeIntervalSince1970: $0) },
                windows: windows))
        case ("result", _):
            self = .result(TurnResult(
                subtype: subtype ?? "",
                isError: o["is_error"] as? Bool ?? false,
                sessionID: o.string("session_id") ?? "",
                text: o.string("result"),
                terminalReason: o.string("terminal_reason"),
                apiErrorStatus: o.int("api_error_status"),
                durationMS: o.int("duration_ms"),
                ttftMS: o.int("ttft_ms"),
                costUSD: o.double("total_cost_usd"),
                permissionDenials: (o["permission_denials"] as? [Any])?.count ?? 0,
                deniedTools: o.objects("permission_denials").compactMap { $0.string("tool_name") },
                errors: (o["errors"] as? [Any])?.compactMap { $0 as? String } ?? [],
                userMessageUUIDs: (o["user_message_uuids"] as? [Any])?.compactMap { $0 as? String }
                    ?? o.string("user_message_uuid").map { [$0] } ?? []))
        default:
            self = .other(type: type)
        }
    }

    private static func partial(_ e: [String: Any]) -> Partial {
        let index = e.int("index") ?? 0
        switch e.string("type") {
        case "message_start": return .messageStart
        case "message_stop": return .messageStop
        case "content_block_stop": return .blockStop(index: index)
        case "content_block_start":
            let b = e["content_block"] as? [String: Any] ?? [:]
            let start: BlockStart = switch b.string("type") {
            case "text": .text
            case "thinking": .thinking
            case "tool_use": .toolUse(id: b.string("id") ?? "", name: b.string("name") ?? "")
            case let t: .other(t ?? "")
            }
            return .blockStart(index: index, block: start)
        case "content_block_delta":
            let d = e["delta"] as? [String: Any] ?? [:]
            switch d.string("type") {
            case "text_delta": return .textDelta(index: index, text: d.string("text") ?? "")
            case "thinking_delta": return .thinkingDelta(index: index)
            case "input_json_delta": return .inputJSONDelta(index: index, json: d.string("partial_json") ?? "")
            case let t: return .other("content_block_delta/\(t ?? "")")
            }
        case let t:
            return .other(t ?? "")
        }
    }

    private static func contentBlock(_ b: [String: Any]) -> ContentBlock {
        switch b.string("type") {
        case "text": return .text(b.string("text") ?? "")
        case "thinking": return .thinking
        case "tool_use":
            let object = b["input"] as? [String: Any]
            var input: [String: String] = [:]
            for (k, v) in object ?? [:] {
                if let s = v as? String { input[k] = s }
            }
            let raw = object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
            return .toolUse(ToolUse(id: b.string("id") ?? "", name: b.string("name") ?? "", input: input, rawInput: raw))
        case let t:
            return .other(t ?? "")
        }
    }
}

extension StreamEvent {
    /// A tool_result's content (a string or text blocks), clipped to `ToolResult.previewLimit` bytes.
    /// The text inside a `<local-command-stdout>` / `<local-command-stderr>` wrapper, trimmed;
    /// nil for any other string content (the compact summary) or empty output.
    static func commandOutput(_ content: String) -> String? {
        for tag in ["local-command-stdout", "local-command-stderr"] {
            guard let open = content.range(of: "<\(tag)>"),
                  let close = content.range(of: "</\(tag)>", range: open.upperBound..<content.endIndex) else { continue }
            let text = content[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    static func preview(_ content: Any?) -> String? {
        let text: String? = if let s = content as? String {
            s
        } else if let blocks = content as? [[String: Any]] {
            blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            nil
        }
        guard let text, !text.isEmpty else { return nil }
        return clip(text, bytes: ToolResult.previewLimit)
    }

    /// At most `bytes` UTF-8 bytes, cut on a character boundary.
    static func clip(_ s: String, bytes: Int) -> String {
        guard s.utf8.count > bytes else { return s }
        var used = 0
        var end = s.startIndex
        for i in s.indices {
            let n = s[i].utf8.count
            if used + n > bytes { break }
            used += n
            end = s.index(after: i)
        }
        return String(s[..<end])
    }

    /// A teammate's report. When the agent handed back by message (`handback`), `summary` is the
    /// CLI's own note ("This agent's report was delivered to you as a message…"); the report is in
    /// `handback_report.text`.
    static func taskSummary(_ o: [String: Any]) -> String? {
        if let report = (o["handback_report"] as? [String: Any])?.string("text"), !report.isEmpty { return report }
        guard let summary = o.string("summary"), !summary.isEmpty,
              o["handback"] == nil, !summary.hasPrefix("This agent's report was delivered") else { return nil }
        return summary
    }

    static func fileEdit(_ r: [String: Any]) -> FileEdit? {
        guard let path = r.string("filePath") else { return nil }
        let hunks = r.objects("structuredPatch").map {
            PatchHunk(oldStart: $0.int("oldStart") ?? 0, oldLines: $0.int("oldLines") ?? 0,
                      newStart: $0.int("newStart") ?? 0, newLines: $0.int("newLines") ?? 0,
                      lines: ($0["lines"] as? [Any])?.compactMap { $0 as? String } ?? [])
        }
        let created = r.string("type") == "create"
        guard created || !hunks.isEmpty else { return nil }
        return FileEdit(path: path, created: created, hunks: hunks)
    }
}

extension Dictionary where Key == String, Value == Any {
    // Internal (not private) so PermissionWire can share them.
    func string(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func objects(_ k: String) -> [[String: Any]] { self[k] as? [[String: Any]] ?? [] }
}

/// Splits a byte stream into newline-terminated lines. A trailing line without a newline is
/// returned by `finish()` when the stream ends.
public struct LineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    public mutating func finish() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}
