import BuddyCore
import Foundation

/// The context strip: what Lumi read when the turn was asked (04 §4.1). Copy is always
/// "Read from …", never "saw".
nonisolated public struct ContextStrip: Sendable, Equatable {
    public var appName: String?
    public var bundleID: String?
    /// The document, page or window title.
    public var title: String?
    /// The selection, or an element, in a few words.
    public var detail: String?
    /// The window crop Lumi captured, when it read the screen.
    public var screenshotPath: String?
    /// False when the ▣ chip was off, capture was declined or the app is blocked.
    public var readScreen: Bool

    public init(appName: String? = nil, bundleID: String? = nil, title: String? = nil, detail: String? = nil,
                screenshotPath: String? = nil, readScreen: Bool = true) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.detail = detail
        self.screenshotPath = screenshotPath
        self.readScreen = readScreen
    }

    /// "Read from Numbers"; nil when nothing was read, and the turn shows no strip.
    public var headline: String? {
        guard readScreen, let appName, !appName.isEmpty else { return nil }
        return "Read from \(appName)"
    }

    /// "Q3 budget · B4:F19".
    public var subline: String? {
        let parts = [title, detail].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func from(_ packet: ContextPacket?, withScreen: Bool = true) -> ContextStrip {
        guard let packet, withScreen else { return ContextStrip(readScreen: false) }
        let title = packet.editor?.file.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? packet.window?.document.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? packet.browser?.tabTitle ?? packet.window?.title
        let detail = packet.selection?.text.map { Self.clip($0) }
        return ContextStrip(appName: packet.app?.name, bundleID: packet.app?.bundle, title: title, detail: detail,
                            screenshotPath: packet.screenshot, readScreen: packet.app != nil)
    }

    static func clip(_ s: String, _ max: Int = 40) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count <= max ? one : String(one.prefix(max - 1)) + "…"
    }
}

/// An inline approval, pending or answered.
nonisolated public struct PageApproval: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case pending
        /// The user answered; the reply is on its way. Clears on the engine's `permissionResolved`,
        /// or goes back to pending if the ask comes again (nothing was sent).
        case sending(allow: Bool)
        case allowed, denied, cancelled
    }

    /// Waiting on the user or on the reply: the card stays pinned.
    public var isOpen: Bool {
        switch state {
        case .pending, .sending: true
        case .allowed, .denied, .cancelled: false
        }
    }

    public var ask: PermissionAsk
    public var since: Date
    public var state: State
    /// When the reply went out (allowed or denied): the receipt's time.
    public var resolvedAt: Date?
    public var id: String { ask.id }

    public init(ask: PermissionAsk, since: Date, state: State = .pending) {
        self.ask = ask
        self.since = since
        self.state = state
    }
}

/// An AskUserQuestion card, pending or answered.
nonisolated public struct PageQuestion: Sendable, Equatable, Identifiable {
    public var ask: QuestionAsk
    public var since: Date
    /// question → chosen labels, once answered.
    public var answers: [String: String]?
    public var id: String { ask.id }
}

/// A teammate's lane on the page: its own Trail and words, by Agent tool use id.
nonisolated public struct PageLane: Sendable, Equatable {
    public var trail: Trail
    public var text: StreamingMarkdown
    /// Its final message (`task_notification.summary`).
    public var summary: String?
    /// The page has had a live event of this teammate: the store's snapshot no longer overrides it.
    public var followedLive = false
}

/// One teammate: a named background subagent of the session (02 §D4), as the page shows it: the
/// roster's entry (state, live line, steps, times) joined with its lane.
nonisolated public struct PageTeammate: Sendable, Equatable, Identifiable {
    public var member: TeammateSnapshot
    public var lane: Trail
    public var laneText: StreamingMarkdown
    public var summary: String?

    public var id: String { member.id }
    public var toolUseID: String { member.toolUseID }
    public var name: String { member.name }
    /// The spawn prompt's description, shown as "Brief ⌄" in the lane.
    public var brief: String? { member.brief }
    public var state: TeammateSnapshot.State { member.state }
    public var liveLine: String? { member.liveLine }

    /// An SF Symbol from the teammate's role (04 §5.1).
    public var glyph: String { TeammateGlyph.symbol(for: name + " " + (brief ?? "")) }

    public var snapshot: TeammateSnapshot { member }
}

nonisolated public enum TeammateGlyph {
    static let table: [(words: [String], symbol: String)] = [
        (["research", "search", "find", "investigat", "explor"], "magnifyingglass"),
        (["review", "check", "audit", "verif", "test"], "checkmark.seal"),
        (["build", "implement", "fix", "engineer", "code"], "hammer"),
        (["writ", "draft", "doc", "note", "copy"], "text.alignleft"),
        (["data", "analy", "number", "chart", "metric"], "chart.bar"),
    ]

    public static func symbol(for role: String) -> String {
        let r = role.lowercased()
        return table.first { $0.words.contains { r.contains($0) } }?.symbol ?? "person.crop.circle"
    }
}

/// One turn on the page: what the user asked, what Lumi read, the Trail and the answer.
nonisolated public struct PageTurn: Sendable, Equatable, Identifiable {
    public var id: String
    public var question: String
    public var kind: TurnKind
    public var context: ContextStrip?
    public var trail: Trail
    public var answer: StreamingMarkdown
    public var approvals: [PageApproval] = []
    public var questions: [PageQuestion] = []
    /// The latest TodoWrite list: the plan tile.
    public var plan: [StepDetail.Todo]?
    public var started = false
    public var finished = false
    public var failure: SessionFailure?
    public var userUUID: String?
    /// Lumi quit (or the process died) mid-turn: "Interrupted · Continue".
    public var interrupted = false
    /// Read back from the transcript: no live timing, so no Trail line.
    public var fromHistory = false
    /// Teammates that worked during a past turn, by name.
    public var historyTeammates: [String] = []
    /// A past turn edited or wrote files (the transcript says).
    public var historyChangedFiles = false
    /// A teammate started while this turn ran.
    public var startedTeam = false

    /// Teammates worked in this turn: a past one by its transcript, a live one as they started.
    public var hadTeam: Bool { startedTeam || !historyTeammates.isEmpty }

    /// The turn edited or wrote files: a past turn by its transcript, a live one by its Trail.
    public var changedFiles: Bool {
        historyChangedFiles || trail.rows.contains { $0.step.map { $0.kind == .edit || $0.kind == .write } ?? false }
    }

    public init(id: String, question: String, kind: TurnKind, context: ContextStrip?, at: Date) {
        self.id = id
        self.question = question
        self.kind = kind
        self.context = context
        trail = Trail(startedAt: at)
        answer = StreamingMarkdown()
    }
}

/// What a send from the composer became.
nonisolated public enum PageSend: Sendable, Equatable {
    /// A new turn on the page.
    case turn(id: String)
    /// A steer: a note inside the running Trail, sent to the running turn.
    case steer
}

/// One session's conversation page: the Panel and the Studio column render this. Pure; the
/// view model feeds it the session's events and the user's actions with their times.
nonisolated public struct ConversationPage: Sendable, Equatable {
    public var session: SessionID
    public var title: String
    /// "From Xcode · AuthKit".
    public var subtitle: String?
    public var symbol: String?
    /// The session's identity colour, for its agent mark.
    public var color: ConversationColor = .ember
    public private(set) var turns: [PageTurn] = []
    /// The session's teammates: one stable entry each, from start to end (`TeamRoster`).
    public private(set) var team = TeamRoster()
    private var lanes: [String: PageLane] = [:]
    private var nextTurn = 0

    public init(session: SessionID, title: String, subtitle: String? = nil, symbol: String? = nil) {
        self.session = session
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
    }

    public init(snapshot: SessionSnapshot) {
        let from = snapshot.origin?.appName.map { "From \($0)" }
        self.init(session: snapshot.id, title: snapshot.title, subtitle: from, symbol: snapshot.symbol)
        color = snapshot.color
    }

    public var isRunning: Bool { !(turns.last?.finished ?? true) }

    /// Every teammate of the latest team, in start order, with its lane.
    public var teammates: [PageTeammate] {
        team.members.map { m in
            let lane = lanes[m.toolUseID]
            return PageTeammate(member: m, lane: lane?.trail ?? Trail(startedAt: m.startedAt ?? .distantPast, lane: m.toolUseID),
                                laneText: lane?.text ?? StreamingMarkdown(), summary: lane?.summary)
        }
    }

    /// Approvals still on screen: waiting on the user, or on the reply.
    public var pendingApprovals: [PageApproval] {
        turns.flatMap(\.approvals).filter(\.isOpen)
    }

    public var pendingQuestions: [PageQuestion] {
        turns.flatMap(\.questions).filter { $0.answers == nil }
    }

    /// Waiting on the user: an approval or a question (the header disc's amber rim, QA U18).
    public var needsYou: Bool { !pendingApprovals.isEmpty || !pendingQuestions.isEmpty }

    /// The live line of the running turn, for the header and the peek.
    public func liveLine(at now: Date) -> String? {
        guard let last = turns.last, !last.finished else { return nil }
        return last.trail.liveLine(at: now)
    }

    /// The earliest time a Trail wants a tick (a held-back live verb).
    public var nextTick: Date? {
        ([turns.last?.trail.nextTick] + lanes.values.map(\.trail.nextTick)).compactMap { $0 }.min()
    }

    /// The session's teammates as the store knows them, for a page opened mid-run or later
    /// (QA U30). Each one the page hasn't seen joins the roster with the snapshot's state and live
    /// line, and its lane gets the earlier text and steps (`lanes`, by tool use id; no handoff
    /// rows), so calling it again is safe. Known ones take the store's state (forward only) unless
    /// this page is following them live. `live`: the store's `teamLive`; it turns the roster on,
    /// and off only while the page follows none of the team itself.
    public mutating func seed(teammates: [TeammateSnapshot], live: Bool, lanes history: [String: LaneHistory] = [:],
                              at now: Date) {
        for mate in teammates {
            let h = history[mate.toolUseID] ?? LaneHistory()
            let working = mate.state.isRunning
            guard var lane = lanes[mate.toolUseID] else {
                team.adopt(mate, live: live)
                lanes[mate.toolUseID] = PageLane(trail: Self.lane(mate, h, working: working, at: now),
                                           text: Self.laneText(h.texts, working: working))
                continue
            }
            guard !lane.followedLive else { continue }
            team.adopt(mate, live: live)
            if lane.trail.rows.isEmpty, !h.steps.isEmpty {
                lane.trail = Self.lane(mate, h, working: working, at: now)
            } else if let line = mate.liveLine {
                // Rows here are only ever the file's (the page isn't following it live).
                lane.trail.setLive(line, overHistory: true)
            }
            if lane.text.isEmpty, !h.texts.isEmpty { lane.text = Self.laneText(h.texts, working: mate.state == .working) }
            lanes[mate.toolUseID] = lane
        }
        if !live, !lanes.values.contains(where: \.followedLive) { team.settle() }
        syncLanes(at: now)
    }

    /// The session's waiting ask, for a page that didn't follow the turn that asked it (opened
    /// from a Needs-you, or later): its card shows, the approval pinned above the composer, the
    /// question in the latest turn. An ask the page already has, answered or not, stays as it is.
    public mutating func seed(ask: NeedsYou?, at now: Date) {
        guard let ask else { return }
        switch ask.kind {
        case .permission(let p) where !turns.contains(where: { $0.approvals.contains { $0.id == p.id } }):
            withLatestTurn(at: now) { $0.approvals.append(PageApproval(ask: p, since: ask.since)) }
            refreshTeammateWaits()
        case .question(let q) where !turns.contains(where: { $0.questions.contains { $0.id == q.id } }):
            withLatestTurn(at: now) { $0.questions.append(PageQuestion(ask: q, since: ask.since)) }
        default:
            break
        }
    }

    /// A seeded lane: its earlier steps at their own times, then the store's live line. No clock:
    /// the task's start time isn't known here (QA U32).
    static func lane(_ mate: TeammateSnapshot, _ history: LaneHistory, working: Bool, at now: Date) -> Trail {
        let first = history.steps.first.map { $0.at == .distantPast ? now : $0.at } ?? now
        var lane = Trail(startedAt: first, lane: mate.toolUseID, live: mate.liveLine, timed: false)
        for step in history.steps { lane.apply(step.event, at: step.at == .distantPast ? now : step.at) }
        // The store's line is newer than the file's last step (QA U42).
        if working, let line = mate.liveLine { lane.setLive(line, overHistory: true) }
        if !working { lane.apply(.turnEnded(TurnEnd(kind: .relay, markdown: "", isError: mate.state == .failed)), at: now) }
        return lane
    }

    /// Earlier lane text: finished, unless the teammate is still working and more streams in.
    static func laneText(_ parts: [String], working: Bool) -> StreamingMarkdown {
        let text = parts.joined(separator: "\n\n")
        guard working else { return StreamingMarkdown(finished: text) }
        var md = StreamingMarkdown()
        if !text.isEmpty { md.append(text + "\n\n") }
        return md
    }

    // MARK: History

    /// Earlier turns, read from the session's transcript.
    public mutating func load(history: [TranscriptTurn], at now: Date) {
        turns = history.map { h in
            var turn = PageTurn(id: h.id, question: h.question, kind: h.kind ?? .voice, context: nil, at: now)
            turn.answer = StreamingMarkdown(finished: Self.historyAnswer(h))
            turn.trail.apply(.turnEnded(TurnEnd(kind: .typed, markdown: "")), at: now)
            turn.started = true
            turn.finished = true
            turn.fromHistory = true
            turn.historyTeammates = h.teammates
            turn.historyChangedFiles = h.changedFiles
            // An open session's turn is keyed by its user uuid (v1 turns have no kind): editable.
            if h.kind != nil { turn.userUUID = h.id }
            return turn
        }
        nextTurn = turns.count
    }

    /// A past turn's answer: the whole Markdown for v2 turns (typed turns keep only their first
    /// line in `block`), else the buddy block as text.
    static func historyAnswer(_ h: TranscriptTurn) -> String {
        if let md = h.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty {
            return h.kind == .voice ? strippingBuddyFence(md, fallback: h.block.say) : md
        }
        return answerText(h.block)
    }

    /// A past buddy block as Markdown: what was said, then the card as text.
    public static func answerText(_ block: BuddyBlock) -> String {
        var parts = [block.say.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let html = block.cardHTML {
            let text = CardText.plainText(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != parts[0] { parts.append(text) }
        }
        if let insert = block.insert, !insert.isEmpty { parts.append("```\n\(insert)\n```") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: User actions

    /// The composer's send (or a voice-in-page transcript). While a turn runs, a typed send is
    /// a steer: a note in the running Trail, not a new turn (04 §4.4).
    @discardableResult
    public mutating func send(_ text: String, kind: TurnKind, context: ContextStrip?, at now: Date) -> PageSend {
        if isRunning, kind == .typed || kind == .steer, let i = turns.indices.last {
            turns[i].trail.steer(text, at: now)
            return .steer
        }
        let id = "turn-\(nextTurn)"
        nextTurn += 1
        turns.append(PageTurn(id: id, question: text, kind: kind, context: context, at: now))
        return .turn(id: id)
    }

    /// An edited prompt: its turn and every turn after it leave the page. The roster holds only
    /// the latest team, so if any of those turns had teammates, that team (and its lanes) goes too.
    public mutating func rewind(from turnID: String) {
        guard let i = turns.firstIndex(where: { $0.id == turnID }) else { return }
        let team = turns[i...].contains(where: \.hadTeam)
        turns.removeSubrange(i...)
        if team {
            self.team.clear()
            lanes = [:]
        }
    }

    /// A page opened while a turn it didn't send still runs (QA U7): that turn, with its question,
    /// its clock from when it started and the store's live line. Its events from now on land in it.
    public mutating func showRunning(userUUID: String, question: String, kind: TurnKind, since: Date, live: String?) {
        guard turns.last?.finished ?? true, !turns.contains(where: { $0.userUUID == userUUID || $0.id == userUUID }) else { return }
        var turn = PageTurn(id: "turn-\(nextTurn)", question: question, kind: kind, context: nil, at: since)
        nextTurn += 1
        turn.started = true
        turn.userUUID = userUUID
        if let live { turn.trail.setLive(live) }
        turns.append(turn)
    }

    /// The session was interrupted (Lumi quit mid-turn): the last turn offers Continue.
    public mutating func markInterrupted() {
        guard let i = turns.indices.last else { return }
        turns[i].interrupted = true
    }

    /// Continue: the interrupted turn's events resume as a new turn on the page.
    public mutating func resumeInterrupted(at now: Date) {
        guard let i = turns.indices.last, turns[i].interrupted else { return }
        turns[i].interrupted = false
        send("", kind: turns[i].kind, context: nil, at: now)
        turns[turns.count - 1].started = true
    }

    /// The context the app read for the latest turn replaces the composer's guess.
    public mutating func setContext(_ strip: ContextStrip) {
        guard let i = turns.indices.last else { return }
        turns[i].context = strip
    }

    /// Stop: the Trail freezes and the partial answer is kept. Nothing resumes on its own.
    public mutating func stop(at now: Date) {
        guard let i = turns.indices.last, !turns[i].finished else { return }
        turns[i].trail.stop(at: now)
        turns[i].answer.finish()
        turns[i].finished = true
        for a in turns[i].approvals.indices where turns[i].approvals[a].isOpen {
            turns[i].approvals[a].state = .cancelled
        }
    }

    /// The user answered an approval card: it shows "Sending…" until the engine's
    /// `permissionResolved` (never cleared without a reply).
    public mutating func resolveApproval(_ id: String, allow: Bool, at now: Date) {
        update(approval: id) { if $0.state == .pending { $0.state = .sending(allow: allow) } }
    }

    public mutating func answerQuestion(_ id: String, answers: [String: String], at now: Date) {
        for i in turns.indices {
            for q in turns[i].questions.indices where turns[i].questions[q].id == id {
                turns[i].questions[q].answers = answers
            }
            if turns[i].trail.phase == .needsYou, !hasPending(i) {
                turns[i].trail.apply(.permissionResolved(id: id), at: now)
            }
        }
    }

    public mutating func tick(at now: Date) {
        if let i = turns.indices.last { turns[i].trail.tick(at: now) }
        for key in lanes.keys { lanes[key]?.trail.tick(at: now) }
    }

    // MARK: Session events

    public mutating func apply(_ event: SessionEvent, at now: Date) {
        let before = team
        team.apply(event, at: now)
        syncLanes(at: now)
        switch event {
        case .turnStarted(let uuid, let kind):
            guard kind != .steer else { return }
            if let i = turns.indices.last, !turns[i].started, !turns[i].finished {
                turns[i].started = true
                turns[i].userUUID = uuid
            } else if turns.last?.finished ?? true {
                // A turn the CLI started on its own (a background teammate finished).
                send("", kind: kind, context: nil, at: now)
                turns[turns.count - 1].started = true
                turns[turns.count - 1].userUUID = uuid
            }
        case .step(let step) where step.subagent != nil:
            withLane(toolUseID: step.subagent!) { $0.trail.apply(event, at: now) }
        case .text(let s, let subagent?):
            withLane(toolUseID: subagent) { $0.text.append(s) }
        case .text(let s, nil):
            withRunningTurn(at: now) { turn in
                turn.answer.append(s)
                turn.trail.apply(event, at: now)
            }
        case .step(let step):
            withRunningTurn(at: now) { turn in
                turn.trail.apply(event, at: now)
                if case .todos(let todos)? = step.detail { turn.plan = todos }
            }
        case .stepFinished:
            if let i = turns.indices.last { turns[i].trail.apply(event, at: now) }
            for key in lanes.keys { lanes[key]?.trail.apply(event, at: now) }
        case .permissionRequested(let ask):
            if turns.contains(where: { $0.approvals.contains { $0.id == ask.id } }) {
                // Asked again after an answer: nothing was sent, so it waits for the user again.
                update(approval: ask.id) { if case .sending = $0.state { $0.state = .pending } }
            } else {
                withRunningTurn(at: now) { turn in
                    turn.approvals.append(PageApproval(ask: ask, since: now))
                    turn.trail.apply(event, at: now)
                }
            }
            refreshTeammateWaits()
        case .permissionResolved(let id):
            // The reply was written (ours, the peek's, voice), or the CLI cancelled the ask.
            update(approval: id) {
                switch $0.state {
                case .sending(let allow):
                    $0.state = allow ? .allowed : .denied
                    $0.resolvedAt = now
                case .pending: $0.state = .cancelled
                default: break
                }
            }
            refreshTeammateWaits()
            for i in turns.indices where turns[i].trail.phase == .needsYou && !hasPending(i) {
                turns[i].trail.apply(event, at: now)
            }
        case .questionAsked(let ask):
            if let t = turns.firstIndex(where: { $0.questions.contains { $0.id == ask.id } }),
               let q = turns[t].questions.firstIndex(where: { $0.id == ask.id }) {
                turns[t].questions[q].answers = nil // asked again: the answer wasn't sent
            } else {
                withRunningTurn(at: now) { turn in
                    turn.questions.append(PageQuestion(ask: ask, since: now))
                    turn.trail.apply(event, at: now)
                }
            }
        case .task(let task):
            if case .started(let taskID, _, _, _, _) = task, !before.members.contains(where: { $0.id == taskID }),
               team.members.contains(where: { $0.id == taskID }), let i = turns.indices.last {
                turns[i].startedTeam = true
            }
            apply(task, before: before, at: now)
        case .thinking, .retrying, .compacted:
            withRunningTurn(at: now) { $0.trail.apply(event, at: now) }
        case .turnEnded(let end):
            guard let i = turns.indices.last, !turns[i].finished else { return }
            turns[i].trail.apply(event, at: now)
            turns[i].answer.finish(end.kind == .voice ? Self.strippingBuddyFence(end.markdown, fallback: end.block?.say) : end.markdown)
            turns[i].finished = true
            turns[i].failure = end.error
            // A teammate's ask outlives the lead's turn (QA R9); the lead's own are over.
            for a in turns[i].approvals.indices where turns[i].approvals[a].isOpen && turns[i].approvals[a].ask.asker == nil {
                turns[i].approvals[a].state = .cancelled
            }
        case .processEnded(_, let midTurn):
            guard midTurn, let i = turns.indices.last, !turns[i].finished else { return }
            turns[i].trail.apply(event, at: now)
            turns[i].answer.finish()
            turns[i].finished = true
            turns[i].interrupted = true
        case .launched, .initialized, .runState, .say, .sayFirstSentence, .rateLimit:
            break
        }
    }

    /// The roster has already taken the event; the lane follows it.
    private mutating func apply(_ task: TaskEvent, before: TeamRoster, at now: Date) {
        switch task {
        case .started(let taskID, _, _, _, _), .progress(let taskID, _, _, _):
            guard let mate = team.members.first(where: { $0.id == taskID }) else { return }
            lanes[mate.toolUseID]?.followedLive = true
        case .ended(let taskID, let status, let summary):
            // Only the end the roster took: a repeated notification adds no second handoff.
            guard before.members.first(where: { $0.id == taskID })?.state.isRunning == true,
                  let mate = team.members.first(where: { $0.id == taskID }), var lane = lanes[mate.toolUseID] else { return }
            lane.followedLive = true
            lane.summary = summary
            lane.trail.apply(.turnEnded(TurnEnd(kind: .relay, markdown: "", isError: status == .failed)), at: now)
            lane.text.finish(summary)
            lanes[mate.toolUseID] = lane
            if mate.state == .done, let i = turns.indices.last {
                turns[i].trail.handoff(name: mate.name, summary: summary, at: now)
            }
        }
    }

    // MARK: Helpers

    private func hasPending(_ i: Int) -> Bool {
        turns[i].approvals.contains(where: \.isOpen) || turns[i].questions.contains { $0.answers == nil }
    }

    private mutating func refreshTeammateWaits() {
        team.waiting(on: Set(pendingApprovals.compactMap(\.ask.asker)))
    }

    private mutating func update(approval id: String, _ change: (inout PageApproval) -> Void) {
        for i in turns.indices {
            for a in turns[i].approvals.indices where turns[i].approvals[a].id == id { change(&turns[i].approvals[a]) }
        }
    }

    private mutating func withLane(toolUseID: String, _ change: (inout PageLane) -> Void) {
        guard var lane = lanes[toolUseID] else { return }
        lane.followedLive = true
        change(&lane)
        lanes[toolUseID] = lane
    }

    /// A lane for every member, none for a past team's.
    private mutating func syncLanes(at now: Date) {
        for m in team.members where lanes[m.toolUseID] == nil {
            lanes[m.toolUseID] = PageLane(trail: Trail(startedAt: m.startedAt ?? now, lane: m.toolUseID), text: StreamingMarkdown())
        }
        if lanes.count > team.members.count {
            let keep = Set(team.members.map(\.toolUseID))
            lanes = lanes.filter { keep.contains($0.key) }
        }
    }

    /// The latest turn, finished or not; one is opened on an empty page.
    private mutating func withLatestTurn(at now: Date, _ change: (inout PageTurn) -> Void) {
        if turns.isEmpty { send("", kind: .typed, context: nil, at: now) }
        change(&turns[turns.count - 1])
    }

    /// The running turn; one is opened if events arrive with none (the session ran a turn this
    /// page didn't send).
    private mutating func withRunningTurn(at now: Date, _ change: (inout PageTurn) -> Void) {
        if turns.last?.finished ?? true {
            send("", kind: .typed, context: nil, at: now)
        }
        turns[turns.count - 1].started = true
        change(&turns[turns.count - 1])
    }

    /// A voice turn's result ends with the ```buddy block: the page shows the prose only, or
    /// the spoken line when that's all there is.
    static func strippingBuddyFence(_ markdown: String, fallback: String?) -> String {
        var text = markdown
        if let range = text.range(of: "```buddy", options: .backwards) {
            text = String(text[..<range.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? (fallback ?? "") : text
    }
}
