import BuddyCore
import Foundation

/// What the pool knows about one live session when deciding whether its process may stop.
public struct SuspendFacts: Sendable, Equatable {
    /// The latest `session_state_changed`; nil before the first one.
    public var runState: RunState?
    /// A user line was written and the session hasn't been `idle` since: the turn may not have
    /// reported `running` yet.
    public var turnInFlight: Bool
    /// `task_started` rows with no `task_notification` yet (teammates, background shells).
    public var openTasks: Int
    /// `can_use_tool` or elicitation requests not yet answered or withdrawn.
    public var pendingPermissions: Int
    public var pinned: Bool
    public var onScreen: Bool

    public init(runState: RunState? = nil, turnInFlight: Bool = false, openTasks: Int = 0, pendingPermissions: Int = 0,
                pinned: Bool = false, onScreen: Bool = false) {
        self.runState = runState
        self.turnInFlight = turnInFlight
        self.openTasks = openTasks
        self.pendingPermissions = pendingPermissions
        self.pinned = pinned
        self.onScreen = onScreen
    }
}

/// When a live session's process may be suspended (02 §D2/§D3). Pure.
public enum SuspendPolicy {
    /// Never while it runs or needs the user, a task is open, it's pinned or it's on screen.
    public static func canSuspend(_ f: SuspendFacts) -> Bool {
        if f.turnInFlight || f.pinned || f.onScreen || f.openTasks > 0 || f.pendingPermissions > 0 { return false }
        switch f.runState {
        case .running?, .requiresAction?: return false
        case .idle?, nil: return true
        }
    }

    /// Whether a project change may restart the process now: between turns only (idle, nothing
    /// in flight, no task, nothing pending). Pinned and on-screen sessions may restart.
    public static func canRespawn(_ f: SuspendFacts) -> Bool {
        var free = f
        free.pinned = false
        free.onScreen = false
        return canSuspend(free)
    }

    public struct Candidate: Sendable, Equatable {
        public var id: SessionID
        public var facts: SuspendFacts
        /// The last user turn or event, on the pool's clock.
        public var lastUsed: ContinuousClock.Instant

        public init(id: SessionID, facts: SuspendFacts, lastUsed: ContinuousClock.Instant) {
            self.id = id
            self.facts = facts
            self.lastUsed = lastUsed
        }
    }

    /// The sessions to suspend now, least recently used first:
    /// - every suspendable one idle for `caps.idleSuspend` or longer;
    /// - under memory pressure, every suspendable one;
    /// - otherwise the oldest suspendable ones until no more than `caps.live` stay live (working
    ///   sessions count but are never picked, so the cap is soft).
    /// `keep`: a session about to be used (the one launching), never picked.
    public static func victims(_ live: [Candidate], caps: PoolCaps, now: ContinuousClock.Instant, pressure: Bool,
                               keep: SessionID? = nil) -> [SessionID] {
        let eligible = live.filter { $0.id != keep && canSuspend($0.facts) }.sorted { $0.lastUsed < $1.lastUsed }
        if pressure { return eligible.map(\.id) }
        var picked = eligible.filter { now - $0.lastUsed >= caps.idleSuspend }.map(\.id)
        var remaining = live.count - picked.count
        for c in eligible where remaining > caps.live && !picked.contains(c.id) {
            picked.append(c.id)
            remaining -= 1
        }
        return picked
    }
}
