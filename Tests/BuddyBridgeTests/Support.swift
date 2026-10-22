import BuddyCore
import Foundation
@testable import BuddyBridge

enum Fixture {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func lines(_ name: String) throws -> [Data] {
        var splitter = LineSplitter()
        var lines = splitter.append(try Data(contentsOf: url(name)))
        if let last = splitter.finish() { lines.append(last) }
        return lines
    }

    static func events(_ name: String) throws -> [StreamEvent] {
        try lines(name).compactMap(StreamEvent.init(line:))
    }
}

/// Builds stream-json lines for synthetic turns.
enum Line {
    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func initLine(session: String = "s-1") -> Data {
        json(["type": "system", "subtype": "init", "session_id": session, "model": "claude-haiku-5-5",
              "cwd": "/Users/me", "permissionMode": "auto", "tools": [], "mcp_servers": [], "plugins": []])
    }

    static func textDelta(_ text: String) -> Data {
        json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
                                                "delta": ["type": "text_delta", "text": text]]])
    }

    static func result(_ text: String, session: String = "s-1", isError: Bool = false) -> Data {
        json(["type": "result", "subtype": "success", "is_error": isError, "session_id": session, "result": text])
    }

    static func toolUse(_ name: String, _ input: [String: String]) -> Data {
        json(["type": "assistant", "parent_tool_use_id": NSNull(),
              "message": ["content": [["type": "tool_use", "id": "t1", "name": name, "input": input]]]])
    }
}

func spec(mode: Mode = .quick, resume: String? = nil) -> LaunchSpec {
    LaunchSpec(executable: URL(fileURLWithPath: "/usr/local/bin/claude"),
               workingDirectory: URL(fileURLWithPath: "/Users/me"),
               mode: mode, config: .default(for: mode),
               pluginDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/com.loomtable.lumi/plugin"),
               resumeSessionID: resume, fallbackModels: ["claude-sonnet-5-5"], environment: [:])
}

func collect(_ stream: AsyncStream<TurnEvent>) async -> [TurnEvent] {
    var out: [TurnEvent] = []
    for await e in stream { out.append(e) }
    return out
}


/// Polls until `condition` holds (or 2 s pass), instead of sleeping a fixed time.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

let fastRestart = RestartPolicy(delays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
