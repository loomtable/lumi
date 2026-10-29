import BuddyCore
import Foundation

/// One session's live state, folded from its event stream. Pure: the shell persists the effects.
public struct SessionActivity: Sendable, Equatable {
    public var status: SessionStatus = .idle
    /// The Trail's live verb line ("Reading budget.md").
    public var liveLine: String?
    /// The session's teammates, one stable entry each from planned to done (`TeamRoster`).
    public private(set) var team = TeamRoster()
    public var teammates: [TeammateSnapshot] { team.members }

    /// An edited prompt replaced the turns from `date` on: a team that started since goes with
    /// them (the roster holds only the latest team).
    public mutating func dropTeam(startedSince date: Date) {
        if team.members.contains(where: { ($0.startedAt ?? .distantPast) >= date }) { team.clear() }
    }
    public var turnStartedAt: Date?
    public var turnKind: TurnKind?
    /// The last finished turn's duration.
    public var ranFor: TimeInterval?
    public var finishedAt: Date?
    /// The last finished answer, short (`SessionSnapshot.lastSay`).
    public var lastSay: String?
    /// The latest event or question line (`SessionSnapshot.lastEventAt`).
    public var lastEventAt: Date?
    /// Permission and question requests still open, oldest first.
    var pending: [NeedsYou] = []
    /// What the turn ended as, while a teammate's ask still waits past it (shown once it's answered).
    var endedAs: SessionStatus?
    var compactedThisTurn = false
    /// What the session showed before a question was sent, while no turn has started for it yet
    /// (`queryBegan`): what `queryEnded` goes back to when none ever does.
    var beforeQuery: SessionStatus?

    public init(status: SessionStatus = .idle) {
        self.status = status
    }

    /// What the store should record after an event.
    public enum Effect: Sendable, Equatable {
        case finishTurn(answerPreview: String)
        case status(PersistedStatus?)
        case topic(SessionTopic)
        case voiceRules(needed: Bool)
    }

    /// `onScreen`: the session's page or Glance is in front, so a finished answer is already seen.
    public mutating func apply(_ event: SessionEvent, at now: Date, onScreen: Bool) -> [Effect] {
        team.apply(event, at: now)
        lastEventAt = now
        defer { team.waiting(on: Set(pending.compactMap(\.asker))) }
        switch event {
        case .turnStarted(_, let kind):
            turnStartedAt = now
            turnKind = kind
            liveLine = nil
            compactedThisTurn = false
            endedAs = nil
            beforeQuery = nil
            // A teammate's ask from the previous turn still waits; the lead's were answered or ended.
            pending.removeAll { $0.asker == nil }
            status = pending.first.map { .needsYou($0) } ?? .thinking(since: now, progress: nil)
            return [.status(nil)]
        case .runState(.running):
            if case .thinking = status { return [] }
            // Background subagents can run past the turn's end: that isn't the turn thinking again.
            if pending.isEmpty, let since = turnStartedAt { status = .thinking(since: since, progress: nil) }
            return []
        case .runState:
            return []
        case .step(let step) where step.subagent == nil:
            // The lead's own steps only: a teammate's are on its lane, and interleaving them here
            // made the line flick between teammates.
            liveLine = step.presentLine
            if case .todos(let todos) = step.detail, case .thinking(let since, _) = status, !todos.isEmpty {
                status = .thinking(since: since, progress: StepProgress(done: todos.count { $0.state == .completed }, total: todos.count))
            }
            return []
        case .permissionRequested(let ask):
            // An ask that arrives on screen is seen at once: its card is in front of the user.
            return needs(NeedsYou(kind: .permission(ask), since: now, seen: onScreen))
        case .questionAsked(let ask):
            return needs(NeedsYou(kind: .question(ask), since: now, seen: onScreen))
        case .permissionResolved(let id):
            drop { $0.requestID == id }
            if case .needsYou(var next) = status, onScreen { next.seen = true; status = .needsYou(next) }
            return []
        case .task(.ended(let taskID, _, _)):
            // A teammate that ended asks nothing any more (the roster still has its name).
            guard let name = team.members.first(where: { $0.id == taskID })?.name else { return [] }
            drop { $0.asker == name }
            return []
        case .compacted:
            compactedThisTurn = true
            return [.voiceRules(needed: true)]
        case .rateLimit(let state, let resetsAt) where state == "rejected":
            status = .failed(SessionFailure(reason: .rateLimited(resetsAt: resetsAt), lastStep: liveLine, retryable: true))
            return [.status(.failed)]
        case .turnEnded(let end):
            return finish(end, at: now, onScreen: onScreen)
        case .processEnded(_, let midTurn):
            // The process is gone: nothing it asked can be answered.
            drop { _ in true }
            guard midTurn, turnStartedAt != nil else {
                turnStartedAt = nil
                return []
            }
            status = .failed(SessionFailure(reason: .crashed, lastStep: liveLine, retryable: true))
            turnStartedAt = nil
            return [.status(.failed)]
        default:
            return []
        }
    }

    /// The user saw it (page, Glance or tile opened): an unread answer is read, and a waiting ask
    /// is acknowledged (it still waits, its card shows it). An answer's `asks_user` is over once
    /// it's read.
    public mutating func markSeen() -> [Effect] {
        switch status {
        case .done(let at, true):
            status = .done(at: at, unread: false)
            return [.status(.idle)]
        case .needsYou(let ask) where ask.kind.isSoft:
            status = .done(at: ask.since, unread: false)
            return [.status(.idle)]
        case .needsYou(var ask) where !ask.seen:
            ask.seen = true
            status = .needsYou(ask)
            if let i = pending.firstIndex(where: { $0.requestID == ask.requestID }) { pending[i].seen = true }
            return []
        default:
            return []
        }
    }

    /// A question was sent: the session runs from now, before its turn starts (a Quick turn's
    /// never does). `line`: what it's doing, when known.
    public mutating func queryBegan(line: String?, at now: Date) {
        lastEventAt = now
        if turnStartedAt == nil {
            beforeQuery = status
            turnStartedAt = now
            status = .thinking(since: now, progress: nil)
            liveLine = nil
        }
        if let line { liveLine = line }
    }

    /// A Quick turn's live line ("Searching the web for …"), while its question runs.
    public mutating func queryLine(_ line: String, at now: Date) {
        guard turnStartedAt != nil else { return }
        liveLine = line
        lastEventAt = now
    }

    /// The question's stream ended. One that never started a turn (cancelled, or it failed to
    /// send) runs no more: the session goes back to how it was.
    public mutating func queryEnded() {
        guard let before = beforeQuery else { return }
        beforeQuery = nil
        turnStartedAt = nil
        liveLine = nil
        status = before
    }

    /// Lumi quit while it ran: "Interrupted · Continue" next launch.
    public mutating func interrupt(at now: Date) -> [Effect] {
        guard turnStartedAt != nil else { return [] }
        status = .interrupted(at: now)
        turnStartedAt = nil
        return [.status(.interrupted)]
    }

    private mutating func needs(_ ask: NeedsYou) -> [Effect] {
        pending.append(ask)
        if pending.count == 1 { status = .needsYou(ask) }
        return []
    }

    /// Asks that were answered, cancelled or can't be answered any more: the next one shows, else
    /// what the turn is doing (or how it ended).
    private mutating func drop(where gone: (NeedsYou) -> Bool) {
        let before = pending.count
        pending.removeAll(where: gone)
        guard pending.count != before || pending.isEmpty, case .needsYou(let shown) = status, !shown.kind.isSoft else { return }
        if let next = pending.first {
            if next.requestID != shown.requestID { status = .needsYou(next) }
        } else if let since = turnStartedAt {
            status = .thinking(since: since, progress: nil)
        } else if let ended = endedAs {
            // The last teammate ask after the turn ended: back to how the turn ended.
            status = ended
            endedAs = nil
        }
    }

    private mutating func finish(_ end: TurnEnd, at now: Date, onScreen: Bool) -> [Effect] {
        ranFor = turnStartedAt.map { now.timeIntervalSince($0) }
        turnStartedAt = nil
        finishedAt = now
        // A background teammate can outlive the lead's turn, and its ask waits with no timeout
        // (QA R9): only the lead's own asks end with the turn.
        pending.removeAll { $0.asker == nil }
        let lastStep = liveLine
        liveLine = nil
        var effects: [Effect] = []
        beforeQuery = nil
        let preview = end.block?.say ?? end.markdown
        if !end.isError { lastSay = SessionSnapshot.lastSay(say: end.block?.say, markdown: end.markdown) ?? lastSay }
        if end.isError {
            status = .failed(end.error ?? SessionFailure(reason: .api(String(end.markdown.prefix(200))), lastStep: lastStep, retryable: true))
            effects.append(.status(.failed))
        } else if let question = end.block?.asksUser {
            status = .needsYou(NeedsYou(kind: .soft(question), since: now))
            effects += [.finishTurn(answerPreview: preview), .status(.doneUnread)]
        } else {
            status = .done(at: now, unread: !onScreen)
            effects += [.finishTurn(answerPreview: preview), .status(onScreen ? .idle : .doneUnread)]
        }
        if let waiting = pending.first {
            endedAs = status
            status = .needsYou(waiting)
        }
        if let topic = end.block?.topic { effects.append(.topic(topic)) }
        // A voice turn carried the full rules; a compaction during it means they're needed again.
        if !end.isError, end.kind == .voice, !compactedThisTurn { effects.append(.voiceRules(needed: false)) }
        compactedThisTurn = false
        return effects
    }
}

extension NeedsYou.Kind {
    var isSoft: Bool {
        if case .soft = self { return true }
        return false
    }
}

extension NeedsYou {
    /// The teammate that asked; nil for the lead's own asks and soft asks.
    var asker: String? {
        switch kind {
        case .permission(let ask): ask.asker
        case .question(let ask): ask.asker
        case .soft: nil
        }
    }

    var requestID: String? {
        switch kind {
        case .permission(let ask): ask.id
        case .question(let ask): ask.id
        case .soft: nil
        }
    }
}

extension SessionStatus {
    /// What a relaunch shows for a stored status.
    public init(persisted: PersistedStatus?, finishedAt: Date?) {
        switch persisted {
        case .doneUnread: self = .done(at: finishedAt ?? .distantPast, unread: true)
        case .failed: self = .failed(SessionFailure(reason: .unavailable("Didn't finish"), retryable: true))
        case .interrupted: self = .interrupted(at: finishedAt ?? .distantPast)
        case .idle, nil: self = .idle
        }
    }
}
