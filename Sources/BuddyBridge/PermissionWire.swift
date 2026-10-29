import Foundation

/// A `control_request` the CLI sends the host, parsed.
///
/// Shapes recorded from claude 2.1.312 with `--permission-prompt-tool stdio` (fixtures
/// `can-use-tool*.jsonl`); optional fields follow the Agent SDK's `sdk.d.ts` (docs/v2-sessions 11 §4a).
public enum ControlRequest: Sendable, Equatable {
    /// A tool needs the user's yes (a permission prompt), or AskUserQuestion wants answers.
    case canUseTool(CanUseTool)
    /// An MCP server asks the user for input.
    case elicitation(Elicitation)
    /// Anything else (`hook_callback`, `mcp_message`, `request_user_dialog`, …): answer with
    /// `PermissionWire.error`, or the turn waits forever.
    case other(subtype: String)
}

public struct CanUseTool: Sendable, Equatable {
    public var toolName: String
    public var displayName: String?
    /// The tool input as JSON, echoed back in `updatedInput` on allow.
    public var input: Data
    /// Top-level string fields of the input (file_path, command, …), as in `StreamEvent.ToolUse`.
    public var stringInput: [String: String]
    public var toolUseID: String?
    /// Set when a subagent asks.
    public var agentID: String?
    /// The CLI's one-line summary ("note.txt", the Bash description).
    public var description: String?
    public var title: String?
    /// Why it asks, ANSI escapes stripped.
    public var decisionReason: String?
    public var blockedPath: String?
    /// `permission_suggestions` as JSON (an array of PermissionUpdate), for "Allow for this session".
    public var suggestions: Data?
    /// Hide "Always allow".
    public var suppressAlwaysAllow: Bool
    /// Don't pre-select Allow, and never approve by voice.
    public var defaultToNo: Bool
    /// AskUserQuestion and similar: only a person can answer.
    public var requiresUserInteraction: Bool
    /// AskUserQuestion's questions; empty for other tools.
    public var questions: [Question]

    public struct Question: Sendable, Equatable {
        public var question: String
        public var header: String?
        public var options: [Option]
        public var multiSelect: Bool
    }

    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String?
    }
}

public struct Elicitation: Sendable, Equatable {
    public var serverName: String
    public var message: String
    /// `form` or `url`.
    public var mode: String?
    public var url: URL?
    public var elicitationID: String?
}

/// The user's answer to a permission prompt.
public enum PermissionDecision: Sendable, Equatable {
    /// Allow once. `updatedInput` replaces the tool input (JSON object); nil echoes the original.
    case allow(updatedInput: Data?)
    /// Allow and apply the CLI's suggestions for the rest of this session. Falls back to a plain
    /// allow when the request suppresses "always allow" or has no suggestions.
    case allowForSession
    case deny(message: String?)
}

/// Reads and writes the permission side of the control protocol. Pure: no I/O.
public enum PermissionWire {
    static let defaultDenyMessage = "The user declined."

    static func parse(_ request: [String: Any]) -> ControlRequest {
        switch request.string("subtype") ?? "" {
        case "can_use_tool":
            let object = request["input"] as? [String: Any] ?? [:]
            var strings: [String: String] = [:]
            for (k, v) in object { if let s = v as? String { strings[k] = s } }
            let suggestions = (request["permission_suggestions"] as? [Any]).flatMap { $0.isEmpty ? nil : $0 }
            return .canUseTool(CanUseTool(
                toolName: request.string("tool_name") ?? "",
                displayName: request.string("display_name"),
                input: json(object),
                stringInput: strings,
                toolUseID: request.string("tool_use_id"),
                agentID: request.string("agent_id"),
                description: request.string("description"),
                title: request.string("title"),
                decisionReason: request.string("decision_reason").map(stripANSI),
                blockedPath: request.string("blocked_path"),
                suggestions: suggestions.map(json),
                suppressAlwaysAllow: request["suppress_always_allow_rule"] as? Bool ?? false,
                defaultToNo: request["default_to_no"] as? Bool ?? false,
                requiresUserInteraction: request["requires_user_interaction"] as? Bool ?? false,
                questions: object.objects("questions").map { q in
                    CanUseTool.Question(
                        question: q.string("question") ?? "", header: q.string("header"),
                        options: q.objects("options").map { .init(label: $0.string("label") ?? "", description: $0.string("description")) },
                        multiSelect: q["multiSelect"] as? Bool ?? false)
                }))
        case "elicitation":
            return .elicitation(Elicitation(
                serverName: request.string("mcp_server_name") ?? "",
                message: request.string("message") ?? "",
                mode: request.string("mode"),
                url: request.string("url").flatMap(URL.init(string:)),
                elicitationID: request.string("elicitation_id")))
        case let subtype:
            return .other(subtype: subtype)
        }
    }

    /// The `control_response` line (newline-terminated) answering a `can_use_tool` request.
    public static func response(_ id: String, _ decision: PermissionDecision, for request: CanUseTool) -> Data {
        let result: [String: Any]
        switch decision {
        case .allow(let updated):
            result = ["behavior": "allow", "updatedInput": object(updated ?? request.input)]
        case .allowForSession:
            var r: [String: Any] = ["behavior": "allow", "updatedInput": object(request.input)]
            if !request.suppressAlwaysAllow, let s = request.suggestions,
               let updates = (try? JSONSerialization.jsonObject(with: s)) as? [[String: Any]], !updates.isEmpty {
                // "For this session" whatever the CLI proposed (it often offers localSettings).
                r["updatedPermissions"] = updates.map { var u = $0; u["destination"] = "session"; return u }
            }
            result = r
        case .deny(let message):
            result = ["behavior": "deny", "message": message ?? defaultDenyMessage]
        }
        return success(id, result)
    }

    /// Answers AskUserQuestion: allow, with the input plus `answers` keyed by question text.
    /// Multi-select labels are joined with ", ".
    public static func answers(_ id: String, _ answers: [String: [String]], for request: CanUseTool) -> Data {
        var input = object(request.input)
        input["answers"] = answers.mapValues { $0.joined(separator: ", ") }
        return success(id, ["behavior": "allow", "updatedInput": input])
    }

    /// Declines or cancels an MCP elicitation.
    public static func elicitation(_ id: String, action: String) -> Data {
        success(id, ["action": action])
    }

    /// The reply to send at once for a request no person answers: decline an MCP elicitation (v1),
    /// and an error for any other subtype we don't handle. Nil for `can_use_tool` (that waits for
    /// the user, with no timeout).
    public static func autoReply(id: String, request: ControlRequest) -> Data? {
        switch request {
        case .canUseTool: nil
        case .elicitation: elicitation(id, action: "decline")
        case .other(let subtype): error(id, "Lumi doesn't handle \(subtype.isEmpty ? "this request" : subtype)")
        }
    }

    /// An error `control_response`: the safety net for subtypes we don't handle.
    public static func error(_ id: String, _ message: String) -> Data {
        line(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": message]])
    }

    // MARK: - Helpers

    static func success(_ id: String, _ response: [String: Any]) -> Data {
        line(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
