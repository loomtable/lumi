import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation

/// Names a session from its first question and answer: a 2–4 word title and an SF Symbol, which
/// `TopicValidator` checks before anything shows them. Nil when it can't (the provisional title stays).
public protocol SessionTitler: Sendable {
    func topic(question: String, answer: String) async -> SessionTopic?
}

/// The live titler: one cheap `claude -p` on Haiku, kept light. It runs in an empty folder and
/// loads no user settings, so no CLAUDE.md, hooks, skills or project context come along (only
/// project and local sources, of which the empty folder has none; `--bare` can't be used: it
/// skips the subscription login). No tools, no MCP servers, no slash commands, nothing saved,
/// a 20 s deadline. It runs after the answer has shown, never on the answer's path, and gets only
/// the first question and the start of the answer.
public struct ClaudeTitler: SessionTitler {
    let claude: URL
    let environment: [String: String]
    let run: CommandRunner

    public init(claude: URL, environment: [String: String], run: CommandRunner? = nil) {
        self.claude = claude
        self.environment = environment
        self.run = run ?? ClaudeCodeProbe.runner(deadline: .seconds(20), currentDirectory: Self.emptyFolder())
    }

    /// An empty folder of Lumi's own to run in (created if missing).
    static func emptyFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(BuddyCore.bundleIdentifier).titler", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func topic(question: String, answer: String) async -> SessionTopic? {
        guard let out = await run(claude, Self.arguments(prompt: Self.prompt(question: question, answer: answer)), environment),
              out.status == 0 else { return nil }
        return Self.parse(out.stdout)
    }

    static let maxQuestion = 300
    static let maxAnswer = 400

    static func arguments(prompt: String) -> [String] {
        ["-p", "--model", "haiku", "--output-format", "text", "--no-session-persistence", "--tools", "",
         "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "project,local",
         "--settings", #"{"disableAllHooks": true}"#, prompt]
    }

    static func prompt(question: String, answer: String) -> String {
        """
        Name this conversation for a sidebar. Reply with only JSON: {"title": "...", "symbol": "..."}.
        title: the topic in 2 to 4 plain words, no quotes, no trailing punctuation, no numbers, emails or links.
        symbol: the one SF Symbol from this list that fits best: \(SymbolAllowlist.symbols.sorted().joined(separator: ", ")).

        Question: \(question.prefix(maxQuestion))

        Answer (start): \(answer.prefix(maxAnswer))
        """
    }

    /// The first JSON object in the reply (a model may wrap it in a code fence).
    static func parse(_ stdout: String) -> SessionTopic? {
        guard let start = stdout.firstIndex(of: "{"), let end = stdout.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(SessionTopic.self, from: Data(stdout[start...end].utf8))
    }
}
