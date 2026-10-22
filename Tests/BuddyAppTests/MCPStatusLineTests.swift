@testable import BuddyApp
@testable import BuddyBridge
import BuddyCompanion
import BuddyConversations
import BuddyCore
import BuddyOverlay
import Foundation
import Testing

struct MCPStatusLineTests {
    private func server(_ name: String, _ status: String) -> StreamEvent.MCPServer { .init(name: name, status: status) }

    @Test func onlyNeedsAuthAndFailedGetALine() {
        #expect(TurnFailureLine.mcpProblemLine([]) == nil)
        #expect(TurnFailureLine.mcpProblemLine([server("A", "connected"), server("B", "pending"), server("C", "disabled")]) == nil)
        #expect(TurnFailureLine.mcpProblemLine([server("Linear", "needs-auth")]) == "Linear needs sign-in in Claude Code.")
        #expect(TurnFailureLine.mcpProblemLine([server("Linear", "failed")]) == "Linear couldn't connect in Claude Code.")
    }

    @Test func severalServersShareOneLine() {
        #expect(TurnFailureLine.mcpProblemLine([server("Linear", "needs-auth"), server("Slack", "needs-auth")])
                == "Linear and Slack need sign-in in Claude Code.")
        #expect(TurnFailureLine.mcpProblemLine([server("Linear", "needs-auth"), server("Jira", "failed")])
                == "Linear needs sign-in and Jira couldn't connect in Claude Code.")
        let many = ["A", "B", "C", "D"].map { server($0, "failed") }
        #expect(TurnFailureLine.mcpProblemLine(many) == "A, B and 2 more couldn't connect in Claude Code.")
        #expect(TurnFailureLine.mcpProblemLine([server("A", "failed"), server("A", "failed")]) == "A couldn't connect in Claude Code.",
                "both lanes report the same server once")
    }

    @MainActor
    private func runtime() -> AppRuntime {
        AppRuntime(voice: UnavailableVoice(), conversationIndex: { try ConversationIndex(url: nil) },
                   overlay: { FakeOverlay() },
                   traceDirectory: FileManager.default.temporaryDirectory.appending(path: "t-\(UUID().uuidString)"))
    }

    @MainActor
    @Test func theMenuLineFollowsTheLatestReport() {
        let runtime = runtime()
        runtime.setPermissionMode("plan")
        let other = TurnFailureLine.permissionModeLine("plan")!
        runtime.setMCPServers([server("Linear", "needs-auth")], lane: .deep)
        #expect(runtime.problems.map(\.text) == [other, "Linear needs sign-in in Claude Code."])
        runtime.setMCPServers([], lane: .quick)
        #expect(runtime.problems.map(\.text) == [other, "Linear needs sign-in in Claude Code."],
                "a lane without the server doesn't clear it")
        runtime.setMCPServers([server("Linear", "failed")], lane: .deep)
        #expect(runtime.problems.map(\.text) == [other, "Linear couldn't connect in Claude Code."], "replaced, not stacked")
        runtime.setMCPServers([server("Linear", "connected")], lane: .deep)
        #expect(runtime.problems.map(\.text) == [other], "signed in: nothing stale, other lines kept")
    }

    @MainActor
    @Test func settingsListsEveryLanesServersAsLastReported() {
        let runtime = runtime()
        #expect(runtime.mcpServerList.isEmpty && runtime.connections == nil, "nothing before a session or Claude Code")
        runtime.setMCPServers([.init(name: "GitHub", status: "connected", source: "user"),
                               .init(name: "Linear", status: "needs-auth", source: "claudeai")], lane: .deep)
        runtime.setMCPServers([.init(name: "Linear", status: "pending", source: "claudeai")], lane: .quick)
        #expect(runtime.mcpServerList.sorted { $0.name < $1.name } == [.init(name: "GitHub", status: "connected", source: "user"),
                                          .init(name: "Linear", status: "needs-auth", source: "claudeai")],
                "a pending report keeps the last real status; each server once")
        runtime.setMCPServers([], lane: .deep)
        runtime.setMCPServers([], lane: .quick)
        #expect(runtime.mcpServerList.isEmpty, "removed in Claude Code: gone")
    }

    @MainActor
    @Test func connectionsGetAddAndRemoveOnlyOnceClaudeCodeIsFound() {
        let none = AppRuntime.connectionActions(nil)
        #expect(none.add == nil && none.remove == nil && none.hasRequirement == nil, "the rows hide Add and Remove")
        let mcp = ClaudeCodeMCP(claude: URL(fileURLWithPath: "/usr/bin/false"), environment: [:],
                                secrets: FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString)"))
        let found = AppRuntime.connectionActions(mcp)
        #expect(found.add != nil && found.remove != nil && found.hasRequirement != nil)
    }

    @MainActor
    @Test func aFresherLaneWinsOverAStaleOne() {
        let runtime = runtime()
        runtime.setMCPServers([server("Linear", "needs-auth")], lane: .deep)
        runtime.setMCPServers([server("Linear", "connected")], lane: .quick)
        #expect(runtime.problems.isEmpty, "signed in since Deep's last turn")
        runtime.setMCPServers([server("Linear", "needs-auth")], lane: .deep)
        runtime.setMCPServers([server("Linear", "failed")], lane: .quick)
        #expect(runtime.problems.map(\.text) == ["Linear couldn't connect in Claude Code."], "one status per server, never both")
    }

    @MainActor
    @Test func pendingKeepsTheLastKnownStatus() {
        let runtime = runtime()
        runtime.setMCPServers([server("Linear", "needs-auth")], lane: .deep)
        runtime.setMCPServers([server("Linear", "pending")], lane: .deep)
        #expect(runtime.problems.map(\.text) == ["Linear needs sign-in in Claude Code."], "a restart doesn't flicker it away")
    }

    @MainActor
    @Test func aServerNoLaneNamesAnyMoreDrops() {
        let runtime = runtime()
        runtime.setMCPServers([server("Linear", "needs-auth")], lane: .deep)
        runtime.setMCPServers([server("Slack", "failed")], lane: .quick)
        #expect(runtime.problems.map(\.text) == ["Linear needs sign-in and Slack couldn't connect in Claude Code."])
        runtime.setMCPServers([], lane: .deep)
        #expect(runtime.problems.map(\.text) == ["Slack couldn't connect in Claude Code."], "removed from Deep's config")
    }
}
