import BuddyBridge
import BuddyCore
import BuddyTrace
import Foundation
import Synchronization
import Testing
@testable import BuddyApp

private let plugin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("buddy-plugin")

private func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// A `claude` that takes each user line like the real one (`--replay-user-messages` echo, then the
/// turn) and plays the next scripted turn. The second turn compacts first.
private final class EchoTransport: ClaudeTransport {
    let lines: AsyncStream<Data>
    private let out: AsyncStream<Data>.Continuation
    private let state = Mutex<(sent: [Data], turn: Int, closed: Bool)>(([], 0, false))

    init() { (lines, out) = AsyncStream<Data>.makeStream() }

    static func turn(_ n: Int, uuid: String) -> [Data] {
        let answer = ["one", "two", "three", "four", "five"][min(n, 4)]
        var lines = [line(["type": "user", "isReplay": true, "uuid": uuid, "message": ["role": "user", "content": [["type": "text", "text": "q"]]]])]
        if n == 1 { lines.append(line(["type": "system", "subtype": "compact_boundary", "compact_metadata": ["trigger": "auto"]])) }
        lines.append(line(["type": "result", "subtype": "success", "is_error": false, "session_id": "c-1", "result": answer,
                           "user_message_uuids": [uuid]]))
        return lines
    }

    func send(_ data: Data) async throws {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard o?["type"] as? String == "user" else { return }
        let n = state.withLock { s in s.sent.append(data); s.turn += 1; return s.turn - 1 }
        for l in Self.turn(n, uuid: o?["uuid"] as? String ?? "") { out.yield(l) }
    }

    func closeInput() { state.withLock { $0.closed = true }; out.finish() }
    func terminate() { out.finish() }
    func exitStatus() async -> Int32 { 0 }
    var stderrTail: String { "" }

    var sentTexts: [String] {
        state.withLock { $0.sent }.compactMap { data in
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let content = (o?["message"] as? [String: Any])?["content"] as? [[String: Any]]
            return content?.compactMap { $0["text"] as? String }.joined()
        }
    }
}

/// `--resume` of a session Claude Code no longer has: no `initialize` answer, one failed result,
/// the marker on stderr, exit 1 (claude 2.1.312, measured).
private final class LostTransport: ClaudeTransport {
    let lines: AsyncStream<Data>
    static let marker = "No conversation found with session ID: x"

    init() {
        let (lines, out) = AsyncStream<Data>.makeStream()
        self.lines = lines
        out.yield(line(["type": "result", "subtype": "error_during_execution", "is_error": true, "session_id": "x",
                        "errors": [Self.marker]]))
        out.finish()
    }

    var answersStartupHandshake: Bool { true }
    func send(_ line: Data) async throws { throw TransportError.inputClosed }
    func closeInput() {}
    func terminate() {}
    func exitStatus() async -> Int32 { 1 }
    var stderrTail: String { Self.marker }
}

private final class Transports: Sendable {
    let made = Mutex<[EchoTransport]>([])
    var sentTexts: [String] { made.withLock { $0 }.flatMap(\.sentTexts) }
}

private func request(_ kind: TurnKind, _ text: String, id: SessionID, launch: SessionLaunch) -> TurnRequest {
    TurnRequest(question: Question(packet: ContextPacket(askedAt: Date(timeIntervalSince1970: 1_791_900_000), utterance: text)),
                state: ConversationState(id: id.rawValue), kind: kind, target: .session(id, launch))
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + waitCeiling
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

struct LiveSessionTurnsTests {
    @Test func lifecycleMapsToTraceEvents() {
        let id = SessionID(rawValue: "s_t")
        #expect(SessionEngine.traceEvent(.launched(id, resumed: false, startup: .milliseconds(900))) == .sessionLaunched)
        #expect(SessionEngine.traceEvent(.launched(id, resumed: true, startup: .milliseconds(900))) == .sessionResumed)
        #expect(SessionEngine.traceEvent(.suspended(id, idle: .seconds(600), reason: .idle)) == .sessionSuspended)
        #expect(SessionEngine.traceDuration(.launched(id, resumed: true, startup: .milliseconds(900))) == .milliseconds(900))
        #expect(SessionEngine.traceDuration(.suspended(id, idle: .seconds(600), reason: .cap)) == .seconds(600))
    }

    @Test func envelopeOnlyOnVoiceUnlessEveryTurn() {
        #expect(LiveSessionTurns.usesEnvelope(.voice, scope: .voiceTurns))
        #expect(LiveSessionTurns.usesEnvelope(.action, scope: .voiceTurns))
        #expect(!LiveSessionTurns.usesEnvelope(.typed, scope: .voiceTurns))
        #expect(!LiveSessionTurns.usesEnvelope(.voiceInPage, scope: .voiceTurns))
        #expect(LiveSessionTurns.usesEnvelope(.typed, scope: .everyTurn))
        #expect(LiveSessionTurns.usesEnvelope(.voiceInPage, scope: .everyTurn))
        #expect(!LiveSessionTurns.usesEnvelope(.relay, scope: .everyTurn))
    }

    /// QA E1: the Claude session is gone. Once, a fresh one seeded with the recap takes the same
    /// turn, and the user sees only the answer.
    @Test func aLostClaudeSessionRetriesOnceInAFreshSeededOne() async throws {
        let echoes = Transports()
        let made = Mutex(0)
        let pool = SessionPool(caps: PoolCaps(live: 2), spec: { launch in
            .open(executable: URL(fileURLWithPath: "/c"), launch: launch, permissionMode: nil, environment: [:])
        }, transport: { _ in
            if made.withLock({ $0 += 1; return $0 }) == 1 { return LostTransport() }
            let t = EchoTransport()
            echoes.made.withLock { $0.append(t) }
            return t
        }, restart: RestartPolicy(delays: []), sweepEvery: nil)
        let recovered = Mutex<[SessionID]>([])
        let fresh = SessionLaunch(claudeSession: UUID(), exists: false, cwd: URL(fileURLWithPath: "/Users/me"))
        let turns = LiveSessionTurns(pool: pool, plugin: plugin, settings: { SessionSettings() },
                                     recover: { id, end in
                                         recovered.withLock { $0.append(id) }
                                         #expect(LiveSessionTurns.isLost(end))
                                         return (fresh, "Q: the budget A: it's over by 4%")
                                     })
        let id = SessionID(rawValue: "s_lost")
        let gone = SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(fileURLWithPath: "/Users/me"))
        var events: [SessionEvent] = []
        for await e in await turns.run(request(.typed, "and next month?", id: id, launch: gone), id: id, launch: gone) { events.append(e) }
        #expect(recovered.withLock { $0 } == [id])
        let ends = events.compactMap { if case .turnEnded(let e) = $0 { e } else { nil } }
        #expect(ends.count == 1 && ends.first?.isError == false)
        #expect(echoes.sentTexts == ["<quick-note>Q: the budget A: it&apos;s over by 4%</quick-note>\n\nand next month?"]
            || echoes.sentTexts == ["<quick-note>Q: the budget A: it's over by 4%</quick-note>\n\nand next month?"])
        _ = await pool.shutdownAll()
    }

    /// Without a way to recover, the failure is shown, and reaches the session's feed.
    @Test func aLostClaudeSessionWithoutRecoveryFails() async throws {
        let pool = SessionPool(caps: PoolCaps(live: 2), spec: { launch in
            .open(executable: URL(fileURLWithPath: "/c"), launch: launch, permissionMode: nil, environment: [:])
        }, transport: { _ in LostTransport() }, restart: RestartPolicy(delays: []), sweepEvery: nil)
        let turns = LiveSessionTurns(pool: pool, plugin: plugin, settings: { SessionSettings() })
        let id = SessionID(rawValue: "s_lost2")
        let gone = SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(fileURLWithPath: "/Users/me"))
        let feed = await pool.allEvents()
        var events: [SessionEvent] = []
        for await e in await turns.run(request(.typed, "hi", id: id, launch: gone), id: id, launch: gone) { events.append(e) }
        #expect(events.contains { if case .turnEnded(let e) = $0 { LiveSessionTurns.isLost(e) } else { false } })
        for await e in feed {
            if case .turnEnded(let end) = e.event { #expect(LiveSessionTurns.isLost(end)); break }
        }
        _ = await pool.shutdownAll()
    }

    /// Every line the CLI is sent is recorded with its uuid and the user's words; a relay while the
    /// session works folds in and its stream ends empty.
    @Test func sentTurnsAreRecordedAndRelaysFoldIn() async throws {
        let running = [line(["type": "system", "subtype": "session_state_changed", "state": "running"])]
        let pool = SessionPool(caps: PoolCaps(live: 2), spec: { launch in
            .open(executable: URL(fileURLWithPath: "/c"), launch: launch, permissionMode: nil, environment: [:])
        }, transport: { _ in ReplayTransport(lines: [line(["type": "system", "subtype": "init", "session_id": "c-1"])] + running,
                                             wholeStream: true) }, sweepEvery: nil)
        let recorded = Mutex<[(String, TurnKind, String)]>([])
        let turns = LiveSessionTurns(pool: pool, plugin: plugin, settings: { SessionSettings() },
                                     onSent: { uuid, kind, shown, _, _ in recorded.withLock { $0.append((uuid, kind, shown)) } })
        let id = SessionID(rawValue: "s_r")
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: URL(fileURLWithPath: "/Users/me"))
        let first = await turns.run(request(.typed, "start the build", id: id, launch: launch), id: id, launch: launch)
        let drain = Task { for await _ in first {} }
        #expect(await waitUntil { await pool.isWorking(id) })
        var relayed: [SessionEvent] = []
        for await e in await turns.run(request(.relay, "The user says to @scout: hurry", id: id, launch: launch), id: id, launch: launch) {
            relayed.append(e)
        }
        #expect(relayed.isEmpty)
        let rows = recorded.withLock { $0 }
        #expect(rows.map(\.1) == [.typed, .relay])
        #expect(rows.map(\.2) == ["start the build", "The user says to @scout: hurry"])
        #expect(rows.allSatisfy { !$0.0.isEmpty })
        drain.cancel()
        _ = await pool.shutdownAll()
    }

    /// Full rules on the first voice turn and after a compaction; a reminder otherwise; typed raw.
    @Test func voiceRulesFollowTheLedger() async throws {
        let transports = Transports()
        let pool = SessionPool(caps: PoolCaps(live: 2), spec: { launch in
            .open(executable: URL(fileURLWithPath: "/c"), launch: launch, permissionMode: nil, environment: [:])
        }, transport: { _ in
            let t = EchoTransport()
            transports.made.withLock { $0.append(t) }
            return t
        }, sweepEvery: nil)
        let turns = LiveSessionTurns(pool: pool, plugin: plugin, settings: { SessionSettings() })
        let id = SessionID(rawValue: "s_t")
        let launch = SessionLaunch(claudeSession: UUID(), exists: false, cwd: URL(fileURLWithPath: "/Users/me"))
        for (kind, text) in [(TurnKind.voice, "first"), (.voice, "second"), (.typed, "fix the **build**"), (.voice, "fourth")] {
            for await _ in await turns.run(request(kind, text, id: id, launch: launch), id: id, launch: launch) {}
        }
        let sent = transports.sentTexts
        #expect(sent.count == 4)
        guard sent.count >= 4 else { Issue.record("sent: \(sent.count) of 4"); return }
        #expect(sent[0].hasPrefix("<lumi-voice>") && sent[0].contains("<lumi-voice-rules>"))
        #expect(sent[1].hasPrefix("<lumi-voice>") && !sent[1].contains("<lumi-voice-rules>"))
        #expect(sent[2] == "fix the **build**")
        // The second turn compacted: the next voice turn sends the full rules again.
        #expect(sent[3].contains("<lumi-voice-rules>"))
        _ = await pool.shutdownAll()
    }
}
