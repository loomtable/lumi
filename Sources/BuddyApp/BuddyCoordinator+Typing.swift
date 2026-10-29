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
    // MARK: - Typing

    /// Double-tap: the audio since the first press is discarded and the text box opens where the
    /// pill was. The summon's capture keeps running, and the typed question uses it.
    func openTextBox() async {
        _ = nextEpoch() // a mic still starting is discarded when it finishes
        summonSound?.cancel()
        discardNeedsConfirmation = false
        setupChipVisible = false // setup progress must not rewrite what's shown from here on
        phase = .typing
        overlay.showTextBox(at: summonPoint)
        _ = await voice.discard(confirmed: true, playSound: false)
    }

    func closeTextBox() {
        _ = nextEpoch()
        capture?.cancel()
        dismissQuietly()
    }

    /// ↵ in the text box asks like a transcript; ↵ in a card's reply field is a follow-up.
    /// Typed questions are never answered aloud unless Voice replies is Always, and the answer
    /// card takes focus so the user can keep typing (Follow-up typing).
    func submit(_ text: String, source: SubmitSource) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch (source, phase) {
        case (.textBox, .typing):
            let mine = epoch
            phase = .thinking
            inFlightConversation = nil // nothing of this ask is sent yet
            overlay.showThinking(lane(for: .quick), status: nil)
            await ask(transcript: text, epoch: mine, spoke: false, typed: true)
        case (.reply, .showing) where !reportShowing:
            noteReply(byKey: false)
            await followUp(text)
        default:
            break
        }
    }

    /// The card has focus, so there's no front app to read: the follow-up reuses the last
    /// question's packet and screenshot with the new words, in the same conversation.
    func followUp(_ text: String) async {
        guard var question = lastQuestion, let card = kept?.conversationID ?? conversations.current?.state.id else { return }
        question.packet.utterance = text
        question.packet.features = features
        question.routing = settings.routing
        kept = nil // the follow-up owns the last question now, even if it's cancelled
        let mine = nextEpoch()
        phase = .thinking
        inFlightConversation = nil // nothing of this reply is sent yet
        overlay.setSpeaking(false)
        overlay.showThinking(lane(for: .quick), status: nil)
        await voice.stopSpeaking() // the last answer may still be reading out
        guard isCurrent(mine) else { return }
        // Routed like any typed turn, to the card's session (V-13): an open session continues there
        // (in the Panel), a Quick one on Quick.
        let routed = await routing.route(RouteRequest(packet: question.packet, kind: .typed, visiblePage: pages.visiblePage,
                                                      source: .composer(SessionID(rawValue: card))))
        guard isCurrent(mine) else { return }
        showPillTarget(routed.sessionID)
        let conversation = routed.conversation
        question.packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        lastQuestion = question
        lastSent = .ask(question, shown: nil, typed: true)
        let target: TurnRequest.Target = routed.launch.map { .session(routed.sessionID, $0) } ?? .cascade
        let stream = await turns.send(TurnRequest(question: question, state: conversation.state, kind: routed.kind, target: target,
                                                  seed: routed.seed))
        if cancelsAfterSend(mine) { await turns.cancel(conversation: conversation.state.id) }
        run(stream, question: text, conversationID: conversation.state.id, spoke: false, typed: true, epoch: mine)
    }

    // MARK: - Page composer

    /// A send from a page's composer as a turn for `session`, with the store's open launch (a
    /// continued Quick or v1 session gets its recap as the seed). With the ▣ chip on, the front
    /// window is read again for this send; off, nothing is read.
    /// Nil without a launch.
    func pageRequest(_ session: SessionID, _ submit: PageSubmit, plan: SessionTurnPlan) async -> TurnRequest? {
        guard let launch = plan.launch else { return nil }
        var question: Question
        if submit.withScreen, let fresh = await freshQuestion(submit.text, conversation: session.rawValue) {
            question = fresh
        } else {
            question = Question(packet: ContextPacket(askedAt: Date(), utterance: submit.text))
        }
        question.packet.features = features
        question.routing = settings.routing
        let state = conversations.current.map(\.state).flatMap { $0.id == session.rawValue ? $0 : nil }
            ?? ConversationState(id: session.rawValue)
        let attachments = submit.attachments.map { TurnAttachment(url: $0.url, isImage: $0.kind != .file) }
        return TurnRequest(question: question, state: state, kind: submit.kind, target: .session(session, launch), seed: plan.seed,
                           attachments: attachments)
    }

    /// Reads the front app and its screenshot now, for one composer send. Nil when the app is
    /// blocked or nothing is in front: the send goes as text only.
    func freshQuestion(_ text: String, conversation: String) async -> Question? {
        let captured = await startCapture().value
        guard case .packet(var packet, _) = captured.context.result else { return nil }
        let shot = captured.shot
        packet.utterance = text
        packet.screenshot = shot?.path
        packet.screenshotUnavailable = captured.unavailable
        packet.screenshotDetail = shot?.detail.map { .init(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height) }
        if let path = shot?.path {
            let conversations = conversations
            Task { await conversations.recordScreenshot(path, conversationID: conversation) }
        }
        return Question(
            packet: packet,
            screenshot: shot.map { TurnInput.Image(data: $0.data, mediaType: $0.mediaType) },
            detail: shot?.detail.map { TurnInput.Image(data: $0.data, mediaType: "image/jpeg") },
            routing: settings.routing,
            screenToken: screenToken(captured, conversation: conversation))
    }

    // MARK: - Page mic and speech

    /// The composer's ◉: down starts listening as the talk key does; up sends it. The turn goes
    /// into that composer's session as voice-in-page, even when another page is key (a Panel's
    /// mic while the Studio window shows another session).
    func pageMic(down: Bool, session: SessionID) async {
        if down {
            await handle(.gesture(.pressBegan(fresh: false)))
            await handle(.gesture(.holdBegan))
            if case .listening = phase { nextRouteSource = .composer(session) }
        } else {
            await handle(.gesture(.holdEnded))
        }
    }

    /// An in-page answer's line, with "Speak answers" on. Once Esc or "stop speaking" stops it,
    /// the rest of that answer stays silent (V-16); the next answer speaks again.
    func speakInPage(_ text: String, continuing: Bool) {
        if !continuing { pageSpeechGeneration = speechGeneration }
        guard pageSpeechGeneration == speechGeneration else { return }
        speechStarting += 1
        Task { [weak self, voice] in
            let started = (try? await voice.speak(text, continuing: continuing)) == true
            guard let self else { return }
            self.speechStarting -= 1
            if started { self.speaking = true } else { self.playNextReady() }
        }
    }

    // MARK: - Voice approval

    /// A talk-key transcript that's only a yes, while the page on screen waits on an approval:
    /// a reversible ask is allowed by voice; a needs-click one (sends, deletes, anything leaving
    /// the Mac, or `default_to_no`) is not, and Lumi says so. True when the transcript was used
    /// that way, so it isn't sent as a turn.
    func approvesByVoice(_ transcript: String) async -> Bool {
        guard Self.isBareAffirmative(transcript), let pageFlow, let page = pageFlow.visiblePage,
              let ask = pageFlow.permissions.pending(in: page.id).last?.ask else { return false }
        let line: String
        if ask.tier == .reversible {
            // The key is held (this is its transcript) and the card is pinned in the visible page.
            if await pageFlow.permissions.approveByVoice(in: page.id, cardFocused: true, keyHeld: true) != nil { return true }
            line = "That one didn't go through. Use the card."
        } else {
            line = LivePermissionHost.needsClickLine
        }
        overlay.showToast(line, at: pointer.location())
        if shouldSpeak(spoke: true) { _ = try? await voice.speak(line, continuing: false) }
        return true
    }

    /// "Yes", "go ahead", "allow it", "do it" and close variants, with nothing else said.
    nonisolated static func isBareAffirmative(_ transcript: String) -> Bool {
        let words = transcript.lowercased().unicodeScalars
            .map { CharacterSet.letters.contains($0) || $0 == " " ? Character($0) : " " }
        let phrase = String(words).split(separator: " ").joined(separator: " ")
        return affirmatives.contains(phrase)
    }

    nonisolated static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yes please", "go ahead", "go for it", "allow", "allow it", "do it", "ok", "okay",
        "sure", "approve", "approve it", "yes go ahead", "ok go ahead", "okay go ahead",
    ]
}
