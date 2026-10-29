import Foundation
@testable import BuddyBridge

/// A `claude` the test drives line by line: it answers `initialize` (like the real CLI), runs an
/// optional script on every user line, and records what was written.
final class ScriptedTransport: ClaudeTransport {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state: Shared<State>
    /// Lines to emit for each user line written (its uuid and text).
    private let script: (@Sendable (_ uuid: String, _ text: String) -> [Data])?
    private let answersInitialize: Bool

    private struct State {
        var sent: [Data] = []
        var exit: Int32?
        var stderr = ""
        var closed = false
    }

    var answersStartupHandshake: Bool { true }

    /// `answersInitialize: false`: a CLI that dies before it starts up (crash it from the test).
    init(answersInitialize: Bool = true, script: (@Sendable (_ uuid: String, _ text: String) -> [Data])? = nil) {
        (lines, continuation) = AsyncStream<Data>.makeStream()
        state = Shared(State())
        self.script = script
        self.answersInitialize = answersInitialize
    }

    func send(_ line: Data) async throws {
        try state.withLock { s in
            guard s.exit == nil, !s.closed else { throw TransportError.inputClosed }
            s.sent.append(line)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if object["type"] as? String == "control_request", answersInitialize,
           let request = object["request"] as? [String: Any], request["subtype"] as? String == "initialize",
           let id = object["request_id"] as? String {
            emit(SLine.controlResponse(id))
        }
        if object["type"] as? String == "user", let script {
            let uuid = object["uuid"] as? String ?? ""
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined()
            for l in script(uuid, text) { emit(l) }
        }
    }

    func emit(_ line: Data) {
        guard state.withLock({ $0.exit == nil }) else { return }
        continuation.yield(line)
    }

    func closeInput() {
        state.withLock { s in
            s.closed = true
            if s.exit == nil { s.exit = 0 }
        }
        continuation.finish()
    }

    func terminate() {
        state.withLock { if $0.exit == nil { $0.exit = 143 } }
        continuation.finish()
    }

    func crash(status: Int32 = 1, stderr: String = "") {
        state.withLock {
            if $0.exit == nil { $0.exit = status }
            $0.stderr += stderr
        }
        continuation.finish()
    }

    func exitStatus() async -> Int32 {
        while true {
            if let exit = state.withLock({ $0.exit }) { return exit }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    var stderrTail: String { state.withLock { $0.stderr } }
    var exited: Int32? { state.withLock { $0.exit } }
    var sent: [[String: Any]] {
        state.withLock { $0.sent }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The control requests written, by subtype (initialize, interrupt, stop_task).
    func controlRequests(_ subtype: String) -> [[String: Any]] {
        sent.filter { $0["type"] as? String == "control_request" && ($0["request"] as? [String: Any])?["subtype"] as? String == subtype }
    }

    /// The control responses written (replies to the CLI's requests).
    var controlResponses: [[String: Any]] {
        sent.filter { $0["type"] as? String == "control_response" }.compactMap { $0["response"] as? [String: Any] }
    }

    var userLines: [[String: Any]] { sent.filter { $0["type"] as? String == "user" } }
}

/// Open-session stream lines (claude 2.1.312 shapes, docs/v2-sessions 10 "Probe results").
enum SLine {
    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func controlResponse(_ id: String, success: Bool = true) -> Data {
        json(["type": "control_response", "response": ["subtype": success ? "success" : "error", "request_id": id, "response": [:]]])
    }

    static func state(_ s: String) -> Data {
        json(["type": "system", "subtype": "session_state_changed", "state": s, "session_id": "c-1"])
    }

    static func initLine(session: String = "c-1") -> Data {
        json(["type": "system", "subtype": "init", "session_id": session, "model": "claude-opus-5-5", "cwd": "/Users/me",
              "permissionMode": "default", "tools": [], "mcp_servers": [], "plugins": []])
    }

    static func echo(_ uuid: String, _ text: String = "hi") -> Data {
        json(["type": "user", "isReplay": true, "uuid": uuid, "session_id": "c-1",
              "message": ["role": "user", "content": [["type": "text", "text": text]]]])
    }

    static func text(_ t: String) -> Data {
        json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": t]]])
    }

    static func result(_ text: String, uuids: [String] = [], isError: Bool = false, errors: [String] = []) -> Data {
        json(["type": "result", "subtype": isError ? "error_during_execution" : "success", "is_error": isError, "session_id": "c-1",
              "result": text, "user_message_uuids": uuids, "errors": errors])
    }

    static func canUseTool(_ id: String, tool: String = "Bash", input: [String: Any] = ["command": "npm test"]) -> Data {
        json(["type": "control_request", "request_id": id,
              "request": ["subtype": "can_use_tool", "tool_name": tool, "input": input, "tool_use_id": "toolu_1"]])
    }

    static func controlRequest(_ id: String, subtype: String) -> Data {
        json(["type": "control_request", "request_id": id, "request": ["subtype": subtype]])
    }

    static func taskStarted(_ id: String) -> Data {
        json(["type": "system", "subtype": "task_started", "task_id": id, "tool_use_id": "toolu_a", "description": "Look around",
              "task_type": "local_agent", "is_backgrounded": true])
    }

    static func taskDone(_ id: String) -> Data {
        json(["type": "system", "subtype": "task_notification", "task_id": id, "tool_use_id": "toolu_a", "status": "completed",
              "summary": "done"])
    }

    /// One whole turn: echo, running, init, text, result, idle.
    static func turn(_ uuid: String, answer: String = "Done.") -> [Data] {
        [echo(uuid), state("running"), initLine(), text(answer), result(answer, uuids: [uuid]), state("idle")]
    }
}
