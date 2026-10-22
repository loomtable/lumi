import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

/// A scripted `claude` that answers `initialize` only when told, like one still starting up.
final class StartingTransport: ClaudeTransport {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state = Mutex<(sent: [String], pending: String?, exit: Int32?, late: Bool)>(([], nil, nil, false))
    var answersStartupHandshake: Bool { true }
    private let answerLateInTurn: Bool
    private let exitsOnTerminate: Bool

    /// `answerLateInTurn`: the start-up reply arrives in the middle of the first turn.
    /// `exitsOnTerminate: false`: the pipe stays open after terminate, like a child slow to die.
    init(answerLateInTurn: Bool = false, exitsOnTerminate: Bool = true) {
        (lines, continuation) = AsyncStream.makeStream()
        self.answerLateInTurn = answerLateInTurn
        self.exitsOnTerminate = exitsOnTerminate
    }

    var lateReplySent: Bool { state.withLock { $0.late } }

    /// What was written, by type (`control_request:initialize`, `user`).
    var sent: [String] { state.withLock { $0.sent } }

    func send(_ line: Data) async throws {
        guard state.withLock({ $0.exit == nil }) else { throw TransportError.inputClosed }
        let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let type = o["type"] as? String ?? ""
        if type == "control_request" {
            let subtype = (o["request"] as? [String: Any])?["subtype"] as? String ?? ""
            state.withLock { $0.sent.append("control_request:\(subtype)"); $0.pending = o["request_id"] as? String }
        } else {
            state.withLock { $0.sent.append(type) }
            continuation.yield(Line.json(["type": "system", "subtype": "init", "session_id": "s-1", "permissionMode": "auto"]))
            if answerLateInTurn, let id = state.withLock({ $0.pending }) {
                state.withLock { $0.late = true }
                continuation.yield(Line.json(["type": "control_response", "response": ["subtype": "success", "request_id": id]]))
            }
            continuation.yield(Line.result("ok"))
        }
    }

    /// Start-up finished.
    func answerStartup() {
        guard let id = state.withLock({ $0.pending }) else { return }
        continuation.yield(Line.json(["type": "control_response", "response": ["subtype": "success", "request_id": id]]))
    }

    func closeInput() { if exitsOnTerminate { exit(0) } }
    func terminate() { if exitsOnTerminate { exit(143) } }
    func exit(_ status: Int32) {
        state.withLock { if $0.exit == nil { $0.exit = status } }
        continuation.finish()
    }
    func exitStatus() async -> Int32 { state.withLock { $0.exit } ?? 0 }
    var stderrTail: String { "" }
}

struct StartupHandshakeTests {
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aQuestionWaitsUntilTheProcessHasStartedUp() async throws {
        let transport = StartingTransport()
        let session = try await ClaudeSession.launch(spec(), transport: { _ in transport })
        let asked = Task { await collect(await session.ask(TurnInput(text: "hi"))) }
        await waitUntil { transport.sent == ["control_request:initialize"] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.sent == ["control_request:initialize"], "held while starting up")
        transport.answerStartup()
        let events = await asked.value
        #expect(transport.sent == ["control_request:initialize", "user"])
        guard case .finished = events.last else { Issue.record("\(events)"); return }
    }

    @Test func aQuestionAfterStartUpGoesAtOnce() async throws {
        let transport = StartingTransport()
        let session = try await ClaudeSession.launch(spec(), transport: { _ in transport })
        await waitUntil { !transport.sent.isEmpty }
        transport.answerStartup()
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        _ = await collect(await session.ask(TurnInput(text: "hi")))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aStartUpThatNeverAnswersHoldsTheQuestionOnlyForTheGrace() async throws {
        let transport = StartingTransport()
        let session = ClaudeSession(spec: spec(), transport: transport)
        await session.startPump()
        await session.beginStartup(grace: .milliseconds(150))
        let events = await collect(await session.ask(TurnInput(text: "hi")))
        #expect(transport.sent == ["control_request:initialize", "user"])
        guard case .finished = events.last else { Issue.record("\(events)"); return }
    }

    @Test func aProcessThatExitsWhileStartingUpReleasesTheQuestion() async throws {
        let transport = StartingTransport()
        let session = try await ClaudeSession.launch(spec(), transport: { _ in transport })
        let asked = Task { await collect(await session.ask(TurnInput(text: "hi"))) }
        await waitUntil { !transport.sent.isEmpty }
        transport.exit(1)
        let events = await asked.value
        guard case .failed = events.last else { Issue.record("\(events)"); return }
    }

    /// Review: Esc while the question waits must not send it (and so not kill the warm process).
    @Test func aQuestionCancelledWhileWaitingIsNeverSent() async throws {
        let transport = StartingTransport()
        let session = try await ClaudeSession.launch(spec(), transport: { _ in transport })
        let asked = Task { await collect(await session.ask(TurnInput(text: "hi"))) }
        await waitUntil { !transport.sent.isEmpty }
        asked.cancel()
        transport.answerStartup()
        let events = await asked.value
        #expect(events == [.failed(.cancelled)])
        #expect(transport.sent == ["control_request:initialize"])
        #expect(await session.isAlive)
    }

    /// Review: a start-up reply after the grace isn't the turn's first event.
    @Test func aLateStartUpReplyIsNotPartOfTheTurn() async throws {
        let transport = StartingTransport(answerLateInTurn: true)
        let session = ClaudeSession(spec: spec(), transport: transport)
        await session.startPump()
        await session.beginStartup(grace: .milliseconds(50))
        let events = await collect(await session.ask(TurnInput(text: "hi")))
        guard case .finished(let outcome) = events.last else { Issue.record("\(events)"); return }
        #expect(outcome.timing.startupWait != nil)
        #expect(!events.contains { if case .status = $0 { true } else { false } })
        #expect(transport.lateReplySent)
    }

    @Test func shuttingDownReleasesAWaitingQuestion() async throws {
        let transport = StartingTransport(exitsOnTerminate: false)
        let session = try await ClaudeSession.launch(spec(), transport: { _ in transport })
        let asked = Task { await collect(await session.ask(TurnInput(text: "hi"))) }
        await waitUntil { !transport.sent.isEmpty }
        let start = ContinuousClock.now
        await session.shutdown()
        _ = await asked.value
        #expect(ContinuousClock.now - start < .seconds(2), "not held for the 5 s grace")
        #expect(transport.sent == ["control_request:initialize"])
    }

    @Test func fakesWithoutTheHandshakeAreNotAsked() async throws {
        let replay = ReplayTransport(lines: [Line.json(["type": "system", "subtype": "init", "session_id": "s"]), Line.result("ok")])
        let session = try await ClaudeSession.launch(spec(), transport: { _ in replay })
        _ = await collect(await session.ask(TurnInput(text: "hi")))
        #expect(replay.sentLines.count == 1)
    }
}
