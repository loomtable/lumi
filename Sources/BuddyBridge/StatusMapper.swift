import Foundation

/// Turns stream events into the one status line the pill shows.
///
/// Every line comes from a real event: the tool Claude Code just started and its input. Nothing
/// is estimated. Returns nil when an event shouldn't change the line.
public enum StatusMapper {
    public static let thinking = "Thinking"

    public static func status(for event: StreamEvent) -> String? {
        switch event {
        case .partial(.blockStart(_, .thinking)):
            return thinking
        case .assistant(let blocks, _, _, _):
            // The last tool_use in a message is the step about to run. Subagent steps
            // (forwarded with --forward-subagent-text) are real steps too.
            for case .toolUse(let tool) in blocks.reversed() {
                return status(for: tool)
            }
            return nil
        case .apiRetry(let r) where r.error == "rate_limit":
            return "Waiting on the plan's rate limit"
        case .apiRetry(let r) where r.error == "overloaded":
            return "Claude is busy, retrying"
        case .apiRetry:
            return "Retrying the request"
        default:
            return nil
        }
    }

    public static func status(for tool: StreamEvent.ToolUse) -> String? {
        let input = tool.input
        switch tool.name {
        case "Read":
            return input["file_path"].map { "Reading \(filename($0))" } ?? "Reading a file"
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return (input["file_path"] ?? input["notebook_path"]).map { "Editing \(filename($0))" } ?? "Editing a file"
        case "Grep":
            return input["pattern"].map { "Searching for “\(clip($0))”" } ?? "Searching the code"
        case "Glob":
            return "Finding files"
        case "Bash":
            // Claude Code's Bash tool carries a human description of the command.
            if let d = input["description"], !d.isEmpty { return clip(d, 60) }
            return input["command"].map { "Running \(clip(firstWord($0), 30))" } ?? "Running a command"
        case "WebSearch":
            return input["query"].map { "Searching the web for “\(clip($0))”" } ?? "Searching the web"
        case "WebFetch":
            return input["url"].flatMap { URL(string: $0)?.host() }.map { "Reading \($0)" } ?? "Reading a web page"
        case "Agent", "Task":
            return input["description"].map { clip($0, 60) } ?? "Working on a sub-task"
        case "Skill", "ToolSearch", "TodoWrite":
            return nil
        default:
            if tool.name.hasPrefix("mcp__") {
                let server = tool.name.split(separator: "__", omittingEmptySubsequences: true).dropFirst().first
                return server.map { "Using \(String($0).replacingOccurrences(of: "_", with: " "))" }
            }
            return "Using \(tool.name)"
        }
    }

    static func filename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func firstWord(_ s: String) -> String {
        String(s.split(whereSeparator: \.isWhitespace).first ?? "")
    }

    static func clip(_ s: String, _ max: Int = 40) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= max ? oneLine : String(oneLine.prefix(max - 1)) + "…"
    }
}
