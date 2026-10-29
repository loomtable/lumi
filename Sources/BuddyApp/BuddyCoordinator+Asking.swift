import BuddyBridge
import BuddyCompanion
import BuddyContext
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import CoreGraphics
import Foundation
import Synchronization

extension BuddyCoordinator {
    // MARK: - Asking

    func send() async {
        let mine = epoch
        let gesture = ContinuousClock.now // the send gesture: every turn latency starts here
        summonSound?.cancel()
        phase = .thinking
        // Nothing of this ask is sent yet: Esc while it transcribes cancels no earlier turn (that
        // one may be another session's, still running in its page).
        inFlightConversation = nil
        overlay.showThinking(lane(for: .quick), status: nil)
        await setKeyListening(false)

        let transcript: String
        awaitingTranscript = mine
        transcribingShown = false
        do {
            transcript = try await voice.finishListening()
            if awaitingTranscript == mine { awaitingTranscript = nil }
        } catch {
            if awaitingTranscript == mine { awaitingTranscript = nil }
            guard isCurrent(mine) else { return }
            showChip(Self.voiceMessage(error, fallback: "I couldn't hear that."))
            return
        }
        guard isCurrent(mine) else { return }
        if transcribingShown {   // the transcript is in: the pill no longer says it's transcribing
            transcribingShown = false
            overlay.updateStatus(nil)
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trace(.transcriptFinal, since: gesture, outcome: .skipped) // nothing was said
            await discardListening()
            return
        }
        trace(.transcriptFinal, since: gesture, outcome: .ok)
        // A yes or no said over the Glance's approval card answers it, and its turn comes back.
        if await answersApprovalByVoice(transcript) {
            nextRouteSource = nil
            capture?.cancel()
            return
        }
        // A bare "yes" while the page on screen waits on an approval answers it, not a turn.
        if await approvesByVoice(transcript) {
            nextRouteSource = nil // a switcher pick made during this listen doesn't carry over
            capture?.cancel()
            dismissQuietly()
            phase = .idle
            return
        }
        await ask(transcript: transcript, epoch: mine, startedAt: gesture)
    }

    /// Builds the question from the captured context and sends it to the cascade.
    /// `startedAt`: the send gesture, for trace timings (typed questions start at the request).
    func ask(
        transcript: String, epoch mine: Int, spoke: Bool = true, typed: Bool = false,
        startedAt: ContinuousClock.Instant? = nil
    ) async {
        var transcript = transcript
        switch ConversationCommand.parse(transcript) {
        case .some(.newTopic(let rest)) where !rest.isEmpty:
            listenFresh = true
            transcript = rest
        case .some(let command):
            await runConversationCommand(command)
            return
        case nil:
            break
        }
        guard let captured = await capture?.value else {
            if isCurrent(mine) {
                lastSent = .capture(transcript: transcript, typed: typed)
                await showFailure(TurnFailureLine.screenUnreadable, lane: .quick, spoke: spoke, epoch: mine)
            }
            return
        }
        guard isCurrent(mine) else { return }
        // From here this question owns the turn state (target app, anchor, question), even if it's
        // cancelled before it's sent: the kept answer no longer matches it.
        kept = nil

        var packet: ContextPacket
        let shot = captured.shot
        switch captured.context.result {
        case .blocked(let app):
            ringSource = nil
            targetPID = nil
            capture = nil
            showChip("I don't look at \(app).")
            return
        case .packet(let p, _):
            packet = p
            ringSource = captured.context.pid.map { RingSource(pid: $0, shot: shot, epoch: mine) }
            targetPID = captured.context.pid
        case .noFrontApp:
            targetPID = nil
            packet = ContextPacket(askedAt: Date(), utterance: transcript)
            ringSource = nil // no app to look in; never the previous turn's
        }
        capture = nil // consumed; don't keep the screenshot alive in the task
        // The first seconds say what was actually captured, not a generic "Thinking".
        let opening = Self.openingStatus(packet)
        if let opening, phase == .thinking { overlay.updateStatus(opening) }
        if listenFresh {
            listenFresh = false
            await startNewConversation(epoch: mine)
        }
        let source = takeRouteSource()
        let routed = await routing.route(RouteRequest(packet: packet, kind: typed ? .typed : .voice, visiblePage: pages.visiblePage,
                                                      source: source, busy: busySessions))
        // Where the turn went, for the live trace: Quick (the cascade) or the session's open Claude
        // session (V-17). No words, no ids.
        trace(.routeDecided, lane: routed.launch == nil ? .quick : .deep)
        if isCurrent(mine) { showPillTarget(routed.sessionID) }
        let conversation = routed.conversation
        guard isCurrent(mine) else {
            if ringSource?.epoch == mine { ringSource = nil } // don't keep a stale capture alive
            return
        }
        packet.utterance = transcript
        packet.screenshot = shot?.path
        packet.screenshotUnavailable = captured.unavailable
        packet.screenshotDetail = shot?.detail.map { .init(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height) }
        packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        if let path = shot?.path {
            // Linked so Forget deletes it; off the question's path.
            let conversations = conversations, id = conversation.state.id
            Task { await conversations.recordScreenshot(path, conversationID: id) }
        }
        lastAnchor = anchor(for: packet)

        var question = Question(
            packet: packet,
            screenshot: shot.map { TurnInput.Image(data: $0.data, mediaType: $0.mediaType) },
            detail: shot?.detail.map { TurnInput.Image(data: $0.data, mediaType: "image/jpeg") },
            routing: settings.routing,
            screenToken: screenToken(captured, conversation: conversation.state.id))
        question.packet.features = features
        lastQuestion = question
        lastSent = .ask(question, shown: nil, typed: typed)
        // An open session's turn goes to the session engine; Quick and v1 turns to the cascade.
        let target: TurnRequest.Target = routed.launch.map { .session(routed.sessionID, $0) } ?? .cascade
        let stream = await turns.send(TurnRequest(question: question, state: conversation.state, kind: routed.kind, target: target,
                                                  seed: routed.seed))
        if cancelsAfterSend(mine) { await turns.cancel(conversation: conversation.state.id) }
        run(stream, question: transcript, conversationID: conversation.state.id, spoke: spoke, typed: typed,
            startedAt: startedAt, opening: opening, epoch: mine)
    }
}
