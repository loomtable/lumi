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
    func goDeeper() async {
        guard var question = lastQuestion, let conversation = conversations.current else { return }
        question.packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        let mine = nextEpoch()
        phase = .thinking
        overlay.showThinking(lane(for: .deep), status: nil)
        lastSent = .deeper(question)
        let stream = await turns.send(TurnRequest(question: question, state: conversation.state, kind: .action, target: .deeper))
        if cancelsAfterSend(mine) { await turns.cancel(conversation: conversation.state.id) }
        run(stream, question: question.packet.utterance, conversationID: conversation.state.id, spoke: false, epoch: mine)
    }

    /// A model action sends its prompt to Deep; inserting is the main button's job.
    func runAction(_ index: Int) async {
        if index == 0, phase == .showing, let fix = shownFix {
            shownFix = nil
            // The failure line may still be reading out.
            overlay.setSpeaking(false)
            await voice.stopSpeaking()
            switch fix {
            case .openSettings(let pane): onOpenSettingsPane?(pane)
            case .repairPlugin: onRepairPlugin?()
            case .grantPermission(let kind): onGrantPermission?(kind)
            case .openDictationHistory: onOpenDictationHistory?()
            case .useModel(let model):
                await useModel(model, lane: shownFixLane, spoke: shownFixSpoke)
                return
            case .retry:
                await retry(lane: shownFixLane, spoke: shownFixSpoke)
                return
            }
            dismissQuietly()
            return
        }
        // Only a button the user could see: a chip shows one, so keys 2–3 can't press a hidden one.
        guard let block = lastAnswer, index < Self.visibleActions(block, mainAction: lastMainAction),
              block.actions.indices.contains(index)
        else { return }
        // A settings link opens that System Settings pane directly: no model turn, no shell.
        if let url = SettingsLink.url(for: block.actions[index].prompt) {
            // The user is off to System Settings: the reply stops, like Esc, and the card closes.
            _ = nextEpoch()
            Task { await voice.stopSpeaking() }
            overlay.setSpeaking(false)
            openURL?.open(url)
            dismissQuietly()
            return
        }
        guard var question = lastQuestion, let conversation = conversations.current else { return }
        let prompt = block.actions[index].prompt
        question.packet.utterance = prompt
        question.packet.features = features
        question.packet.conversation = .init(
            id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        question.routing = .alwaysDeep
        // The user pressed it: the engine, never the model, marks the request as approved.
        question.isApprovedAction = true
        lastSent = .ask(question, shown: block.actions[index].label, typed: false)
        let mine = nextEpoch()
        phase = .thinking
        overlay.showThinking(lane(for: .deep), status: nil)
        let stream = await turns.send(TurnRequest(question: question, state: conversation.state, kind: .action, target: .cascade))
        if cancelsAfterSend(mine) { await turns.cancel(conversation: conversation.state.id) }
        // The transcript shows the button the user pressed, not the model-written prompt behind it.
        run(stream, question: prompt, conversationID: conversation.state.id, spoke: false,
            shownQuestion: block.actions[index].label, epoch: mine)
    }

    // MARK: - Rings

    /// Rings the points that can be found (the overlay decides how long). Located off
    /// the answer path, so the card and speech never wait on AX or OCR; points that can't be found
    /// are skipped.
    func ring(_ points: [BuddyBlock.Point], epoch mine: Int) {
        guard settings.rings, let locator, let source = ringSource, !points.isEmpty else { return }
        let shot = source.epoch == mine ? source.shot : nil
        var quotes: [String] = []
        for point in points where !quotes.contains(point.quote) { quotes.append(point.quote) }
        Task { [weak self, quotes] in
            guard self?.isCurrent(mine) == true else { return }
            let found = await locator.locate(quotes, pid: source.pid, shot: shot)
            guard let self, self.isCurrent(mine), self.phase == .showing else { return }
            let rects = Dictionary(found.map { ($0.quote, $0.rect) }, uniquingKeysWith: { first, _ in first })
            let rings = points.compactMap { point in rects[point.quote].map { Ring(rect: $0, label: point.label) } }
            self.trace(.rings, outcome: rings.isEmpty ? .skipped : .ok, count: rings.count)
            if !rings.isEmpty { self.overlay.showRings(rings) }
        }
    }

    /// "Use Sonnet 5.5": the lane switches for good (the toast says so), then the failed
    /// question is asked again there.
    /// `spoke`: the original question's flag (the same question, so its answer is read out alike).
    func useModel(_ model: ModelID, lane mode: Mode, spoke: Bool) async {
        guard let onUseModel, canResend else { return dismissQuietly() }
        let mine = nextEpoch()
        phase = .thinking
        overlay.showThinking(lane(for: mode), status: "Switching to \(model.displayName)…")
        await onUseModel(model, mode)
        guard isCurrent(mine) else { return }
        overlay.showToast(TurnFailureLine.modelSwitched(mode: mode, model: model), at: pointer.location())
        await resend(lane: mode, spoke: spoke, epoch: mine)
    }

    /// "Try again": what failed is sent again, as it was sent.
    func retry(lane mode: Mode, spoke: Bool) async {
        guard canResend else { return dismissQuietly() }
        let mine = nextEpoch()
        phase = .thinking
        await resend(lane: mode, spoke: spoke, epoch: mine)
    }

    /// Whether `resend` has something to send and somewhere to send it: a capture asks afresh
    /// (finding its conversation then); anything else needs the current one (gone after Forget or
    /// a temporary-mode switch).
    var canResend: Bool {
        switch lastSent {
        case .capture: true
        case .ask, .deeper: conversations.current != nil
        case nil: false
        }
    }

    /// Sends `lastSent` again as the current conversation's next turn. `mode`: the lane that
    /// failed; a Deep failure is asked of Deep again.
    func resend(lane mode: Mode, spoke: Bool, epoch mine: Int) async {
        guard let sent = lastSent else { return dismissQuietly() }
        overlay.showThinking(lane(for: mode), status: nil)
        if case .capture(let transcript, let typed) = sent {
            capture?.cancel()
            capture = startCapture()
            return await ask(transcript: transcript, epoch: mine, spoke: spoke, typed: typed)
        }
        guard let conversation = conversations.current else { return dismissQuietly() }
        let turn = ContextPacket.Conversation(id: conversation.state.id, turn: conversation.turn + 1, previous: conversation.previous)
        switch sent {
        case .capture:
            break // sent above
        case .ask(var question, let shown, let typed):
            question.packet.features = features
            question.packet.conversation = turn
            if mode == .deep { question.routing = .alwaysDeep }
            // A failed approved action may have partly run (a send, an edit): it comes back as a
            // fresh proposal that needs the user's OK again, never re-run on the old approval.
            question.isApprovedAction = false
            lastSent = .ask(question, shown: shown, typed: typed)
            let stream = await turns.send(TurnRequest(question: question, state: conversation.state, kind: spoke ? .voice : .typed, target: .cascade))
            if cancelsAfterSend(mine) { await turns.cancel(conversation: conversation.state.id) }
            run(stream, question: question.packet.utterance, conversationID: conversation.state.id, spoke: spoke,
                typed: typed, shownQuestion: shown, epoch: mine)
        case .deeper(var question):
            question.packet.conversation = turn
            lastSent = .deeper(question)
            let stream = await turns.send(TurnRequest(question: question, state: conversation.state, kind: spoke ? .voice : .typed, target: .deeper))
            if cancelsAfterSend(mine) { await turns.cancel(conversation: conversation.state.id) }
            run(stream, question: question.packet.utterance, conversationID: conversation.state.id, spoke: spoke, epoch: mine)
        }
    }

    /// The main button: put `insert` into the user's app, or copy the answer.
    func runMainAction(_ action: MainAction) async {
        guard phase == .showing, !reportShowing, let block = lastAnswer, action == lastMainAction else { return }
        switch action {
        case .copy:
            overlay.copyAnswer()
        case .insert, .replace:
            // Replace is the same call: the selection is still selected, so the text replaces it
            // (the app's own ⌘Z undoes it).
            guard let text = block.insert, let inserter else { return }
            let mine = epoch
            let problem = await inserter.insert(text, into: targetPID)
            trace(.insert, outcome: problem == nil ? .ok : .failed)
            guard isCurrent(mine) else { return }
            if let problem {
                // The card stays, so the draft isn't lost and the user can try again.
                overlay.showToast(problem, at: pointer.location())
                return
            }
            // Done: the card closes, so a second press can't insert it twice.
            _ = nextEpoch()
            Task { await voice.stopSpeaking() }
            overlay.setSpeaking(false)
            dismissQuietly()
        }
    }
}
