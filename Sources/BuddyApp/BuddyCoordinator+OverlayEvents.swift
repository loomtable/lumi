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
    // MARK: - Overlay events

    func handle(_ event: OverlayEvent) {
        switch event {
        case .dismissed(let reason):
            // Lumi's own dismiss (`.requested`) echoes back a hop later: if a new answer is on
            // screen by then, the echo was about the earlier one and must not close this one.
            if reason == .requested, phase == .showing, overlay.showsAnswer { return }
            // The approval card closed unanswered: Esc cancels its turn; any other close leaves it
            // waiting in the background, with an amber capsule (V-03).
            if reason == .escape, let shown = shownApproval {
                shownApproval = nil
                _ = nextEpoch()
                Task { await cancel(shown.ticket) }
            } else if reason != .requested {
                approvalClosed()
            }
            let answerClosed = phase == .showing && reason != .requested && reason != .appSwitched
            if reason == .escape || reason == .closeButton {
                Task { await voice.stopSpeaking() }
                overlay.setSpeaking(false)
            }
            if case .showing = phase { phase = .idle }
            reportShowing = false
            setupChipVisible = false
            if phase == .held { heldChipVisible = false }
            // Esc or a click away closed the text box. Not `.requested`: that's Lumi's own dismiss,
            // whose echo can arrive after a new text box opened, and would close it.
            if phase == .typing, reason != .requested { closeTextBox() }
            ringSource?.shot = nil
            if reason != .requested { shownFix = nil } // the user closed its chip (ours may echo late)
            if answerClosed { offerPermissionFix() }
            playNextReady() // the Glance may be free now (a report closed while idle)
        case .action(let index) where shownApproval != nil:
            Task { await answerApproval(index) }
        case .action(let index):
            Task { await runAction(index) }
        case .mainAction(let action):
            Task { await runMainAction(action) }
        case .openLink(let url):
            openLink(url)
        case .goDeeper:
            Task { await goDeeper() }
        case .stopSpeaking:
            speechGeneration += 1
            Task { await voice.stopSpeaking() }
            overlay.setSpeaking(false)
        case .newConversation:
            Task {
                await cancelCurrent()
                _ = nextEpoch()
                overlay.resetPositions() // a new conversation opens at the default spots
                // UI first: a key press while the index starts the new conversation must not be
                // dismissed afterwards. Questions from then on wait for `startNew` (call order).
                overlay.dismiss(.requested)
                phase = .idle
                await startNewConversation()
            }
        case .wantsEscape(let wants):
            setEscape(wants)
        case .answerPresented:
            answerOnScreen = true
            switcherFlow?.glanceShown() // one answer on screen: the peek gives way
            releasePresentWaiters()
        case .submitted(let text, let source):
            Task { await submit(text, source: source) }
        case .jump(let label):
            guard phase == .showing, let point = lastAnswer?.points.first(where: { $0.label == label }) else { return }
            ring([point], epoch: epoch)
        case .popOut where shownApproval != nil:
            // ⤢ on the approval card: its session in Lumi, where the ask shows in full.
            if let shown = shownApproval { openInLumi(shown) }
        case .popOut where pageFlow != nil:
            // ⤢ Continue: the card lifts into the Panel with the conversation so far.
            Task { await continueInPanel() }
        case .openConversations, .popOut:
            // ⌘Y, and ⇱ on a rich card with the Panel off: the Lumi window, whose sidebar is the history.
            onOpenLumiWindow?()
        case .openSettings:
            onOpenSettings?()
        case .progressClicked(let id):
            // A waiting background question: a voice turn's comes back as the Glance's approval
            // card (V-03); any other (a page's turn) opens its page, which shows the ask.
            if !openWaiting(id) { onOpenWaiting?(id) }
        case .stopResearch:
            Task { [research] in await research?.handle(event) }
        case .openReport:
            // Never over a live mic, text box or turn in flight; the capsule keeps the report.
            guard phase == .idle || phase == .showing else { return }
            // The click on the capsule closed any card; the report card replaces it.
            _ = nextEpoch() // rings or speech still pending for the old card stop
            // The capsule click's dismissal offered the permission chip; the report takes its place.
            if case .grantPermission = shownFix { permissionChipShown = false }
            shownFix = nil
            lastAnswer = nil
            lastMainAction = nil
            typedCardShowing = false
            setupChipVisible = false
            reportShowing = true
            keptOnScreen = false
            phase = .showing
            Task { [research] in await research?.handle(event) }
        }
    }

    /// ⤢ Continue on a Glance card (LumiFeatures.panel): the Panel opens on the card's session
    /// with all of its turns (V-14: earlier launches too), and the card goes.
    func continueInPanel() async {
        guard let pageFlow, let kept else { return }
        let id = SessionID(rawValue: kept.conversationID)
        let shown = TranscriptTurn(question: kept.answer.question ?? "", block: kept.block, mode: kept.answer.lane.mode,
                                   model: kept.answer.lane.model)
        let packet = lastQuestion?.packet
        dismissQuietly()
        phase = .idle
        let stored = await pageFlow.history(id)
        // The stored history, else what this launch saw; the card's own turn last if it isn't written yet.
        var history = stored.isEmpty ? kept.answer.earlier : stored
        if history.last?.question != shown.question { history.append(shown) }
        let snapshot = pageFlow.snapshot(for: id) ?? Self.snapshot(id, question: history.first?.question ?? "", packet: packet, now: Date())
        pageFlow.show(snapshot, history: history, dock: packet.flatMap(Self.dock))
    }
}
