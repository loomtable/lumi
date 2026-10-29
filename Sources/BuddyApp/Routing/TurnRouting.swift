import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation

/// What the router needs to place one user turn.
public struct RouteRequest: Sendable {
    public var packet: ContextPacket
    public var kind: TurnKind
    /// The Lumi page on screen, if any: a talk-key turn goes into it (owner).
    public var visiblePage: (id: SessionID, kind: PageKind)?
    /// An explicit target that decides by itself (SummonRouter rule 1): a switcher pick, a
    /// composer, or `.newSession` after ⌘N, ＋/N or "new topic". Nil: the talk key or the text box,
    /// by `kind`. The v1 router ignores it.
    public var source: SummonInput.Source?
    /// Sessions still running a voice turn the user moved to the background (V-02).
    public var busy: Set<SessionID>

    public init(packet: ContextPacket, kind: TurnKind, visiblePage: (id: SessionID, kind: PageKind)? = nil,
                source: SummonInput.Source? = nil, busy: Set<SessionID> = []) {
        self.packet = packet
        self.kind = kind
        self.visiblePage = visiblePage
        self.source = source
        self.busy = busy
    }
}

/// Where a turn goes: the conversation (and its session) it belongs to, how it's sent, and what
/// the shell should offer.
public struct RoutedTurn: Sendable {
    public var conversation: ConversationTurn
    public var sessionID: SessionID
    public var kind: TurnKind
    public var harness: Harness
    /// An open session's launch: the turn goes to the session engine, not the cascade.
    public var launch: SessionLaunch?
    public var seed: String?
    /// An untrusted project in front: "Add <repo> to this session?".
    public var offerDirectory: String?

    public init(conversation: ConversationTurn, sessionID: SessionID, kind: TurnKind, harness: Harness,
                launch: SessionLaunch? = nil, seed: String? = nil, offerDirectory: String? = nil) {
        self.conversation = conversation
        self.sessionID = sessionID
        self.kind = kind
        self.harness = harness
        self.launch = launch
        self.seed = seed
        self.offerDirectory = offerDirectory
    }
}

/// Picks the conversation for each turn. The coordinator asks once per question, after a pending
/// "new topic" has started fresh. It never offers another conversation back.
@MainActor public protocol TurnRouting: AnyObject {
    func route(_ request: RouteRequest) async -> RoutedTurn
    /// ⌘N, ＋/N or "new topic": the next routed question starts a new session, however long after.
    func startNewSession()
    /// A cascade (Quick, or v1 Deep) answer was recorded: the session finishes its turn, as an
    /// open session's does from its events.
    func cascadeTurnFinished(_ id: SessionID, kind: TurnKind, question: String, block: BuddyBlock)
}

extension TurnRouting {
    /// The v1 router needs nothing: `ConversationPort.startNew()` already started fresh.
    public func startNewSession() {}
    /// The v1 router has no sessions to finish.
    public func cascadeTurnFinished(_ id: SessionID, kind: TurnKind, question: String, block: BuddyBlock) {}
}

/// Today's rules: the project in front, then `ConversationPort.prepare`.
@MainActor public final class ConversationRouting: TurnRouting {
    private let conversations: any ConversationPort
    private let trust: @Sendable () -> FolderTrust

    public init(conversations: any ConversationPort, trust: @escaping @Sendable () -> FolderTrust) {
        self.conversations = conversations
        self.trust = trust
    }

    public func route(_ request: RouteRequest) async -> RoutedTurn {
        let project = ProjectResolver.project(in: request.packet, trust: trust())?.standardizedFileURL.path
        let conversation = await conversations.prepare(project: project)
        return RoutedTurn(
            conversation: conversation, sessionID: SessionID(rawValue: conversation.state.id), kind: request.kind,
            harness: conversation.state.deepSessionID == nil ? .quick : .legacy)
    }
}

/// v2 (LumiFeatures.sessions): SummonRouter over the session store. The cascade's bookkeeping
/// still runs in `conversations`, switched to the routed session, so Quick turns save as before.
@MainActor public final class SessionRouting: TurnRouting {
    private let sessions: LiveSessions
    private let conversations: any ConversationPort
    private let trust: @Sendable () -> FolderTrust
    private let clock: @MainActor () -> Date
    /// A new-conversation request waiting for the next question.
    private var newSessionRequested = false

    public init(sessions: LiveSessions, conversations: any ConversationPort, trust: @escaping @Sendable () -> FolderTrust,
                clock: @escaping @MainActor () -> Date = Date.init) {
        self.sessions = sessions
        self.conversations = conversations
        self.trust = trust
        self.clock = clock
    }

    public func startNewSession() { newSessionRequested = true }

    public func cascadeTurnFinished(_ id: SessionID, kind: TurnKind, question: String, block: BuddyBlock) {
        sessions.finishCascadeTurn(id, kind: kind, question: question, block: block)
    }

    public func route(_ request: RouteRequest) async -> RoutedTurn {
        let trust = trust()
        // An explicit pick after ⌘N still wins; either way the request is used up.
        let source = request.source ?? (newSessionRequested ? .newSession : nil)
        newSessionRequested = false
        let project = ProjectResolver.project(in: request.packet, trust: trust)?.standardizedFileURL
        let input = SummonInput(
            source: source ?? (request.kind == .voice ? .talkKey : .textBox), kind: request.kind,
            contextKey: ContextKey.from(request.packet), project: project?.path,
            projectTrusted: project.map { trust.isTrusted($0, rule: .folderOrAncestor) } ?? false,
            visiblePage: request.visiblePage, panelShownAt: sessions.panelShownAt, current: sessions.current, busy: request.busy,
            now: clock())
        let plan = await sessions.plan(input, packet: request.packet)
        let conversation = await conversations.switchTo(plan.id.rawValue)
            ?? ConversationTurn(state: ConversationState(id: plan.id.rawValue), color: .ember, turn: 0, previous: [])
        return RoutedTurn(conversation: conversation, sessionID: plan.id, kind: plan.kind, harness: plan.harness,
                          launch: plan.launch, seed: plan.seed, offerDirectory: plan.offerDirectory)
    }
}
