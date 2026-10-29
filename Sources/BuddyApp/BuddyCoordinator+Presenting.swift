import BuddyBridge
import BuddyCompanion
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import CoreGraphics
import Foundation
import Synchronization

extension BuddyCoordinator {
    /// Drains a turn's stream. While the request is current the Glance follows it. A stale one (a
    /// new press, the switcher) keeps running in the background with sessions on: its answer is
    /// recorded and its session shows it ready (V-02). Otherwise the cascade was told to cancel it,
    /// and the stream is still drained so `.done`'s session ids reach the conversation.
    func run(
        _ stream: AsyncStream<TurnStreamEvent>, question: String, conversationID: String, spoke: Bool,
        typed: Bool = false, shownQuestion: String? = nil, startedAt: ContinuousClock.Instant? = nil,
        opening: String? = nil, epoch mine: Int
    ) {
        inFlightConversation = conversationID
        if isCurrent(mine) {
            setupChipVisible = false // the answer replaces any setup chip
            kept = nil // a new question: the answer to recall is its own
        }
        let start = startedAt ?? .now // typed questions, Go deeper and actions start here
        if isCurrent(mine) { trace(.questionSent) } // a stale request is cancelled at once
        // Its capsule at the top centre, shown once the pill or the page no longer shows it.
        let query = isCurrent(mine)
            ? progress.begin(session: SessionID(rawValue: conversationID), question: shownQuestion ?? question, line: opening,
                             epoch: mine)
            : nil
        let ticket = TurnTicket(epoch: mine, conversationID: conversationID, startedAt: start, anchor: lastAnchor,
                                packet: lastQuestion?.packet, spoke: spoke)
        ticket.capsule = query
        ticket.endOwed = isCurrent(mine) // its questionSent was traced just above
        tickets.append(ticket)
        noteFront()
        Task { [weak self] in
            var reply = ReplyTracker(question: question, conversationID: conversationID, startedAt: start, typed: typed)
            reply.shownQuestion = shownQuestion ?? question
            reply.opening = opening
            self?.statusShown(since: start, epoch: mine)
            var session = SessionTurn(kind: typed ? .typed : .voice)
            for await turnEvent in stream {
                guard let self else { return }
                // Behind, the capsule ends after the answer is handled: a queued one stays, as Ready.
                let endsBehind = ProgressBoard.ends(turnEvent) && !self.isCurrent(ticket.epoch)
                if let query, !endsBehind { self.progress.event(turnEvent, query: query) }
                ticket.follow(turnEvent)
                switch turnEvent {
                case .session(let e):
                    // An open session's turn: the page or the Glance (LumiFeatures.panel).
                    await self.apply(e, conversationID: conversationID, turn: &session, spoke: spoke, reply: &reply, ticket: ticket)
                case .cascade(let e):
                    await self.apply(e, spoke: spoke, reply: &reply, ticket: ticket)
                }
                if let query, endsBehind { self.progress.event(turnEvent, query: query) }
            }
            if let query { self?.progress.end(query) }
            guard let self else { return }
            self.ended(ticket, reply: reply)
            if self.isCurrent(ticket.epoch), !reply.finished {
                self.traceEnd(.error, ticket: ticket, lane: reply.lane, outcome: .failed)
                await self.showFailure(TurnFailureLine.stopped, lane: reply.lane ?? .quick, spoke: spoke, reply: reply, epoch: ticket.epoch)
            }
            // Ended any other way (its stream stopped behind a newer question): still one end.
            self.traceEnd(.error, ticket: ticket, lane: reply.lane, outcome: .failed)
        }
    }

    /// One cascade event of `ticket`'s turn: in front, the pill, card and voice; in the background
    /// (or while its approval card is up) only what its answer needs.
    func apply(_ event: CascadeEvent, spoke: Bool, reply: inout ReplyTracker, ticket: TurnTicket) async {
        if case .turn(_, .hostEvent(let e)) = event { hostSaw(e, ticket: ticket) }
        if case .done(let result) = event {
            await conversations.update(result.state)
            // The turn ended: its card (if the ask was never answered) gives way to the answer.
            if cardHolds(ticket) { shownApproval = nil }
        }
        if isCurrent(ticket.epoch), !cardHolds(ticket) {
            await apply(event, spoke: spoke, reply: &reply, epoch: ticket.epoch)
        } else {
            await applyInBackground(event, reply: &reply, ticket: ticket)
        }
    }

    func apply(_ event: CascadeEvent, spoke: Bool, reply: inout ReplyTracker, epoch mine: Int) async {
        if case .turn(.quick, _) = event, !reply.sawEvent {
            reply.sawEvent = true // Quick's first event; Deep-only starts trace deepStarted instead
            trace(.quickFirstEvent, since: reply.startedAt, lane: .quick)
        }
        if case .turn(.deep, _) = event, !reply.deepStarted {
            reply.deepStarted = true
            trace(.deepStarted, since: reply.handoffAt ?? reply.startedAt, lane: .deep)
        }
        switch event {
        case .turn(let mode, .status(let status)):
            // The pill is showing the headline being spoken; a later status in the same lane waits.
            if reply.headlineInPill, reply.lane == mode { return }
            // Quick's generic "Thinking" says less than the opening line already shown: keep it.
            // A real step (a tool) still replaces it.
            if mode == .quick, status == StatusMapper.thinking, reply.opening != nil, (reply.lane ?? .quick) == .quick {
                reply.lane = .quick
                return
            }
            if reply.lane != mode {
                reply.lane = mode
                overlay.showThinking(lane(for: mode), status: status)
            } else {
                overlay.updateStatus(status)
            }
            statusShown(since: reply.startedAt, epoch: mine)
        case .turn(let mode, .retrying(let retry)):
            // Claude Code is retrying the API call: say why, nothing estimated.
            if let status = TurnFailureLine.retrying(retry), !reply.headlineInPill {
                if reply.lane != mode {
                    reply.lane = mode
                    overlay.showThinking(lane(for: mode), status: status)
                } else {
                    overlay.updateStatus(status)
                }
                statusShown(since: reply.startedAt, epoch: mine)
            }
        case .turn(_, .permissionNotice(.denied(let tools))):
            reply.deniedTools += tools
        case .turn(let mode, .initialized(let info)):
            reply.pluginProblem = TurnFailureLine.pluginProblem(info.pluginErrors)
            onPermissionMode?(info.permissionMode) // every turn: the menu line clears when auto is back
            onMCPServers?(mode, info.mcpServers)
        case .turn(let mode, .reconnecting(let attempt)):
            trace(.processRestart, lane: mode, count: attempt) // the lane's Claude Code restarting
            overlay.updateStatus("Reconnecting…")
            statusShown(since: reply.startedAt, epoch: mine)
        case .turn(_, .sayFirstSentence(let sentence)):
            // Quick's headline streams before its card exists: put the words in the pill for every
            // question, typed too, and before the voice starts, so nothing is heard that isn't shown.
            if phase == .thinking {
                overlay.showHeadline(sentence)
                reply.headlineInPill = true
                stopQuietStatus() // the headline stays until the card
            }
            guard shouldSpeak(spoke: spoke) else { return }
            reply.spoken = sentence
            if await say(sentence, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine) { markSpoken(&reply) }
        case .turn(_, .say(let full)):
            // The whole headline has streamed before its card: all of it goes in the pill and the
            // rest is spoken now, so there's no silent gap while the card loads. It's on screen, so
            // nothing is heard that isn't shown; the card then shows it at once, without inking.
            guard phase == .thinking else { return }
            overlay.showHeadline(full)
            reply.headlineInPill = true
            stopQuietStatus()
            guard shouldSpeak(spoke: spoke), !reply.saidFull else { return }
            let rest = Self.remainder(of: full, after: reply.spoken)
            reply.spoken = full
            if !rest.isEmpty, await say(rest, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine) {
                markSpoken(&reply)
            }
        case .turn(_, .failed(let error)):
            reply.error = error
        case .handingOff(let line):
            reply.headlineInPill = false
            reply.handoffAt = .now
            trace(.handoff, since: reply.startedAt, lane: .quick)
            reply.lane = .deep
            // The pill shows the line the voice says, not a label of its own.
            overlay.showThinking(lane(for: .deep), status: line ?? "Handing to Deep")
            statusShown(since: reply.startedAt, epoch: mine)
            // Quick's turn may already have spoken some or all of this line.
            await sayUnspoken(line, spoke: spoke, reply: &reply, epoch: mine)
            reply.spoken = nil
            reply.saidFull = false
        case .researchRequested(let line):
            reply.researchRequested = true
            // The router's start carries no line; the spoken reply for research.
            await sayUnspoken(line ?? "On it. I'll let you know when it's done.", spoke: spoke, reply: &reply, epoch: mine)
        case .done(let result):
            reply.finished = true
            stopQuietStatus()
            await finish(result, spoke: spoke, reply: reply, epoch: mine)
            // After the answer, so it's read as a note on it, not as the answer.
            if isCurrent(mine), let line = Self.deniedLine(reply.deniedTools) {
                overlay.showToast(line, at: pointer.location())
            }
        case .turn:
            break
        }
    }

    /// The turn's answer: its block, or plain prose with no block unless the turn failed. Nil for
    /// none, and for a hand-off block, which is Quick's promise, not an answer.
    static func answerBlock(_ result: CascadeResult, error: BridgeError?) -> BuddyBlock? {
        let block = result.outcome.flatMap { $0.extraction.block ?? (error == nil ? proseBlock($0.extraction.prose) : nil) }
        return block?.handoff == nil ? block : nil
    }

    func finish(_ result: CascadeResult, spoke: Bool, reply: ReplyTracker, epoch mine: Int) async {
        let block = Self.answerBlock(result, error: reply.error)
        // Only the cascade's own request starts Research: the router heard the user say it, or an
        // allowed Quick hand-off asked. A block's `handoff` alone (Deep, an action, a "quick
        // answer" turn) never starts a background web job with model-written text as its topic.
        if reply.researchRequested {
            await startResearch(reply, packet: lastQuestion?.packet, spoke: spoke, epoch: mine)
            return
        }
        // A handoff block is Quick's promise, not an answer: if Deep failed, say that instead.
        guard let block else {
            let failedLane = reply.lane ?? .quick
            if reply.handoffAt != nil || reply.deepStarted {
                trace(.deepFinished, since: reply.handoffAt ?? reply.startedAt, lane: .deep, outcome: .failed)
            }
            if let error = reply.error {
                let model = (failedLane == .deep ? settings.deep : settings.quick).model
                if var line = TurnFailureLine.line(for: error, model: model) {
                    // A plugin that didn't load explains a turn that couldn't finish.
                    if line == TurnFailureLine.generic, let plugin = reply.pluginProblem { line = plugin }
                    traceEnd(.error, ticket: ticket(epoch: mine), lane: failedLane, outcome: .failed)
                    await showFailure(line, lane: failedLane, spoke: spoke, reply: reply, epoch: mine)
                } else {
                    traceEnd(.cancelled, ticket: ticket(epoch: mine), lane: failedLane, outcome: .cancelled)
                    dismissQuietly()
                }
            } else {
                traceEnd(.error, ticket: ticket(epoch: mine), lane: failedLane, outcome: .failed)
                await showFailure(TurnFailureLine.noAnswer, lane: failedLane, spoke: spoke, reply: reply, epoch: mine)
            }
            return
        }
        await present(block, mode: result.lane ?? reply.lane ?? .quick, contextTokens: result.outcome?.result.contextTokens,
                      spoke: spoke, reply: reply, epoch: mine, cascade: !result.inOpenSession)
    }

    /// Shows an answer's block in the Glance: records the turn, rings, speaks the rest. `cascade`: a
    /// Quick (or v1 Deep) answer, whose session finishes its turn here; an open session's finishes
    /// from its own events.
    func present(_ block: BuddyBlock, mode: Mode, contextTokens: Int?, spoke: Bool, reply: ReplyTracker, epoch mine: Int,
                 cascade: Bool = false) async {
        // Quick's context only: Deep starts with Claude Code's full prompt and tools, and is
        // expected to take its time.
        let isLong = mode == .quick && (contextTokens ?? 0) >= Self.longConversationTokens
        let shown = TranscriptTurn(question: reply.shownQuestion, block: block, mode: mode, model: lane(for: mode).model)
        let current = await conversations.record(shown, conversationID: reply.conversationID)
        if cascade {
            routing.cascadeTurnFinished(SessionID(rawValue: reply.conversationID), kind: reply.typed ? .typed : .voice,
                                        question: reply.shownQuestion, block: block)
        }
        // A newer question took the Glance meanwhile: the answer is saved, ready behind it.
        guard isCurrent(mine) else {
            let ticket = ticket(epoch: mine)
            traceEnd(.backgroundReady, ticket: ticket, since: reply.startedAt, lane: mode, outcome: .ok)
            if let ticket {
                queueReady(ReadyAnswer(block: block, turn: shown, conversation: current, mode: mode, reply: reply, ticket: ticket))
            }
            return
        }
        // With today's toggles: an action's turn doesn't replace `lastQuestion`.
        var packet = lastQuestion?.packet
        packet?.features = features
        await show(block, turn: shown, conversation: current, mode: mode, isLong: isLong, spoke: spoke, reply: reply,
                   epoch: mine, anchor: lastAnchor, packet: packet)
    }

    /// Puts a recorded answer on its surface (the Glance, a page, or nothing) and speaks it.
    /// `queued`: a ready answer's turn (`playReadyIfFree`), already in its page and traced as
    /// backgroundReady, so neither happens again.
    func show(_ block: BuddyBlock, turn shown: TranscriptTurn, conversation current: ConversationTurn?, mode: Mode,
              isLong: Bool, spoke: Bool, reply: ReplyTracker, epoch mine: Int, anchor: Anchor, packet: ContextPacket?,
              queued: Bool = false) async {
        lastAnswer = block
        shownFix = nil
        answerHeard = false
        lastMainAction = Self.mainAction(for: block, packet: packet)
        reportShowing = false
        answerOnScreen = false
        lastAnswerAt = clock()
        var answer = Answer(
            block: block,
            lane: lane(for: mode),
            conversation: current?.color ?? .ember,
            turn: current?.turn ?? 1,
            replyHint: replyHint,
            // Full screen shows the whole conversation: every earlier turn, oldest first.
            question: reply.shownQuestion,
            // By id, so a port that returns the turns with or without this one both work.
            earlier: (current?.turns ?? []).filter { $0.id != shown.id },
            isLong: isLong,
            mainAction: lastMainAction)
        answer.reviewSteps = reply.steps.shown
        kept = (answer, block, lastMainAction, reply.conversationID, anchor)
        keptOnScreen = true
        let kind: TurnKind = reply.typed ? .typed : .voice
        switch delivery.surface(for: answer, conversationID: reply.conversationID, kind: kind) {
        case .glance:
            overlay.showAnswer(answer, anchor: anchor)
        case .page:
            // The page shows the conversation: the answer lands there, no card.
            keptOnScreen = false
            if !queued {
                pageFlow?.showAnswer(block, question: reply.shownQuestion, session: SessionID(rawValue: reply.conversationID), kind: kind)
            }
            stopQuietStatus()
            dismissQuietly()
            phase = .idle
            if !queued { traceEnd(.answerShown, ticket: ticket(epoch: mine), since: reply.startedAt, lane: mode, outcome: .ok) }
            if kind == .voice, shouldSpeak(spoke: spoke), !reply.saidFull {
                let rest = Self.remainder(of: block.say, after: reply.spoken)
                if !rest.isEmpty { await say(rest, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine) }
            }
            return
        case .ambient:
            keptOnScreen = false
            stopQuietStatus()
            dismissQuietly()
            phase = .idle
            if !queued { traceEnd(.answerShown, ticket: ticket(epoch: mine), since: reply.startedAt, lane: mode, outcome: .ok) }
            return
        }
        phase = .showing
        typedCardShowing = reply.typed
        if isLong, longHinted.insert(reply.conversationID).inserted {
            let fresh = BuddyKey.allCases.first { $0.symbol == settings.keySymbol }?.freshSymbol ?? "⇧"
            overlay.showToast("Long session · \(fresh) + \(settings.keySymbol) starts fresh", at: pointer.location())
        }
        if !queued {
            traceEnd(.answerShown, ticket: ticket(epoch: mine), since: reply.startedAt, lane: mode, outcome: .ok)
            if mode == .deep { trace(.deepFinished, since: reply.handoffAt ?? reply.startedAt, lane: .deep, outcome: .ok) }
        }
        ring(block.points, epoch: mine)
        onAnswerShown?()
        // One card at a time (65-SURFACE-RULES, rule A): a ready answer may replace this one only
        // once it's had its reading time with the pointer off it, and the voice is quiet. Spoken
        // or not, so a short spoken card isn't swapped the moment its last word ends.
        glanceTakesItsTurn(block, epoch: mine)
        if shouldSpeak(spoke: spoke), !reply.saidFull {
            // The card presents asynchronously; the voice waits for it (at most `presentWait`).
            await waitForAnswerOnScreen()
            guard isCurrent(mine) else { return }
            let rest = Self.remainder(of: block.say, after: reply.spoken)
            // The only speech may be here (no streamed headline): still the first spoken word.
            if !rest.isEmpty, await say(rest, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine),
               !queued, !reply.speaking {
                trace(.firstSpokenWord, since: reply.startedAt)
            }
        }
    }

    /// A new Glance (answer, chip, recall) holds it until its own reading time: a ready answer
    /// never replaces it on the previous card's turn.
    func glanceTakesItsTurn(_ block: BuddyBlock, epoch mine: Int? = nil) {
        answerHeard = false
        giveReadingTime(block, epoch: mine ?? epoch)
    }

    /// A card has had its turn once it's been up for its reading time and the pointer isn't on it;
    /// then, once the voice is quiet, the next ready answer may replace it (it stays in its session).
    func giveReadingTime(_ block: BuddyBlock, epoch mine: Int) {
        readingTimer?.cancel()
        let (wait, sleep) = (Self.readingTime(block), sleep)
        readingTimer = Task { [weak self] in
            try? await sleep(wait)
            while let self, !Task.isCancelled, self.isCurrent(mine), self.phase == .showing {
                if !self.overlay.pointerOnAnswer {
                    self.answerHeard = true
                    return self.playNextReady()
                }
                try? await sleep(.seconds(1))
            }
        }
    }

    /// About 8 s, plus 1 s per 25 words of the headline and card, at most 30 s.
    nonisolated static func readingTime(_ block: BuddyBlock) -> Duration {
        let text = block.say + " " + (block.cardHTML ?? "").replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let words = text.split(whereSeparator: \.isWhitespace).count
        return .seconds(min(30, 8 + words / 25))
    }

    func waitForAnswerOnScreen() async {
        guard !answerOnScreen else { return }
        await withCheckedContinuation { continuation in
            presentWaiters.append(continuation)
            presentCap?.cancel()
            let sleep = sleep
            presentCap = Task { [weak self] in
                try? await sleep(Self.presentWait)
                guard !Task.isCancelled else { return }
                self?.releasePresentWaiters()
            }
        }
    }

    func releasePresentWaiters() {
        presentCap?.cancel() // a stale cap must not release a later wait early
        presentCap = nil
        let waiters = presentWaiters
        presentWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Speaks only while the request is current, so a stale turn never talks over a new one.
    /// `continuing`: a later piece of this turn's reply, queued after what's playing instead of
    /// cutting it ("Let me check." then " One moment."). Returns whether it started or queued.
    /// `since`: the speech generation this turn's reply began in; after "stop speaking" (or a
    /// lock) the rest of the turn stays silent instead of starting a fresh reply.
    @discardableResult
    func say(_ text: String, continuing: Bool = false, since: Int? = nil, epoch mine: Int) async -> Bool {
        guard isCurrent(mine), since.map({ $0 == speechGeneration }) ?? true else { return false }
        let generation = speechGeneration
        speechStarting += 1 // a ready answer waits while this starts
        let started = (try? await voice.speak(text, continuing: continuing)) == true
        speechStarting -= 1
        guard started else {
            playNextReady()
            return false
        }
        // Playback started after the request went stale (key press, Esc) or speech was stopped.
        guard isCurrent(mine), generation == speechGeneration else {
            await voice.stopSpeaking()
            return false
        }
        overlay.setSpeaking(true)
        speaking = true
        return true
    }

    /// Speaks whatever part of `line` Quick's own turn hasn't already spoken.
    func sayUnspoken(_ line: String?, spoke: Bool, reply: inout ReplyTracker, epoch mine: Int) async {
        guard let line, shouldSpeak(spoke: spoke), !reply.saidFull else { return }
        let rest = Self.remainder(of: line, after: reply.spoken)
        if !rest.isEmpty, await say(rest, continuing: reply.speaking, since: reply.speechGeneration, epoch: mine) { markSpoken(&reply) }
    }

    /// Something new is in the pill: the quiet count starts again from now.
    func statusShown(since start: ContinuousClock.Instant, epoch mine: Int) {
        quietStatus?.cancel()
        let (after, tick) = (quietAfter, quietTick)
        quietStatus = Task { [weak self] in
            try? await Task.sleep(for: after)
            while !Task.isCancelled {
                guard let self, self.isCurrent(mine), self.phase == .thinking else { return }
                let seconds = Int((ContinuousClock.now - start) / .seconds(1))
                self.overlay.updateStatus("\(StatusMapper.thinking) · \(seconds) s")
                try? await Task.sleep(for: tick)
            }
        }
    }

    func stopQuietStatus() {
        quietStatus?.cancel()
        quietStatus = nil
    }

    /// What the pill says while the question goes out, from what was actually captured.
    static func openingStatus(_ packet: ContextPacket) -> String? {
        guard let app = packet.app?.name, !app.isEmpty else { return nil }
        if let selection = packet.selection, selection.length > 0 { return "Reading your selection in \(app)" }
        return "Looking at \(app)"
    }

    /// A turn that ended in plain prose, with no block (a clarifying question, "A or B?"): its first
    /// sentence is the headline and the rest plain card text. Nil when there's nothing to show, or
    /// a fence is left (a block that didn't decode) that would show as raw JSON.
    static func proseBlock(_ prose: String) -> BuddyBlock? {
        let text = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("```") else { return nil }
        let say = BuddyBlock.firstSentence(of: text)
        // Past the headline's words in the original text, so the rest keeps its line breaks.
        var words = say.split(whereSeparator: \.isWhitespace).count
        var index = text.startIndex
        while words > 0, index < text.endIndex {
            index = text[index...].firstIndex { !$0.isWhitespace } ?? text.endIndex
            index = text[index...].firstIndex { $0.isWhitespace } ?? text.endIndex
            words -= 1
        }
        let rest = text[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return BuddyBlock(say: say, shape: .chip) }
        let escaped = rest.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
        return BuddyBlock(say: say, shape: .card, cardHTML: paragraphs.joined())
    }

    func shouldSpeak(spoke: Bool) -> Bool {
        switch settings.voiceReplies {
        case .always: true
        case .onlyWhenSpoken: spoke
        case .off: false
        }
    }

    // MARK: - Open-session turns

    /// What a session turn's stream has shown so far.
    struct SessionTurn {
        var kind: TurnKind
        /// The page took the turn: everything after goes there.
        var paged = false
    }

    /// One event of an open session's turn. Typed, voice-in-page, steer and relay turns render in
    /// the page (never through `proseBlock`, D8 fix 1); voice turns get voice plus Glance, as
    /// cascade turns do. A page turn keeps streaming even after a newer ask took the overlay.
    func apply(_ event: SessionEvent, conversationID: String, turn: inout SessionTurn, spoke: Bool,
               reply: inout ReplyTracker, ticket: TurnTicket) async {
        let session = SessionID(rawValue: conversationID)
        let mine = ticket.epoch
        if case .turnStarted(_, let kind) = event, kind != .steer { turn.kind = kind }
        if let pageFlow, turn.paged || Self.rendersInPage(turn.kind) {
            if !turn.paged {
                turn.paged = true
                let packet = lastQuestion?.packet
                pageFlow.begin(pageFlow.snapshot(for: session) ?? Self.snapshot(session, question: reply.shownQuestion, packet: packet, now: Date()),
                               question: reply.shownQuestion, kind: turn.kind,
                               context: ContextStrip.from(packet, withScreen: packet?.screenshot != nil || packet?.app != nil),
                               dock: packet.flatMap(Self.dock))
                if isCurrent(mine), phase == .thinking {
                    // The page shows the Trail now; the pill goes.
                    stopQuietStatus()
                    dismissQuietly()
                    phase = .idle
                }
            }
            pageFlow.receive(event, session: session, kind: turn.kind)
            record(reply.marks.marks(for: event, inPage: true, speaks: pageFlow.speaksInPage(turn.kind)), since: reply.startedAt,
                   ticket: ticket)
            switch event {
            case .turnEnded, .processEnded: reply.finished = true
            default: break
            }
            return
        }
        pageFlow?.render(event, session: session)
        // The Glance marks the spoken word and the answer itself (`markSpoken`, `present`).
        record(reply.marks.marks(for: event, inPage: false, speaks: false), since: reply.startedAt, ticket: ticket)
        reply.steps.apply(event)
        guard isCurrent(mine) else {
            // In the background: its answer goes into the conversation; the pool's events mark the
            // session ready (or needing the user), with its capsule and tile.
            if case .turnEnded(let end) = event {
                reply.finished = true
                if let block = end.block ?? (end.isError ? nil : Self.proseBlock(end.markdown)) {
                    traceEnd(.backgroundReady, ticket: ticket, since: reply.startedAt, lane: .deep, outcome: .ok)
                    await recordInBackground(block, mode: .deep, reply: reply, ticket: ticket, cascade: false)
                } else {
                    traceEnd(.error, ticket: ticket, lane: .deep, outcome: .failed)
                }
            }
            return
        }
        switch event {
        case .permissionRequested, .questionAsked, .permissionResolved:
            // V-03: the Glance becomes the approval card, and back to the pill once answered.
            showOrResolve(event, ticket: ticket)
            return
        case .turnEnded:
            if cardHolds(ticket) { shownApproval = nil }
        default:
            // The card stays until the ask is answered; the turn's lines wait meanwhile.
            if cardHolds(ticket) { return }
        }
        switch event {
        case .step(let step) where step.subagent == nil:
            // The Glance pill shows the Trail's live verb.
            await apply(.turn(lane: .deep, .status(TrailCopy.presentLine(step))), spoke: spoke, reply: &reply, epoch: mine)
        case .sayFirstSentence(let sentence):
            await apply(.turn(lane: .deep, .sayFirstSentence(sentence)), spoke: spoke, reply: &reply, epoch: mine)
        case .say(let full):
            await apply(.turn(lane: .deep, .say(full)), spoke: spoke, reply: &reply, epoch: mine)
        case .turnEnded(let end):
            reply.finished = true
            stopQuietStatus()
            reply.deniedTools += end.deniedTools
            if let block = end.block ?? (end.isError ? nil : Self.proseBlock(end.markdown)) {
                await present(block, mode: .deep, contextTokens: end.contextTokens, spoke: spoke, reply: reply, epoch: mine)
            } else {
                traceEnd(.error, ticket: ticket, lane: .deep, outcome: .failed)
                // The cascade's lines for what the session reported (signed out, a limit, offline).
                let line = end.isError
                    ? TurnFailureLine.line(for: SessionTurnEvents.error(for: end), model: nil) ?? TurnFailureLine.generic
                    : TurnFailureLine.noAnswer
                await showFailure(line, lane: .deep, spoke: spoke, reply: reply, epoch: mine)
            }
            if isCurrent(mine), let line = Self.deniedLine(reply.deniedTools) { overlay.showToast(line, at: pointer.location()) }
        default:
            break
        }
    }

    /// A page turn's answerShown is its end (`traceEnd`); the other marks just trace.
    func record(_ marks: [TurnMarks.Mark], since start: ContinuousClock.Instant, ticket: TurnTicket) {
        for mark in marks {
            if mark.event == .answerShown {
                traceEnd(.answerShown, ticket: ticket, since: start, lane: .deep, outcome: mark.outcome ?? .ok)
            } else {
                trace(mark.event, since: start, lane: .deep, outcome: mark.outcome)
            }
        }
    }

    /// Typed, voice-in-page, steer and relay turns are read in the page.
    nonisolated static func rendersInPage(_ kind: TurnKind) -> Bool {
        switch kind {
        case .typed, .voiceInPage, .steer, .relay: true
        case .voice, .action: false
        }
    }

    /// A first snapshot for a session the store hasn't published yet.
    nonisolated static func snapshot(_ id: SessionID, question: String, packet: ContextPacket?, now: Date) -> SessionSnapshot {
        let words = question.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        return SessionSnapshot(id: id, title: words.isEmpty ? "New session" : words, color: .ember,
                               origin: packet.flatMap(SessionOrigin.from), harness: .open,
                               status: .thinking(since: now, progress: nil), lastUsed: now)
    }

    /// The Panel docks beside the window the question was asked over. The packet's bounds are
    /// top-left global coordinates; the Panel wants AppKit's bottom-left ones.
    nonisolated static func dock(_ packet: ContextPacket) -> PanelDock? {
        guard let b = packet.window?.bounds else { return nil }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let window = CGRect(x: b.x, y: primaryHeight - b.y - b.height, width: b.width, height: b.height)
        return PanelDock(originWindow: window, anchor: nil)
    }
}
