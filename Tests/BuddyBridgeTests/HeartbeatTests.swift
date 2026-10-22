import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// A scripted `claude` whose answer to a question is a tool call, then `tick` every `every` until
/// `count` have gone out, then a result.
final class TickingTransport: ClaudeTransport {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let tick: Data
    private let every: Duration
    private let count: Int
    private let exit = Mutex<Int32?>(nil)

    init(tick: Data, every: Duration, count: Int) {
        (lines, continuation) = AsyncStream.makeStream()
        (self.tick, self.every, self.count) = (tick, every, count)
    }

    func send(_ line: Data) async throws {
        guard exit.withLock({ $0 == nil }) else { throw TransportError.inputClosed }
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        guard object["type"] as? String == "user" else { return }
        continuation.yield(Line.initLine())
        continuation.yield(Line.toolUse("mcp__fake__slow_lookup", [:]))
        Task {
            var sent = 0
            while sent < count, exit.withLock({ $0 == nil }) {
                try? await Task.sleep(for: every)
                continuation.yield(tick)
                sent += 1
            }
            continuation.yield(Line.result("done"))
        }
    }

    func closeInput() { finish(0) }
    func terminate() { finish(143) }
    private func finish(_ status: Int32) {
        exit.withLock { if $0 == nil { $0 = status } }
        continuation.finish()
    }
    func exitStatus() async -> Int32 { exit.withLock { $0 } ?? 0 }
    var stderrTail: String { "" }
}

struct HeartbeatTests {
    /// As 2.1.301 sends it while a tool runs, every 30 s.
    static let heartbeat = Line.json([
        "type": "tool_progress", "tool_use_id": "t1-heartbeat-0", "tool_name": "mcp__fake__slow_lookup",
        "parent_tool_use_id": "t1", "elapsed_time_seconds": 30, "heartbeat": true, "session_id": "s-1",
    ])

    @Test func heartbeatsParse() {
        #expect(StreamEvent(line: Self.heartbeat) == .heartbeat)
    }

    /// A tool that doesn't reply: only heartbeats come back, so the watchdog fires long before the
    /// late result (bounded so a regression fails instead of hanging).
    @Test func heartbeatsDontKeepAHungTurnAlive() async {
        let session = ClaudeSession(spec: spec(mode: .deep),
                                    transport: TickingTransport(tick: Self.heartbeat, every: .milliseconds(20), count: 50))
        await session.startPump()
        let events = await collect(await session.ask(TurnInput(text: "q"), inactivity: .milliseconds(150)))
        #expect(events.last == .failed(.timedOut))
    }

    /// Real output arriving more often than the limit keeps a long turn going.
    @Test func realProgressStillCounts() async {
        let session = ClaudeSession(spec: spec(mode: .deep),
                                    transport: TickingTransport(tick: Line.textDelta("."), every: .milliseconds(20), count: 20))
        await session.startPump()
        let events = await collect(await session.ask(TurnInput(text: "q"), inactivity: .milliseconds(150)))
        guard case .finished = events.last else { Issue.record("\(String(describing: events.last))"); return }
    }
}
