import Testing
@testable import BuddyBridge

struct StatusMapperTests {
    private func status(_ name: String, _ input: [String: String] = [:]) -> String? {
        StatusMapper.status(for: StreamEvent.ToolUse(id: "t", name: name, input: input))
    }

    @Test func linesComeFromTheToolAndItsInput() {
        #expect(status("Read", ["file_path": "/Users/me/web/useFeed.ts"]) == "Reading useFeed.ts")
        #expect(status("Edit", ["file_path": "/a/b.swift"]) == "Editing b.swift")
        #expect(status("Bash", ["command": "git status --short", "description": "Show changed files"]) == "Show changed files")
        #expect(status("Bash", ["command": "git status --short"]) == "Running git")
        #expect(status("WebFetch", ["url": "https://www.ecb.europa.eu/stats"]) == "Reading www.ecb.europa.eu")
        #expect(status("WebSearch", ["query": "QT meaning"]) == "Searching the web for “QT meaning”")
        #expect(status("Grep", ["pattern": "dateFilter"]) == "Searching for “dateFilter”")
        #expect(status("mcp__playwright__browser_snapshot") == "Using playwright")
        #expect(status("SomethingNew") == "Using SomethingNew")
    }

    @Test func internalToolsDontChangeTheLine() {
        #expect(status("Skill", ["skill": "buddy:buddy-answer"]) == nil)
        #expect(status("TodoWrite") == nil)
    }

    @Test func longInputsAreClipped() {
        let line = status("Bash", ["description": String(repeating: "x", count: 200)])
        #expect(line?.count == 60)
        #expect(line?.hasSuffix("…") == true)
    }

    @Test func thinkingAndRetriesComeFromEvents() {
        #expect(StatusMapper.status(for: .partial(.blockStart(index: 0, block: .thinking))) == "Thinking")
        #expect(StatusMapper.status(for: .apiRetry(.init(attempt: 1, error: "rate_limit"))) == "Waiting on the plan's rate limit")
        #expect(StatusMapper.status(for: .status("requesting")) == nil)
    }

    @Test func subagentStepsTickInToo() {
        let tool = StreamEvent.ToolUse(id: "t", name: "Read", input: ["file_path": "/x.txt"])
        #expect(StatusMapper.status(for: .assistant(blocks: [.toolUse(tool)], parentToolUseID: "toolu_parent")) == "Reading x.txt")
        #expect(StatusMapper.status(for: .assistant(blocks: [.text("hi")], parentToolUseID: nil)) == nil)
    }
}

extension StreamEvent.APIRetry {
    init(attempt: Int, error: String) {
        self.init(attempt: attempt, maxRetries: nil, retryDelayMS: nil, errorStatus: nil, error: error)
    }
}

struct StepDescriptionTests {
    private func step(_ name: String, _ input: [String: String] = [:]) -> StepDescription? {
        StatusMapper.step(for: StreamEvent.ToolUse(id: "t", name: name, input: input))
    }

    @Test func stepsHaveAKindAVerbAndAShortObject() {
        #expect(step("Read", ["file_path": "/Users/me/web/useFeed.ts"]) == .init(kind: .read, verb: "Reading", object: "useFeed.ts"))
        #expect(step("Edit", ["file_path": "/a/b.swift"])?.line == "Editing b.swift")
        #expect(step("Write", ["file_path": "/a/new.md"])?.kind == .write)
        #expect(step("Grep", ["pattern": "dateFilter"])?.line == "Searching for “dateFilter”")
        #expect(step("WebFetch", ["url": "https://www.ecb.europa.eu/stats"])?.line == "Reading www.ecb.europa.eu")
        #expect(step("Bash", ["command": "npm test", "description": "Run the tests"]) == .init(kind: .bash, verb: "Run the tests", object: nil))
        #expect(step("Bash", ["command": "npm test"])?.line == "Running npm")
        #expect(step("Agent", ["name": "scout", "description": "Find the bug"])?.line == "Starting scout")
        #expect(step("Agent", ["description": "Find the bug"])?.line == "Starting Find the bug")
        #expect(step("SendMessage", ["to": "scout"])?.line == "Messaging scout")
        #expect(step("AskUserQuestion")?.kind == .ask)
        #expect(step("TodoWrite")?.kind == .plan)
        #expect(step("SomethingNew")?.line == "Using SomethingNew")
        // 04 §4.2: never "Watching".
        #expect(step("Monitor", ["description": "dev server log"])?.line == "Checking dev server log")
    }

    @Test func mcpStepsNameTheServer() {
        let s = step("mcp__claude_ai_Slack__send_message")
        #expect(s?.kind == .mcp)
        #expect(s?.mcpServer == "claude_ai_Slack")
        #expect(s?.line == "Using claude ai Slack")
    }

    @Test func objectsAreNeverRawPaths() {
        #expect(step("Read", ["file_path": "/Users/me/a/b/c/secret-notes.md"])?.object == "secret-notes.md")
        #expect(step("ToolSearch") == nil)
    }
}
