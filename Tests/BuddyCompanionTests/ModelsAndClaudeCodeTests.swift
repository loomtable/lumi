import BuddyBridge
import BuddyCore
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Settings › Models and Claude Code")
@MainActor
struct ModelsAndClaudeCodeTests {
    private func decode(_ json: String) throws -> ModelPreferences {
        try JSONDecoder().decode(ModelPreferences.self, from: Data(json.utf8))
    }

    @Test("Defaults are BuddyCore's: Haiku low, Opus high, Opus max, Auto")
    func defaults() {
        let m = ModelPreferences()
        #expect(m.quick == ModeConfig(model: .haiku, effort: .low))
        #expect(m.deep == ModeConfig(model: .opus, effort: .high))
        #expect(m.research == ModeConfig(model: .opus, effort: .max))
        #expect(m.routing == .auto)
        #expect(Mode.allCases.allSatisfy { m.isDefault($0) })
    }

    @Test("An effort a mode doesn't offer falls back to its default; a blank ID to its default model")
    func cleaning() throws {
        let m = try decode(#"{"quick": {"model": "  claude-sonnet-5-5 ", "effort": "max"}, "deep": {"model": "", "effort": "low"}}"#)
        #expect(m.quick == ModeConfig(model: "claude-sonnet-5-5", effort: .low))
        #expect(m.deep == ModeConfig(model: .opus, effort: .high))
        #expect(m.research == .default(for: .research), "missing keys keep their defaults")
    }

    @Test("A field added later never loses the user's other choices")
    func forwardCompatible() throws {
        let m = try decode(#"{"routing": "alwaysDeep", "somethingNew": 3}"#)
        #expect(m.routing == .alwaysDeep)
    }

    @Test("Any model ID can be typed; set() keeps it, trimmed")
    func customModel() {
        var m = ModelPreferences()
        m.set(ModeConfig(model: "claude-fable-5-1 ", effort: .medium), for: .quick)
        #expect(m.quick == ModeConfig(model: "claude-fable-5-1", effort: .medium))
        #expect(!m.isDefault(.quick))
        m.restoreDefaults()
        #expect(m == ModelPreferences())
    }

    @Test("The pane's status comes from the probe and the session's plugin_errors")
    func statusMapping() {
        let report = ClaudeCodeReport(executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude"), version: "2.1.296",
                                      auth: .init(loggedIn: true, method: "claude.ai", subscription: "max", provider: "firstParty"),
                                      plugin: .valid)
        let ok = ClaudeCodeStatus(report: report)
        #expect(ok.loggedIn == true && ok.loginDetail == "Claude Max" && ok.pluginLoaded == true && ok.checked)
        let failedToLoad = ClaudeCodeStatus(report: report, pluginErrors: ["path-not-found: plugin"])
        #expect(failedToLoad.pluginLoaded == false && failedToLoad.pluginProblem == "path-not-found: plugin")
        var missing = report
        missing.executable = nil
        missing.version = nil
        missing.auth = nil
        missing.plugin = ClaudeCodeReport.PluginCheck.notInstalled
        let none = ClaudeCodeStatus(report: missing)
        #expect(none.executablePath == nil && none.checked && none.pluginLoaded == nil, "not checked, so not \"needs repair\"")
        var notCopied = report
        notCopied.plugin = ClaudeCodeReport.PluginCheck.notInstalled
        #expect(ClaudeCodeStatus(report: notCopied).pluginLoaded == false)
        var unknown = report
        unknown.plugin = ClaudeCodeReport.PluginCheck.unknown("The plugin check didn't finish.")
        let u = ClaudeCodeStatus(report: unknown)
        #expect(u.pluginLoaded == nil && u.pluginProblem == "The plugin check didn't finish.")
    }

    @Test("Login detail names the plan or provider, never the account")
    func loginDetail() {
        #expect(ClaudeCodeStatus.loginDetail(.init(loggedIn: true, method: "api_key", subscription: nil, provider: "firstParty")) == "API key")
        #expect(ClaudeCodeStatus.loginDetail(.init(loggedIn: true, method: nil, subscription: nil, provider: "bedrock")) == "Bedrock")
        #expect(ClaudeCodeStatus.loginDetail(.init(loggedIn: true, method: "claude.ai", subscription: "pro", provider: nil)) == "Claude Pro")
    }
}
