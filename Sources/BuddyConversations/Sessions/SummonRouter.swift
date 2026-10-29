import BuddyCore
import Foundation

/// One summon, as the router sees it.
public struct SummonInput: Sendable {
    public enum Source: Sendable, Equatable {
        case talkKey, textBox
        case composer(SessionID), switcherPick(SessionID)
        case newSession
        case action(SessionID)
    }

    /// A spoken or typed command that decides by itself.
    public enum Command: Sendable, Equatable {
        /// "New topic", ⌘N, ＋, the fresh modifier.
        case newSession
        /// "Continue …" with a session named.
        case continueSession(SessionID)
    }

    public var source: Source
    /// How the turn was given: `.voice` for the talk key, `.typed` for a box or composer, `.action`
    /// for a card button. A talk-key turn into a visible page becomes `.voiceInPage`.
    public var kind: TurnKind
    public var command: Command?
    public var contextKey: ContextKey?
    /// The project in front (ProjectResolver), standardised; nil when there's none. Home never counts.
    public var project: String?
    public var projectTrusted: Bool
    public var visiblePage: (id: SessionID, kind: PageKind)?
    /// When the Panel last showed each session.
    public var panelShownAt: [SessionID: Date]
    /// The session the next summon continues by default.
    public var current: SessionID?
    /// Sessions running a turn the user asked by voice (moved to the background by a new press,
    /// V-02): only an explicit pick continues one, so a second question never cuts the first off.
    public var busy: Set<SessionID>
    public var now: Date

    public init(
        source: Source, kind: TurnKind, command: Command? = nil, contextKey: ContextKey? = nil, project: String? = nil,
        projectTrusted: Bool = false, visiblePage: (id: SessionID, kind: PageKind)? = nil,
        panelShownAt: [SessionID: Date] = [:], current: SessionID? = nil, busy: Set<SessionID> = [], now: Date
    ) {
        self.source = source
        self.kind = kind
        self.command = command
        self.contextKey = contextKey
        self.project = project
        self.projectTrusted = projectTrusted
        self.visiblePage = visiblePage
        self.panelShownAt = panelShownAt
        self.current = current
        self.busy = busy
        self.now = now
    }
}

public enum RouteDecision: Sendable, Equatable {
    case continueSession(SessionID, kind: TurnKind)
    case newSession(kind: TurnKind)
    /// Continue, adding the trusted project in front to the session (respawn with `--add-dir`).
    case absorb(SessionID, dir: String, kind: TurnKind)
    /// Continue, offering "Add <repo> to this session?" for an untrusted project.
    case offerAbsorb(SessionID, dir: String, kind: TurnKind)

    /// The session the turn goes to; nil for a new one.
    public var session: SessionID? {
        switch self {
        case .continueSession(let id, _), .absorb(let id, _, _), .offerAbsorb(let id, _, _): id
        case .newSession: nil
        }
    }

    public var kind: TurnKind {
        switch self {
        case .continueSession(_, let kind), .newSession(let kind), .absorb(_, _, let kind), .offerAbsorb(_, _, let kind): kind
        }
    }
}

public struct RoutingPolicy: Sendable, Equatable {
    /// After this long unused, the current session isn't continued by default (Settings, 30 min).
    public var idleLimit: TimeInterval
    /// The same app and document continue a session used this recently.
    public var contextWindow: TimeInterval
    /// A session the Panel showed this recently is continued.
    public var panelWindow: TimeInterval
    /// The user's home folder, standardised: never a project.
    public var home: String

    public init(idleLimit: TimeInterval = 30 * 60, contextWindow: TimeInterval = 30 * 60, panelWindow: TimeInterval = 2 * 60,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.idleLimit = idleLimit
        self.contextWindow = contextWindow
        self.panelWindow = panelWindow
        self.home = FolderTrustPath.normalize(home)
    }
}

/// Continue or new, decided instantly: pure, deterministic, no model call and no I/O.
///
/// In order:
/// 1. An explicit command, a picked session, the composer or an action wins.
/// 2. The talk key while a Lumi page shows a session: that session, as a voice-in-page turn (owner).
/// 3. A session the Panel showed under 2 min ago.
/// 4. A session used from the same app and document under 30 min ago.
/// 5. The current session, used under the idle limit.
/// 6. Otherwise a new session.
///
/// Rules 3–5 skip a session that's still running a voice turn (`busy`): a second question while
/// the first runs starts its own session, and the first keeps going (V-02).
///
/// No chip offers another session: switching is the switcher's (Tab), starting fresh is N, ＋, ⌘N
/// or "new topic" (owner, Oct 28).
///
/// A project change never starts a new session: a continued session absorbs a trusted project in
/// front, and offers to add an untrusted one. Home is never a project.
public enum SummonRouter {
    public static func route(_ input: SummonInput, candidates: [SessionRoutingInfo], policy: RoutingPolicy) -> RouteDecision {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let project = input.project.map(FolderTrustPath.normalize).flatMap { $0 == policy.home || $0 == "/" ? nil : $0 }

        func continued(_ id: SessionID, kind: TurnKind) -> RouteDecision {
            // A v1 row's folder can be home (Deep ran there): that covers nothing.
            let dirs = byID[id]?.directories.map(FolderTrustPath.normalize).filter { $0 != policy.home && $0 != "/" } ?? []
            guard let project, byID[id] != nil, !dirs.contains(where: { covers($0, project) }) else {
                return .continueSession(id, kind: kind)
            }
            return input.projectTrusted ? .absorb(id, dir: project, kind: kind) : .offerAbsorb(id, dir: project, kind: kind)
        }
        func fresh(within window: TimeInterval, _ date: Date) -> Bool {
            // A clock that jumped backwards is not idle time.
            input.now.timeIntervalSince(date) < window
        }

        // 1. Explicit.
        switch input.command {
        case .newSession: return .newSession(kind: input.kind)
        case .continueSession(let id): return continued(id, kind: input.kind)
        case nil: break
        }
        switch input.source {
        case .composer(let id):
            // A composer's mic: the spoken turn is read in that page.
            return continued(id, kind: input.kind == .voice ? .voiceInPage : input.kind)
        case .switcherPick(let id), .action(let id):
            return continued(id, kind: input.kind)
        case .newSession:
            return .newSession(kind: input.kind)
        case .talkKey, .textBox:
            break
        }
        // 2. Owner: the talk key into the page on screen.
        if input.source == .talkKey, let page = input.visiblePage {
            return continued(page.id, kind: .voiceInPage)
        }
        // Archived sessions are out of the strip: only an explicit pick (rule 1) or the page that
        // shows one (rule 2) continues them (QA R12). A busy one isn't continued by default either.
        let skipped = Set(candidates.filter(\.archived).map(\.id)).union(input.busy)
        // 3. The Panel showed it moments ago.
        if let shown = input.panelShownAt.filter({ !skipped.contains($0.key) && fresh(within: policy.panelWindow, $0.value) })
            .max(by: { $0.value < $1.value }) {
            return continued(shown.key, kind: input.kind)
        }
        // 4. The same app and document, recently.
        if let key = input.contextKey,
           let match = candidates
               .filter({ !skipped.contains($0.id) && $0.contextKey == key && fresh(within: policy.contextWindow, $0.lastUsed) })
               .max(by: { $0.lastUsed < $1.lastUsed }) {
            return continued(match.id, kind: input.kind)
        }
        // 5. The current session, unless idle.
        if let id = input.current, let session = byID[id], !skipped.contains(id), fresh(within: policy.idleLimit, session.lastUsed) {
            return continued(id, kind: input.kind)
        }
        // 6. New.
        return .newSession(kind: input.kind)
    }

    /// `dir` is the project or one of its parents (a session in a repo covers its subfolders).
    static func covers(_ dir: String, _ project: String) -> Bool {
        project == dir || project.hasPrefix(dir + "/")
    }
}
