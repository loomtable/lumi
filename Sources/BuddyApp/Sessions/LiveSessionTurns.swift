import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation

/// Which voice turns carry the full voice rules: on a session's first voice turn and after a
/// compaction. `SessionStore` (foundation) is the real one.
public protocol VoiceRulesLedger: Sendable {
    func voiceRulesNeeded(_ id: SessionID) async -> Bool
    /// `sent`: a full-rules turn finished (clear); false marks them needed again (a compaction).
    func markVoiceRules(sent: Bool, for id: SessionID) async
}

/// The session store's ledger, read from the index in use (temporary mode swaps it). Read-only.
public struct StoreVoiceRules: VoiceRulesLedger {
    private let manager: ConversationManager

    public init(manager: ConversationManager) {
        self.manager = manager
    }

    public func voiceRulesNeeded(_ id: SessionID) async -> Bool {
        await SessionStore(index: await manager.activeIndex).voiceRulesNeeded(id)
    }

    /// Read-only: LiveSessions is the one writer (its SessionActivity sets "needed" on any
    /// compaction in the session's feed, CLI-started turns included, and clears it when a voice turn
    /// ends without one).
    public func markVoiceRules(sent: Bool, for id: SessionID) async {}

    /// The session's latest user turn (the one a Continue resumes): its uuid and kind.
    public func lastTurn(_ id: SessionID) async -> (uuid: String, kind: TurnKind)? {
        guard let last = ((try? await SessionStore(index: await manager.activeIndex).userTurns(of: id)) ?? []).last else { return nil }
        return (last.uuid, last.kind)
    }

    /// Turns the session already has.
    public func turnCount(_ id: SessionID) async -> Int {
        ((try? await SessionStore(index: await manager.activeIndex).userTurns(of: id)) ?? []).count
    }
}

/// The in-memory ledger, without a session store (tests).
public actor MemoryVoiceRules: VoiceRulesLedger {
    private var sent: Set<SessionID> = []
    public init() {}
    public func voiceRulesNeeded(_ id: SessionID) -> Bool { !sent.contains(id) }
    public func markVoiceRules(sent done: Bool, for id: SessionID) {
        if done { sent.insert(id) } else { sent.remove(id) }
    }
}

/// One turn in an open session (02 §D8): the right input for the turn's kind, then the pool's
/// events for that turn. Typed turns are the user's own words (owner: typed = full Claude Code);
/// voice turns, and every turn with "Use Lumi's voice layer for: Every turn", get the envelope.
public struct LiveSessionTurns: Sendable {
    public let pool: SessionPool
    private let plugin: URL
    private let settings: @Sendable () -> SessionSettings
    private let rules: any VoiceRulesLedger
    /// Turns the session already has, for asking `topic` on turn 1 and turn 3 only.
    private let turnCount: @Sendable (SessionID) async -> Int
    /// A user line the CLI took (its replayed uuid keys the transcript): `LiveSessions.recordSent`.
    public typealias Sent = @Sendable (_ uuid: String, _ kind: TurnKind, _ shown: String, _ claudeSession: UUID, _ id: SessionID) async -> Void
    private let onSent: Sent
    private let recover: Recover?

    public init(pool: SessionPool, plugin: URL, settings: @escaping @Sendable () -> SessionSettings,
                rules: any VoiceRulesLedger = MemoryVoiceRules(),
                turnCount: @escaping @Sendable (SessionID) async -> Int = { _ in 1 },
                onSent: @escaping Sent = { _, _, _, _, _ in }, recover: Recover? = nil) {
        self.recover = recover
        self.pool = pool
        self.plugin = plugin
        self.settings = settings
        self.rules = rules
        self.turnCount = turnCount
        self.onSent = onSent
    }

    public func run(_ request: TurnRequest, id: SessionID, launch: SessionLaunch) async -> AsyncStream<SessionEvent> {
        let s = settings()
        let packet = request.question.packet
        // A steer, or a relay while the session works, folds into the running turn: its events
        // already reach the page on that turn's stream, so this one ends empty.
        let folds = request.kind == .steer ? true : request.kind == .relay ? await pool.isWorking(id) : false
        if folds {
            let uuid = try? await pool.steer(packet.utterance, session: id, kind: request.kind)
            if let uuid { await onSent(uuid, request.kind, packet.utterance, launch.claudeSession, id) }
            return AsyncStream { out in
                if uuid == nil { out.yield(.turnEnded(TurnEnd(kind: .steer, markdown: "", isError: true,
                                                               error: SessionFailure(reason: .crashed, retryable: true)))) }
                out.finish()
            }
        }
        let first = await input(for: request, id: id, seed: request.seed, settings: s)
        let recover = recover
        return AsyncStream { out in
            let relay = Task {
                // A Claude session the CLI no longer has (QA E1): once, a new open session in the
                // same Lumi session, seeded with the recap, and the same turn again. The user only
                // sees the answer.
                var attempt = first
                var launch = launch
                var retried = false
                while true {
                    let ended = await self.relay(attempt, request: request, id: id, launch: launch, to: out, holdLost: !retried)
                    guard case .lost(let end) = ended else { break }
                    retried = true
                    guard let recover, let (fresh, seed) = await recover(id, end) else {
                        out.yield(.turnEnded(end))
                        await self.pool.report(.turnEnded(end), for: id)
                        break
                    }
                    launch = fresh
                    attempt = await self.input(for: request, id: id, seed: seed ?? request.seed, settings: self.settings())
                }
                out.finish()
            }
            out.onTermination = { _ in relay.cancel() }
        }
    }

    /// A Lumi session's Claude session is gone: forget it and give a fresh launch plus its seed, or
    /// nil to report the failure. Real: `LiveSessions` (apply the failure, then `composerPlan`).
    public typealias Recover = @Sendable (SessionID, TurnEnd) async -> (SessionLaunch, String?)?

    struct Prepared: Sendable {
        var input: TurnInput
        var fullRules: Bool
        var speak: Bool
    }

    enum Ending: Sendable {
        case done
        case lost(TurnEnd)
    }

    static let sessionNotFound = "session_not_found"

    static func isLost(_ end: TurnEnd) -> Bool {
        if case .unavailable(sessionNotFound)? = end.error?.reason { return true }
        return false
    }

    private func input(for request: TurnRequest, id: SessionID, seed: String?, settings s: SessionSettings) async -> Prepared {
        var prepared = await bareInput(for: request, id: id, seed: seed, settings: s)
        // Composer attachments go with either input: image blocks, or `@path` lines.
        if !request.attachments.isEmpty {
            prepared.input = TypedTurn.attaching(await TypedTurn.load(request.attachments), to: prepared.input)
        }
        return prepared
    }

    private func bareInput(for request: TurnRequest, id: SessionID, seed: String?, settings s: SessionSettings) async -> Prepared {
        let packet = request.question.packet
        let envelope = Self.usesEnvelope(request.kind, scope: s.voiceLayer)
        let speak = envelope && (request.kind == .voice || request.kind == .action || s.speakTypedAnswers)
        guard envelope else {
            let input = TypedTurn.input(text: packet.utterance, screen: request.question.screenshot.map { (packet, $0) }, seed: seed)
            return Prepared(input: input, fullRules: false, speak: false)
        }
        let needed = await rules.voiceRulesNeeded(id) || seed != nil
        let text = needed ? VoiceEnvelope.rulesText(plugin: plugin, teammates: s.teammates) : nil
        let turns = await turnCount(id)
        let input = VoiceEnvelope.input(packet: packet, screenshot: request.question.screenshot, detail: request.question.detail,
                                        rules: text.map { .full($0) } ?? .reminder, quickNote: seed,
                                        approved: request.question.isApprovedAction, askTopic: turns == 0 || turns == 2)
        return Prepared(input: input, fullRules: text != nil, speak: speak)
    }

    /// One attempt's events to `out`. `holdLost`: a lost-session failure isn't shown; it's returned
    /// for the retry. The rules ledger: needed again on a compaction; sent only when a full-rules
    /// turn ended without one (QA E13).
    private func relay(_ prepared: Prepared, request: TurnRequest, id: SessionID, launch: SessionLaunch,
                       to out: AsyncStream<SessionEvent>.Continuation, holdLost: Bool) async -> Ending {
        let onSent = onSent, kind = request.kind, shown = request.question.packet.utterance
        let events = await pool.turn(prepared.input, kind: kind, to: id, launch: launch, speak: prepared.speak,
                                     sent: { uuid in await onSent(uuid, kind, shown, launch.claudeSession, id) })
        var compacted = false
        for await event in events {
            switch event {
            case .compacted:
                compacted = true
                await rules.markVoiceRules(sent: false, for: id)
            case .turnEnded(let end) where end.isError && holdLost && Self.isLost(end):
                return .lost(end)
            case .turnEnded(let end) where prepared.fullRules && !end.isError && !compacted:
                await rules.markVoiceRules(sent: true, for: id)
            default:
                break
            }
            out.yield(event)
        }
        return .done
    }

    /// Continue on an Interrupted session (U11): the interrupted turn resumes as it was (its kind
    /// and uuid, QA E11), with no user line.
    public func resume(_ id: SessionID, launch: SessionLaunch, kind: TurnKind, uuid: String?) async -> AsyncStream<SessionEvent> {
        await pool.resume(id, launch: launch, kind: kind, uuid: uuid)
    }

    /// Voice and approved-action turns always; typed and voice-in-page turns only with "Every turn".
    static func usesEnvelope(_ kind: TurnKind, scope: VoiceLayerScope) -> Bool {
        switch kind {
        case .voice, .action: true
        case .typed, .voiceInPage: scope == .everyTurn
        case .steer, .relay: false
        }
    }

    /// Quick hands off (or the user asked for Deep): a voice turn in the open session `resolve`
    /// names for the conversation, seeded with Quick's line. `resolve` returns nil (a legacy
    /// conversation, sessions off) to keep the Deep lane.
    public func handoff(resolve: @escaping @Sendable (ConversationState) async -> (SessionID, SessionLaunch)?) -> OpenHandoffRunner {
        { [self] h in
            guard let (id, launch) = await resolve(h.state) else { return nil }
            let s = settings()
            let needed = await rules.voiceRulesNeeded(id)
            let text = needed ? VoiceEnvelope.rulesText(plugin: plugin, teammates: s.teammates) : nil
            let input = VoiceEnvelope.input(packet: h.question.packet, screenshot: h.question.screenshot, detail: h.question.detail,
                                            rules: text.map { .full($0) } ?? .reminder, quickNote: h.quickNote,
                                            approved: h.question.isApprovedAction, askTopic: true)
            let onSent = onSent, shown = h.question.packet.utterance
            let events = await pool.turn(input, kind: .voice, to: id, launch: launch, speak: true,
                                         sent: { uuid in await onSent(uuid, .voice, shown, launch.claudeSession, id) })
            let rules = rules
            let observed = AsyncStream<SessionEvent> { out in
                let relay = Task {
                    for await event in events {
                        if case .turnEnded(let end) = event, text != nil, !end.isError { await rules.markVoiceRules(sent: true, for: id) }
                        if case .compacted = event { await rules.markVoiceRules(sent: false, for: id) }
                        out.yield(event)
                    }
                    out.finish()
                }
                out.onTermination = { _ in relay.cancel() }
            }
            return SessionTurnEvents.adapt(observed, sessionID: launch.claudeSession.uuidString.lowercased())
        }
    }
}
