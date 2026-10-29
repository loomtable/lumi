import BuddyCore
import Foundation

/// Everything needed to start one `claude -p` stream-json process.
public struct LaunchSpec: Sendable, Equatable {
    public var executable: URL
    public var workingDirectory: URL
    public var mode: Mode
    public var config: ModeConfig
    public var pluginDirectory: URL?
    /// Resume this Claude Code session. Flags below are passed again on every resume because
    /// the CLI does not restore them (S4).
    public var resumeSessionID: String?
    public var fallbackModels: [ModelID]
    /// Run a plugin agent as the main thread (`--agent buddy:buddy-quick`).
    public var agent: String?
    public var appendSystemPromptFile: URL?
    /// `--append-system-prompt`: text appended to the system prompt (the lane's answer rules).
    public var appendSystemPrompt: String?
    /// `--settings` (a file path or JSON), re-passed on every launch and resume.
    public var settings: String?
    /// `--mcp-config` sources (files or JSON), re-passed on every launch and resume. Measured
    /// in M2: servers passed this way are awaited before the first turn (a server that took 5 s
    /// to initialise delayed `system/init` by 5.4–11.5 s), unlike the user's configured servers,
    /// which connect in the background and are reached mid-turn through ToolSearch. Keep it
    /// empty for Quick.
    public var mcpConfigs: [String]
    /// `--add-dir`: extra folders the session may use (Research writes its report here).
    public var addDirs: [URL] = []
    /// `--strict-mcp-config`: use only `mcpConfigs`, none of the user's MCP servers.
    public var strictMCPConfig = false
    /// `--setting-sources`: which settings files load (nil: all of them).
    public var settingSources: String?
    /// `--restricted`: no command-running tools, no user/project/local settings files, file tools
    /// confined to the working directories, bypassPermissions refused.
    public var restricted = false
    /// `--tools`: the built-in tools available (restricted mode needs WebFetch named here).
    public var tools: [String]?
    /// `--disable-slash-commands`: no skills (the buddy rules are appended, not loaded as skills).
    public var disableSlashCommands = false
    public var permissionMode: String
    /// `--permission-prompts none`: nobody answers prompts, so anything that would ask is denied at
    /// once ("do not retry"), and an MCP server's elicitation is cancelled. Without it an elicitation
    /// came to us as a `control_request` and the turn waited for an answer forever (2.1.301, measured).
    public var noPermissionPrompts = false
    public var environment: [String: String]
    /// An open session (the user's full Claude Code): `arguments` is built from this instead of
    /// the lane flags. See `open(executable:launch:permissionMode:environment:)`.
    public var open: OpenOptions?

    public struct OpenOptions: Sendable, Equatable {
        /// Lumi mints it: `--session-id` on the first launch, `--resume` after.
        public var claudeSession: UUID
        public var resume: Bool
        /// `--permission-mode`, only when the user's settings have no `permissions.defaultMode`.
        public var permissionMode: String?
        /// `--resume-session-at`: the resume keeps the conversation up to this message (an edited
        /// prompt's parent) and the next prompt branches from it.
        public var resumeAt: String?

        public init(claudeSession: UUID, resume: Bool, permissionMode: String?, resumeAt: String? = nil) {
            self.claudeSession = claudeSession
            self.resume = resume
            self.permissionMode = permissionMode
            self.resumeAt = resumeAt
        }
    }

    public init(
        executable: URL,
        workingDirectory: URL,
        mode: Mode,
        config: ModeConfig,
        pluginDirectory: URL? = nil,
        resumeSessionID: String? = nil,
        fallbackModels: [ModelID] = [],
        agent: String? = nil,
        appendSystemPromptFile: URL? = nil,
        settings: String? = nil,
        mcpConfigs: [String] = [],
        permissionMode: String = "auto",
        environment: [String: String]
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.mode = mode
        self.config = config
        self.pluginDirectory = pluginDirectory
        self.resumeSessionID = resumeSessionID
        self.fallbackModels = fallbackModels
        self.agent = agent
        self.appendSystemPromptFile = appendSystemPromptFile
        self.settings = settings
        self.mcpConfigs = mcpConfigs
        self.permissionMode = permissionMode
        self.environment = environment
    }

    /// The `claude` command line for a turn.
    public var arguments: [String] {
        if let open { return Self.openArguments(open, addDirs: addDirs) }
        var args = [
            "-p",
            "--model", config.model.rawValue,
            "--effort", config.effort.rawValue,
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", permissionMode,
        ]
        if noPermissionPrompts { args += ["--permission-prompts", "none"] }
        if mode != .quick { args.append("--forward-subagent-text") }
        if let pluginDirectory { args += ["--plugin-dir", pluginDirectory.path] }
        // `claude --help`: "Accepts a comma-separated list to try each in order."
        if !fallbackModels.isEmpty { args += ["--fallback-model", fallbackModels.map(\.rawValue).joined(separator: ",")] }
        if let settings { args += ["--settings", settings] }
        if !mcpConfigs.isEmpty { args += ["--mcp-config"] + mcpConfigs }
        if !addDirs.isEmpty { args += ["--add-dir"] + addDirs.map(\.path) }
        if strictMCPConfig { args.append("--strict-mcp-config") }
        if let settingSources { args += ["--setting-sources", settingSources] }
        if restricted { args.append("--restricted") }
        if let tools { args += ["--tools", tools.joined(separator: ",")] }
        if disableSlashCommands { args.append("--disable-slash-commands") }
        if let agent { args += ["--agent", agent] }
        if let appendSystemPrompt {
            args += ["--append-system-prompt", appendSystemPrompt]
        } else if let appendSystemPromptFile {
            args += ["--append-system-prompt-file", appendSystemPromptFile.path]
        }
        if let resumeSessionID { args += ["--resume", resumeSessionID] }
        return args
    }

    /// The Quick lane as measured in M1: the plugin's `buddy-quick` agent replaces Claude Code's
    /// default system prompt (small and cacheable, tools cut to Read/Glob/Grep) and the
    /// buddy-answer rules are appended with no tool call. A model-invoked skill costs a round
    /// trip, and an agent's `skills:` preload does not load for a main-session agent.
    public static func quick(executable: URL, home: URL, plugin: URL, config: ModeConfig = .default(for: .quick),
                             environment: [String: String]) -> LaunchSpec {
        var spec = LaunchSpec(executable: executable, workingDirectory: home, mode: .quick, config: config,
                              pluginDirectory: plugin, agent: "buddy:buddy-quick",
                              appendSystemPromptFile: buddyAnswerSkill(in: plugin), environment: environment)
        spec.appendSystemPrompt = AnswerRules.text(for: [.quick], in: plugin)
        spec.noPermissionPrompts = true
        return spec
    }

    /// The Deep lane: Claude Code's full prompt and tools in the project folder, with the
    /// buddy-answer rules appended so the final message ends in a `buddy` block.
    public static func deep(executable: URL, folder: URL, plugin: URL, resume: String?,
                            config: ModeConfig = .default(for: .deep), fallbackModels: [ModelID] = [],
                            environment: [String: String]) -> LaunchSpec {
        var spec = LaunchSpec(executable: executable, workingDirectory: folder, mode: .deep, config: config,
                              pluginDirectory: plugin, resumeSessionID: resume, fallbackModels: fallbackModels,
                              appendSystemPromptFile: buddyAnswerSkill(in: plugin), environment: environment)
        spec.appendSystemPrompt = AnswerRules.text(for: [.deep], in: plugin)
        spec.noPermissionPrompts = true
        return spec
    }

    /// An open session: the user's full Claude Code (00-PLAN, 02 §D8.2). No `--model`, `--effort`,
    /// `--fallback-model`, `--plugin-dir`, `--agent`, `--append-system-prompt[-file]`, `--restricted`,
    /// `--tools` or `--strict-mcp-config`. Prompts go to Lumi over stdio (`--permission-prompt-tool
    /// stdio`; `--permission-prompts host` alone sends no `can_use_tool`, probe 1), user lines echo
    /// with their uuids (`--replay-user-messages`), and every stored folder is passed again, because
    /// resume doesn't restore `--add-dir`.
    public static func open(executable: URL, launch: SessionLaunch, permissionMode: String?,
                            environment: [String: String]) -> LaunchSpec {
        var env = environment
        env["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = "1"
        env["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] = "1"
        env["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] = String(max(1, launch.maxSubagents))
        if launch.continueInterrupted && launch.exists {
            env["CLAUDE_CODE_RESUME_INTERRUPTED_TURN"] = "1"
        } else {
            env["CLAUDE_CODE_RESUME_INTERRUPTED_TURN"] = nil
        }
        var spec = LaunchSpec(executable: executable, workingDirectory: launch.cwd, mode: .deep, config: .default(for: .deep),
                              permissionMode: permissionMode ?? "", environment: env)
        spec.addDirs = launch.addDirs.filter { $0.standardizedFileURL.path != launch.cwd.standardizedFileURL.path }
        spec.open = OpenOptions(claudeSession: launch.claudeSession, resume: launch.exists, permissionMode: permissionMode,
                                resumeAt: launch.exists ? launch.resumeAt : nil)
        return spec
    }

    static func openArguments(_ open: OpenOptions, addDirs: [URL]) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--forward-subagent-text",
            "--replay-user-messages",
            "--permission-prompt-tool", "stdio",
        ]
        if let mode = open.permissionMode, !mode.isEmpty { args += ["--permission-mode", mode] }
        let id = open.claudeSession.uuidString.lowercased()
        args += open.resume ? ["--resume", id] : ["--session-id", id]
        if open.resume, let at = open.resumeAt { args += ["--resume-session-at", at] }
        if !addDirs.isEmpty { args += ["--add-dir"] + addDirs.map(\.path) }
        return args
    }

    /// The `--permission-mode` an open session passes: nil when the user's or the folder's settings
    /// set `permissions.defaultMode` (it applies under `-p`, probe 2), else `auto` (02 §D8.2).
    /// `settingsFiles`: `~/.claude/settings.json`, and the cwd's `.claude/settings.json` and
    /// `.claude/settings.local.json`.
    public static func openPermissionMode(settingsFiles: [URL], fallback: String = "auto",
                                          read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> String? {
        for file in settingsFiles {
            guard let data = read(file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let mode = (object["permissions"] as? [String: Any])?["defaultMode"] as? String,
                  !mode.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            return nil
        }
        return fallback
    }

    /// The settings files `openPermissionMode` reads for a session in `cwd`.
    public static func openSettingsFiles(home: URL, cwd: URL) -> [URL] {
        var files = [home.appendingPathComponent(".claude/settings.json")]
        if cwd.standardizedFileURL.path != home.standardizedFileURL.path {
            files += [cwd.appendingPathComponent(".claude/settings.json"), cwd.appendingPathComponent(".claude/settings.local.json")]
        }
        return files
    }

    static func buddyAnswerSkill(in plugin: URL) -> URL {
        plugin.appendingPathComponent("skills/buddy-answer/SKILL.md")
    }


    public func resuming(_ sessionID: String?) -> LaunchSpec {
        var copy = self
        copy.resumeSessionID = sessionID
        return copy
    }
}

/// Builds the child environment. A GUI app gets launchd's minimal environment, so the user's
/// tools (node for MCP servers, git) are missing from PATH unless we add the login shell's PATH.
/// In development the app may run inside a Claude Code session, whose session variables must
/// not leak into the child (S4: they made the child join the parent's messaging socket).
public enum LaunchEnvironment {
    /// Variables a parent Claude Code session sets for its own children.
    public static let parentSessionKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH",
    ]

    public static let fallbackPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func make(base: [String: String], loginShellPath: String?, home: String) -> [String: String] {
        var env = base.filter { !parentSessionKeys.contains($0.key) }
        var path: [String] = []
        for part in [loginShellPath, base["PATH"]].compactMap({ $0 }).flatMap({ $0.split(separator: ":").map(String.init) })
            + ["\(home)/.local/bin"] + fallbackPath where !path.contains(part) && !part.isEmpty {
            path.append(part)
        }
        env["PATH"] = path.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home
        return env
    }

    /// Reads PATH from the user's interactive login shell, the way editors pick up a GUI user's
    /// tools (zsh users often set PATH in .zshrc, which only interactive shells read). Startup
    /// output is skipped with a marker. Returns nil on failure or after `timeout`: interactive
    /// shells ignore SIGTERM, so the shell gets SIGKILL, and a child an rc file forked can hold
    /// stdout open, so output is read through a handler and never by blocking a thread.
    /// Call once at launch and cache.
    /// How long a shell that exited with nothing read is waited on before it counts as giving nothing.
    static let exitGrace: Duration = .milliseconds(500)

    public static func loginShellPath(shell: String, home: String, timeout: Duration = .seconds(3)) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", #"printf '\n__SB_PATH__%s\n__SB_END__\n' "$PATH""#]
        process.environment = ["HOME": home, "TERM": "dumb"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let buffer = Shared(Data())
        out.fileHandleForReading.readabilityHandler = outputCollector(buffer)
        do { try process.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let deadline = ContinuousClock.now + timeout
        var exitedWithNothing: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            // Done when the end marker is in: the shell may still be exiting, or a forked
            // child may hold the pipe.
            if let path = parseMarkedPath(buffer.withLock { $0 }) { return path }
            // A shell that exited with nothing read yet may still have output on its way (the
            // reading handler runs on its own queue, or a child writes it): give it a moment.
            if !process.isRunning, buffer.withLock({ $0.isEmpty }) {
                let now = ContinuousClock.now
                if let since = exitedWithNothing {
                    if now - since >= exitGrace { return nil }
                } else {
                    exitedWithNothing = now
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return parseMarkedPath(buffer.withLock { $0 })
    }

    private nonisolated static func outputCollector(_ buffer: Shared<Data>) -> @Sendable (FileHandle) -> Void {
        { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            buffer.withLock { if $0.count < 65_536 { $0.append(chunk) } }
        }
    }

    static func parseMarkedPath(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "__SB_PATH__", options: .backwards),
              let end = text.range(of: "\n__SB_END__", range: start.upperBound..<text.endIndex) else { return nil }
        let path = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Finds the user's `claude`: an explicit choice, then the native installer's location,
    /// then Homebrew and npm global paths, then anything else on PATH.
    public static func locateClaude(preferred: String?, path: String, home: String,
                                    isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        let candidates = [preferred].compactMap { $0 }
            + ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + path.split(separator: ":").map { "\($0)/claude" }
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

/// The buddy-answer rules each lane is given: the shared core (`SKILL.md`, frontmatter dropped) and the
/// lane's own notes (`quick.md`: when to answer or hand off, proposing changes; `deep.md`: links,
/// Quick's note, approved actions), so neither lane carries the other's. Nil only when the core can't
/// be read (the launch then appends `SKILL.md` as a file); a missing notes file leaves those notes out.
public enum AnswerRules {
    public enum Part: String, Sendable { case quick, deep }

    public static func text(for parts: [Part], in plugin: URL) -> String? {
        let folder = plugin.appendingPathComponent("skills/buddy-answer")
        guard let core = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        var text = withoutFrontmatter(core).trimmingCharacters(in: .whitespacesAndNewlines)
        for part in parts {
            guard let notes = try? String(contentsOf: folder.appendingPathComponent(part.rawValue + ".md"), encoding: .utf8)
            else { continue }
            text += "\n\n" + notes.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text + "\n"
    }

    static func withoutFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...])
    }
}
