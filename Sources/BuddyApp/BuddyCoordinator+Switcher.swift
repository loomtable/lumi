import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay

extension BuddyCoordinator {
    // MARK: - Switcher (the switcher stream's)

    /// Takes the switcher's flow: its pill hints and tap-mode picks come back here.
    func attachSwitcher(_ flow: SwitcherFlow) {
        switcherFlow = flow
        flow.onHint = { [weak self] in self?.switcherHint($0) }
        flow.onTapCommit = { [weak self] in self?.switcherCommitted($0) }
        flow.onGlanceFree = { [weak self] in self?.playNextReady() }
    }

    /// The switcher's part of a buddy-key event, before the usual handling. True when the
    /// switcher took the event; false lets it through (`pressBegan`, the gesture's end).
    /// Without `switcherFlow` (flag off) nothing changes.
    func handleSwitcher(_ event: BuddyKeyEvent) async -> Bool {
        guard let flow = switcherFlow, !isPaused else { return false }
        switch event {
        case .gesture(.pressBegan):
            // A press that starts a new listen (not tap mode's sending press) carries no pick.
            if case .listening = phase {} else { flow.clearPick() }
            // After the press's own work (the pill, the mic): build the strip hidden.
            Task { @MainActor [weak self] in
                guard let self, let flow = self.switcherFlow else { return }
                flow.prepare()
                guard case .listening = self.phase else { return }
                self.overlay.setPillTarget(flow.pressTarget(fresh: self.pressFresh))
                if let waiting = flow.waitingHint() {
                    self.overlay.updateListeningHint(self.listenHint("tap \(self.settings.keySymbol) to send · \(waiting)"))
                }
            }
            return false
        case .gesture(.switcher(let key)):
            await startListeningForSwitcher()
            await flow.key(key)
            if case .listening = phase { overlay.updateListeningHint(listenHint("release to send")) }
            return true
        case .gesture(.switcherReleased):
            await finishSwitch(flow.released())
            return true
        case .gesture(.tap), .gesture(.holdEnded), .gesture(.doubleTap):
            // Tap mode's send: an open strip commits first, so the recording goes to the pick.
            if flow.inTapMode { await flow.commitOpenTap() } else { flow.reset() }
            return false
        case .gesture(.cancelled), .gesture(.holdDiscarded):
            flow.reset()
            flow.clearPick()
            return false
        case .switcher(let key):
            guard case .listening = phase else { return false }
            await flow.tapKey(key)
            return true
        case .gesture(.holdBegan), .secureInput, .dictation:
            return false
        }
    }

    /// A switcher key during a press that waited (an answer in flight or on screen): the
    /// recording starts now.
    private func startListeningForSwitcher() async {
        guard freshPressWaiting else { return }
        freshPressWaiting = false
        await beginListening()
    }

    /// The release after switching: send, switch, start fresh or restore (03 §3.4).
    private func finishSwitch(_ outcome: SwitcherFlow.Outcome) async {
        guard case .listening = phase else { return }
        switch outcome {
        case .send(.new):
            listenFresh = true
            await send()
        case .send(.session(let id)):
            // QA R1: the pick, not the routing rules, decides where this turn goes (one-shot;
            // the listen's discard or the next listen clears it).
            nextRouteSource = .switcherPick(id)
            await send()
        case .restored(spoke: true), .none:
            await send()
        case .switched(let id):
            // No speech: the flow made the session current; the next summon goes to it (V-12).
            await discardListening(sound: false)
            switchedTo = (id, clock())
        case .restored(spoke: false):
            await discardListening(sound: false)
        case .fresh:
            await discardListening(sound: false)
            await startNewConversation()
        }
    }

    /// Tap mode retargeted the recording: the pill says where it goes.
    func switcherHint(_ hint: String?) {
        guard case .listening = phase else { return }
        let send = "tap \(settings.keySymbol) to send"
        overlay.updateListeningHint(listenHint(hint.map { "\(send) · \($0)" } ?? send))
    }

    /// Tap mode committed a pick (Return, the 1.5 s timeout, a click or the sending tap): the
    /// live recording goes there. The sending press doesn't start a new listen, so the pick
    /// lasts until this listen's ask. ＋ starts a new conversation.
    func switcherCommitted(_ target: SwitcherFlow.Target) {
        switch target {
        case .session(let id): nextRouteSource = .switcherPick(id)
        case .new: listenFresh = true
        }
    }

    /// A routed turn: the pill's thinking row shows the session it went to.
    func showPillTarget(_ id: SessionID) {
        guard let flow = switcherFlow else { return }
        overlay.setPillTarget(flow.snapshot(id).map(PillTarget.session) ?? .none)
    }

}
