import BuddyCore
import Foundation

/// A change in a session's attention state, from one sessions update to the next.
public enum AttentionTransition: Sendable, Equatable {
    /// Started needing the user. `ran`: how long its turn had been running, when known.
    case needsYou(SessionSnapshot, ran: TimeInterval?)
    /// Finished with its answer unseen.
    case ready(SessionSnapshot, ran: TimeInterval?)
    case failed(SessionSnapshot)
    /// No longer needs the user or waits unseen (answered, opened, archived or forgotten):
    /// withdraw its banner.
    case settled(SessionID)
}

/// Diffs successive session lists into transitions. The first list it sees only sets the
/// baseline, so launching Lumi never replays old results as new ones.
public struct TransitionTracker: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case running, needsYou, readyUnread, failed, resting }

    private var kinds: [SessionID: Kind] = [:]
    private var runningSince: [SessionID: Date] = [:]
    private var primed = false

    public init() {}

    public mutating func update(_ sessions: [SessionSnapshot], now: Date) -> [AttentionTransition] {
        var out: [AttentionTransition] = []
        var seen: Set<SessionID> = []
        for s in sessions where !s.archived {
            seen.insert(s.id)
            let state = Decay.state(of: s, now: now)
            let kind = Self.kind(state)
            let old = kinds[s.id]
            kinds[s.id] = kind
            if case .running(let since, _) = state { runningSince[s.id] = since }
            guard primed, old != nil || kind != .resting, old != kind else { continue }
            let ran = runningSince[s.id].map { now.timeIntervalSince($0) } ?? s.ranFor
            if old == .needsYou || old == .readyUnread, kind != .needsYou, kind != .readyUnread {
                out.append(.settled(s.id))
            }
            switch kind {
            case .needsYou: out.append(.needsYou(s, ran: ran))
            case .readyUnread:
                out.append(.ready(s, ran: ran))
                runningSince[s.id] = nil
            case .failed:
                out.append(.failed(s))
                runningSince[s.id] = nil
            case .running, .resting: break
            }
        }
        for (id, kind) in kinds where !seen.contains(id) {
            kinds[id] = nil
            runningSince[id] = nil
            if primed, kind == .needsYou || kind == .readyUnread { out.append(.settled(id)) }
        }
        primed = true
        return out.sorted { $0.order < $1.order }
    }

    private static func kind(_ state: AttentionState) -> Kind {
        switch state {
        case .running: .running
        case .needsYou: .needsYou
        case .readyUnread: .readyUnread
        case .failed: .failed
        case .resting: .resting
        }
    }
}

private extension AttentionTransition {
    /// Settles first, so a withdraw never follows the post it should precede; then by id.
    var order: String {
        switch self {
        case .settled(let id): "0" + id.rawValue
        case .needsYou(let s, _), .ready(let s, _), .failed(let s): "1" + s.id.rawValue
        }
    }
}
