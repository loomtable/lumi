import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// Each `claude` call's arguments.
private final class Calls: Sendable {
    let list = Mutex<[[String]]>([])
}

struct MCPCatalogTests {
    private let claude = URL(fileURLWithPath: "/Users/me/.local/bin/claude")
    private let secrets = FileManager.default.temporaryDirectory.appending(path: "MCPSecrets-\(UUID().uuidString)/it's here", directoryHint: .isDirectory)

    /// An installer whose `claude` answers `reply` and records each call's arguments.
    private func installer(_ reply: (status: Int32, stdout: String, stderr: String)? = (0, "Added", ""),
                           npx: Bool = true, calls: Calls) -> ClaudeCodeMCP {
        ClaudeCodeMCP(claude: claude, environment: ["PATH": "/usr/bin:/opt/homebrew/bin"], secrets: secrets, run: { _, args, _ in
            calls.list.withLock { $0.append(args) }
            return reply
        }, isExecutable: { npx && $0 == "/opt/homebrew/bin/npx" })
    }

    private func recommendation(_ id: String) -> MCPRecommendation {
        MCPCatalog.recommended.first { $0.id == id }!
    }

    @Test func theCatalogIsTheApprovedList() {
        let catalog = MCPCatalog.recommended
        #expect(catalog.map(\.id) == ["context7", "playwright", "github", "linear", "notion", "slack", "atlassian"])
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        #expect(catalog.filter(\.isAddable).map(\.id) == ["context7", "playwright", "github"])
        for item in catalog {
            #expect(item.serverNames.contains(item.id))
            switch item.setup {
            case .remote(let url), .remoteWithToken(let url, _), .connector(let url): #expect(url.scheme == "https")
            case .local(_, _, let requirement): #expect(requirement.download.scheme == "https")
            }
        }
    }

    @Test func eachSetupBecomesItsUserScopeCommand() async {
        let calls = Calls()
        let mcp = installer(calls: calls)
        #expect(await mcp.add(recommendation("context7")) == .added)
        #expect(await mcp.add(recommendation("playwright")) == .added)
        #expect(calls.list.withLock { $0 } == [
            ["mcp", "add", "--scope", "user", "--transport", "http", "context7", "https://mcp.context7.com/mcp"],
            ["mcp", "add", "--scope", "user", "playwright", "--", "npx", "@playwright/mcp@latest"],
        ])
    }

    @Test func aTokenNeverGoesOnTheCommandLine() async throws {
        defer { try? FileManager.default.removeItem(at: secrets.deletingLastPathComponent()) }
        let calls = Calls()
        let mcp = installer(calls: calls)
        #expect(await mcp.add(recommendation("github"), token: "  ghp_abc123\n") == .added)
        let args = try #require(calls.list.withLock { $0 }.first)
        #expect(!args.joined(separator: " ").contains("ghp_abc123"))
        #expect(Array(args.prefix(5)) == ["mcp", "add-json", "--scope", "user", "github"])
        let server = try JSONSerialization.jsonObject(with: Data(args[5].utf8)) as? [String: String]
        let file = mcp.headersFile(recommendation("github"))
        #expect(server == ["type": "http", "url": "https://api.githubcopilot.com/mcp/",
                           "headersHelper": "/bin/cat " + ClaudeCodeMCP.shellQuoted(file.path)])
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String] == ["Authorization": "Bearer ghp_abc123"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: secrets.path)[.posixPermissions] as? Int == 0o700)

        // The helper prints exactly that file, path quoting and all.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", server?["headersHelper"] ?? ""]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()
        shell.waitUntilExit()
        #expect(try JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: String]
                == ["Authorization": "Bearer ghp_abc123"])

        try Data("{}".utf8).write(to: file.appendingPathExtension("new-interrupted"))
        #expect(await installer((0, "Removed", ""), calls: calls).remove(recommendation("github")))
        #expect(!FileManager.default.fileExists(atPath: file.path), "removing the server removes its token")
        #expect(try FileManager.default.contentsOfDirectory(atPath: secrets.path).isEmpty, "and any pending one")
    }

    @Test func tokensLiveInAFolderThatNeverMoves() {
        // Users' Claude Code configs point here (headersHelper); a rename or migration must not move it.
        #expect(ClaudeCodeMCP.defaultSecrets.path.hasSuffix("/Library/Application Support/Loomtable/Lumi/connections"))
    }

    @Test func reAddingAConnectionLumiAddedReplacesItsTokenAndNeverBreaksIt() async throws {
        defer { try? FileManager.default.removeItem(at: secrets.deletingLastPathComponent()) }
        let calls = Calls()
        let first = installer(calls: calls)
        #expect(await first.add(recommendation("github"), token: "ghp_old") == .added)
        let file = first.headersFile(recommendation("github"))
        let again = installer((1, "", "MCP server github already exists in user config"), calls: calls)
        #expect(await again.add(recommendation("github"), token: "ghp_new") == .tokenReplaced)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String] == ["Authorization": "Bearer ghp_new"],
                "the server's helper still finds a file, with the new token")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

        // A refusal for another reason keeps the token that works.
        #expect(await installer((1, "", "Something broke"), calls: calls).add(recommendation("github"), token: "ghp_bad") == .failed("Something broke"))
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String] == ["Authorization": "Bearer ghp_new"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: secrets.path)
        #expect(leftovers == ["github.headers.json"], "no pending files left behind")
    }

    @Test func aTokenThatWasntUsedIsntKept() async {
        defer { try? FileManager.default.removeItem(at: secrets.deletingLastPathComponent()) }
        let calls = Calls()
        let theirs = installer((1, "", "MCP server github already exists in user config"), calls: calls)
        #expect(await theirs.add(recommendation("github"), token: "ghp_abc123") == .alreadyThere)
        #expect(!FileManager.default.fileExists(atPath: theirs.headersFile(recommendation("github")).path))
    }

    @Test func nothingRunsForWhatLumiDoesntAdd() async {
        let calls = Calls()
        let mcp = installer(npx: false, calls: calls)
        #expect(await mcp.add(recommendation("linear")) == .notAddable, "a connector is added on claude.ai")
        #expect(await mcp.add(recommendation("github")) == .notAddable)
        #expect(await mcp.add(recommendation("github"), token: "   ") == .notAddable)
        #expect(await mcp.add(recommendation("github"), token: "abc\r\nX-Evil: 1") == .notAddable, "never a second header")
        guard case .local(_, _, let node) = recommendation("playwright").setup else { Issue.record("playwright is local"); return }
        #expect(await mcp.add(recommendation("playwright")) == .missingRequirement(node))
        #expect(!mcp.hasRequirement(recommendation("playwright")) && mcp.hasRequirement(recommendation("context7")))
        #expect(calls.list.withLock { $0 }.isEmpty)
    }

    @Test func refusalsAreToldApart() async {
        let calls = Calls()
        let there = installer((1, "", "MCP server context7 already exists in user config\n"), calls: calls)
        #expect(await there.add(recommendation("context7")) == .alreadyThere, "the user's own server is left as it is")
        #expect(await installer((1, "", "\nSomething else broke\nmore\n"), calls: calls).add(recommendation("context7"))
                == .failed("Something else broke"))
        #expect(await installer(nil, calls: calls).add(recommendation("context7")) == .failed(nil))
    }

    @Test func removeIsUserScopeAndAlreadyGoneCounts() async {
        let calls = Calls()
        #expect(await installer((0, "Removed", ""), calls: calls).remove(recommendation("context7")))
        #expect(await installer((1, "", #"No MCP server named "context7" in user scope"#), calls: calls).remove(recommendation("context7")))
        #expect(!(await installer((1, "", "permission denied"), calls: calls).remove(recommendation("context7"))))
        #expect(!(await installer(nil, calls: calls).remove(recommendation("context7"))))
        #expect(calls.list.withLock { $0 }.first == ["mcp", "remove", "--scope", "user", "context7"])
    }

    @Test func aConnectionIsFoundUnderAnyOfItsNames() {
        let servers = [
            StreamEvent.MCPServer(name: "plugin:atlassian:atlassian", status: "connected", source: "plugin"),
            StreamEvent.MCPServer(name: "claude.ai Linear", status: "needs-auth", source: "claudeai"),
            StreamEvent.MCPServer(name: "Context7", status: "connected", source: "user"),
        ]
        #expect(recommendation("linear").server(in: servers)?.status == "needs-auth")
        #expect(recommendation("atlassian").server(in: servers)?.source == "plugin")
        #expect(recommendation("context7").server(in: servers)?.name == "Context7")
        #expect(recommendation("slack").server(in: servers) == nil)
    }

    @Test func initKeepsEachServersSource() throws {
        let line = Data(#"{"type":"system","subtype":"init","session_id":"s","mcp_servers":[{"name":"claude.ai Slack","status":"needs-auth","source":"claudeai"},{"name":"old","status":"connected"}]}"#.utf8)
        guard case .initialized(let info) = StreamEvent(line: line) else { Issue.record("not init"); return }
        #expect(info.mcpServers == [.init(name: "claude.ai Slack", status: "needs-auth", source: "claudeai"),
                                    .init(name: "old", status: "connected")])
    }

    @Test func theRealRunnerKeepsStandardError() async {
        let run = ClaudeCodeProbe.outputRunner(deadline: .seconds(5))
        let outcome = await run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"], [:])
        #expect(outcome?.status == 3 && outcome?.stdout == "out\n" && outcome?.stderr == "err\n")
        // 200 KB of errors (a crash trace) doesn't stall the child: it's read while it runs.
        let big = await run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; exit 1"], [:])
        #expect(big?.status == 1 && big?.stderr.count == 200_000)
    }

    @Test func aGrandchildHoldingStandardErrorIsNilNotAHang() async {
        let run = ClaudeCodeProbe.outputRunner(deadline: .seconds(5))
        let clock = ContinuousClock(), start = clock.now
        #expect(await run(URL(fileURLWithPath: "/bin/sh"), ["-c", "(sleep 6 >/dev/null) & exit 0"], [:]) == nil)
        #expect(clock.now - start < .seconds(4))
    }

    @Test func aDirectoryNamedLikeTheCommandDoesntCount() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "npxdir-\(UUID().uuidString)/npx", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(!ClaudeCodeMCP.isExecutableFile(folder.path))
        #expect(ClaudeCodeMCP.isExecutableFile("/bin/sh"))
    }
}
