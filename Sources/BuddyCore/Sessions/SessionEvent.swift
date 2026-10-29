import Foundation

/// The parsed, UI-ready stream of one Lumi session, across turns, processes and resumes.
/// The bridge's mapper produces it inside the session's actor, never on main.
public enum SessionEvent: Sendable, Equatable {
    case launched(resumed: Bool)
    /// From `system/init`.
    case initialized(InitSummary)
    /// From `system/session_state_changed`. It repeats; treat each as the current state.
    case runState(RunState)
    case turnStarted(userUUID: String?, kind: TurnKind)
    /// A tool use, in the main session or a subagent.
    case step(TrailStep)
    /// `preview` is at most 2 KB of the result.
    case stepFinished(id: String, isError: Bool, preview: String?)
    /// Coalesced deltas, at most one batch per frame.
    case text(String, subagent: String?)
    /// Bounded; shown only with "Show thinking" on.
    case thinking(summary: String?)
    /// Voice turns (and voice-in-page turns with speech on) only.
    case sayFirstSentence(String)
    case say(String)
    case permissionRequested(PermissionAsk)
    case permissionResolved(id: String)
    case questionAsked(QuestionAsk)
    /// Teammates and background jobs.
    case task(TaskEvent)
    /// `compact_boundary`: the next voice turn sends the full voice rules again.
    case compacted
    case retrying(attempt: Int, delayMS: Int?, reason: String?)
    case rateLimit(status: String, resetsAt: Date?)
    case turnEnded(TurnEnd)
    case processEnded(status: Int32, midTurn: Bool)
}

/// What `system/init` reports that the page and the Details pane show.
public struct InitSummary: Sendable, Equatable {
    public struct MCPServer: Sendable, Equatable {
        public var name: String
        public var status: String

        public init(name: String, status: String) {
            self.name = name
            self.status = status
        }
    }

    public var sessionID: String?
    public var model: String?
    public var cwd: String?
    public var permissionMode: String?
    public var version: String?
    public var capabilities: [String]
    public var mcpServers: [MCPServer]
    /// The commands and skills `/` can run in this session, by name (the composer's menu).
    public var commands: [String]

    public init(
        sessionID: String? = nil, model: String? = nil, cwd: String? = nil, permissionMode: String? = nil,
        version: String? = nil, capabilities: [String] = [], mcpServers: [MCPServer] = [], commands: [String] = []
    ) {
        self.sessionID = sessionID
        self.model = model
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.version = version
        self.capabilities = capabilities
        self.mcpServers = mcpServers
        self.commands = commands
    }
}

public enum RunState: String, Sendable, Equatable {
    case idle
    case running
    case requiresAction = "requires_action"
}

public enum TaskEvent: Sendable, Equatable {
    case started(taskID: String, toolUseID: String?, name: String?, description: String, kind: TaskKind)
    /// `steps`: the tool uses so far (`usage.tool_uses`).
    case progress(taskID: String, lastTool: String?, line: String?, steps: Int? = nil)
    case ended(taskID: String, status: TaskEnd, summary: String?)
}

public enum TaskKind: String, Sendable, Equatable {
    case agent = "local_agent"
    /// A background shell or monitor: a background job, not a teammate.
    case bash = "local_bash"
    case remote = "remote_agent"
}

public enum TaskEnd: String, Sendable, Equatable {
    case completed, failed, stopped
}

public struct TurnEnd: Sendable, Equatable {
    public var kind: TurnKind
    /// `result.text`: rendered as Markdown for typed turns.
    public var markdown: String
    /// Extracted only for voice turns.
    public var block: BuddyBlock?
    public var isError: Bool
    public var error: SessionFailure?
    public var contextTokens: Int?
    /// Cumulative for the process; the Details pane only.
    public var costUSD: Double?
    public var deniedTools: [String]

    public init(
        kind: TurnKind, markdown: String, block: BuddyBlock? = nil, isError: Bool = false, error: SessionFailure? = nil,
        contextTokens: Int? = nil, costUSD: Double? = nil, deniedTools: [String] = []
    ) {
        self.kind = kind
        self.markdown = markdown
        self.block = block
        self.isError = isError
        self.error = error
        self.contextTokens = contextTokens
        self.costUSD = costUSD
        self.deniedTools = deniedTools
    }
}

/// One line of the Trail: a tool use, in plain words.
public struct TrailStep: Sendable, Equatable, Identifiable {
    /// The tool use id.
    public var id: String
    public var kind: StepKind
    /// Present tense, in the status vocabulary ("Reading", "Searching for").
    public var verb: String
    /// A file name, domain or connector: never a raw path or JSON.
    public var object: String?
    /// The parent tool use id when a subagent ran the tool.
    public var subagent: String?
    public var detail: StepDetail?

    public init(id: String, kind: StepKind, verb: String, object: String? = nil, subagent: String? = nil, detail: StepDetail? = nil) {
        self.id = id
        self.kind = kind
        self.verb = verb
        self.object = object
        self.subagent = subagent
        self.detail = detail
    }
}

extension TrailStep {
    /// The live line every surface shows (Trail, capsule, sidebar): "Reading budget.md"; a Bash
    /// description in its -ing form ("Running the auth tests").
    public var presentLine: String {
        let verb = kind == .bash ? Self.bashForm(verb, past: false) : verb
        return object.map { "\(verb) \($0)" } ?? verb
    }

    /// Imperative first words of Bash descriptions ("Run the tests") and their -ing and past forms.
    static let imperative: [String: (ing: String, past: String)] = [
        "Run": ("Running", "Ran"), "Check": ("Checking", "Checked"), "List": ("Listing", "Listed"),
        "Install": ("Installing", "Installed"), "Build": ("Building", "Built"), "Find": ("Finding", "Found"),
        "Show": ("Showing", "Showed"), "Create": ("Creating", "Created"), "Remove": ("Removing", "Removed"),
        "Delete": ("Deleting", "Deleted"), "Test": ("Testing", "Tested"), "Count": ("Counting", "Counted"),
        "Get": ("Getting", "Got"), "Read": ("Reading", "Read"), "Search": ("Searching", "Searched"),
        "Print": ("Printing", "Printed"), "Move": ("Moving", "Moved"), "Copy": ("Copying", "Copied"),
        "Make": ("Making", "Made"), "Start": ("Starting", "Started"), "Stop": ("Stopping", "Stopped"),
        "Open": ("Opening", "Opened"), "Compile": ("Compiling", "Compiled"), "Fetch": ("Fetching", "Fetched"),
        "Update": ("Updating", "Updated"), "Verify": ("Verifying", "Verified"), "Compare": ("Comparing", "Compared"),
        "Format": ("Formatting", "Formatted"), "Lint": ("Linting", "Linted"), "Commit": ("Committing", "Committed"),
    ]

    public static func bashForm(_ description: String, past: Bool) -> String {
        let first = description.prefix { !$0.isWhitespace }
        guard let forms = imperative[String(first)] else { return description }
        return (past ? forms.past : forms.ing) + description.dropFirst(first.count)
    }
}

public enum StepKind: Sendable, Equatable {
    case read, search, edit, write, bash, web
    case mcp(server: String)
    case agent, plan, ask, screen, other
}

public enum StepDetail: Sendable, Equatable {
    /// From an Edit's input, or its result's `structuredPatch`.
    case diff(path: String?, old: String, new: String)
    case command(description: String?, command: String)
    case todos([Todo])
    case question(QuestionAsk)

    public struct Todo: Sendable, Equatable {
        public enum State: String, Sendable, Equatable {
            case pending
            case inProgress = "in_progress"
            case completed
        }

        public var content: String
        public var state: State

        public init(content: String, state: State) {
            self.content = content
            self.state = state
        }
    }
}
