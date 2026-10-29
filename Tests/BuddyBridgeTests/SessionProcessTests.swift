import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyBridge

final class ThreadLog: Sendable {
    let onMain = Mutex<[Bool]>([])
}

/// Records the thread every line is mapped on.
struct ThreadProbeMapper: SessionEventMapping {
    let log: ThreadLog
    var inner = SessionEventMapper()

    mutating func beginTurn(kind: TurnKind, userUUID: String?, speak: Bool?) { inner.beginTurn(kind: kind, userUUID: userUUID, speak: speak) }
    func request(_ id: String) -> CanUseTool? { inner.request(id) }
    mutating func answered(_ id: String) -> [SessionEvent] { inner.answered(id) }
    mutating func processEnded(status: Int32) -> [SessionEvent] { inner.processEnded(status: status) }
    var hasRunningTasks: Bool { inner.hasRunningTasks }
    var hasPendingRequests: Bool { inner.hasPendingRequests }
    var isTurnOpen: Bool { inner.isTurnOpen }
    mutating func map(_ event: StreamEvent) -> [SessionEvent] {
        log.onMain.withLock { $0.append(Thread.isMainThread) }
        return inner.map(event)
    }
}

private func process(_ t: ScriptedTransport, hosts: Bool = true, mapper: (any SessionEventMapping)? = nil,
                     interruptGrace: Duration = .milliseconds(100)) -> SessionProcess {
    SessionProcess(id: SessionID(rawValue: "s_x"),
                   launch: SessionLaunch(claudeSession: UUID(), exists: false, cwd: URL(fileURLWithPath: "/Users/me")),
                   transport: t, mapper: mapper ?? SessionEventMapper(), hostsPermissions: { hosts }, interruptGrace: interruptGrace,
                   batchWindow: .milliseconds(50))
}

/// Reads events until `stop` matches (inclusive).
private func read(_ output: AsyncStream<SessionProcess.Output>, until stop: (SessionEvent) -> Bool) async -> [SessionEvent] {
    var out: [SessionEvent] = []
    for await o in output {
        guard case .event(let e) = o else { continue }
        out.append(e)
        if stop(e) { break }
    }
    return out
}

struct SessionProcessTests {
    /// An open session keeps going after `result`: a teammate finishes, the CLI starts a turn of
    /// its own, and only then is the session idle.
    @Test func eventsKeepComingAfterResult() async throws {
        let t = ScriptedTransport(script: { u, _ in
            [SLine.echo(u), SLine.state("running"), SLine.taskStarted("t1"), SLine.text("Started."),
             SLine.result("Started.", uuids: [u])]
        })
        let p = process(t)
        await p.start()
        #expect(await p.ready())
        try await p.send(TurnInput(text: "go"), kind: .typed, uuid: "u1")
        let first = await read(p.output) { if case .turnEnded = $0 { true } else { false } }
        #expect(first.contains(.turnStarted(userUUID: "u1", kind: .typed)))
        #expect(await p.facts(pinned: false, onScreen: false).turnInFlight)
        t.emit(SLine.taskDone("t1"))
        t.emit(SLine.text("All done."))
        t.emit(SLine.result("All done."))
        t.emit(SLine.state("idle"))
        let rest = await read(p.output) { $0 == .runState(.idle) }
        #expect(rest.contains(.turnStarted(userUUID: nil, kind: .typed)))
        #expect(rest.contains { if case .turnEnded(let e) = $0 { e.markdown == "All done." } else { false } })
        let f = await p.facts(pinned: false, onScreen: false)
        #expect(!f.turnInFlight && f.openTasks == 0 && f.runState == .idle)
        #expect(await p.isAlive)
    }

    /// Live finding (Oct 29): an idle from the turn before can land after Lumi wrote the next line
    /// and before the CLI took it. The session must still count as working, or a sweep suspends it
    /// with that line unsent. Once the line is taken and its turn ends, it's idle again.
    @Test func anIdleBeforeTheWrittenLineIsTakenKeepsTheTurnInFlight() async throws {
        let t = ScriptedTransport(script: { _, _ in [] })   // the CLI hasn't taken the line yet
        let p = process(t)
        await p.start()
        #expect(await p.ready())
        try await p.send(TurnInput(text: "next"), kind: .voice, uuid: "u2")
        t.emit(SLine.state("idle"))
        _ = await read(p.output) { $0 == .runState(.idle) }
        let waiting = await p.facts(pinned: false, onScreen: false)
        #expect(waiting.turnInFlight, "the written line is still on its way")
        #expect(!SuspendPolicy.canSuspend(waiting))

        t.emit(SLine.echo("u2"))
        t.emit(SLine.state("running"))
        t.emit(SLine.result("Done.", uuids: ["u2"]))
        t.emit(SLine.state("idle"))
        _ = await read(p.output) { $0 == .runState(.idle) }
        #expect(await !p.facts(pinned: false, onScreen: false).turnInFlight, "idle once its turn ended")
    }

    /// A result that names the line answers it even when its echo never came: it isn't left
    /// waiting, so the session can go idle and be suspended later.
    @Test func aResultNamingTheLineEndsTheWaitWithoutAnEcho() async throws {
        let t = ScriptedTransport(script: { u, _ in [SLine.state("running"), SLine.result("Done.", uuids: [u]), SLine.state("idle")] })
        let p = process(t)
        await p.start()
        #expect(await p.ready())
        try await p.send(TurnInput(text: "go"), kind: .typed, uuid: "u3")
        _ = await read(p.output) { $0 == .runState(.idle) }
        #expect(await !p.facts(pinned: false, onScreen: false).turnInFlight)
        #expect(await p.lostLines().isEmpty)
    }

    /// The user's uuid goes on the line, so the replay echo and `result` can be matched.
    @Test func userLinesCarryLumisUUIDAndPriority() throws {
        let line = SessionProcess.userLine(TurnInput(text: "hi", images: [.init(data: Data([1]), mediaType: "image/png")]),
                                           uuid: "u-9", priority: "now")
        let o = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(o["uuid"] as? String == "u-9")
        #expect(o["priority"] as? String == "now")
        let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(content?.map { $0["type"] as? String } == ["image", "text"])
        #expect(line.last == 0x0A)
    }

    /// Esc: the interrupt control request; a turn that doesn't end in time gets SIGTERM.
    @Test func interruptThenTerminateAfterGrace() async throws {
        let t = ScriptedTransport(script: { u, _ in [SLine.echo(u), SLine.state("running")] })
        let p = process(t)
        await p.start()
        _ = await p.ready()
        try await p.send(TurnInput(text: "go"), kind: .typed, uuid: "u1")
        await p.interrupt()
        #expect(t.controlRequests("interrupt").count == 1)
        #expect(await eventually { t.exited == 143 })
    }

    /// An interrupt the CLI honours keeps the process warm.
    @Test func interruptThatEndsTheTurnKeepsTheProcess() async throws {
        let t = ScriptedTransport(script: { u, _ in [SLine.echo(u), SLine.state("running")] })
        let p = process(t, interruptGrace: .milliseconds(80))
        await p.start()
        _ = await p.ready()
        try await p.send(TurnInput(text: "go"), kind: .typed, uuid: "u1")
        await p.interrupt()
        let id = try #require(t.controlRequests("interrupt").first?["request_id"] as? String)
        t.emit(SLine.controlResponse(id))
        t.emit(SLine.result("", uuids: ["u1"]))
        t.emit(SLine.state("idle"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(t.exited == nil)
        #expect(await p.isAlive)
    }

    /// The safety net: an unknown control request gets an error reply at once; an elicitation is
    /// declined; nothing waits forever.
    @Test func unknownControlRequestGetsAnErrorReply() async throws {
        let t = ScriptedTransport()
        let p = process(t)
        await p.start()
        _ = await p.ready()
        t.emit(SLine.controlRequest("q1", subtype: "hook_callback"))
        t.emit(SLine.json(["type": "control_request", "request_id": "q2",
                           "request": ["subtype": "elicitation", "mcp_server_name": "x", "message": "Pick"]]))
        #expect(await eventually { t.controlResponses.count == 2 })
        let byID = Dictionary(uniqueKeysWithValues: t.controlResponses.map { ($0["request_id"] as? String ?? "", $0) })
        #expect(byID["q1"]?["subtype"] as? String == "error")
        #expect((byID["q2"]?["response"] as? [String: Any])?["action"] as? String == "decline")
    }

    /// With the permission host off, a prompt is declined at once (not left pending).
    @Test func permissionHostOffDeclines() async throws {
        let t = ScriptedTransport()
        let p = process(t, hosts: false)
        await p.start()
        _ = await p.ready()
        t.emit(SLine.canUseTool("r1"))
        #expect(await eventually { !t.controlResponses.isEmpty })
        let reply = t.controlResponses[0]["response"] as? [String: Any]
        #expect(reply?["behavior"] as? String == "deny")
        #expect(await p.facts(pinned: false, onScreen: false).pendingPermissions == 0)
    }

    /// The CLI echoes the host's own replies (`--replay-user-messages`): ignored, not mistaken for ours.
    @Test func echoedControlResponsesAreIgnored() async throws {
        let t = ScriptedTransport()
        let p = process(t)
        await p.start()
        _ = await p.ready()
        t.emit(SLine.canUseTool("r1"))
        #expect(await eventually { await p.facts(pinned: false, onScreen: false).pendingPermissions == 1 })
        #expect(await p.answer("r1", .deny(message: "no")))
        t.emit(SLine.controlResponse("r1"))
        t.emit(SLine.controlResponse("startup-bogus"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await p.isAlive)
        #expect(await p.facts(pinned: false, onScreen: false).pendingPermissions == 0)
        #expect(await !p.answer("r1", .allow(updatedInput: nil)))
    }

    /// Stream JSON is parsed and mapped on the process's actor, never on main.
    @MainActor
    @Test func linesAreNeverMappedOnMain() async throws {
        let log = ThreadLog()
        let mapper = ThreadProbeMapper(log: log)
        let t = ScriptedTransport(script: { u, _ in SLine.turn(u) })
        let p = process(t, mapper: mapper)
        await p.start()
        try await p.send(TurnInput(text: "go"), kind: .typed, uuid: "u1")
        _ = await read(p.output) { $0 == .runState(.idle) }
        let flags = log.onMain.withLock { $0 }
        #expect(!flags.isEmpty)
        #expect(flags.allSatisfy { !$0 })
    }

    /// Text deltas within a frame reach the page as one batch; other events keep their order.
    @Test func textIsBatchedInOrder() async throws {
        let t = ScriptedTransport(script: { u, _ in
            [SLine.echo(u), SLine.text("a"), SLine.text("b"), SLine.text("c"), SLine.result("abc", uuids: [u])]
        })
        let p = process(t)
        await p.start()
        try await p.send(TurnInput(text: "go"), kind: .typed, uuid: "u1")
        let events = await read(p.output) { if case .turnEnded = $0 { true } else { false } }
        let texts = events.compactMap { if case .text(let s, _) = $0 { s } else { nil } }
        #expect(texts == ["abc"])
        #expect(events.firstIndex { if case .text = $0 { true } else { false } }! < events.firstIndex { if case .turnEnded = $0 { true } else { false } }!)
    }
}
