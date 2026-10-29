import Foundation
import Testing
@testable import BuddyCore

/// The tiers the inline approval card and voice "yes" rely on (10 §1.8). SessionTypesTests
/// covers the path rules; these cover the tools.
struct ApprovalTierTests {
    let dirs = [URL(filePath: "/Users/me/repo"), URL(filePath: "/Users/me/notes")]

    func tier(_ tool: String, _ input: [String: String] = [:]) -> ApprovalTier {
        ApprovalTier.classify(tool: tool, input: input, sessionDirs: dirs)
    }

    @Test(arguments: ["Read", "Glob", "Grep"])
    func readsAreReversibleAnywhere(tool: String) {
        #expect(tier(tool, ["file_path": "/etc/hosts", "path": "/"]) == .reversible)
    }

    @Test(arguments: [
        "mcp__claude_ai_Slack__send_message", "mcp__claude_ai_Gmail__create_draft", "mcp__notion__update_page",
        "mcp__github__delete_branch", "mcp__site__publish", "mcp__claude_ai_Slack__search_public", "mcp__x__read_thing",
    ])
    func everyConnectorToolNeedsAClick(tool: String) {
        #expect(tier(tool) == .needsClick)
    }

    @Test(arguments: ["Bash", "WebFetch", "WebSearch", "Agent", "SendMessage", "Skill", "SomethingNew", ""])
    func shellWebAndUnknownToolsNeedAClick(tool: String) {
        #expect(tier(tool, ["command": "ls", "url": "https://example.com"]) == .needsClick)
    }

    @Test func editsInsideAnyDirAreReversible() {
        #expect(tier("Edit", ["file_path": "/Users/me/notes/a.md"]) == .reversible)
        #expect(tier("Write", ["file_path": "~/x/a.md"]) == .needsClick)
        #expect(tier("Edit", ["file_path": "/Users/me/repo/./sub/../a.swift"]) == .reversible)
    }
}
