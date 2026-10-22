import Foundation
import Testing
@testable import BuddyBridge

struct PermissionNoticeTests {
    private func session(_ transport: ReplayTransport) async -> ClaudeSession {
        let s = ClaudeSession(spec: spec(), transport: transport)   // asks for --permission-mode auto
        await s.startPump()
        return s
    }

    private func initLine(mode: String) -> Data {
        Line.json(["type": "system", "subtype": "init", "session_id": "s-1", "model": "claude-haiku-5-5",
                   "cwd": "/Users/me", "permissionMode": mode, "tools": [], "mcp_servers": [], "plugins": []])
    }

    private func notices(_ events: [TurnEvent]) -> [PermissionNotice] {
        events.compactMap { if case .permissionNotice(let n) = $0 { n } else { nil } }
    }

    @Test func aDifferentModeIsReportedOncePerProcess() async {
        let turns = (0 ..< 2).flatMap { _ in [initLine(mode: "default"), Line.result("ok")] }
        let s = await session(ReplayTransport(lines: turns))
        let first = await collect(await s.ask(TurnInput(text: "1")))
        let second = await collect(await s.ask(TurnInput(text: "2")))
        #expect(notices(first) == [.modeDiffers(requested: "auto", actual: "default")])
        #expect(notices(second).isEmpty, "not repeated on every turn's init")
    }

    @Test func theRequestedModeIsQuiet() async {
        let s = await session(ReplayTransport(lines: [initLine(mode: "auto"), Line.result("ok")]))
        #expect(notices(await collect(await s.ask(TurnInput(text: "1")))).isEmpty)
    }

    @Test func deniedToolsAreReportedBeforeTheTurnEnds() async {
        let result = Line.json(["type": "result", "subtype": "success", "is_error": false, "session_id": "s-1", "result": "done",
                                "permission_denials": [["tool_name": "Bash", "tool_use_id": "t1", "tool_input": [:]],
                                                       ["tool_name": "Write", "tool_use_id": "t2", "tool_input": [:]]]])
        let s = await session(ReplayTransport(lines: [initLine(mode: "auto"), result]))
        let events = await collect(await s.ask(TurnInput(text: "1")))
        #expect(notices(events) == [.denied(tools: ["Bash", "Write"])])
        let noticeAt = events.firstIndex { if case .permissionNotice = $0 { true } else { false } }
        let endAt = events.firstIndex { if case .finished = $0 { true } else { false } }
        #expect(noticeAt != nil && endAt != nil && noticeAt! < endAt!, "the notice comes before the answer")
    }
}
