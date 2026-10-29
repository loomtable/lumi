import BuddyCore
import Foundation

/// A connection Lumi recommends (Settings › Connections, onboarding): plain data, with nothing about
/// how a particular agent adds it. `ClaudeCodeMCP` turns it into Claude Code's commands.
public struct MCPRecommendation: Sendable, Equatable, Identifiable {
    public enum Setup: Sendable, Equatable {
        /// A remote server, added as is.
        case remote(url: URL)
        /// A remote server that needs a token the user pastes, sent as `Authorization: Bearer <token>`.
        /// `tokenPage` is where the user makes one. The token is kept in a private file and read at each
        /// connection, never put on a command line.
        case remoteWithToken(url: URL, tokenPage: URL)
        /// A server run on this Mac: `command` (found on the user's PATH) with `arguments`.
        /// `requirement` names what provides the command, for "Needs Node.js".
        case local(command: String, arguments: [String], requirement: Requirement)
        /// Added and signed in on the provider's site, not by Lumi (apps whose sign-in needs a registered
        /// client): `page` opens it.
        case connector(page: URL)
    }

    public struct Requirement: Sendable, Equatable {
        public let name: String
        public let download: URL
    }

    /// Also the server's name when Lumi adds it.
    public let id: String
    public let name: String
    /// One line on what it lets Lumi do.
    public let benefit: String
    public let setup: Setup
    /// The names this connection has in a session's server list, however it was added: by Lumi
    /// (`id`), by the user, as a claude.ai connector or a plugin. Compared without case.
    public let serverNames: [String]

    /// Lumi can add it itself (with the user's click), rather than sending them to a page.
    public var isAddable: Bool {
        if case .connector = setup { false } else { true }
    }

    /// The first server in `servers` that is this connection.
    public func server(in servers: [StreamEvent.MCPServer]) -> StreamEvent.MCPServer? {
        let names = Set(serverNames.map { $0.lowercased() })
        return servers.first { names.contains($0.name.lowercased()) }
    }
}

public enum MCPCatalog {
    static let connectorsPage = URL(string: "https://claude.ai/customize/connectors")!

    /// The recommended set: one-click adds (Context7, Playwright), a pasted token (GitHub), and
    /// claude.ai connectors for apps that sign in (Linear, Notion, Slack, Atlassian).
    public static let recommended: [MCPRecommendation] = [
        MCPRecommendation(
            id: "context7", name: "Context7", benefit: "Up-to-date docs for the libraries you use.",
            setup: .remote(url: URL(string: "https://mcp.context7.com/mcp")!),
            serverNames: ["context7"]),
        MCPRecommendation(
            id: "playwright", name: "Playwright", benefit: "Opens and drives a browser to check web pages.",
            setup: .local(command: "npx", arguments: ["@playwright/mcp@latest"],
                          requirement: .init(name: "Node.js", download: URL(string: "https://nodejs.org/en/download")!)),
            serverNames: ["playwright"]),
        MCPRecommendation(
            id: "github", name: "GitHub", benefit: "Reads issues, pull requests and code on GitHub.",
            setup: .remoteWithToken(url: URL(string: "https://api.githubcopilot.com/mcp/")!,
                                    tokenPage: URL(string: "https://github.com/settings/personal-access-tokens/new")!),
            serverNames: ["github", "claude.ai GitHub"]),
        MCPRecommendation(
            id: "linear", name: "Linear", benefit: "Finds and updates your Linear issues.",
            setup: .connector(page: connectorsPage), serverNames: ["linear", "claude.ai Linear"]),
        MCPRecommendation(
            id: "notion", name: "Notion", benefit: "Searches and edits your Notion pages.",
            setup: .connector(page: connectorsPage), serverNames: ["notion", "claude.ai Notion"]),
        MCPRecommendation(
            id: "slack", name: "Slack", benefit: "Searches and sends Slack messages.",
            setup: .connector(page: connectorsPage), serverNames: ["slack", "claude.ai Slack"]),
        MCPRecommendation(
            id: "atlassian", name: "Atlassian", benefit: "Jira issues and Confluence pages.",
            setup: .connector(page: connectorsPage),
            serverNames: ["atlassian", "claude.ai Atlassian", "plugin:atlassian:atlassian"]),
    ]
}

/// Adds and removes Lumi's recommended servers in the user's Claude Code (`claude mcp`, user scope, so
/// every project has them). Only on the user's click, and only servers they chose (their
/// own setup is never changed otherwise). Status isn't checked here (`claude mcp get` connects to the
/// server): the next session's `system/init` list says it.
///
/// A token never goes on a command line, where other processes could read it: it's written to a file
/// only this user can read, and the server is added with a `headersHelper` that prints that file
/// (Claude Code runs it at each connection; documented, verified on 2.1.302). Nothing here logs
/// arguments.
public struct ClaudeCodeMCP: Sendable {
    public enum AddResult: Sendable, Equatable {
        case added
        /// A server with this name was there and Lumi's token file for it too, so it's taken to be the one
        /// Lumi added: the new token replaced the old one (read at the next connection). Only for a token
        /// connection. Inferred from the file, so it isn't proof of ownership on its own: only offer
        /// Remove for ids the caller recorded from an `.added`.
        case tokenReplaced
        /// A server with this name is already in their setup, not added by Lumi: left as it is.
        case alreadyThere
        /// The command it runs isn't on this Mac (Playwright without Node.js).
        case missingRequirement(MCPRecommendation.Requirement)
        /// Not something Lumi adds (a connector), or a token was needed and not given.
        case notAddable
        /// Claude Code refused or couldn't run: its own line, or nil.
        case failed(String?)
    }

    public let claude: URL
    public let environment: [String: String]
    /// Where tokens are kept, one `<id>.headers.json` per server.
    public let secrets: URL
    var run: OutputRunner
    var isExecutable: @Sendable (String) -> Bool

    /// Status and both outputs, nil when it couldn't run or missed its deadline.
    typealias OutputRunner = @Sendable (_ executable: URL, _ arguments: [String], _ environment: [String: String]) async
        -> (status: Int32, stdout: String, stderr: String)?

    /// `~/Library/Application Support/Loomtable/Lumi/connections` for the release app. The user's
    /// Claude Code config points at files here, so this folder never moves: not in the rename, not in any
    /// migration. Change it only together with re-adding every server that uses it. Another bundle ID
    /// (a QA copy) keeps its own, `Loomtable/<bundle id>/connections`.
    public static var defaultSecrets: URL {
        BuddyCore.paths.connections
    }

    /// `environment` is the one sessions launch with (`LaunchEnvironment.make`), so its PATH is the user's.
    public init(claude: URL, environment: [String: String], secrets: URL = ClaudeCodeMCP.defaultSecrets) {
        self.init(claude: claude, environment: environment, secrets: secrets,
                  run: ClaudeCodeProbe.outputRunner(deadline: .seconds(30)), isExecutable: Self.isExecutableFile)
    }

    init(claude: URL, environment: [String: String], secrets: URL, run: @escaping OutputRunner,
         isExecutable: @escaping @Sendable (String) -> Bool) {
        self.claude = claude
        self.environment = environment
        self.secrets = secrets
        self.run = run
        self.isExecutable = isExecutable
    }

    /// An executable file, not a directory that happens to have the name.
    static let isExecutableFile: @Sendable (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    func headersFile(_ recommendation: MCPRecommendation) -> URL {
        secrets.appending(path: "\(recommendation.id).headers.json")
    }

    /// Whether this Mac has what `recommendation` runs (only local servers need anything).
    public func hasRequirement(_ recommendation: MCPRecommendation) -> Bool {
        guard case .local(let command, _, _) = recommendation.setup else { return true }
        return (environment["PATH"] ?? "").split(separator: ":").contains { isExecutable("\($0)/\(command)") }
    }

    /// Adds `recommendation` at user scope. `token` is for `.remoteWithToken`. It isn't checked here: the
    /// next session's server status says whether it works.
    public func add(_ recommendation: MCPRecommendation, token: String? = nil) async -> AddResult {
        var arguments = ["mcp", "add", "--scope", "user"]
        switch recommendation.setup {
        case .remote(let url):
            arguments += ["--transport", "http", recommendation.id, url.absoluteString]
        case .remoteWithToken(let url, _):
            // One line, no control characters: it becomes an HTTP header.
            guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
                  !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return .notAddable }
            // The live file is what an existing server reads, so the new token goes to a file of its own
            // and replaces the live one only once it's wanted: an add or a re-add never breaks it.
            let file = headersFile(recommendation)
            // Its own name per add, so two adds at once never move each other's token.
            let pending = file.appendingPathExtension("new-\(UUID().uuidString)")
            do {
                try writePrivately(["Authorization": "Bearer \(token)"], to: pending)
            } catch {
                return .failed("Couldn't save the token.")
            }
            let server: [String: String] = ["type": "http", "url": url.absoluteString, "headersHelper": "/bin/cat \(Self.shellQuoted(file.path))"]
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: server, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            var result = await runAdd(["mcp", "add-json", "--scope", "user", recommendation.id, json])
            // Already there with Lumi's token file beside it: Lumi added it, so this replaces the token.
            // Without one it's the user's own server, which is left as it is.
            if result == .alreadyThere, FileManager.default.fileExists(atPath: file.path) { result = .tokenReplaced }
            if result == .added || result == .tokenReplaced {
                do {
                    _ = try FileManager.default.replaceItemAt(file, withItemAt: pending)
                } catch {
                    try? FileManager.default.removeItem(at: pending)
                    return .failed("Couldn't save the token.")
                }
            } else {
                try? FileManager.default.removeItem(at: pending)
            }
            return result
        case .local(let command, let commandArguments, let requirement):
            guard hasRequirement(recommendation) else { return .missingRequirement(requirement) }
            arguments += [recommendation.id, "--", command] + commandArguments
        case .connector:
            return .notAddable
        }
        return await runAdd(arguments)
    }

    private func runAdd(_ arguments: [String]) async -> AddResult {
        guard let outcome = await run(claude, arguments, environment) else { return .failed(nil) }
        if outcome.status == 0 { return .added }
        let line = Self.firstLine(outcome.stderr)
        // Claude Code 2.1.302: "MCP server <name> already exists in user config", exit 1.
        if line?.localizedCaseInsensitiveContains("already exists") == true { return .alreadyThere }
        return .failed(line)
    }

    /// Removes a server Lumi added: only ones whose `add` returned `.added` (the caller keeps track),
    /// never `.alreadyThere`, which is the user's own. Its token file goes too. True once it's gone,
    /// including when it was already gone.
    public func remove(_ recommendation: MCPRecommendation) async -> Bool {
        guard let outcome = await run(claude, ["mcp", "remove", "--scope", "user", recommendation.id], environment) else { return false }
        // Claude Code 2.1.302: `No MCP server named "<name>" in user scope`, exit 1.
        let gone = outcome.status == 0 || Self.firstLine(outcome.stderr)?.hasPrefix("No MCP server named") == true
        if gone {
            let file = headersFile(recommendation)
            try? FileManager.default.removeItem(at: file)
            // And any pending token an interrupted add left beside it.
            let prefix = file.lastPathComponent + ".new-"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: secrets.path)) ?? [] where name.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: secrets.appending(path: name))
            }
        }
        return gone
    }

    /// Owner-only from the first byte: the folder 0700 and the file created 0600 before it's written.
    private func writePrivately(_ headers: [String: String], to file: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: secrets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secrets.path)
        let data = try JSONSerialization.data(withJSONObject: headers)
        try? fm.removeItem(at: file)
        guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    /// `path` as one single-quoted shell word.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
