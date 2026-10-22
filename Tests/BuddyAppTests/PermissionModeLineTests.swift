@testable import BuddyApp
import BuddyConversations
import BuddyOverlay
import Foundation
import Testing

struct PermissionModeLineTests {
    @Test func onlyAModeThatBlocksActionsGetsALine() {
        #expect(TurnFailureLine.permissionModeLine("auto") == nil)
        #expect(TurnFailureLine.permissionModeLine("bypassPermissions") == nil)
        #expect(TurnFailureLine.permissionModeLine("default")
                == "Claude Code is in default mode, not auto, so actions that need permission are blocked.")
        #expect(TurnFailureLine.permissionModeLine("dontAsk")?.contains("not auto") == true)
        #expect(TurnFailureLine.permissionModeLine("plan") == "Claude Code is in plan mode, so it plans but doesn't act.")
        #expect(TurnFailureLine.permissionModeLine("default")?.contains("ask") == false, "-p can't ask: never 'may ask'")
    }

    @MainActor
    @Test func theMenuLineFollowsTheReportedMode() {
        let runtime = AppRuntime(voice: UnavailableVoice(), conversationIndex: { try ConversationIndex(url: nil) },
                                 overlay: { FakeOverlay() },
                                 traceDirectory: FileManager.default.temporaryDirectory.appending(path: "t-\(UUID().uuidString)"))
        runtime.setPermissionMode("default")
        #expect(runtime.problems.map(\.text) == [TurnFailureLine.permissionModeLine("default")!])
        runtime.setPermissionMode("plan")
        #expect(runtime.problems.map(\.text) == [TurnFailureLine.permissionModeLine("plan")!], "replaced, not stacked")
        runtime.setPermissionMode("auto")
        #expect(runtime.problems.isEmpty, "auto is back: nothing stale")
    }
}
