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
    /// `fix`: a button that puts it right, e.g. Settings › Claude Code.
    func showChip(_ text: String, lane mode: Mode = .quick, fix: FixAction? = nil) {
        lastMainAction = nil // the chip has no main button
        keptOnScreen = false
        // A model switch needs the runtime's hook; without it there's no button.
        // "Try again" needs something to send again.
        let fix = fix.flatMap { fix -> FixAction? in
            switch fix {
            case .useModel where onUseModel == nil, .useModel where lastSent == nil, .retry where lastSent == nil,
                 .openDictationHistory where onOpenDictationHistory == nil: nil
            default: fix
            }
        }
        shownFix = fix
        shownFixLane = mode
        setupChipVisible = false
        typedCardShowing = false
        overlay.showAnswer(
            Answer(
                block: BuddyBlock(say: text, shape: .chip,
                                  actions: fix.map { [BuddyBlock.Action(label: $0.label, prompt: "")] } ?? []),
                lane: lane(for: mode),
                conversation: conversations.current?.color ?? .ember,
                turn: conversations.current?.turn ?? 0,
                replyHint: "",
                keepsPlacement: false), // a system chip never takes an answer's remembered spot
            anchor: lastAnchor)
        phase = .showing
        glanceTakesItsTurn(BuddyBlock(say: text, shape: .chip))
    }

    /// A real answer of the current conversation to bring back, shown or tucked away. None after a
    /// new question starts, a new conversation, Forget or switching conversations.
    public var hasKeptAnswer: Bool {
        kept != nil && kept?.conversationID == conversations.current?.state.id
    }

    /// The card on screen is that answer (not a chip or a report).
    public var isShowingKeptAnswer: Bool {
        phase == .showing && keptOnScreen && hasKeptAnswer
    }

    /// The last answer back where it sat (the menu-bar dot, "Show Last Answer", reopening the app),
    /// silently: its main button, ⌘↵, jumps and actions work again. Only while idle.
    @discardableResult
    public func recallLastAnswer() -> Bool {
        guard phase == .idle, hasKeptAnswer, let kept else { return false }
        _ = nextEpoch() // a pending permission chip fade or ring is the old card's
        shownFix = nil
        lastAnswer = kept.block
        lastMainAction = kept.mainAction
        reportShowing = false
        typedCardShowing = false
        setupChipVisible = false
        phase = .showing
        answerOnScreen = false // the overlay says when it's back (`.answerPresented`)
        keptOnScreen = true
        overlay.recallAnswer(kept.answer, anchor: kept.anchor)
        glanceTakesItsTurn(kept.block)
        return true
    }

    /// The menu-bar dot's own close: like ✕, but the answer stays to bring back.
    public func tuckAnswer() {
        guard isShowingKeptAnswer else { return }
        speechGeneration += 1
        Task { await voice.stopSpeaking() }
        overlay.setSpeaking(false)
        dismissQuietly(.closeButton) // a tuck, so it folds into the dot it comes back from
    }

    /// The runtime's permission state. A chip up for another kind (or a granted one) closes; a new
    /// kind is offered again.
    public func setMissingPermission(_ kind: PermissionKind?) {
        guard kind != missingPermission else { return }
        missingPermission = kind
        permissionChipShown = false
        if phase == .showing, case .grantPermission(let shown) = shownFix, shown != kind { dismissQuietly() }
    }

    /// After the user closes an answer: the missing permission's Fix chip, once. It never takes an
    /// answer's place and goes by itself unless something replaces it first.
    func offerPermissionFix() {
        guard let kind = missingPermission, !permissionChipShown, phase == .idle else { return }
        permissionChipShown = true
        showChip(Self.permissionLine(kind), fix: .grantPermission(kind))
        let mine = epoch
        permissionChipFade?.cancel()
        permissionChipFade = Task { [weak self, lifetime = permissionChipLifetime] in
            try? await Task.sleep(for: lifetime)
            guard let self, !Task.isCancelled, isCurrent(mine), phase == .showing,
                  case .grantPermission = shownFix else { return }
            dismissQuietly()
        }
    }

    static func permissionLine(_ kind: PermissionKind) -> String {
        kind == .screenRecording
            ? "\(BuddyCore.appName) needs Screen Recording to see your screen."
            : "\(BuddyCore.appName) needs Accessibility to read your selection and close with Esc."
    }

    /// "tap ⌥ to reply · click to type" until both have been used once.
    var replyHint: String {
        repliedByKey && repliedByClick ? "" : "tap \(settings.keySymbol) to reply · click to type"
    }

    func noteReply(byKey: Bool) {
        if byKey {
            repliedByKey = true
            hintDefaults?.set(true, forKey: Self.repliedByKeyKey)
        } else {
            repliedByClick = true
            hintDefaults?.set(true, forKey: Self.repliedByClickKey)
        }
    }

    /// The pill's hint, saying when this listen starts a new session.
    func listenHint(_ hint: String) -> String {
        listenFresh ? "new session · \(hint)" : hint
    }

    /// ⌘N, ＋, ⇧ + buddy key or "new topic": the toast says so.
    /// `epoch`: shows nothing if a newer request took over meanwhile.
    func startNewConversation(epoch mine: Int? = nil) async {
        // With sessions on, the router decides: the next question starts a new session.
        routing.startNewSession()
        await conversations.startNew()
        guard mine.map(isCurrent) ?? true else { return }
        overlay.showToast("New session", at: pointer.location())
    }

    /// A bare "new topic": a conversation change with no question to answer.
    func runConversationCommand(_ command: ConversationCommand) async {
        let mine = epoch
        capture?.cancel()
        capture = nil
        ringSource = nil
        dismissQuietly()
        switch command {
        case .newTopic:
            await startNewConversation(epoch: mine)
        }
    }


    func showSetupProgress(_ state: VoiceController.PrepareState) {
        guard setupChipVisible, phase == .showing else { return }
        switch state {
        case .preparing: if let line = Self.setupLine(state, key: typeKey) { overlay.updateChipText(line) }
        case .ready: overlay.updateChipText("Voice is ready. Tap \(settings.keySymbol) to talk.")
        // The next press retries setup (and says so).
        case .failed:
            let type = typeKey.map { ", or double-tap \($0) to type" } ?? ""
            overlay.updateChipText("Voice setup failed. Tap \(settings.keySymbol) to try again\(type).")
        case .notStarted: break
        }
    }

    /// The setup chip's line while the speech models load; nil once ready or failed. The
    /// percentage is the downloader's whole-load fraction (download and compile), the same figure
    /// Settings › Voice shows. Never an estimate of time. Typing works meanwhile, so
    /// the line says how (`key`: the buddy key's symbol; nil when double-tap is off).
    static func setupLine(_ state: VoiceController.PrepareState, key: String?) -> String? {
        guard case .preparing(let step) = state else { return nil }
        let detail: String? = switch step {
        case .speechModel(let progress?): "\(Int((min(max(progress.fraction, 0), 1) * 100 + 1e-9).rounded(.down)))%"
        case .speechModel(nil): nil
        case .voiceActivity: "loading voice detection"
        case .voice: "loading the voice"
        case .microphone: "starting the microphone"
        }
        return withTypeHint(detail.map { "Still setting up voice · \($0)" } ?? "Still setting up voice", key: key)
    }

    /// "… · double-tap ⌥ to type": typing works while the voice sets up. `key` nil: the line
    /// as it is, since nothing else opens the text box.
    static func withTypeHint(_ line: String, key: String?) -> String {
        guard let key else { return line.hasSuffix(".") || line.hasSuffix("…") ? line : line + "." }
        var line = Substring(line)
        while let last = line.last, last == "." || last == "…" { line = line.dropLast() }
        return "\(line) · double-tap \(key) to type"
    }

    /// The key a setup chip's typing hint names, or nil while double-tap is off (Sticky Keys).
    var typeKey: String? { doubleTapAvailable() ? settings.keySymbol : nil }

    static func voiceMessage(_ error: any Error, fallback: String) -> String {
        (error as? VoicePortError)?.message ?? fallback
    }
}
