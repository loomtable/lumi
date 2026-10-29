import BuddyCore
import Foundation

/// One question as the engine hands it over.
public struct Question: Sendable, Equatable {
    public var packet: ContextPacket
    public var screenshot: TurnInput.Image?
    /// A close-up at full resolution (`packet.screenshot_detail` says where), sent after
    /// `screenshot` and only with it.
    public var detail: TurnInput.Image?
    /// Settings › Models › Routing.
    public var routing: Routing
    /// The user pressed a card's action button: an explicit request to do it. Set only by the
    /// engine, never from model or screen text. Goes straight to Deep, which is told it's approved.
    public var isApprovedAction: Bool
    /// Names what `screenshot` shows: the engine keeps the token while the screen is unchanged
    /// (`ScreenFingerprint`), so a session that already has that image isn't sent it again.
    /// Nil: always send.
    public var screenToken: String?

    public init(packet: ContextPacket, screenshot: TurnInput.Image? = nil, detail: TurnInput.Image? = nil,
                routing: Routing = .auto, isApprovedAction: Bool = false, screenToken: String? = nil) {
        self.packet = packet
        self.screenshot = screenshot
        self.detail = detail
        self.routing = routing
        self.isApprovedAction = isApprovedAction
        self.screenToken = screenToken
    }
}

/// Where a question starts (routing and overrides).
public enum Start: Sendable, Equatable {
    case quick(allowHandoff: Bool)
    case deep
    /// Spoken "go deeper": like the card's button, Deep gets Quick's last answer as its note.
    case deeper
    case research
}

public enum Router {
    /// How long after Deep's answer a follow-up still counts as continuing it.
    public static let deepFollowUpWindow: TimeInterval = 120

    /// Spoken overrides first, then the Settings routing. Under Auto a question goes to Quick, which
    /// can hand off again, unless `deepIsCurrent`: a close follow-up to Deep's last answer.
    public static func start(utterance: String, routing: Routing, deepIsCurrent: Bool) -> Start {
        let said = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Whole words only: "researchers say…" is not "research…".
        func saidFirst(_ phrases: [String]) -> Bool {
            phrases.contains { phrase in
                guard said.hasPrefix(phrase) else { return false }
                guard let next = said.dropFirst(phrase.count).first else { return true }
                return next.isWhitespace || next.isPunctuation
            }
        }

        if saidFirst(["research"]) { return .research }
        if saidFirst(["go deeper"]) { return .deeper }
        if saidFirst(["quick answer"]) { return .quick(allowHandoff: false) }
        if saidFirst(["go deep", "think hard"]) { return .deep }
        switch routing {
        case .alwaysDeep: return .deep
        case .alwaysQuick: return .quick(allowHandoff: false)
        case .auto: return deepIsCurrent ? .deep : .quick(allowHandoff: true)
        }
    }
}

/// The text part of a turn, in the shape the buddy-answer skill describes.
public enum BuddyPrompt {
    /// `allowHandoff: false` ("quick answer…", Always Quick) tells Quick to answer itself.
    public static func quick(_ packet: ContextPacket, allowHandoff: Bool = true) -> String {
        allowHandoff ? body(packet) : body(packet) + "\n<handoff>off</handoff> Answer yourself from what you have; `handoff` must be null."
    }

    /// Deep gets the same packet and question, plus what Quick said when it handed off.
    /// `approved`: the engine's own mark that the user pressed the action button. Quick's note is
    /// model text that screen content can steer, so it's escaped and can't forge that mark.
    public static func deep(_ packet: ContextPacket, quickNote: String?, approved: Bool = false) -> String {
        var text = body(packet)
        if let quickNote, !quickNote.isEmpty {
            text += "\n<quick-note>\(escape(quickNote))</quick-note>"
        }
        if approved { text += "\n<approved-action/>" }
        text += "\nYou are Lumi's Deep lane: work it through with your tools, then end with the buddy block. Its `handoff` is null."
        return text
    }

    /// Screen text (titles, selections, chat) and typed questions can contain anything, so
    /// nothing inside may close a tag: `<`, `>` and `&` become JSON escapes in the packet and
    /// entities in the question.
    static func body(_ packet: ContextPacket) -> String {
        let json = modelJSON(packet)
        let safeJSON = json.replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
        return "<buddy-packet>\n\(safeJSON)\n</buddy-packet>\n<question>\(escape(packet.utterance))</question>"
    }

    /// Fields the model never uses, left out of what it reads (the app keeps the whole packet):
    /// `utterance` is the `<question>` already; screen coordinates and IDs are for the app's own
    /// rings, overlay and history. `window.bounds` stays: it places `screenshot_detail` in the window
    /// image. `cursor.element`, `display.appearance` and the rest stay too.
    static let modelOmits: [[String]] = [
        ["utterance"], ["selection", "bounds"], ["selection", "bounds_source"],
        ["cursor", "x"], ["cursor", "y"], ["display", "id"], ["display", "scale"], ["conversation", "id"],
    ]

    /// The packet as the model reads it: the wire JSON without `modelOmits`, keys sorted as before.
    static func modelJSON(_ packet: ContextPacket) -> String {
        guard let data = try? ContextPacket.makeEncoder().encode(packet),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        for path in modelOmits {
            if path.count == 1 {
                object[path[0]] = nil
            } else if var inner = object[path[0]] as? [String: Any] {
                inner[path[1]] = nil
                object[path[0]] = inner.isEmpty ? nil : inner
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: rounded(object), options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: out, as: UTF8.self)
    }

    /// JSONSerialization writes doubles with 17 digits (0.1 as 0.10000000000000001): coordinates
    /// such as `screenshot_detail` on a scaled display are rounded to 2 decimals. Integers and
    /// booleans are left as they are.
    static func rounded(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(rounded)
        case let array as [Any]: return array.map(rounded)
        case let number as NSNumber where CFNumberIsFloatType(number) && CFGetTypeID(number) != CFBooleanGetTypeID():
            return NSDecimalNumber(string: String(format: "%.2f", number.doubleValue).replacingOccurrences(of: ".00", with: ""))
        default: return value
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Picks Deep's working folder from the packet (localhost server cwd, editor
/// workspace, terminal cwd), then applies the trust rule.
public enum ProjectResolver {
    /// Whether the packet itself is about the project Deep last ran in: its folder is in Deep's
    /// folder, or Deep's folder is in its repo. A packet with no folder of its own (a web page, a
    /// document) isn't.
    public static func isSameProject(_ packet: ContextPacket, deepFolder: URL?, home: String = NSHomeDirectory(),
                                     isRepo: (String) -> Bool = hasGitEntry) -> Bool {
        guard let deepFolder, let candidate = candidate(in: packet) else { return false }
        let deep = FolderTrust.normalize(deepFolder.path)
        func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if within(FolderTrust.normalize(candidate.path), deep) { return true }
        guard let root = project(in: packet, home: home, isRepo: isRepo) else { return false }
        return within(deep, FolderTrust.normalize(root.path))
    }

    public static func candidate(in packet: ContextPacket) -> URL? {
        let path = packet.localServer?.cwd ?? packet.editor?.workspace ?? packet.terminal?.cwd
        return path.map { URL(fileURLWithPath: $0) }
    }

    /// The packet's own folder, else a local clone of the repo the browser shows (a github.com or
    /// gitlab.com page), found among trusted folders and their direct children, else the folder
    /// of the most recent terminal or editor that sits in a trusted folder. So a question asked
    /// on the repo's web page, or from Slack right after the terminal, still finds the project.
    public static func candidate(in packet: ContextPacket, trust: FolderTrust?) -> URL? {
        if let own = candidate(in: packet) { return own }
        guard let trust else { return nil }
        if let url = packet.browser?.url, let repo = HostedRepo(browserURL: url),
           let clone = RepoClones.find(repo, in: trust).first {
            return URL(fileURLWithPath: clone)
        }
        // `recent` is newest first. Untrusted folders are skipped, not just refused later, so an
        // older trusted project still counts.
        return (packet.recent ?? []).lazy.compactMap { $0.cwd.map { URL(fileURLWithPath: $0) } }
            .first { trust.isTrusted($0, rule: .folderOrAncestor) }
    }

    /// The project the packet is about: the git top-level of the candidate folder, so `cd src`,
    /// or a dev server in a subfolder, is the same project as the editor at the repo root. Both
    /// the conversation rule and Deep's folder use it. A folder outside any repo stays as it is:
    /// widening it to a trusted parent such as ~/Developer would merge unrelated projects. For
    /// the same reason, a repo at home or / (dotfiles) doesn't count.
    public static func project(in packet: ContextPacket, trust: FolderTrust? = nil, home: String = NSHomeDirectory(),
                               isRepo: (String) -> Bool = hasGitEntry) -> URL? {
        guard let candidate = candidate(in: packet, trust: trust) else { return nil }
        return gitRoot(of: candidate.path, home: home, isRepo: isRepo).map { URL(fileURLWithPath: $0) } ?? candidate
    }

    static func gitRoot(of path: String, home: String, isRepo: (String) -> Bool) -> String? {
        let home = FolderTrust.normalize(home)
        var dir = FolderTrust.normalize(path)
        while dir != "/" && !dir.isEmpty && dir != home {
            if isRepo(dir) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// A `.git` folder, or the `.git` file of a worktree or submodule.
    public static func hasGitEntry(_ dir: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
    }

    /// A trusted project in the packet wins: its repo root when that is trusted; else the
    /// highest trusted folder between the repo root and the packet's folder, so `cd src` keeps
    /// one Deep session when only a subfolder of the repo was trusted. A repo root above the
    /// trusted folder is never used (Deep starts only in or under a trusted folder). Otherwise
    /// the conversation's last Deep folder (still re-checked), so a follow-up asked from an
    /// untrusted terminal keeps its context. Otherwise home. Moving to a different trusted
    /// project is a conversation-level change (fresh, with "keep in the old one"); the
    /// app decides that, the cascade just follows.
    public static func folder(for packet: ContextPacket, state: ConversationState, trust: FolderTrust,
                              policy: DeepPolicy, home: URL, isRepo: (String) -> Bool = hasGitEntry) -> DeepFolder {
        if let candidate = candidate(in: packet, trust: trust), trust.isTrusted(candidate, rule: policy.trust) {
            let root = gitRoot(of: candidate.path, home: home.path, isRepo: isRepo)
            let chosen = root.flatMap { highestTrusted(from: candidate.path, upTo: $0, trust: trust, rule: policy.trust) }
            return trust.deepDirectory(for: chosen.map { URL(fileURLWithPath: $0) } ?? candidate, home: home, rule: policy.trust)
        }
        return trust.deepDirectory(for: state.deepFolder, home: home, rule: policy.trust)
    }

    /// The repo root if trusted, else the highest folder below it, down to `path`, that is
    /// trusted itself.
    static func highestTrusted(from path: String, upTo root: String, trust: FolderTrust, rule: DeepPolicy.Trust) -> String? {
        if trust.isTrusted(URL(fileURLWithPath: root), rule: rule) { return root }
        var dirs: [String] = []
        var dir = FolderTrust.normalize(path)
        while dir.count > root.count { dirs.append(dir); dir = (dir as NSString).deletingLastPathComponent }
        return dirs.reversed().first { trust.trustedPaths.contains($0) }
    }
}

/// What the UI sees for one question through the cascade.
public enum CascadeEvent: Sendable, Equatable {
    /// A lane's turn event. The pill's mode chip follows `lane`.
    case turn(lane: Mode, TurnEvent)
    /// Quick handed off. Show "Handing to Deep" and speak Quick's line ("Let me check the repo").
    case handingOff(say: String?)
    /// Quick asked for Research (M3): the engine starts a background job.
    case researchRequested(say: String?)
    /// The question is over. Persist `state`.
    case done(CascadeResult)
}

public struct CascadeResult: Sendable, Equatable {
    /// The lane whose answer stands (nil if nothing answered).
    public var lane: Mode?
    public var outcome: TurnOutcome?
    public var state: ConversationState
    /// From Quick's result to Deep's first streamed text as the cascade forwards it: Deep's
    /// launch, cold start and thinking included (M1 ask). Nil when Deep wasn't a handoff.
    public var handoffToFirstText: Duration?
    /// Deep's work ran in the session's open Claude session: that session's own events finish its
    /// turn, so the shell doesn't finish it a second time.
    public var inOpenSession = false
}

/// Quick answers or hands off; Deep takes over in the project folder (steps 2–4).
public actor Cascade {
    private let quick: QuickLane
    private let deep: DeepLane
    private let trust: @Sendable () -> FolderTrust
    private let policy: DeepPolicy
    private let home: URL
    private let now: @Sendable () -> Date
    /// Sessions on: Deep's work goes to a new open session instead of the Deep lane.
    private let openHandoff: OpenHandoffRunner?
    private var running: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    /// `trust` is read per question, so trusting a folder in Claude Code takes effect at once.
    public init(quick: QuickLane, deep: DeepLane, policy: DeepPolicy = .default, home: URL,
                now: @escaping @Sendable () -> Date = { Date() },
                openHandoff: OpenHandoffRunner? = nil,
                trust: @escaping @Sendable () -> FolderTrust) {
        self.openHandoff = openHandoff
        self.quick = quick
        self.deep = deep
        self.policy = policy
        self.home = home
        self.now = now
        self.trust = trust
    }

    /// Deep stays the lane only for a close follow-up: Deep answered last, and either it was within
    /// `Router.deepFollowUpWindow` or this question is about the same project. Otherwise Quick takes
    /// it (it sees Deep's answer in the recap and can hand off again), so one hand-off doesn't keep
    /// a conversation on the slower lane for good.
    func deepIsCurrent(_ question: Question, state: ConversationState) -> Bool {
        guard state.lastLane == .deep else { return false }
        if let at = state.lastDeepAnswerAt, now().timeIntervalSince(at) <= Router.deepFollowUpWindow { return true }
        return ProjectResolver.isSameProject(question.packet, deepFolder: state.deepFolder, home: home.path)
    }

    public func ask(_ question: Question, state: ConversationState) -> AsyncStream<CascadeEvent> {
        // An action's prompt is model-written, so its words never pick the lane ("quick answer…").
        let start = question.isApprovedAction ? .deep
            : Router.start(utterance: question.packet.utterance, routing: question.routing,
                           deepIsCurrent: deepIsCurrent(question, state: state))
        return run(conversation: state.id) { out in
            await self.flow(question, state: state, start: start, out: out)
        }
    }

    /// "Go deeper" on a Quick card: the same question in Deep, with Quick's answer as the note.
    public func goDeeper(_ question: Question, state: ConversationState) -> AsyncStream<CascadeEvent> {
        run(conversation: state.id) { out in
            var s = state
            let r = await self.runDeep(question, state: &s, note: state.lastQuickAnswer.map { "Quick answered: \($0)" },
                                       handoffAt: nil, out: out)
            out.yield(.done(r))
        }
    }

    /// Esc: stops whichever lane is working on the conversation.
    public func cancel(conversation: String) async {
        running[conversation]?.task.cancel()
        await quick.cancel(conversation: conversation)
        await deep.cancel(conversation: conversation)
    }

    private func run(conversation: String,
                     _ body: @escaping @Sendable (AsyncStream<CascadeEvent>.Continuation) async -> Void) -> AsyncStream<CascadeEvent> {
        let (stream, out) = AsyncStream<CascadeEvent>.makeStream()
        let id = UUID()
        // A new question on the same conversation supersedes the running one, which ends (with
        // its own `.done`) before this one starts, so saved states arrive in order.
        let previous = running[conversation]?.task
        previous?.cancel()
        let task = Task {
            await previous?.value
            await body(out)
            out.finish()
            self.finished(conversation: conversation, id: id)
        }
        running[conversation] = (id, task)
        out.onTermination = { _ in task.cancel() }
        return stream
    }

    private func finished(conversation: String, id: UUID) {
        if running[conversation]?.id == id { running[conversation] = nil }
    }

    private func flow(_ question: Question, state: ConversationState, start: Start,
                      out: AsyncStream<CascadeEvent>.Continuation) async {
        var state = state
        switch start {
        case .research:
            out.yield(.researchRequested(say: nil))
            out.yield(.done(CascadeResult(lane: nil, outcome: nil, state: state)))
        case .deep, .deeper:
            let note = start == .deeper ? state.lastQuickAnswer.map { "Quick answered: \($0)" } : nil
            let r = await runDeep(question, state: &state, note: note, handoffAt: nil, out: out)
            out.yield(.done(r))
        case .quick(let allowHandoff):
            if await !quick.isLive(conversation: state.id) { Self.forgetShown(state.quickSessionID, in: &state) }
            var outcome: TurnOutcome?
            var ended = false
            // A second pass only when Claude Code no longer has the resumed session: start fresh,
            // with the whole recap and screen, instead of failing the conversation for good.
            for _ in 0..<2 {
                let (sent, images) = Self.forSession(question, session: state.quickSessionID, state: state, lane: .quick)
                let input = TurnInput(text: BuddyPrompt.quick(sent, allowHandoff: allowHandoff), images: images)
                var sessionLost = false
                for await event in await quick.ask(conversation: state.id, resumeSessionID: state.quickSessionID, input: input) {
                    if case .failed(.sessionNotFound) = event, state.quickSessionID != nil {
                        Self.forgetShown(state.quickSessionID, in: &state)
                        state.quickSessionID = nil
                        sessionLost = true
                        continue
                    }
                    // Keep the session even when the turn fails or is cancelled: Claude Code wrote it.
                    if let id = Self.sessionID(in: event) { state.quickSessionID = id }
                    if case .finished(let o) = event {
                        outcome = o
                        Self.answered(state.quickSessionID, o, packet: sent, question: question, sentImage: !images.isEmpty, in: &state)
                    }
                    ended = ended || event.isTerminal
                    out.yield(.turn(lane: .quick, event))
                }
                if !sessionLost { break }
            }
            if !ended { out.yield(.turn(lane: .quick, .failed(.cancelled))) }
            guard let outcome else {
                out.yield(.done(CascadeResult(lane: nil, outcome: nil, state: state)))
                return
            }
            let block = outcome.extraction.block
            state.lastLane = .quick
            switch (block?.handoff, allowHandoff) {
            case (.deep?, true):
                let handoffAt = ContinuousClock.now
                out.yield(.handingOff(say: block?.say))
                var r = await runDeep(question, state: &state, note: block?.say, handoffAt: handoffAt, out: out)
                if r.outcome == nil {
                    // Deep failed: Quick's turn is what there is; the failure was forwarded.
                    r.lane = .quick
                    r.outcome = outcome
                }
                out.yield(.done(r))
            case (.research?, true):
                out.yield(.researchRequested(say: block?.say))
                out.yield(.done(CascadeResult(lane: .quick, outcome: outcome, state: state)))
            default:
                // A handoff line is a promise, not an answer: never keep it for "Go deeper".
                if block?.handoff == nil { state.lastQuickAnswer = Self.answerText(outcome) }
                if let id = state.quickSessionID, let own = Self.ownEntry(question, outcome) { Self.markSeen(id, [own], in: &state) }
                out.yield(.done(CascadeResult(lane: .quick, outcome: outcome, state: state)))
            }
        }
    }

    /// What `session` is sent: the recap it hasn't seen, and only what changed on screen since it
    /// last looked.
    /// Deep always gets the whole packet and the image: it runs tools for many turns and is the
    /// lane Claude Code compacts, which drops earlier images the record would still count on.
    static func forSession(_ question: Question, session: String?, state: ConversationState,
                           lane: Mode) -> (ContextPacket, [TurnInput.Image]) {
        let packet = unseenTurns(question.packet, session: session, state: state)
        return ScreenDelta.apply(packet, image: question.screenshot, detail: question.detail, token: question.screenToken,
                                 seen: lane == .quick ? session.flatMap { state.seenScreens[$0] } : nil)
    }

    /// A turn finished: only now does the session count as holding what it was sent (a cancelled
    /// or crashed turn may never have reached its transcript). After a compaction it holds a
    /// summary of everything before, so only this turn counts.
    static func answered(_ session: String?, _ outcome: TurnOutcome, packet: ContextPacket, question: Question,
                         sentImage: Bool, in state: inout ConversationState) {
        guard let session, !outcome.result.isError else { return }
        if outcome.result.compacted { forgetShown(session, in: &state) }
        markSeen(session, packet.conversation?.previous ?? [], in: &state)
        markShown(session, question, sentImage: sentImage, in: &state)
    }

    /// After a compaction the session holds a summary, not the turns or images it was sent: the
    /// next question sends everything again.
    static func forgetShown(_ session: String?, in state: inout ConversationState) {
        guard let session else { return }
        state.seenScreens[session] = nil
        state.seenRecaps[session] = nil
    }

    /// `session` now has this question's screen: its image (when sent) and its packet fields.
    static func markShown(_ session: String, _ question: Question, sentImage: Bool, in state: inout ConversationState) {
        state.seenScreens[session] = ScreenDelta.seen(
            question.packet, token: question.screenToken, sentImage: sentImage, before: state.seenScreens[session])
    }

    /// The recap a session gets (`conversation.previous`): only turns it doesn't hold, so a
    /// resumed session isn't sent its own history again. A session with no record (new to the
    /// conversation, or its record was lost to a switch) gets them all: a repeat beats a gap.
    static func unseenTurns(_ packet: ContextPacket, session: String?, state: ConversationState) -> ContextPacket {
        guard let session, let seen = state.seenRecaps[session], var conversation = packet.conversation else { return packet }
        conversation.previous = conversation.previous.filter { !seen.contains($0) }
        var copy = packet
        copy.conversation = conversation
        return copy
    }

    /// `session` now holds `entries` (a recap it was sent, or its own answer). Keeps the last few.
    static func markSeen(_ session: String, _ entries: [String], in state: inout ConversationState) {
        let held = state.seenRecaps[session] ?? []
        state.seenRecaps[session] = Array((held + entries.filter { !held.contains($0) })
            .suffix(2 * ContextPacket.Conversation.maxPrevious))
    }

    /// The recap entry this question's answer will become, as the app records it.
    static func ownEntry(_ question: Question, _ outcome: TurnOutcome) -> String? {
        outcome.extraction.block.map {
            ContextPacket.Conversation.recapEntry(question: question.packet.utterance, answer: $0.say)
        }
    }

    static func sessionID(in event: TurnEvent) -> String? {
        switch event {
        case .initialized(let info) where !info.sessionID.isEmpty: info.sessionID
        case .finished(let o) where !o.result.sessionID.isEmpty: o.result.sessionID
        case .failed(.turnFailed(let r)) where !r.sessionID.isEmpty: r.sessionID
        default: nil
        }
    }

    /// What Quick answered, for Deep's note: the spoken line plus the card's text.
    static func answerText(_ outcome: TurnOutcome) -> String {
        guard let block = outcome.extraction.block else { return outcome.extraction.prose }
        let card = block.cardHTML.map {
            $0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        } ?? ""
        return card.isEmpty ? block.say : "\(block.say) \(card)"
    }

    private func runDeep(_ question: Question, state: inout ConversationState, note: String?, handoffAt: ContinuousClock.Instant?,
                         out: AsyncStream<CascadeEvent>.Continuation) async -> CascadeResult {
        if let openHandoff, let events = await openHandoff(OpenHandoff(question: question, state: state, quickNote: note)) {
            return await runOpen(events, state: &state, handoffAt: handoffAt, out: out)
        }
        let folder = ProjectResolver.folder(for: question.packet, state: state, trust: trust(), policy: policy, home: home)
        // A different folder means a different Claude Code session. The switch is committed only
        // once Deep has started, so a failed or cancelled launch keeps the old folder's session.
        // By path: a URL made for an existing folder can carry a trailing slash.
        let sameFolder = state.deepFolder?.standardizedFileURL.path == folder.url.standardizedFileURL.path
        // Another folder resumes that folder's own Deep session, if the conversation has one.
        var resume = sameFolder ? state.deepSessionID : state.deepSessions[folder.url.standardizedFileURL.path]
        if await !deep.isLive(conversation: state.id, folder: folder) { Self.forgetShown(resume, in: &state) }
        var outcome: TurnOutcome?
        var firstText: Duration?
        var ended = false
        defer { if !ended { out.yield(.turn(lane: .deep, .failed(.cancelled))) } }
        // As in Quick: a resumed session Claude Code no longer has gets one fresh start.
        for _ in 0..<2 {
            let (packet, images) = Self.forSession(question, session: resume, state: state, lane: .deep)
            let input = TurnInput(text: BuddyPrompt.deep(packet, quickNote: note, approved: question.isApprovedAction),
                                  images: images)
            var sessionLost = false
            for await event in await deep.ask(conversation: state.id, folder: folder,
                                              resumeSessionID: resume, input: input) {
                if case .failed(.sessionNotFound) = event, resume != nil {
                    Self.forgetShown(resume, in: &state)
                    if state.deepSessionID == resume { state.deepSessionID = nil }
                    state.deepSessions[folder.url.standardizedFileURL.path] = nil
                    resume = nil
                    sessionLost = true
                    continue
                }
                if let id = Self.sessionID(in: event) {
                    state.deepSessionID = id
                    state.deepFolder = folder.url
                    state.deepSessions[folder.url.standardizedFileURL.path] = id
                }
                if case .text = event, firstText == nil, let handoffAt { firstText = ContinuousClock.now - handoffAt }
                if case .finished(let o) = event {
                    outcome = o
                    Self.answered(state.deepSessionID, o, packet: packet, question: question, sentImage: !images.isEmpty, in: &state)
                }
                ended = ended || event.isTerminal
                out.yield(.turn(lane: .deep, event))
            }
            if !sessionLost { break }
        }
        if outcome != nil {
            state.lastLane = .deep
            state.lastDeepAnswerAt = now()
            if let id = state.deepSessionID, let outcome, let own = Self.ownEntry(question, outcome) {
                Self.markSeen(id, [own], in: &state)
            }
        }
        return CascadeResult(lane: outcome == nil ? nil : .deep, outcome: outcome, state: state, handoffToFirstText: firstText)
    }
}

extension Cascade {
    /// Deep's work in an open session: its events stand in for the Deep lane's. The open session's
    /// ids live in Lumi's session store, not in `ConversationState`.
    private func runOpen(_ events: AsyncStream<TurnEvent>, state: inout ConversationState, handoffAt: ContinuousClock.Instant?,
                         out: AsyncStream<CascadeEvent>.Continuation) async -> CascadeResult {
        var outcome: TurnOutcome?
        var firstText: Duration?
        var ended = false
        for await event in events {
            if case .text = event, firstText == nil, let handoffAt { firstText = ContinuousClock.now - handoffAt }
            if case .finished(let o) = event { outcome = o }
            ended = ended || event.isTerminal
            out.yield(.turn(lane: .deep, event))
        }
        if !ended { out.yield(.turn(lane: .deep, .failed(.cancelled))) }
        if outcome != nil {
            state.lastLane = .deep
            state.lastDeepAnswerAt = now()
        }
        return CascadeResult(lane: outcome == nil ? nil : .deep, outcome: outcome, state: state, handoffToFirstText: firstText,
                             inOpenSession: true)
    }
}

extension TurnEvent {
    /// `.finished` or `.failed`: the last event of a turn. A lane stream cut off by Esc ends
    /// without one, so the cascade adds `.failed(.cancelled)`.
    var isTerminal: Bool {
        switch self {
        case .finished, .failed: true
        default: false
        }
    }
}
