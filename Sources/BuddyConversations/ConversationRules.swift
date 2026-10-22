import Foundation

/// Timings for the conversation rules.
public struct ConversationPolicy: Sendable, Equatable {
    /// After this long without a question, the next one starts fresh (Settings, default 30 min).
    public var idleTimeout: TimeInterval
    /// How long "↩ Back to …" is offered after starting fresh.
    public var backWindow: TimeInterval

    public init(idleTimeout: TimeInterval = 30 * 60, backWindow: TimeInterval = 8) {
        self.idleTimeout = idleTimeout
        self.backWindow = backWindow
    }
}

/// A chip the shell shows next to the answer.
public enum ConversationChip: Sendable, Equatable {
    /// "↩ Back to '…'", until `until`.
    case back(to: String, until: Date)
    /// "Resume '…'" after the idle timeout.
    case resume(String)
    /// "Keep in the old one" when a different project is in front.
    case keepInOld(String)
}

/// Why a question went to a fresh conversation.
public enum FreshReason: Sendable, Equatable {
    case first
    case requested  // ⌘N, ＋ or "new topic"
    case idle
    case otherProject
}

/// The conversation rules as a pure state machine; times come in with each call.
///
/// - Continue by default.
/// - ⌘N, ＋ or "new topic" starts fresh; "↩ Back" returns to the previous one for 8 s.
/// - After the idle timeout the next question starts fresh, with a resume chip.
/// - A different project in front starts fresh, with "keep in the old one".
///
/// A fresh conversation stays pending until its first turn finishes, so no empty rows appear.
public struct ConversationRules: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case continueCurrent(String)
        case startFresh(String, FreshReason)

        public var conversationID: String {
            switch self {
            case .continueCurrent(let id), .startFresh(let id, _): id
            }
        }
    }

    public var policy: ConversationPolicy
    public private(set) var currentID: String?
    public private(set) var currentProject: String?
    public private(set) var lastActivity: Date?
    /// Started but no turn finished yet.
    public private(set) var currentIsPending = false
    private var backTarget: (id: String, project: String?, until: Date)?

    /// The conversations the rules can still return to at `now`: the current one and the ↩ Back
    /// target while its window is open.
    public func referencedIDs(at now: Date) -> Set<String> {
        let back = backTarget.flatMap { now < $0.until ? $0.id : nil }
        return Set([currentID, back].compactMap { $0 })
    }

    public init(policy: ConversationPolicy = ConversationPolicy()) {
        self.policy = policy
    }

    public static func == (a: ConversationRules, b: ConversationRules) -> Bool {
        a.policy == b.policy && a.currentID == b.currentID && a.currentProject == b.currentProject
            && a.lastActivity == b.lastActivity && a.currentIsPending == b.currentIsPending
            && a.backTarget?.id == b.backTarget?.id && a.backTarget?.until == b.backTarget?.until
    }

    /// A question is starting with `projectFolder` in front. `newID` is used if it goes fresh.
    public mutating func ask(projectFolder: String?, at now: Date, newID: String) -> (Decision, [ConversationChip]) {
        guard let current = currentID else {
            start(newID, project: projectFolder, at: now)
            return (.startFresh(newID, .first), [])
        }
        // A pending fresh conversation (⌘N, then the question) takes this question. It is empty,
        // so the idle rule doesn't apply to it.
        if currentIsPending {
            // Still empty, so it simply takes whichever project is in front now.
            currentProject = projectFolder ?? currentProject
            lastActivity = now
            return (.continueCurrent(current), backChip(at: now))
        }
        // A clock that jumped backwards (now < last) is not idle time.
        if let last = lastActivity, now.timeIntervalSince(last) > policy.idleTimeout {
            start(newID, project: projectFolder, at: now)
            return (.startFresh(newID, .idle), [.resume(current)])
        }
        if let old = currentProject, let new = projectFolder, old != new {
            start(newID, project: projectFolder, at: now)
            return (.startFresh(newID, .otherProject), [.keepInOld(current)])
        }
        lastActivity = now
        if currentProject == nil { currentProject = projectFolder }
        return (.continueCurrent(current), [])
    }

    /// ⌘N, ＋ or "new topic". Pressed again while the new one is still empty, the back target
    /// stays the original conversation and its 8 s window starts again.
    public mutating func newConversation(at now: Date, newID: String) -> (Decision, [ConversationChip]) {
        let previous = currentIsPending ? backTarget.map { ($0.id, $0.project) } : currentID.map { ($0, currentProject) }
        start(newID, project: nil, at: now)
        guard let previous else { return (.startFresh(newID, .requested), []) }
        backTarget = (previous.0, previous.1, now.addingTimeInterval(policy.backWindow))
        return (.startFresh(newID, .requested), [.back(to: previous.0, until: now.addingTimeInterval(policy.backWindow))])
    }

    /// "↩ Back" or "go back": returns the previous conversation while the window is open.
    public mutating func goBack(at now: Date) -> String? {
        guard let back = backTarget, Self.isOpen(until: back.until, window: policy.backWindow, now: now) else { return nil }
        switchTo(back.id, project: back.project, at: now)
        return back.id
    }

    /// "Keep in the old one", "Resume '…'" or a pick from ⌘Y.
    public mutating func switchTo(_ id: String, project: String?, at now: Date) {
        currentID = id
        currentProject = project
        currentIsPending = false
        lastActivity = now
        backTarget = nil
    }

    /// A turn finished in the current conversation.
    public mutating func turnFinished(at now: Date, projectFolder: String?) {
        currentIsPending = false
        lastActivity = now
        if let projectFolder { currentProject = projectFolder }
    }

    /// The current conversation was forgotten.
    public mutating func forgot(_ id: String) {
        if currentID == id {
            currentID = nil
            currentProject = nil
            currentIsPending = false
        }
        if backTarget?.id == id { backTarget = nil }
    }

    private mutating func start(_ id: String, project: String?, at now: Date) {
        currentID = id
        currentProject = project
        currentIsPending = true
        lastActivity = now
        backTarget = nil
    }

    private func backChip(at now: Date) -> [ConversationChip] {
        guard let back = backTarget, Self.isOpen(until: back.until, window: policy.backWindow, now: now) else { return [] }
        return [.back(to: back.id, until: back.until)]
    }

    /// The window is open from its start to `until`. If the clock jumped backwards to before the
    /// start, the window is treated as closed rather than stretched.
    static func isOpen(until: Date, window: TimeInterval, now: Date) -> Bool {
        now <= until && now >= until.addingTimeInterval(-window)
    }
}
