import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

struct LaunchSpecTests {
    @Test func quickCommandLine() {
        let args = spec().arguments
        #expect(Array(args.prefix(5)) == ["-p", "--model", "claude-haiku-5-5", "--effort", "low"])
        for flag in ["--input-format", "--output-format", "--verbose", "--include-partial-messages", "--plugin-dir"] {
            #expect(args.contains(flag))
        }
        #expect(args.contains("auto"))
        #expect(!args.contains("--forward-subagent-text"))
        #expect(!args.contains("--resume"))
    }

    @Test func quickRunsTheBuddyAgentWithTheSkillAppended() {
        let plugin = URL(fileURLWithPath: "/Users/me/Library/Application Support/com.loomtable.lumi/plugin")
        let q = LaunchSpec.quick(executable: URL(fileURLWithPath: "/c"), home: URL(fileURLWithPath: "/Users/me"),
                                 plugin: plugin, environment: [:])
        let args = q.arguments
        #expect(args.contains("buddy:buddy-quick"))
        #expect(args.contains(plugin.path + "/skills/buddy-answer/SKILL.md"))
        #expect(q.workingDirectory.path == "/Users/me")
        let d = LaunchSpec.deep(executable: URL(fileURLWithPath: "/c"), folder: URL(fileURLWithPath: "/p"),
                                plugin: plugin, resume: "s1", environment: [:])
        #expect(!d.arguments.contains("--agent"))
        #expect(d.arguments.contains("--append-system-prompt-file"))
        #expect(d.arguments.suffix(2) == ["--resume", "s1"])
    }

    /// Nobody can answer a prompt in Quick or Deep: it's denied, and an MCP elicitation cancelled.
    @Test func quickAndDeepAnswerNoPermissionPrompts() {
        let plugin = URL(fileURLWithPath: "/plugin")
        let q = LaunchSpec.quick(executable: URL(fileURLWithPath: "/c"), home: URL(fileURLWithPath: "/h"),
                                 plugin: plugin, environment: [:])
        let d = LaunchSpec.deep(executable: URL(fileURLWithPath: "/c"), folder: URL(fileURLWithPath: "/p"),
                                plugin: plugin, resume: "s1", environment: [:])
        for args in [q.arguments, d.arguments, d.resuming("s2").arguments] {
            let i = args.firstIndex(of: "--permission-prompts")
            #expect(i.map { args[$0 + 1] } == "none")
        }
        #expect(!spec().arguments.contains("--permission-prompts"))
    }

    @Test func deepForwardsSubagentText() {
        #expect(spec(mode: .deep).arguments.contains("--forward-subagent-text"))
        #expect(spec(mode: .deep).arguments.contains("claude-opus-5-5"))
    }

    /// S4: the CLI doesn't restore these on resume, so every resume passes them again.
    @Test func resumeRepassesPluginAndFallback() {
        var withSettings = spec()
        withSettings.settings = "/Users/me/Library/Application Support/com.loomtable.lumi/settings.json"
        withSettings.mcpConfigs = ["/a.json", #"{"mcpServers":{}}"#]
        let resumed = withSettings.resuming("abc").arguments
        #expect(resumed.contains("--settings"))
        #expect(resumed.contains(withSettings.settings!))
        let mcp = resumed.firstIndex(of: "--mcp-config")!
        #expect(Array(resumed[(mcp + 1)...(mcp + 2)]) == withSettings.mcpConfigs)
        #expect(spec().arguments.contains("--fallback-model"))
        #expect(spec().arguments.contains("claude-sonnet-5-5"))
        let args = spec().resuming("abc").arguments
        #expect(args.suffix(2) == ["--resume", "abc"])
        #expect(args.contains("--plugin-dir"))
        #expect(args.contains("--fallback-model"))
    }

    @Test func environmentDropsParentSessionVariables() {
        let env = LaunchEnvironment.make(
            base: ["CLAUDECODE": "1", "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/x.sock", "CLAUDE_EFFORT": "medium",
                   "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "ANTHROPIC_BASE_URL": "https://proxy"],
            loginShellPath: "/Users/me/.nvm/bin:/opt/homebrew/bin:/usr/bin", home: "/Users/me")
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["CLAUDE_CODE_MESSAGING_SOCKET"] == nil)
        #expect(env["CLAUDE_EFFORT"] == nil)
        #expect(env["ANTHROPIC_BASE_URL"] == "https://proxy")
        let path = env["PATH"]!.split(separator: ":").map(String.init)
        #expect(path.first == "/Users/me/.nvm/bin")
        #expect(path.contains("/Users/me/.local/bin"))
        #expect(Set(path).count == path.count)
    }

    /// The real zsh with a throwaway HOME whose `.zshrc` plays the user's rc file: a data file, so no
    /// new executable is made. A fresh executable's first exec waits on macOS's security check, which
    /// runs one at a time system-wide (0.17 s alone, 9.7 s for 20 at once, at 0% CPU); spawned from
    /// test threads, those waits starved the whole suite until it hung (Oct 17).
    private struct LoginShell {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("login-shell-\(UUID().uuidString)")
        init(rc: String) throws {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try (rc + "\n").write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        }
        /// 30 s: a ceiling a shell that answers never reaches, but one a loaded Mac's zsh start-up
        /// (batch 1: load average 158) can't miss either.
        func path(timeout: Duration = .seconds(30)) async -> String? {
            defer { try? FileManager.default.removeItem(at: home) }
            return await LaunchEnvironment.loginShellPath(shell: "/bin/zsh", home: home.path, timeout: timeout)
        }
    }

    @Test func loginShellPathSkipsStartupNoise() async throws {
        let shell = try LoginShell(rc: #"export PATH=/opt/homebrew/bin:/usr/bin; echo "Welcome!""#)
        #expect(await shell.path() == "/opt/homebrew/bin:/usr/bin")
    }

    /// The flake behind loginShellPathSkipsStartupNoise: a shell that exits before its output has been
    /// read. Here the output arrives just after the shell exits (a child still holding the pipe), well
    /// inside the 0.5 s grace even when the child is scheduled late on a loaded machine.
    @Test func outputArrivingJustAfterTheShellExitsIsStillRead() async throws {
        let shell = try LoginShell(rc: #"(sleep 0.05; printf '\n__SB_PATH__/usr/bin\n__SB_END__\n') & exit 0"#)
        #expect(await shell.path() == "/usr/bin")
    }

    @Test func aShellThatPrintsNothingStillGivesUpSoon() async throws {
        let shell = try LoginShell(rc: "exit 0")
        let start = ContinuousClock.now
        #expect(await shell.path(timeout: .seconds(90)) == nil)
        // Far below the timeout, with room for a slow zsh start on a loaded machine.
        #expect(ContinuousClock.now - start < .seconds(45), "the 0.5 s grace, not the 90 s timeout")
    }

    /// Interactive shells ignore SIGTERM; the deadline must still hold.
    @Test func loginShellPathGivesUpOnAHungShell() async throws {
        let shell = try LoginShell(rc: "trap '' TERM; sleep 120")
        let start = ContinuousClock.now
        #expect(await shell.path(timeout: .milliseconds(300)) == nil)
        // Far below the shell's 120 s, with room for a loaded machine: the deadline held.
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    /// An rc file that forks a child holding stdout must not block the read.
    @Test func loginShellPathIgnoresAChildHoldingStdout() async throws {
        // An absolute path: with PATH set to /usr/bin, plain `sleep` (in /bin) would not be found and no
        // child would hold the pipe.
        let shell = try LoginShell(rc: "/bin/sleep 120 & export PATH=/usr/bin")
        let start = ContinuousClock.now
        #expect(await shell.path(timeout: .seconds(90)) == "/usr/bin")
        // Answered without waiting for the 120 s child, or the 90 s timeout; the margin absorbs a loaded machine.
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    @Test func locatesClaude() {
        let found = LaunchEnvironment.locateClaude(preferred: nil, path: "/x/bin", home: "/Users/me") {
            $0 == "/opt/homebrew/bin/claude" || $0 == "/x/bin/claude"
        }
        #expect(found?.path == "/opt/homebrew/bin/claude")
        #expect(LaunchEnvironment.locateClaude(preferred: "/custom/claude", path: "", home: "/h") { $0 == "/custom/claude" }?.path == "/custom/claude")
        #expect(LaunchEnvironment.locateClaude(preferred: nil, path: "", home: "/h") { _ in false } == nil)
    }

    @Test func turnInputPutsImagesBeforeText() throws {
        let line = TurnInput(text: "why is this empty?", images: [.init(data: Data([1, 2, 3]), mediaType: "image/png")]).streamJSONLine
        #expect(line.last == 0x0A)
        let o = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let content = try #require((o["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        #expect((content[0]["source"] as? [String: Any])?["data"] as? String == "AQID")
        #expect(o["parent_tool_use_id"] is NSNull)
    }
}

struct FolderTrustTests {
    private let json = Data("""
    {"numStartups": 3, "projects": {
      "/Users/me/Developer": {"hasTrustDialogAccepted": true},
      "/Users/me/Developer/lumi": {"hasTrustDialogAccepted": false},
      "/Users/me/Notes/": {"hasTrustDialogAccepted": true},
      "/Users/me": {"hasTrustDialogAccepted": false},
      "/tmp/odd": {"hasTrustDialogAccepted": "yes"}
    }}
    """.utf8)

    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    @Test func exactFolderRule() {
        let trust = FolderTrust(claudeJSON: json)
        #expect(trust.isTrusted(url("/Users/me/Developer"), rule: .exactFolder))
        #expect(trust.isTrusted(url("/Users/me/Notes"), rule: .exactFolder))
        #expect(!trust.isTrusted(url("/Users/me/Developer/aipulse"), rule: .exactFolder))
    }

    /// Rule (S4): a trusted ancestor trusts everything below it — even a child that
    /// ~/.claude.json marks `false`, because interactive Claude Code behaves the same way.
    @Test func ancestorRuleTrustsChildrenEvenWhenMarkedFalse() {
        let trust = FolderTrust(claudeJSON: json)
        #expect(trust.isTrusted(url("/Users/me/Developer/aipulse/web"), rule: .folderOrAncestor))
        #expect(trust.isTrusted(url("/Users/me/Developer/lumi"), rule: .folderOrAncestor))
        #expect(!trust.isTrusted(url("/Users/me/Downloads/repo"), rule: .folderOrAncestor))
        #expect(!trust.isTrusted(url("/Users/me"), rule: .folderOrAncestor))
        #expect(!trust.isTrusted(url("/tmp/odd"), rule: .folderOrAncestor))
    }

    /// The number 1 is not `true`; trust must not fail open.
    @Test func onlyARealTrueTrusts() {
        let trust = FolderTrust(claudeJSON: Data(#"{"projects": {"/a": {"hasTrustDialogAccepted": 1}, "/b": {"hasTrustDialogAccepted": true}}}"#.utf8))
        #expect(!trust.isTrusted(url("/a"), rule: .exactFolder))
        #expect(trust.isTrusted(url("/b"), rule: .exactFolder))
    }

    @Test(arguments: [nil, Data("not json".utf8), Data("[]".utf8), Data(#"{"projects": 3}"#.utf8)])
    func anyFailureMeansUntrusted(data: Data?) {
        #expect(!FolderTrust(claudeJSON: data).isTrusted(url("/Users/me/Developer"), rule: .folderOrAncestor))
    }

    @Test func untrustedProjectsRunDeepInHome() {
        let trust = FolderTrust(claudeJSON: json)
        let home = url("/Users/me")
        #expect(trust.deepDirectory(for: url("/Users/me/Developer/aipulse"), home: home, rule: .folderOrAncestor).url.path == "/Users/me/Developer/aipulse")
        #expect(trust.deepDirectory(for: url("/Users/me/Downloads/x"), home: home, rule: .folderOrAncestor).url == home)
        #expect(trust.deepDirectory(for: nil, home: home, rule: .folderOrAncestor).url == home)
    }

    @Test func defaultsAreTheChosenPolicy() {
        #expect(DeepPolicy.default.trust == .folderOrAncestor)
        #expect(DeepPolicy.default.spawn == .onHandoff)
    }

    @Test func restartBackoff() {
        let p = RestartPolicy()
        #expect(p.delay(beforeAttempt: 1) == .seconds(1))
        #expect(p.delay(beforeAttempt: 2) == .seconds(2))
        #expect(p.delay(beforeAttempt: 3) == .seconds(5))
        #expect(p.delay(beforeAttempt: 4) == nil)
        #expect(p.delay(beforeAttempt: 0) == nil)
    }
}
