import BuddyBridge
import BuddyCore
import BuddyOverlay
import BuddyTrace
import Foundation

/// One turn the coordinator follows, in front or in the background (V-02).
///
/// The Glance follows the turn while `epoch` is the coordinator's. A new press, the switcher or a
/// closed approval card moves the epoch on, and the turn keeps running in the background: it
/// never speaks or touches the overlay there, and its answer lands as a ready tile.
/// It comes back to the front with a new epoch (a spoken yes, a click on its needs-you capsule).
@MainActor
final class TurnTicket {
    /// Stable for the turn's life, unlike `epoch`.
    let id: Int
    var epoch: Int
    let conversationID: String
    let startedAt: ContinuousClock.Instant
    /// Where its pill and cards sit, and what it asked about (Research reads it).
    let anchor: Anchor
    let packet: ContextPacket?
    /// The question was spoken: a voice answer that finishes behind waits its turn (`readyAnswers`).
    let spoke: Bool
    /// Its progress capsule (`ProgressBoard`), which says "Ready" while its answer waits.
    var capsule: Int?
    /// What the pill showed last, so it can show it again when the turn comes back.
    var lane: Mode = .quick
    var status: String?
    /// Its `questionSent` was traced and its end not yet: it owes exactly one of answerShown,
    /// backgroundReady, researchStarted, cancelled or error (`traceEnd`).
    var endOwed = false

    var session: SessionID { SessionID(rawValue: conversationID) }

    init(epoch: Int, conversationID: String, startedAt: ContinuousClock.Instant, anchor: Anchor, packet: ContextPacket?,
         spoke: Bool) {
        id = epoch
        self.epoch = epoch
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.anchor = anchor
        self.packet = packet
        self.spoke = spoke
    }

    /// Keeps the pill's lane and line, from the same events the pill shows.
    func follow(_ event: TurnStreamEvent) {
        switch event {
        case .cascade(.turn(let mode, .status(let line))):
            lane = mode
            if line != SessionTurnEvents.waitingLine { status = line }
        case .cascade(.turn(let mode, _)):
            lane = mode
        case .cascade(.handingOff(let line)):
            lane = .deep
            status = line ?? "Handing to Deep"
        case .session(.step(let step)) where step.subagent == nil:
            lane = .deep
            status = TrailCopy.presentLine(step)
        case .session:
            lane = .deep
        default:
            break
        }
    }
}

/// An approval or a question a voice turn is waiting on.
enum GlanceAsk: Equatable {
    case permission(PermissionAsk)
    case question(QuestionAsk)

    var id: String {
        switch self {
        case .permission(let ask): ask.id
        case .question(let ask): ask.id
        }
    }
}

/// A spoken question's answer that finished behind a newer one, recorded and waiting its turn
/// to be shown and spoken (`BuddyCoordinator.readyAnswers`).
struct ReadyAnswer {
    let block: BuddyBlock
    let turn: TranscriptTurn
    let conversation: ConversationTurn?
    let mode: Mode
    let reply: ReplyTracker
    let ticket: TurnTicket
    var queuedAt = ContinuousClock.now
}

/// The approval card on screen, and the turn it belongs to.
struct ShownApproval {
    let ticket: TurnTicket
    let ask: GlanceAsk
}

extension BuddyCoordinator {
    // MARK: - Turns in front and in the background (V-02)

    /// The turn the Glance follows now, if any.
    var foregroundTicket: TurnTicket? { tickets.last { $0.epoch == epoch } }

    /// The id (`TurnTicket.id`) of the turn the pill or its approval card shows; nil when none.
    public var foregroundTurn: Int? { foregroundTicket?.id }

    /// The session the Glance shows: the turn in front (its pill, approval card or answer), or the
    /// answer card still up. Nil while listening or idle, and for a turn in the background.
    public var glanceSession: SessionID? {
        if let ticket = foregroundTicket { return ticket.session }
        if phase == .showing, keptOnScreen, let kept { return SessionID(rawValue: kept.conversationID) }
        return nil
    }

    /// Sessions still running a turn (in front or behind): a new question isn't routed into one.
    var busySessions: Set<SessionID> { Set(tickets.map(\.session)) }

    /// Tells the runtime when what the Glance shows changed.
    func noteFront() {
        let front = Front(session: glanceSession, turn: foregroundTurn)
        guard front != lastFront else { return }
        lastFront = front
        progress.refresh() // a turn left the pill for its capsule, or came back
        onFrontChanged?()
    }

    struct Front: Equatable {
        var session: SessionID?
        var turn: Int?
    }

    /// After `turns.send`: a request that went stale while it was sent is cancelled, unless a new
    /// press only moved it to the background (sessions on); Esc still cancels it.
    func cancelsAfterSend(_ mine: Int) -> Bool {
        guard !isCurrent(mine) else { return false }
        return !turnsKeepRunning || cancelledEpochs.remove(mine) != nil
    }

    /// The turn with this epoch (`TurnTicket.id` for one that never moved) or conversation.
    func ticket(epoch: Int) -> TurnTicket? { tickets.last { $0.epoch == epoch } }
    func ticket(conversation id: String?) -> TurnTicket? { id.flatMap { id in tickets.last { $0.conversationID == id } } }

    /// Every turn whose question was traced as sent ends in exactly one trace: answerShown,
    /// backgroundReady (finished behind a newer question), researchStarted, cancelled or error.
    /// Each end calls this; the run loop's tail traces an error for a turn that ended any other
    /// way, so none ends silently. Without a ticket (nothing was sent yet) it just traces.
    func traceEnd(_ event: TraceEvent, ticket: TurnTicket?, since start: ContinuousClock.Instant? = nil, lane: Mode? = nil,
                  outcome: TraceOutcome?) {
        if let ticket {
            guard ticket.endOwed else { return }
            ticket.endOwed = false
        }
        trace(event, since: start, lane: lane, outcome: outcome)
    }

    /// Esc or Stop: the turn ends.
    func cancel(_ ticket: TurnTicket) async {
        traceEnd(.cancelled, ticket: ticket, outcome: .cancelled)
        await turns.cancel(conversation: ticket.conversationID)
    }

    /// The turn's stream is over.
    func ended(_ ticket: TurnTicket, reply: ReplyTracker) {
        tickets.removeAll { $0 === ticket }
        if shownApproval?.ticket === ticket {
            shownApproval = nil
            if isCurrent(ticket.epoch), phase == .showing { dismissQuietly() }
        }
        noteFront()
    }

    /// A background turn's event: no pill, card or voice, only what its answer needs.
    func applyInBackground(_ event: CascadeEvent, reply: inout ReplyTracker, ticket: TurnTicket) async {
        // Traced behind too, so a turn that left the front before its first event still shows
        // it ran (live, Oct 29: such turns looked like they never started).
        if case .turn(.quick, _) = event, !reply.sawEvent {
            reply.sawEvent = true
            trace(.quickFirstEvent, since: reply.startedAt, lane: .quick)
        }
        if case .turn(.deep, _) = event, !reply.deepStarted {
            reply.deepStarted = true
            trace(.deepStarted, since: reply.handoffAt ?? reply.startedAt, lane: .deep)
        }
        switch event {
        case .turn(_, .failed(let error)):
            reply.error = error
        case .handingOff:
            reply.lane = .deep
        case .researchRequested:
            reply.researchRequested = true
        case .done(let result):
            reply.finished = true
            let mode = result.lane ?? reply.lane ?? .quick
            if reply.researchRequested {
                await startResearch(reply, packet: ticket.packet, spoke: false, epoch: ticket.epoch)
            } else if let block = Self.answerBlock(result, error: reply.error) {
                // A hand-off's open session finishes its turn from the pool's events (V-06).
                traceEnd(.backgroundReady, ticket: ticket, since: reply.startedAt, lane: mode, outcome: .ok)
                await recordInBackground(block, mode: mode, reply: reply, ticket: ticket, cascade: !result.inOpenSession)
            } else {
                traceEnd(.error, ticket: ticket, lane: mode, outcome: .failed)
            }
        default:
            break
        }
    }

    /// A background turn's answer goes into its conversation, and its session lands ready and
    /// unread, with its tile (a cascade turn's here; an open session's from its events).
    /// A spoken question's answer then waits its turn to be shown and spoken.
    func recordInBackground(_ block: BuddyBlock, mode: Mode, reply: ReplyTracker, ticket: TurnTicket, cascade: Bool) async {
        let turn = TranscriptTurn(question: reply.shownQuestion, block: block, mode: mode, model: lane(for: mode).model)
        let conversation = await conversations.record(turn, conversationID: reply.conversationID)
        if cascade {
            routing.cascadeTurnFinished(SessionID(rawValue: reply.conversationID), kind: reply.typed ? .typed : .voice,
                                        question: reply.shownQuestion, block: block)
        }
        queueReady(ReadyAnswer(block: block, turn: turn, conversation: conversation, mode: mode, reply: reply, ticket: ticket))
    }

    // MARK: - Ready answers take turns (owner, Oct 29)

    /// A voice answer that finished behind: it joins the queue, its capsule says "Ready", and it
    /// plays as soon as the Glance is free. Only with sessions on, where a press never cancels.
    func queueReady(_ ready: ReadyAnswer) {
        guard turnsKeepRunning, ready.ticket.spoke, !ready.reply.typed else { return }
        readyAnswers.append(ready)
        trace(.answerQueued, count: readyAnswers.count)
        if let capsule = ready.ticket.capsule { progress.ready(capsule) }
        playNextReady()
    }

    /// The session was forgotten or archived: its answers waiting their turn never play, and their
    /// capsules go (QA gate 4.6).
    func dropReady(for session: SessionID) {
        let gone = readyAnswers.filter { $0.reply.conversationID == session.rawValue }
        guard !gone.isEmpty else { return }
        readyAnswers.removeAll { $0.reply.conversationID == session.rawValue }
        for capsule in gone.compactMap(\.ticket.capsule) { progress.played(capsule) }
    }

    /// Plays ready answers, oldest first, while the Glance is free. Call whenever it may have
    /// become free: an answer was spoken, the voice went quiet, the Glance closed.
    func playNextReady() {
        guard !readyAnswers.isEmpty, readyTask == nil else { return }
        readyTask = Task { [weak self] in
            while let self, await self.playReadyIfFree() {}
            self?.readyTask = nil
        }
    }

    /// The Glance is free when nothing is being said and the user isn't listening, dictating or
    /// typing, and no card is up that hasn't had its turn: every kind counts (an answer, a hand-off's
    /// Deep answer, a chip, a recall, an approval, a research report). A turn in front keeps it too:
    /// its answer comes first, then the queue goes on (65-SURFACE-RULES, rule A).
    /// The switcher's strip and its peeks count too (rule 4): a summon that only looked at the
    /// strip, or switched without a word, leaves it free once they're gone.
    var glanceFreeForReady: Bool {
        guard !isPaused, !speaking, speechStarting == 0, shownApproval == nil, !keyboardInOverlay,
              dictation?.isActive != true, switcherFlow?.holdsGlance != true else { return false }
        return (phase == .idle && !overlay.showsAnswer) || (phase == .showing && answerHeard)
    }

    /// Shows and speaks the oldest ready answer, as it would have in front, with a new epoch and
    /// no trace (its turn ended in backgroundReady). Its capsule goes. Esc skips it like any answer
    /// (`escapePressed`); it stays in its session either way. True when one played.
    func playReadyIfFree() async -> Bool {
        guard glanceFreeForReady, !readyAnswers.isEmpty else { return false }
        let next = readyAnswers.removeFirst()
        trace(.answerPlayed, since: next.queuedAt, outcome: shouldSpeak(spoke: true) ? .ok : .skipped,
              count: readyAnswers.count)
        if let capsule = next.ticket.capsule { progress.played(capsule) }
        // Spoken from the start: a headline begun in front was cut off by the press.
        var reply = next.reply
        (reply.spoken, reply.saidFull, reply.speaking, reply.speechGeneration) = (nil, false, false, nil)
        // No Insert: the app in front now isn't the one it was asked over.
        await show(next.block, turn: next.turn, conversation: next.conversation, mode: next.mode, isLong: false,
                   spoke: true, reply: reply, epoch: nextEpoch(), anchor: next.ticket.anchor, packet: nil, queued: true)
        return true
    }

    /// Brings a background turn to the front with a new epoch; whatever the Glance followed moves
    /// to the background. The pill shows its lane and last line again.
    func reattach(_ ticket: TurnTicket) {
        let mine = nextEpoch()
        ticket.epoch = mine
        noteFront()
        phase = .thinking
        overlay.showThinking(lane(for: ticket.lane), status: ticket.status)
        statusShown(since: ticket.startedAt, epoch: mine)
    }

    // MARK: - Approvals during a voice turn (V-03)

    /// The turn in front asks: the Glance becomes its approval card. Without the permission host
    /// (no Panel) nothing could answer it, so the pill keeps saying it's waiting.
    func showApproval(_ ask: GlanceAsk, for ticket: TurnTicket) {
        guard isCurrent(ticket.epoch), pageFlow != nil else { return }
        stopQuietStatus()
        shownApproval = ShownApproval(ticket: ticket, ask: ask)
        lastMainAction = nil
        shownFix = nil
        keptOnScreen = false
        typedCardShowing = false
        reportShowing = false
        setupChipVisible = false
        overlay.showAnswer(Self.approvalCard(ask, keySymbol: settings.keySymbol, lane: lane(for: ticket.lane),
                                             color: conversations.current?.color ?? .ember), anchor: ticket.anchor)
        phase = .showing
    }

    /// An ask answered anywhere (this card, the peek, a page) or withdrawn: back to the pill.
    func approvalResolved(_ id: String, ticket: TurnTicket) {
        guard let shown = shownApproval, shown.ticket === ticket, shown.ask.id == id else { return }
        resumeThinking(ticket)
    }

    func resumeThinking(_ ticket: TurnTicket) {
        shownApproval = nil
        guard isCurrent(ticket.epoch) else { return }
        phase = .thinking
        overlay.showThinking(lane(for: ticket.lane), status: ticket.status)
        statusShown(since: ticket.startedAt, epoch: ticket.epoch)
    }

    /// While the card is up, the turn's own status lines wait (they'd turn it back into the pill).
    func cardHolds(_ ticket: TurnTicket) -> Bool { shownApproval?.ticket === ticket }

    /// A hand-off's ask, answer or end (`TurnEvent.hostEvent`): the host follows it like a session
    /// turn's, and the turn in front shows the card.
    func hostSaw(_ event: SessionEvent, ticket: TurnTicket) {
        pageFlow?.permissions.observe(event, in: ticket.session)
        guard isCurrent(ticket.epoch) else { return }
        showOrResolve(event, ticket: ticket)
    }

    func showOrResolve(_ event: SessionEvent, ticket: TurnTicket) {
        switch event {
        case .permissionRequested(let ask): showApproval(.permission(ask), for: ticket)
        case .questionAsked(let ask): showApproval(.question(ask), for: ticket)
        case .permissionResolved(let id): approvalResolved(id, ticket: ticket)
        default: break
        }
    }

    /// A click on the card: Allow or Deny, or a question's option. A question that doesn't fit the
    /// card opens its session in Lumi, where the whole question is.
    func answerApproval(_ index: Int) async {
        guard let shown = shownApproval, let host = pageFlow?.permissions else { return }
        let session = shown.ticket.session
        let sent: Bool
        switch shown.ask {
        case .permission(let ask):
            guard index < 2 else { return }
            sent = await host.respond(ask.id, in: session, allow: index == 0) || host.ask(ask.id) == nil
        case .question(let ask):
            guard let options = Self.cardOptions(ask), let item = ask.items.first else {
                openInLumi(shown)
                return
            }
            guard options.indices.contains(index) else { return }
            sent = await host.answerQuestion(ask.id, in: session, answers: [item.question: options[index].label])
                || !host.questions.contains { $0.ask.id == ask.id }
        }
        guard shownApproval?.ticket === shown.ticket else { return }
        if sent {
            resumeThinking(shown.ticket)
        } else {
            overlay.showToast(Self.approvalNotSent, at: pointer.location())
        }
    }

    static let approvalNotSent = "That didn't go through. Try again."

    /// ⤢ on the card, or a question too big for it: the session opens in Lumi, where its page
    /// shows the ask in full; the turn keeps running there.
    func openInLumi(_ shown: ShownApproval) {
        shownApproval = nil
        _ = nextEpoch()
        dismissQuietly()
        pageFlow?.onExpand(shown.ticket.session)
    }

    /// Dictation over a running turn (65-SURFACE-RULES C): the turn keeps running behind, as after
    /// a new press (V-02), and its answer waits as a Ready capsule until the dictation ends. False
    /// with sessions off, where moving behind isn't possible without cancelling it.
    func moveTurnBehind() -> Bool {
        guard phase == .thinking, turnsKeepRunning else { return false }
        shownApproval = nil  // an open approval waits in its amber capsule
        _ = nextEpoch()
        phase = .idle
        return true
    }

    /// The card closed without an answer (click away, ✕, Cancel): the turn keeps waiting in the
    /// background, and its capsule turns amber.
    func approvalClosed() {
        guard shownApproval != nil else { return }
        shownApproval = nil
        _ = nextEpoch()
    }

    /// A click on a session's needs-you capsule or tile: when one of our turns waits on an
    /// ask there, it comes back to the front as the approval card. False otherwise (the caller
    /// shows the peek), and never over a listen or the text box.
    @discardableResult
    public func openWaiting(_ session: SessionID) -> Bool {
        switch phase {
        case .listening, .held, .typing: return false
        case .idle, .thinking, .showing: break
        }
        guard let host = pageFlow?.permissions, let ticket = tickets.last(where: { $0.session == session }),
              let ask = Self.waitingAsk(in: host, session: session) else { return false }
        let mine = nextEpoch()
        ticket.epoch = mine
        noteFront()
        phase = .thinking
        showApproval(ask, for: ticket)
        return true
    }

    static func waitingAsk(in host: LivePermissionHost, session: SessionID) -> GlanceAsk? {
        if let ask = host.pending(in: session).first?.ask { return .permission(ask) }
        return host.questions.first { $0.session == session }.map { .question($0.ask) }
    }

    /// A spoken yes or no, said over the approval card (the listen began while it was up). A
    /// reversible ask takes either; one that needs a click takes a no, and a yes brings the card
    /// back with "This one needs a click." True when the transcript was this answer.
    func answersApprovalByVoice(_ transcript: String) async -> Bool {
        guard let shown = answeringApproval else { return false }
        answeringApproval = nil
        let yes = Self.isBareAffirmative(transcript), no = Self.isBareNegative(transcript)
        guard yes || no, case .permission(let ask) = shown.ask, let host = pageFlow?.permissions, host.ask(ask.id) != nil
        else { return false }
        let alive = tickets.contains { $0 === shown.ticket }
        let line: String
        if no || LivePermissionHost.voiceMayApprove(ask, cardFocused: true, keyHeld: true) {
            if await host.respond(ask.id, in: shown.ticket.session, allow: yes) {
                if alive { reattach(shown.ticket) } else { dismissQuietly() }
                return true
            }
            line = "That one didn't go through. Use the card."
        } else {
            line = LivePermissionHost.needsClickLine
        }
        // The card comes back, to be clicked.
        if alive {
            reattach(shown.ticket)
            showApproval(shown.ask, for: shown.ticket)
        } else {
            dismissQuietly()
        }
        overlay.showToast(line, at: pointer.location())
        if shouldSpeak(spoke: true) { _ = try? await voice.speak(line, continuing: false) }
        return true
    }

    /// The listen that began over the card was discarded: the card comes back.
    func restoreApproval() {
        guard let shown = answeringApproval else { return }
        answeringApproval = nil
        guard tickets.contains(where: { $0 === shown.ticket }), let host = pageFlow?.permissions,
              Self.waitingAsk(in: host, session: shown.ticket.session)?.id == shown.ask.id else { return }
        reattach(shown.ticket)
        showApproval(shown.ask, for: shown.ticket)
    }

    // MARK: - The card

    /// The approval card: what the turn wants to do in plain words, with Allow and Deny (or a short
    /// question's options), amber like every needs-your-OK card. Never a model action: the buttons
    /// answer the ask and nothing is sent to Claude as a prompt.
    nonisolated static func approvalCard(_ ask: GlanceAsk, keySymbol: String, lane: Lane, color: ConversationColor) -> Answer {
        let block: BuddyBlock
        switch ask {
        case .permission(let p):
            let who = p.asker.map { "\($0): " } ?? ""
            var rows = [detail(p)].compactMap { $0 }
            rows.append(p.tier == .reversible ? "Or press \(keySymbol) and say yes or no." : LivePermissionHost.needsClickLine)
            block = BuddyBlock(say: "\(who)\(p.title)?", shape: .card, cardHTML: rows.map { "<p>\($0)</p>" }.joined(),
                               actions: [.init(label: "Allow", prompt: ""), .init(label: "Deny", prompt: "")], needsApproval: true)
        case .question(let q):
            let actions = cardOptions(q).map { $0.map { BuddyBlock.Action(label: $0.label, prompt: "") } }
                ?? [.init(label: "Answer in Lumi", prompt: "")]
            let say = q.items.count == 1 ? q.items[0].question : "\(q.items.count) questions for you"
            block = BuddyBlock(say: q.asker.map { "\($0): \(say)" } ?? say, shape: .card, actions: actions, needsApproval: true)
        }
        return Answer(block: block, lane: lane, conversation: color, turn: 0, replyHint: "", keepsPlacement: false)
    }

    /// The options as buttons when the card can hold them: one single-choice question with at most
    /// two options (the card's third slot is its Cancel). Nil: answer it in Lumi.
    nonisolated static func cardOptions(_ ask: QuestionAsk) -> [QuestionAsk.Option]? {
        guard ask.items.count == 1, let item = ask.items.first, !item.multiSelect, (1...2).contains(item.options.count)
        else { return nil }
        return item.options
    }

    /// The line under the title, when it adds something: the exact command, or the tool's own words.
    nonisolated static func detail(_ ask: PermissionAsk) -> String? {
        let text: String
        switch ask.detail {
        case .command(let command): text = command
        case .plain(let plain) where plain != ask.title: text = plain
        case .plain, .diff, .url: return nil
        }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let clipped = line.count > 200 ? String(line.prefix(199)) + "…" : line
        let escaped = clipped.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if case .command = ask.detail { return "<code>\(escaped)</code>" }
        return escaped
    }

    /// "No", "deny", "don't" and close variants, with nothing else said.
    nonisolated static func isBareNegative(_ transcript: String) -> Bool {
        let words = transcript.lowercased().unicodeScalars
            .map { CharacterSet.letters.contains($0) || $0 == " " ? Character($0) : " " }
        return negatives.contains(String(words).split(separator: " ").joined(separator: " "))
    }

    nonisolated static let negatives: Set<String> = [
        "no", "nope", "nah", "no thanks", "no thank you", "deny", "deny it", "don t", "do not", "don t do it", "no don t",
        "no way", "reject", "reject it",
    ]
}
