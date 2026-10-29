import Foundation

/// Timings for the conversation rules.
public struct ConversationPolicy: Sendable, Equatable {
    /// After this long without a question, the next one starts fresh (Settings, default 30 min).
    public var idleTimeout: TimeInterval
    /// The user's home folder: never a project (Deep often runs there when nothing is in front).
    public var home: String

    public init(idleTimeout: TimeInterval = 30 * 60, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.idleTimeout = idleTimeout
        self.home = FolderTrustPath.normalize(home)
    }

    /// `folder` unless it is home or the root, which are never a project.
    public func project(_ folder: String?) -> String? {
        guard let folder else { return nil }
        let path = FolderTrustPath.normalize(folder)
        return path == home || path == "/" ? nil : folder
    }
}

/// Why a question went to a fresh conversation.
public enum FreshReason: Sendable, Equatable {
    case first
    case requested  // ⌘N, ＋ or "new topic"
    case idle
}

/// The conversation rules as a pure state machine; times come in with each call.
///
/// - Continue by default.
/// - ⌘N, ＋ or "new topic" starts fresh.
/// - After the idle timeout the next question starts fresh.
/// - A different project in front never starts fresh: the conversation continues (the resume bug
///   was this split, silent, after Deep had run in home). Home is never a project.
///
/// No chip offers the previous conversation back: switching is the switcher's job (Tab), and a
/// past conversation is picked from the history.
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

    /// The conversation the next question continues: retention never prunes it.
    public var referencedIDs: Set<String> { Set([currentID].compactMap { $0 }) }

    public init(policy: ConversationPolicy = ConversationPolicy()) {
        self.policy = policy
    }

    /// A question is starting with `projectFolder` in front. `newID` is used if it goes fresh.
    public mutating func ask(projectFolder: String?, at now: Date, newID: String) -> Decision {
        let projectFolder = policy.project(projectFolder)
        guard let current = currentID else {
            start(newID, project: projectFolder, at: now)
            return .startFresh(newID, .first)
        }
        // A pending fresh conversation (⌘N, then the question) takes this question. It is empty,
        // so the idle rule doesn't apply to it.
        if currentIsPending {
            // Still empty, so it simply takes whichever project is in front now.
            currentProject = projectFolder ?? currentProject
            lastActivity = now
            return .continueCurrent(current)
        }
        // A clock that jumped backwards (now < last) is not idle time.
        if let last = lastActivity, now.timeIntervalSince(last) > policy.idleTimeout {
            start(newID, project: projectFolder, at: now)
            return .startFresh(newID, .idle)
        }
        lastActivity = now
        if currentProject == nil { currentProject = projectFolder }
        return .continueCurrent(current)
    }

    /// ⌘N, ＋ or "new topic".
    public mutating func newConversation(at now: Date, newID: String) -> Decision {
        start(newID, project: nil, at: now)
        return .startFresh(newID, .requested)
    }

    /// A pick from the history (⌘Y, Studio): that conversation is current.
    public mutating func switchTo(_ id: String, project: String?, at now: Date) {
        currentID = id
        currentProject = project
        currentIsPending = false
        lastActivity = now
    }

    /// A turn finished in the current conversation.
    public mutating func turnFinished(at now: Date, projectFolder: String?) {
        currentIsPending = false
        lastActivity = now
        if let projectFolder = policy.project(projectFolder) { currentProject = projectFolder }
    }

    /// The current conversation was forgotten.
    public mutating func forgot(_ id: String) {
        guard currentID == id else { return }
        currentID = nil
        currentProject = nil
        currentIsPending = false
    }

    private mutating func start(_ id: String, project: String?, at now: Date) {
        currentID = id
        currentProject = project
        currentIsPending = true
        lastActivity = now
    }
}
