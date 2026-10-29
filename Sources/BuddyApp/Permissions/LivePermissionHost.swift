import BuddyBridge
import BuddyCore
import Foundation

/// Answers a session's pending `can_use_tool` requests. Real: the session pool (it holds the
/// request's input, so it builds AskUserQuestion's `updatedInput.answers`). Returns whether a
/// reply was written: false for an id already answered or cancelled, or no live session.
public protocol PermissionAnswering: Sendable {
    func decide(_ requestID: String, in session: SessionID, _ decision: PermissionDecision) async -> Bool
    func answer(_ requestID: String, in session: SessionID, answers: [String: String]) async -> Bool
}

/// The session pool answers: it holds each request's input, so an AskUserQuestion's answers
/// become `updatedInput.answers` there. One label per question.
extension SessionPool: PermissionAnswering {
    public func decide(_ requestID: String, in session: SessionID, _ decision: PermissionDecision) async -> Bool {
        await answer(requestID, decision, session: session)
    }

    public func answer(_ requestID: String, in session: SessionID, answers: [String: String]) async -> Bool {
        await answer(requestID, answers: answers.mapValues { [$0] }, session: session)
    }
}

/// No engine to answer: nothing is written, so every ask stays pending (never a silent clear).
public struct NoPermissionAnswering: PermissionAnswering {
    public init() {}
    public func decide(_ requestID: String, in session: SessionID, _ decision: PermissionDecision) async -> Bool { false }
    public func answer(_ requestID: String, in session: SessionID, answers: [String: String]) async -> Bool { false }
}

/// The permission host's policy (10 §1.8). It tracks what each session is waiting on, turns the
/// user's answer on any surface (the inline card, the peek's Allow/Deny, a spoken "yes") into
/// one decision, and never times out: the session stays needs-you until answered.
@MainActor public final class LivePermissionHost {
    public struct Pending: Sendable, Equatable {
        public var session: SessionID
        public var ask: PermissionAsk
        public var since: Date
    }

    private let answering: any PermissionAnswering
    private let clock: () -> Date
    public private(set) var pending: [Pending] = []
    public private(set) var questions: [(session: SessionID, ask: QuestionAsk)] = []
    /// Request ids Lumi already answered: no second reply, ever (the CLI echoes, cancels race).
    private var answered: Set<String> = []

    public init(answering: any PermissionAnswering, clock: @escaping () -> Date = Date.init) {
        self.answering = answering
        self.clock = clock
    }

    /// Every session event passes through, so the host knows what's waiting.
    public func observe(_ event: SessionEvent, in session: SessionID) {
        switch event {
        case .permissionRequested(let ask):
            guard !answered.contains(ask.id), !pending.contains(where: { $0.ask.id == ask.id }) else { return }
            pending.append(Pending(session: session, ask: ask, since: clock()))
        case .questionAsked(let ask):
            guard !answered.contains(ask.id), !questions.contains(where: { $0.ask.id == ask.id }) else { return }
            questions.append((session, ask))
        case .permissionResolved(let id):
            // Answered, cancelled by the CLI, or the process died: no reply to a cancelled id.
            drop(id)
        case .turnEnded:
            // The lead's turn is over; a background teammate's ask still waits (QA R9).
            pending.removeAll { $0.session == session && $0.ask.asker == nil }
            questions.removeAll { $0.session == session && $0.ask.asker == nil }
        case .processEnded:
            // The process is gone: nothing can be answered any more.
            pending.removeAll { $0.session == session }
            questions.removeAll { $0.session == session }
        default:
            break
        }
    }

    public func pending(in session: SessionID) -> [Pending] { pending.filter { $0.session == session } }

    /// The user's click: Allow, "Always for this session", or Deny (with "Tell Lumi something
    /// instead" as the message). True when the reply was written; false leaves the ask pending.
    @discardableResult
    public func respond(_ requestID: String, in session: SessionID, allow: Bool, always: Bool = false, message: String? = nil) async -> Bool {
        guard begin(requestID) else { return false }
        let decision: PermissionDecision = allow ? (always ? .allowForSession : .allow(updatedInput: nil)) : .deny(message: message)
        return finish(requestID, sent: await answering.decide(requestID, in: session, decision))
    }

    @discardableResult
    public func answerQuestion(_ requestID: String, in session: SessionID, answers: [String: String]) async -> Bool {
        guard begin(requestID) else { return false }
        return finish(requestID, sent: await answering.answer(requestID, in: session, answers: answers))
    }

    /// The pending ask with this id, for re-showing its card after a failed reply.
    public func ask(_ requestID: String) -> PermissionAsk? { pending.first { $0.ask.id == requestID }?.ask }

    /// A spoken "yes": only for a reversible ask, only while its card is focused and the key is
    /// held. Returns the request it allowed, or nil when a click is needed.
    @discardableResult
    public func approveByVoice(in session: SessionID, cardFocused: Bool, keyHeld: Bool) async -> String? {
        guard let p = pending.last(where: { $0.session == session }),
              Self.voiceMayApprove(p.ask, cardFocused: cardFocused, keyHeld: keyHeld) else { return nil }
        await respond(p.ask.id, in: session, allow: true)
        return p.ask.id
    }

    /// Tier 1 only; sends, deletes, anything leaving the Mac and `default_to_no` asks (the
    /// mapper makes those `.needsClick`) need a click.
    public nonisolated static func voiceMayApprove(_ ask: PermissionAsk, cardFocused: Bool, keyHeld: Bool) -> Bool {
        ask.tier == .reversible && cardFocused && keyHeld
    }

    /// "This one needs a click." when voice can't approve.
    public nonisolated static let needsClickLine = "This one needs a click."

    /// Ids with a reply being written: a second click while the first is in flight is ignored.
    private var sending: Set<String> = []

    private func begin(_ id: String) -> Bool {
        guard !answered.contains(id), !sending.contains(id) else { return false }
        sending.insert(id)
        return true
    }

    private func finish(_ id: String, sent: Bool) -> Bool {
        sending.remove(id)
        if sent {
            answered.insert(id)
            drop(id)
        }
        return sent
    }

    private func drop(_ id: String) {
        pending.removeAll { $0.ask.id == id }
        questions.removeAll { $0.ask.id == id }
    }
}
