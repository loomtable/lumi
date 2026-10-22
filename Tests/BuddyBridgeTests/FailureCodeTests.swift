import Foundation
import Testing
@testable import BuddyBridge

/// Recorded failures (Claude Code 2.x, scrubbed): the synthetic reply's error code reaches the
/// failed turn's result, so the app can say what went wrong.
struct FailureCodeTests {
    private func session(_ transport: ReplayTransport) async -> ClaudeSession {
        let s = ClaudeSession(spec: spec(), transport: transport)
        await s.startPump()
        return s
    }

    @Test(arguments: [("error-signed-out.jsonl", "authentication_failed"), ("error-unknown-model.jsonl", "model_not_found")])
    func aFailedTurnCarriesClaudeCodesErrorCode(fixture: String, code: String) async throws {
        let s = await session(try ReplayTransport(fixture: Fixture.url(fixture)))
        let events = await collect(await s.ask(TurnInput(text: "hi")))
        guard case .failed(.turnFailed(let r)) = events.last else { Issue.record("\(events)"); return }
        #expect(r.errorCode == code)
    }

    @Test func offlineIsRetriesWithNoHTTPStatus() throws {
        let retries = try Fixture.events("retry-offline.jsonl").compactMap { e -> StreamEvent.APIRetry? in
            if case .apiRetry(let r) = e { r } else { nil }
        }
        #expect(retries.count == 8)
        #expect(retries.allSatisfy { $0.errorStatus == nil && $0.error == "unknown" })
        #expect(retries.map(\.attempt) == Array(1...8))
    }

    @Test func aNormalReplyHasNoErrorCode() {
        let line = Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#.utf8)
        guard case .assistant(_, _, _, let error) = StreamEvent(line: line) else { Issue.record("not assistant"); return }
        #expect(error == nil)
    }

    @Test func aLaterNormalReplyClearsAnEarlierErrorCode() async {
        let lines: [Data] = [
            Line.initLine(),
            Data(#"{"type":"assistant","error":"max_output_tokens","message":{"model":"<synthetic>","content":[{"type":"text","text":"x"}]}}"#.utf8),
            Data(#"{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[{"type":"text","text":"recovered"}]}}"#.utf8),
            Data(#"{"type":"result","subtype":"success","is_error":true,"session_id":"s","result":"later failure","terminal_reason":"api_error"}"#.utf8),
        ]
        let s = await session(ReplayTransport(lines: lines))
        let events = await collect(await s.ask(TurnInput(text: "hi")))
        guard case .failed(.turnFailed(let r)) = events.last else { Issue.record("\(events)"); return }
        #expect(r.errorCode == nil, "the stale code isn't pinned on an unrelated failure")
    }
}
