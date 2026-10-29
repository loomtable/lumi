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

    /// One Trail step for a tool call: a kind, a present-tense verb and a short object (a file
    /// name, a domain, a connector), never a raw path or JSON. Nil for bookkeeping tools the Trail
    /// doesn't show (ToolSearch).
    public static func step(for tool: StreamEvent.ToolUse) -> StepDescription? {
        let input = tool.input
        switch tool.name {
        case "Read":
            return .init(kind: .read, verb: "Reading", object: input["file_path"].map(filename) ?? "a file")
        case "NotebookRead":
            return .init(kind: .read, verb: "Reading", object: input["notebook_path"].map(filename) ?? "a notebook")
        case "Edit", "MultiEdit", "NotebookEdit":
            return .init(kind: .edit, verb: "Editing",
                         object: (input["file_path"] ?? input["notebook_path"]).map(filename) ?? "a file")
        case "Write":
            return .init(kind: .write, verb: "Writing", object: input["file_path"].map(filename) ?? "a file")
        case "Grep":
            return .init(kind: .search, verb: "Searching for", object: input["pattern"].map { "“\(clip($0))”" } ?? "text")
        case "Glob":
            return .init(kind: .search, verb: "Finding files", object: input["pattern"].map { clip($0) })
        case "Bash", "PowerShell":
            if let d = input["description"], !d.isEmpty { return .init(kind: .bash, verb: clip(d, 60), object: nil) }
            return .init(kind: .bash, verb: "Running", object: input["command"].map { clip(firstWord($0), 30) } ?? "a command")
        case "Monitor":
            return .init(kind: .bash, verb: "Checking", object: input["description"].map { clip($0, 50) } ?? "a command")
        case "WebSearch":
            return .init(kind: .web, verb: "Searching the web for", object: input["query"].map { "“\(clip($0))”" } ?? "an answer")
        case "WebFetch":
            return .init(kind: .web, verb: "Reading", object: input["url"].flatMap { URL(string: $0)?.host() } ?? "a web page")
        case "Agent", "Task":
            return .init(kind: .agent, verb: "Starting",
                         object: (input["name"] ?? input["description"]).map { clip($0, 50) } ?? "a teammate")
        case "SendMessage":
            return .init(kind: .agent, verb: "Messaging", object: input["to"].map { clip($0, 30) } ?? "a teammate")
        case "TodoWrite":
            return .init(kind: .plan, verb: "Updating the plan", object: nil)
        case "EnterPlanMode", "ExitPlanMode":
            return .init(kind: .plan, verb: "Planning", object: nil)
        case "AskUserQuestion":
            return .init(kind: .ask, verb: "Asking you", object: nil)
        case "Skill":
            return .init(kind: .other, verb: "Using", object: input["skill"].map { clip($0, 30) } ?? "a skill")
        case "ToolSearch":
            return nil
        default:
            if tool.name.hasPrefix("mcp__") {
                let parts = tool.name.split(separator: "__", omittingEmptySubsequences: true).dropFirst()
                let server = parts.first.map { String($0).replacingOccurrences(of: "_", with: " ") }
                return .init(kind: .mcp, verb: "Using", object: server ?? tool.name, mcpServer: parts.first.map(String.init))
            }
            return .init(kind: .other, verb: "Using", object: tool.name)
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

/// What a tool call looks like as one Trail step. `SessionEventMapper` turns it into
/// `BuddyCore.TrailStep`.
public struct StepDescription: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case read, search, edit, write, bash, web, mcp, agent, plan, ask, screen, other
    }

    public var kind: Kind
    /// Present tense: "Reading", "Searching for", or a Bash description used whole.
    public var verb: String
    public var object: String?
    /// The MCP server's raw name for `.mcp` steps.
    public var mcpServer: String?

    public init(kind: Kind, verb: String, object: String?, mcpServer: String? = nil) {
        self.kind = kind
        self.verb = verb
        self.object = object
        self.mcpServer = mcpServer
    }

    /// "Reading budget.md".
    public var line: String { object.map { "\(verb) \($0)" } ?? verb }
}
