import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// A scripted `claude` that answers stream-json control requests. The first question streams and never
/// finishes (so it can be interrupted); later questions answer at once.
final class InterruptibleTransport: ClaudeTransport {
    enum Reply: Sendable { case acknowledge, acknowledgeLate(Duration), refuse, ignore }
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let reply: Reply
    private let capabilities: [String]
    private let state = Mutex<(sent: [Data], questions: Int, terminated: Bool, exit: Int32?)>(([], 0, false, nil))

    init(reply: Reply, capabilities: [String] = ["interrupt_receipt_v1"]) {
        (lines, continuation) = AsyncStream.makeStream()
        self.reply = reply
        self.capabilities = capabilities
    }

    var sentTypes: [String] {
        state.withLock { $0.sent }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.compactMap { $0["type"] as? String }
    }
    var terminated: Bool { state.withLock { $0.terminated } }

    private func emit(_ object: [String: Any]) { continuation.yield(Line.json(object)) }

    func send(_ line: Data) async throws {
        guard state.withLock({ $0.exit == nil }) else { throw TransportError.inputClosed }
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let n = state.withLock { s -> Int in
            s.sent.append(line)
            if object["type"] as? String == "user" { s.questions += 1 }
            return s.questions
        }
        switch object["type"] as? String {
        case "user":
            emit(["type": "system", "subtype": "init", "session_id": "s-1", "permissionMode": "auto", "capabilities": capabilities])
            continuation.yield(Line.textDelta(n == 1 ? "thinking about the first question" : "second answer"))
            if n > 1 { continuation.yield(Line.result("second answer")) }
        case "control_request":
            let id = (object["request_id"] as? String) ?? ""
            switch reply {
            case .acknowledge:
                acknowledge(id)
            case .acknowledgeLate(let delay):
                Task {
                    try? await Task.sleep(for: delay)
                    self.acknowledge(id)
                }
            case .refuse:
                emit(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "no"]])
            case .ignore:
                break
            }
        default:
            break
        }
    }

    private func acknowledge(_ id: String) {
        emit(["type": "control_response", "response": ["subtype": "success", "request_id": id, "still_queued": []]])
        // As CLI 2.1.300 sends it: an error result for the aborted turn, and the process lives on.
        emit(["type": "result", "subtype": "error_during_execution", "is_error": true, "session_id": "s-1",
              "terminal_reason": "aborted_streaming", "result": "aborted first answer"])
    }

    func closeInput() { finish(0) }
    func terminate() {
        state.withLock { $0.terminated = true }
        finish(143)
    }
    private func finish(_ status: Int32) {
        state.withLock { if $0.exit == nil { $0.exit = status } }
        continuation.finish()
    }
    func exitStatus() async -> Int32 { state.withLock { $0.exit } ?? 0 }
    var stderrTail: String { "" }
}

struct InterruptTests {
    private func session(_ t: InterruptibleTransport, grace: Duration = .seconds(2)) async -> ClaudeSession {
        let s = ClaudeSession(spec: spec(), transport: t, interruptGrace: grace)
        await s.startPump()
        return s
    }

    private func waitForText(_ stream: AsyncStream<TurnEvent>) async -> AsyncStream<TurnEvent>.Iterator {
        var it = stream.makeAsyncIterator()
        while let e = await it.next() { if case .text = e { break } }
        return it
    }

    @Test func escInterruptsTheTurnAndKeepsTheProcessWarm() async throws {
        let t = InterruptibleTransport(reply: .acknowledge)
        let s = await session(t)
        var first = await waitForText(await s.ask(TurnInput(text: "first")))
        #expect(await s.cancel())
        var rest: [TurnEvent] = []
        while let e = await first.next() { rest.append(e) }
        #expect(rest.last == .failed(.cancelled), "Esc ends the turn at once")
        let second = await collect(await s.ask(TurnInput(text: "second")))
        guard case .finished(let o) = second.last else { Issue.record("no answer: \(second)"); return }
        #expect(o.result.text == "second answer", "the aborted turn's result isn't taken as this answer")
        #expect(await s.isAlive && !t.terminated, "no cold --resume next time")
        #expect(t.sentTypes == ["user", "control_request", "user"])
    }

    @Test func aQuestionAskedWhileTheInterruptSettlesGetsItsOwnAnswer() async throws {
        let t = InterruptibleTransport(reply: .acknowledgeLate(.milliseconds(150)))
        let s = await session(t)
        _ = await waitForText(await s.ask(TurnInput(text: "first")))
        #expect(await s.cancel())
        // Asked at once: the aborted turn's result is still on its way.
        let second = await collect(await s.ask(TurnInput(text: "second")))
        guard case .finished(let o) = second.last else { Issue.record("no answer: \(second)"); return }
        #expect(o.result.text == "second answer")
        #expect(!t.terminated)
    }

    @Test func theRealControlResponseParses() {
        // CLI 2.1.300, live.
        let line = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"probe-1","response":{"still_queued":[]}}}"#.utf8)
        #expect(StreamEvent(line: line) == .controlResponse(requestID: "probe-1", success: true))
        let refused = Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"x","error":"no"}}"#.utf8)
        #expect(StreamEvent(line: refused) == .controlResponse(requestID: "x", success: false))
    }

    @Test func anOlderCLIWithoutInterruptsIsStopped() async throws {
        let t = InterruptibleTransport(reply: .acknowledge, capabilities: [])
        let s = await session(t)
        _ = await waitForText(await s.ask(TurnInput(text: "first")))
        #expect(await s.cancel())
        #expect(t.terminated && !t.sentTypes.contains("control_request"))
    }

    @Test func aRefusedInterruptStopsTheProcess() async throws {
        let t = InterruptibleTransport(reply: .refuse)
        let s = await session(t)
        _ = await waitForText(await s.ask(TurnInput(text: "first")))
        #expect(await s.cancel())
        let deadline = ContinuousClock.now + .seconds(2)
        while !t.terminated, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(t.terminated)
    }

    @Test func noAnswerWithinTheGraceStopsTheProcessAndFreesTheNextQuestion() async throws {
        let t = InterruptibleTransport(reply: .ignore)
        let s = await session(t, grace: .milliseconds(80))
        _ = await waitForText(await s.ask(TurnInput(text: "first")))
        #expect(await s.cancel())
        // Asked while the interrupt is pending: it waits, then finds the process gone (the lane relaunches).
        let next = await collect(await s.ask(TurnInput(text: "second")))
        #expect(t.terminated)
        guard case .failed(.processExited) = next.last else { Issue.record("expected a stopped process: \(next)"); return }
    }
}
