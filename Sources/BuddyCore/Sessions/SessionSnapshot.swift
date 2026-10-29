import Foundation

/// The one read model for the switcher, capsules, Panel, Studio and router.
public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    public var id: SessionID
    public var title: String
    public var symbol: String?
    public var color: ConversationColor
    public var origin: SessionOrigin?
    public var harness: Harness
    public var status: SessionStatus
    /// The latest team, kept after it finishes (the inspector's Team tab).
    public var teammates: [TeammateSnapshot]
    /// The team is still at work: from the first teammate's start until the lead answers after
    /// the last one ends (`TeamRoster.isLive`).
    public var teamLive: Bool
    public var pinned: Bool
    public var archived: Bool
    public var lastUsed: Date
    public var finishedAt: Date?
    /// The Trail's live verb line, also the peek's status.
    public var liveLine: String?
    public var turns: Int
    /// The last turn's duration (the notification ≥ 30 s rule).
    public var ranFor: TimeInterval?
    /// The last finished answer in a line or two: a voice answer's `say`, else the start of a typed
    /// answer (at most `lastSayLimit` characters). The peek and a no-speech switch show it.
    public var lastSay: String?
    /// The session's latest event (inspire #4): after `Liveness.quietAfter` with none, a running
    /// line shows its age instead of looking busy.
    public var lastEventAt: Date?

    public static let lastSayLimit = 160

    /// The teammates to show live (beads, roster, sidebar, switcher): the team while it works,
    /// nothing once it has handed back and the lead answered.
    public var liveTeam: [TeammateSnapshot] { teamLive ? teammates : [] }

    /// Something runs in the session now: the lead's turn or a teammate. Every running indicator
    /// reads this, so none shows once all work has stopped.
    public var isRunning: Bool { turnRunning || teamWorking }

    /// The lead's turn runs: from the question being sent until its answer, or it ends without one.
    public var turnRunning: Bool { status.turnRunning }

    /// A teammate still works or waits on the user.
    public var teamWorking: Bool { liveTeam.contains { $0.state.isRunning } }

    /// What the session waits on the user for, if anything.
    public var ask: NeedsYou? {
        if case .needsYou(let ask) = status { return ask }
        return nil
    }

    /// An ask the user hasn't seen yet: amber, and the reminder.
    public var needsAttention: Bool {
        ask.map { !$0.seen } ?? false
    }

    public init(
        id: SessionID, title: String, symbol: String? = nil, color: ConversationColor, origin: SessionOrigin? = nil,
        harness: Harness, status: SessionStatus = .idle, teammates: [TeammateSnapshot] = [], teamLive: Bool? = nil, pinned: Bool = false,
        archived: Bool = false, lastUsed: Date, finishedAt: Date? = nil, liveLine: String? = nil, turns: Int = 0,
        ranFor: TimeInterval? = nil, lastSay: String? = nil, lastEventAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
        self.origin = origin
        self.harness = harness
        self.status = status
        self.teammates = teammates
        self.teamLive = teamLive ?? teammates.contains { $0.state.isRunning }
        self.pinned = pinned
        self.archived = archived
        self.lastUsed = lastUsed
        self.finishedAt = finishedAt
        self.liveLine = liveLine
        self.turns = turns
        self.ranFor = ranFor
        self.lastSay = lastSay
        self.lastEventAt = lastEventAt
    }

    /// `lastSay` from an answer: its `say`, else its Markdown, as one plain line
    /// (`MarkdownPreview`), cut at a word.
    public static func lastSay(say: String?, markdown: String) -> String? {
        let say = say.map { MarkdownPreview.line($0, limit: lastSayLimit) } ?? ""
        let line = say.isEmpty ? MarkdownPreview.line(markdown, limit: lastSayLimit) : say
        return line.isEmpty ? nil : line
    }
}

public struct TeammateSnapshot: Sendable, Equatable, Identifiable {
    /// Working ⇄ needs you → done, failed or stopped. Only ever forward (`TeamRoster`).
    public enum State: Sendable, Equatable {
        case working, needsYou, done, failed, stopped

        /// Working or waiting on the user.
        public var isRunning: Bool { self == .working || self == .needsYou }
    }

    /// The task id: stable from start to end, so views key on it.
    public var id: String
    public var toolUseID: String
    /// From the Agent tool use's input (`name`, else `description`), else "Teammate n".
    public var name: String
    public var state: State
    public var liveLine: String?
    /// The spawn's description ("Pull March invoices"), shown as the lane's brief.
    public var brief: String?
    /// Tool uses so far.
    public var steps: Int
    public var startedAt: Date?
    public var endedAt: Date?
    /// Its latest step or progress (inspire #4).
    public var lastEventAt: Date?

    public init(id: String, toolUseID: String, name: String, state: State, liveLine: String? = nil, brief: String? = nil,
                steps: Int = 0, startedAt: Date? = nil, endedAt: Date? = nil, lastEventAt: Date? = nil) {
        self.id = id
        self.toolUseID = toolUseID
        self.name = name
        self.state = state
        self.liveLine = liveLine
        self.brief = brief
        self.steps = steps
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastEventAt = lastEventAt ?? startedAt
    }

    /// How long it has worked: to its end, else to `now`. Nil before it starts.
    public func elapsed(at now: Date) -> TimeInterval? {
        startedAt.map { max(0, (endedAt ?? now).timeIntervalSince($0)) }
    }
}

extension SessionStatus {
    /// A turn runs: working, or waiting on the lead's own permission or question, which only ever
    /// waits mid-turn. A teammate's ask can outlive the turn, and an answer's `asks_user` comes
    /// after it.
    public var turnRunning: Bool {
        switch self {
        case .thinking: return true
        case .needsYou(let ask):
            switch ask.kind {
            case .permission(let p): return p.asker == nil
            case .question(let q): return q.asker == nil
            case .soft: return false
            }
        default: return false
        }
    }
}

/// Only animate what is moving (inspire #4): a session or teammate with no event for 90 s stops
/// looking busy, and its line says how long it has been quiet.
public enum Liveness {
    public static let quietAfter: TimeInterval = 90

    public static func isQuiet(since last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= quietAfter } ?? false
    }

    /// "Running tests · 2m" once quiet; the line itself before.
    public static func line(_ line: String, since last: Date?, now: Date) -> String {
        guard let last, isQuiet(since: last, now: now) else { return line }
        let minutes = Int(now.timeIntervalSince(last) / 60)
        let age = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
        return line + " · " + age
    }
}
