import Foundation

/// One line of Claude Code's `--output-format stream-json`, reduced to what the bridge uses.
///
/// Shapes were recorded from claude 2.1.296 (fixtures under
/// `Tests/BuddyBridgeTests/Fixtures`). Unknown types and subtypes decode to `.other` so a newer
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
    case controlResponse(requestID: String, success: Bool)
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

        public init(id: String, name: String, input: [String: String]) {
            self.id = id
            self.name = name
            self.input = input
        }
    }

    public struct ToolResult: Sendable, Equatable {
        public var toolUseID: String
        public var isError: Bool
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
    }
}

extension StreamEvent {
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
                capabilities: (o["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []))
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
        case ("user", _):
            let message = o["message"] as? [String: Any] ?? [:]
            self = .toolResults(message.objects("content").compactMap { b in
                guard b.string("type") == "tool_result" else { return nil }
                return ToolResult(toolUseID: b.string("tool_use_id") ?? "", isError: b["is_error"] as? Bool ?? false)
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
                errors: (o["errors"] as? [Any])?.compactMap { $0 as? String } ?? []))
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
            var input: [String: String] = [:]
            for (k, v) in b["input"] as? [String: Any] ?? [:] {
                if let s = v as? String { input[k] = s }
            }
            return .toolUse(ToolUse(id: b.string("id") ?? "", name: b.string("name") ?? "", input: input))
        case let t:
            return .other(t ?? "")
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
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
