import AppKit
import WebKit
import BuddyCore
import SwiftUI

/// The real overlay. The shell creates one and drives it through `OverlayPresenting`.
///
/// Idle cost: when nothing is visible every panel is ordered out and no event monitors
/// are installed, so the overlay does no work at all.
public final class BuddyOverlayController: OverlayPresenting {
    public let events: AsyncStream<OverlayEvent>
    private let continuation: AsyncStream<OverlayEvent>.Continuation
    let model = OverlayModel()

    private var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var activeDisplay: CGDirectDisplayID?
    private var pointerMonitors: [Any] = []
    private var clickAwayMonitors: [Any] = []
    private var peekMonitors: [Any] = []
    private var chipMonitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []
    private var hintTask: Task<Void, Never>?
    private var foldTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    /// A `showAnswer` is still measuring or placing; chip text sent meanwhile waits for it, so it
    /// lands on the new chip, not the one still on screen.
    private var presentingAnswer = false
    private var pendingChipText: String?
    private var micEnvelope = LevelEnvelope.mic
    private var speechEnvelope = LevelEnvelope.speech
    private var lastMic: ContinuousClock.Instant?
    private var lastSpeech: ContinuousClock.Instant?
    private var lastSpeechPublish: ContinuousClock.Instant?
    private var lastWantsEscape = false
    /// Where recent answers sat when they left the screen, oldest first, for `recallAnswer`.
    private var recentPlacements: [(answer: Answer, origin: CGPoint)] = []
    static let recentPlacementLimit = 4
    /// The answer `recallAnswer` put up: it keeps its old spot, also when its content
    /// re-measures, until the user drags it or another answer comes.
    private var recalledAnswer: Answer?

    /// Card widths: 22 em, rich 36 em, chips up to 26 em, at the prototype's 15 pt em.
    /// Kept when the type moved to the macOS scale (13 pt body): lines hold more words and
    /// cards get shorter.
    static let cardWidth: CGFloat = 330
    static let richWidth: CGFloat = 540
    static let chipMaxWidth: CGFloat = 390
    /// Answers never take more than this share of the display's height.
    static let maxHeightFraction: CGFloat = 0.8
    /// Web area height when the HTML never reported one (it then scrolls).
    static let fallbackWebHeight: CGFloat = 120

    public convenience init() { self.init(observesSystem: true) }

    /// `observesSystem: false` (tests) ignores other apps: no app-switch, Space or screen
    /// notifications and no global event monitors, so the person using the Mac while tests run
    /// can't close a test's card by switching apps or clicking elsewhere.
    init(observesSystem: Bool) {
        self.observesSystem = observesSystem
        (events, continuation) = AsyncStream.makeStream(of: OverlayEvent.self)
        Task { [weak self] in
            await SmartPlacement.prewarm()
            self?.saliencyWarm = true
        }
        guard observesSystem else { return }
        // NotificationCenter delivers these on the main queue; the blocks are @Sendable,
        // so hop explicitly.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.appActivated() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.replaceCapsule() } })
    }

    private let observesSystem: Bool

    /// A global monitor (events in other apps). When not observing the system it's an inert
    /// token, so the add/remove bookkeeping still runs and stays testable.
    private func globalMonitor(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
        observesSystem ? NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) : InertMonitor()
    }

    private final class InertMonitor {}

    isolated deinit {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        removeMonitors(&pointerMonitors)
        removeMonitors(&clickAwayMonitors)
        removeMonitors(&peekMonitors)
        removeMonitors(&chipMonitors)
        // A controller going away (e.g. a test ending early) leaves nothing on screen.
        for panel in panels.values { panel.orderOut(nil) }
        continuation.finish()
    }

    /// The shell's scoped Esc tap is needed while something is visible, except when the
    /// overlay itself has keyboard focus over the text box or a card: then Esc reaches it
    /// directly (and can cancel an IME composition). During typed thinking the panel is
    /// focused but has nothing that handles Esc, so the tap stays on and Esc still cancels.
    public var wantsEscape: Bool {
        if foldingIntoListening { return true }  // Esc discards the listening about to start
        let focusedSurface = model.hasFocus && (model.surface == .textBox || model.surface.isAnswer)
        guard model.surface != .none, !model.folding else { return false }
        return !focusedSurface
    }
    public var foldTarget: (@MainActor () -> CGRect?)?
    public var onFoldedIntoTarget: (@MainActor () -> Void)?
    /// A recalled answer pops out of the orb it was tucked into.
    private var pendingPopSource: CGPoint?

    /// Closing an answer this way tucks it into the menu-bar orb, where it can be brought back;
    /// `.requested` (the app replacing or clearing it) folds as before.
    static let tuckReasons: Set<DismissReason> = [.clickAway, .appSwitched, .escape, .closeButton]

    /// The orb's centre (global top-left), when the answer on screen can be recalled and the
    /// menu-bar item is visible.
    private func orbPoint() -> CGPoint? {
        guard case .answer(let answer, _, _) = model.surface, answer.keepsPlacement,
              let frame = foldTarget?(), !frame.isEmpty else { return nil }
        let r = ScreenSpace.topLeft(frame)
        return CGPoint(x: r.midX, y: r.midY)
    }
    public var settings: OverlaySettings {
        get { model.settings }
        set { model.settings = newValue }
    }
    public var placementMode: Placer.Mode {
        get { model.settings.placement }
        set { model.settings.placement = newValue }
    }
    private var brightness = BrightnessGate()
    /// Luminance of the latest snapshot, built once per snapshot.
    private var luminance: (image: CGImage, map: LuminanceMap)?
    /// Saliency joins edge density once its model is loaded (pre-warmed at launch).
    private var saliencyWarm = false
    /// An open card is folding away before listening starts.
    private var foldingIntoListening = false

    // MARK: OverlayPresenting

    public func showListening(at pointer: CGPoint, hint: String) {
        guard Self.fallbackScreen != nil else { return }  // no display attached
        cancelPendingAnswer()
        hideConversationChip()
        // The buddy key with a card open: the card folds away toward the new pill, then
        // listening starts. The mic is already live; only the pill waits 200 ms.
        rememberPlacement()  // the card this folds away may be recalled later
        if model.surface.isAnswer, !model.folding, !reduceMotion {
            let screen = ScreenSpace.screen(containing: pointer) ?? Self.fallbackScreen!
            let origin = model.statusPillOrigin(size: model.pillSize, in: ScreenSpace.topLeft(screen.visibleFrame))
            model.source = CGPoint(x: origin.x, y: origin.y + model.pillSize.height / 2)
            model.foldScale = Motion.foldScale
            withAnimation(Motion.fold) { model.folding = true }
            foldingIntoListening = true
            hintTask?.cancel()
            foldTask?.cancel()
            publishWantsEscape()
            updateFocusability()
            foldTask = Task { [weak self] in
                try? await Task.sleep(for: Motion.foldDuration)
                guard !Task.isCancelled, let self else { return }
                self.foldingIntoListening = false
                self.clearAnswer()
                // Remove the folded card without animation, so it can't snap back and morph.
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    self.model.surface = .none
                    self.model.folding = false
                }
                self.enterListening(at: pointer, hint: hint)
            }
            return
        }
        cancelFold()
        if model.surface.isAnswer { clearAnswer() }  // Reduce Motion: no fold, but drop the card's state
        enterListening(at: pointer, hint: hint)
    }

    private func enterListening(at pointer: CGPoint, hint: String) {
        // Also reached after the 200 ms fold: the last display may have gone meanwhile (lid shut).
        guard Self.fallbackScreen != nil else { return }
        let screen = activate(screenContaining: pointer)
        micEnvelope.reset()
        lastMic = nil
        model.mic.value = 0
        model.showsListeningHint = false
        resetBrightness()
        model.typed = false
        model.reply = ""
        model.fullScreen = false
        placePill(at: pointer, on: screen)
        withAnimation(reduceMotion ? Motion.crossfade : Motion.pillIn) {
            model.surface = .listening(hint: hint)
        }
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: self?.listeningHintDelay ?? .seconds(2))
            guard !Task.isCancelled, let self, case .listening = self.model.surface else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.model.showsListeningHint = true }
        }
        surfaceChanged()
    }

    public func updateListeningHint(_ hint: String) {
        guard case .listening(let current) = model.surface, current != hint else { return }
        withAnimation(.easeInOut(duration: 0.2)) { model.surface = .listening(hint: hint) }
    }

    public func showTextBox(at pointer: CGPoint) {
        guard Self.fallbackScreen != nil else { return }  // no display attached
        hideConversationChip()
        cancelFold()
        hintTask?.cancel()
        cancelPendingAnswer()
        let screen = activate(screenContaining: pointer)
        model.typed = true
        resetBrightness()
        model.draft = ""
        model.reply = ""
        model.fullScreen = false
        // A visible pill (the first tap of a double-tap) morphs into the box in place;
        // otherwise the box appears at the pill's fixed spot.
        if !model.surface.isPill { placePill(at: pointer, on: screen) }
        withAnimation(reduceMotion ? Motion.crossfade : Motion.pillIn) { model.surface = .textBox }
        surfaceChanged()
        installClickAway()
        takeFocus()
    }

    /// ↵ in the text box or the reply field.
    func submit(_ source: SubmitSource) {
        guard !model.folding else { return }
        let raw = source == .textBox ? model.draft : model.reply
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if source == .textBox { model.draft = "" } else { model.reply = "" }
        model.typed = true
        continuation.yield(.submitted(text: text, source: source))
    }

    public func showThinking(_ lane: Lane, status: String?) {
        guard Self.fallbackScreen != nil else { return }  // no display attached
        // A new answer is on its way: the last answer's marks go, so a 6 s wash can't sit on
        // text the user has since scrolled to.
        if !model.rings.isEmpty { withAnimation(.easeIn(duration: 0.2)) { model.rings.removeAll() } }
        cancelFold()
        hintTask?.cancel()
        if !model.surface.isPill {
            // No pill yet (e.g. a typed question): start one at the fixed spot on the pointer's display.
            let pointer = ScreenSpace.topLeft(NSEvent.mouseLocation)
            placePill(at: pointer, on: activate(screenContaining: pointer))
        }
        model.statusIsHeadline = false
        withAnimation(reduceMotion ? Motion.crossfade : .smooth(duration: 0.25)) {
            model.surface = .thinking(lane, status: status)
        }
        surfaceChanged()
    }

    public func updateStatus(_ status: String?) {
        guard case .thinking(let lane, _) = model.surface else { return }
        model.statusIsHeadline = false
        withAnimation(.easeInOut(duration: 0.15)) { model.surface = .thinking(lane, status: status) }
    }

    public func showHeadline(_ headline: String) {
        guard case .thinking(let lane, _) = model.surface else { return }
        model.statusIsHeadline = true
        withAnimation(.easeInOut(duration: 0.15)) { model.surface = .thinking(lane, status: headline) }
    }

    /// The headline the pill is showing now, if its status is the answer's headline.
    private var pillHeadline: String? {
        guard model.statusIsHeadline, case .thinking(_, let status?) = model.surface else { return nil }
        return status
    }

    public func showAnswer(_ answer: Answer, anchor: Anchor, snapshot: DisplaySnapshot?) {
        // A new conversation's first answer goes back to the placement mode (drag is per conversation).
        if answer.turn == 1 { resetPositions() }
        recalledAnswer = nil
        pendingPopSource = nil
        // Read in the pill already: the card shows it at once rather than inking it in again.
        startAnswer(answer, anchor: anchor, snapshot: snapshot,
                    headlineShown: Self.sameHeadline(pillHeadline, answer.block.say))
    }

    public func recallAnswer(_ answer: Answer, anchor: Anchor) {
        rememberPlacement()  // an answer on screen now may be recalled later too
        recalledAnswer = answer
        pendingPopSource = foldTarget?().flatMap { $0.isEmpty ? nil : ScreenSpace.topLeft($0) }.map { CGPoint(x: $0.midX, y: $0.midY) }
        // Already read once: no ink-in.
        startAnswer(answer, anchor: anchor, snapshot: nil, headlineShown: true)
    }

    /// Notes where the answer on screen sits, so a later `recallAnswer` puts it back there.
    private func rememberPlacement() {
        guard case .answer(let answer, let placement, _) = model.surface, answer.keepsPlacement else { return }
        recentPlacements.removeAll { $0.answer == answer }
        recentPlacements.append((answer, placement.frame.origin))
        if recentPlacements.count > Self.recentPlacementLimit { recentPlacements.removeFirst() }
    }

    private func startAnswer(_ answer: Answer, anchor: Anchor, snapshot: DisplaySnapshot?, headlineShown: Bool) {
        model.headlineAlreadyShown = headlineShown
        cancelFold()
        hintTask?.cancel()
        answerTask?.cancel()
        presentingAnswer = true
        pendingChipText = nil // meant for the surface this answer replaces
        answerTask = Task { [weak self] in await self?.present(answer, anchor: anchor, snapshot: snapshot) }
    }

    static func sameHeadline(_ shown: String?, _ say: String) -> Bool {
        guard let shown else { return false }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return !trim(say).isEmpty && trim(shown) == trim(say)
    }

    public func updateChipText(_ text: String) {
        if presentingAnswer {
            pendingChipText = text
            return
        }
        guard case .answer(var answer, let placement, let style) = model.surface, style == .chip,
              answer.block.shape == .chip, !model.folding, !model.fullScreen, answer.block.say != text,
              let id = activeDisplay, let screen = NSScreen.screens.first(where: { $0.displayID == id })
        else { return }
        answer.block.say = text
        let size = measure(answer, style: style, width: Self.width(for: style), webHeight: 0)
        let bounds = ScreenSpace.topLeft(screen.visibleFrame)
        var updated = placement
        updated.frame = Self.resizedChipFrame(placement.frame, to: size, edge: placement.edge, in: bounds)
        // No animation and no answerID bump: the chip stays put and doesn't pop or ink again.
        // A headline still inking in snaps sharp: InkText's timer ends on its first run.
        model.surface = .answer(answer, updated, style)
        surfaceChanged()
    }

    /// The chip's frame for new text. It only grows, so ticking progress doesn't make its edge
    /// jitter. The side facing the anchor stays put, so growing never covers the anchor; then
    /// it's pulled back onto the display.
    static func resizedChipFrame(_ frame: CGRect, to size: CGSize, edge: PlacementEdge, in bounds: CGRect) -> CGRect {
        let grown = CGSize(width: max(frame.width, size.width), height: max(frame.height, size.height))
        var r = CGRect(origin: frame.origin, size: grown)
        if edge == .above { r.origin.y = frame.maxY - grown.height }
        if edge == .leading { r.origin.x = frame.maxX - grown.width }
        let area = bounds.insetBy(dx: Placer.edgeMargin, dy: Placer.edgeMargin)
        return Placer.clamp(r, in: area)
    }

    public func setMicLevel(_ level: Double) {
        let now = ContinuousClock.now
        let dt = lastMic.map { Self.seconds(now - $0) } ?? 0.02
        lastMic = now
        let v = micEnvelope.step(toward: level, dt: dt)
        model.mic.value = v
    }

    public func setSpeechLevel(_ level: Double) {
        let now = ContinuousClock.now
        let dt = lastSpeech.map { Self.seconds(now - $0) } ?? 0.02
        lastSpeech = now
        let v = speechEnvelope.step(toward: level, dt: dt)
        // Publish at most 30 times a second; each publish redraws the card's glow.
        if model.speaking, lastSpeechPublish.map({ now - $0 >= .milliseconds(33) }) ?? true {
            lastSpeechPublish = now
            model.speech = v
        }
    }

    public func setSpeaking(_ speaking: Bool) {
        model.speaking = speaking
        if !speaking {
            speechEnvelope.reset()
            lastSpeech = nil
            model.speech = 0
        }
    }

    public func dismiss(_ reason: DismissReason) {
        dragStart = nil
        // Cancel a pending answer first: it may still be loading with nothing on screen.
        cancelPendingAnswer()
        hideConversationChip()
        if foldingIntoListening {
            // Discard or cancel during the fold into listening: stop it, don't start listening.
            foldingIntoListening = false
            foldTask?.cancel()
            finishFold()
            continuation.yield(.dismissed(reason))
            return
        }
        guard model.surface != .none, !model.folding else { return }
        hintTask?.cancel()
        rememberPlacement()
        // Tucked: fold into the menu-bar orb (lifecycle v2). Otherwise toward the source, as before.
        let orb = Self.tuckReasons.contains(reason) ? orbPoint() : nil
        if let orb { model.source = orb }
        model.foldScale = orb == nil ? Motion.foldScale : Motion.tuckScale
        withAnimation(reduceMotion ? Motion.crossfade : orb == nil ? Motion.fold : Motion.tuck) { model.folding = true }
        updateFocusability()
        continuation.yield(.dismissed(reason))
        publishWantsEscape()
        removeMonitors(&clickAwayMonitors)
        foldTask = Task { [weak self] in
            try? await Task.sleep(for: orb == nil ? Motion.foldDuration : Motion.tuckDuration)
            guard !Task.isCancelled, let self else { return }
            self.finishFold()
            if orb != nil { self.onFoldedIntoTarget?() }
        }
    }

    public func focusAnswer() {
        guard model.surface.isAnswer, !model.folding else { return }
        takeFocus()
    }

    /// Makes the panel key without activating the app (non-activating panel).
    private func takeFocus() {
        guard let id = activeDisplay, let panel = panels[id] else { return }
        updateFocusability()
        // One request only: a delayed retry could take keystrokes the user meant for their
        // own app. If it's refused (rare, measured 1 in 8 under load), a click focuses it.
        panel.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    public func handleEscape() -> Bool {
        // Not gated on wantsEscape: an Esc the shell already captured (e.g. just before the
        // panel took focus) must still close what's visible.
        if foldingIntoListening {
            dismiss(.escape)
            return true
        }
        guard model.surface != .none, !model.folding else { return false }
        // In full screen, Esc returns to the card first.
        if model.fullScreen {
            toggleFullScreen()
            return true
        }
        dismiss(.escape)
        return true
    }

    // MARK: Answer

    private func present(_ answer: Answer, anchor initialAnchor: Anchor, snapshot: DisplaySnapshot?) async {
        var anchor = initialAnchor
        guard let fallback = Self.fallbackScreen else { return }  // no display attached (asleep)
        // The research report is centred, popping out of the capsule.
        let style = anchor == .capsule ? .centered : Placer.style(for: answer.block.shape, mode: placementMode)
        let fromCapsule = anchor == .capsule
        // The report opens on the capsule's own display.
        let screens = NSScreen.screens
        let reportIndex = ScreenSpace.reportScreenIndex(
            capsuleFrame: model.capsuleScreenFrame, capsuleVisible: model.capsuleVisible,
            screenFrames: screens.map { ScreenSpace.topLeft($0.frame) },
            menuBarIndex: ScreenSpace.menuBarScreen.flatMap { s in screens.firstIndex { $0 === s } })
        var screen = (fromCapsule ? reportIndex.map { screens[$0] } : nil)
            ?? ScreenSpace.screen(containing: CGPoint(x: anchor.rect.midX, y: anchor.rect.midY))
            ?? fallback
        var bounds = ScreenSpace.topLeft(screen.visibleFrame)
        let width = Self.width(for: style)
        let maxHeight = bounds.height * Self.maxHeightFraction

        // Load and measure card_html first, so the card pops at its final size.
        var web: CardWebContent?
        var webHeight: CGFloat = 0
        if let html = answer.block.cardHTML, !html.isEmpty {
            let content = CardWebContent(width: width - 2 * (Tokens.rimInset + 14))
            let measured = await content.load(html: html, timeout: Self.cardLoadBudget, jumps: model.settings.rings)
            guard !Task.isCancelled else { return content.tearDown() }
            web = content
            // No height report in time: show a scrolling area rather than hiding the HTML.
            webHeight = measured ?? Self.fallbackWebHeight
            if measured == nil { enableScrolling(content) }
        }
        var size = measure(answer, style: style, width: width, webHeight: webHeight)
        if size.height > maxHeight, webHeight > 0 {
            // Too tall: shrink the web area and let it scroll.
            webHeight = max(80, webHeight - (size.height - maxHeight))
            size = measure(answer, style: style, width: width, webHeight: webHeight)
            if let web { enableScrolling(web) }
        }
        // Every await above can be overtaken by a newer call (another answer, listening,
        // dismiss). Only the latest request may touch the model.
        guard !Task.isCancelled else { return web?.tearDown() ?? () }

        // Smart placement scores only make sense for the display the snapshot shows.
        var scores: SmartPlacement.Scores?
        // Content scoring is what makes Smart smart; "Next to it" is the plain placement rule.
        if style != .centered, placementMode == .smart,
           let snapshot = Self.usableSnapshot(snapshot, for: anchor, on: screen) {
            scores = await SmartPlacement.scores(for: snapshot, withSaliency: saliencyWarm)
            guard !Task.isCancelled else { return web?.tearDown() ?? () }
        }
        // The awaits above can outlast a display change (unplugged, rearranged, resolution):
        // place on the display as it is now, never on one that's gone.
        let live = NSScreen.screens
        switch Self.recheckDisplay(captured: screen.displayID, capturedFrame: screen.frame,
                                   live: live.map { ($0.displayID, $0.frame) }, main: NSScreen.main?.displayID) {
        case .unchanged:
            break
        case .noScreens:
            return web?.tearDown() ?? ()
        case .changed(let id, let gone):
            guard let now = live.first(where: { $0.displayID == id }) else { return web?.tearDown() ?? () }
            screen = now
            bounds = ScreenSpace.topLeft(now.visibleFrame)
            scores = nil  // the snapshot showed the display as it was
            if gone {
                // As screensChanged does: continue on the main display, near its centre.
                let centre = CGPoint(x: bounds.midX, y: bounds.midY)
                if anchor != .capsule { anchor = anchor.isPage ? .page(centre) : .point(centre) }
            }
            if size.height > bounds.height * Self.maxHeightFraction, webHeight > 0 {
                webHeight = max(80, webHeight - (size.height - bounds.height * Self.maxHeightFraction))
                size = measure(answer, style: style, width: width, webHeight: webHeight)
                // Shrunk to fit the new display: let the HTML scroll (not awaited, as in relayoutAnswer).
                if let web { Task { await web.allowScrolling() } }
            }
        }
        let placement = placeAnswer(answer, size: size, anchor: anchor, in: bounds, style: style, scores: scores)
        activate(screen)
        model.scores = scores
        // Out of a pill or a previous answer, the shared glassEffectID morphs; only a
        // surface appearing from nothing pops.
        let morph = (model.surface.isPill || model.surface.isAnswer) && !reduceMotion
        // From the capsule if it's on this display; otherwise from this display's top centre.
        let capsulePoint = model.capsuleScreenFrame == ScreenSpace.topLeft(screen.frame) && model.capsuleVisible
            ? CGPoint(x: model.capsuleFrame.midX, y: model.capsuleFrame.midY)
            : CGPoint(x: bounds.midX, y: bounds.minY + 19)
        model.source = fromCapsule ? capsulePoint
            : pendingPopSource ?? (model.surface.isPill ? CGPoint(x: model.pillFrame.minX, y: model.pillFrame.midY)
                                                        : CGPoint(x: anchor.rect.midX, y: anchor.rect.midY))
        pendingPopSource = nil
        model.morphs = morph
        model.anchor = anchor
        model.web?.tearDown()
        model.web = web
        model.webHeight = webHeight
        web?.onJump = { [weak self] label in self?.continuation.yield(.jump(label: label)) }
        web?.onCopy = { [weak self] text in self?.copyBlock(text) }
        web?.onHeightChange = { [weak self, weak web] height in
            guard let self, let web, self.model.web === web else { return }
            self.relayoutAnswer(webHeight: height)
        }
        if !morph { model.popTrigger += 1 }
        rememberPlacement()  // the answer this one replaces
        withAnimation(reduceMotion ? Motion.crossfade : Motion.pop) {
            model.fullScreen = false
            model.answerID += 1
            model.surface = .answer(answer, placement, style)
        }
        surfaceChanged()
        continuation.yield(.answerPresented)
        installClickAway()
        resetBrightness()
        sampleBackdrop(snapshot)
        // A typed conversation keeps focus in the reply field, but only if the user is
        // still with us: if they clicked back into their app while it was thinking, the
        // answer must not grab their keystrokes.
        if Self.answerTakesFocus(typed: model.typed, panelHasFocus: model.hasFocus) { takeFocus() }
        presentingAnswer = false
        if let text = pendingChipText {
            pendingChipText = nil
            updateChipText(text)
        }
    }

    private func cancelPendingAnswer() {
        answerTask?.cancel()
        presentingAnswer = false
        pendingChipText = nil
    }

    static func answerTakesFocus(typed: Bool, panelHasFocus: Bool) -> Bool { typed && panelHasFocus }

    private func updateFocusability() {
        // Focusable: an answer, the text box, or a typed question still thinking (so focus
        // stays with the conversation until its answer arrives).
        let focusable: Bool = switch model.surface {
        case .answer, .textBox: !model.folding
        case .thinking: model.typed && !model.folding
        case .none, .listening: false
        }
        for panel in panels.values where panel.acceptsFocus != focusable { panel.acceptsFocus = focusable }
        if !focusable {
            // canBecomeKey turning false doesn't resign a key panel: hand keyboard focus back
            // to the user's app (re-ordering a window that can't be key drops key status).
            for panel in panels.values where panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    private func measure(_ answer: Answer, style: Placer.Style, width: CGFloat, webHeight: CGFloat) -> CGSize {
        let probe = AnswerContent(answer: answer, style: style, t: Tokens(.init(dark: false)), web: nil,
                                  webHeight: webHeight, speaking: true, sizing: true)
        let host = NSHostingController(rootView: probe)
        let fitted = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let w = style == .chip ? min(ceil(fitted.width), width) : width
        return CGSize(width: w, height: ceil(fitted.height))
    }

    /// Re-measures and re-places the visible answer in place, e.g. when its web content
    /// changes height after late images load, or its display changes.
    private func relayoutAnswer(webHeight newHeight: CGFloat? = nil) {
        // In full screen, heights reported at the wider width size the full-screen web area
        // only; they must not replace the card's own (it reflows again on exit).
        if model.fullScreen, let newHeight {
            model.fullScreenContentHeight = newHeight
            guard case .answer(let answer, _, let style) = model.surface,
                  let id = activeDisplay, let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
            withAnimation(reduceMotion ? Motion.crossfade : .smooth(duration: 0.25)) {
                updateFullScreenGeometry(answer, style: style, bounds: ScreenSpace.topLeft(screen.visibleFrame))
            }
            return
        }
        guard case .answer(let answer, _, let style) = model.surface, !model.folding, let anchor = model.anchor,
              let id = activeDisplay, let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        let bounds = ScreenSpace.topLeft(screen.visibleFrame)
        let width = Self.width(for: style)
        var webHeight = newHeight ?? model.webHeight
        var size = measure(answer, style: style, width: width, webHeight: webHeight)
        let maxHeight = bounds.height * Self.maxHeightFraction
        if size.height > maxHeight, webHeight > 0 {
            webHeight = max(80, webHeight - (size.height - maxHeight))
            size = measure(answer, style: style, width: width, webHeight: webHeight)
            Task { await model.web?.allowScrolling() }
        }
        let placement = placeAnswer(answer, size: size, anchor: anchor, in: bounds, style: style, scores: model.scores)
        withAnimation(reduceMotion ? Motion.crossfade : .smooth(duration: 0.25)) {
            if model.fullScreen { updateFullScreenGeometry(answer, style: style, bounds: bounds) }
            model.webHeight = webHeight
            model.surface = .answer(answer, placement, style)
        }
        surfaceChanged()
    }

    static func place(size: CGSize, anchor: Anchor, in bounds: CGRect, style: Placer.Style,
                      scores: SmartPlacement.Scores?) -> Placement {
        if style == .centered { return Placer.place(size: size, anchor: anchor, in: bounds, style: .centered) }
        if anchor.isPage { return SmartPlacement.placeOnPage(size: size, in: bounds, scores: scores) }
        return SmartPlacement.placeNextTo(size: size, anchor: anchor, in: bounds, style: style, scores: scores)
    }

    /// F, ⤢ or Esc in full screen: one continuous morph between the placed card and about
    /// 94% × 90% of the display (FLIP over 500 ms, ease (.2,.9,.25,1)).
    func toggleFullScreen() {
        guard case .answer(let answer, _, let style) = model.surface, style != .chip, !model.folding,
              let id = activeDisplay, let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        let entering = !model.fullScreen
        if entering {
            model.fullScreenContentHeight = nil  // reported afresh at the new width
            updateFullScreenGeometry(answer, style: style, bounds: ScreenSpace.topLeft(screen.visibleFrame))
            Task { await model.web?.allowScrolling() }
        }
        if reduceMotion {
            // A true crossfade: the card is replaced rather than morphed (Reduce Motion).
            withAnimation(Motion.crossfade) {
                model.fullScreen = entering
                model.answerID += 1
            }
        } else {
            withAnimation(Motion.fullScreen) { model.fullScreen = entering }
        }
        surfaceChanged()
        // On the way out, size the card from the content's last known height: if it reflows to
        // the same height it had at full width, no new report comes.
        if !entering, let height = model.web?.contentHeight { relayoutAnswer(webHeight: height) }
    }

    /// The full-screen frame and the web area inside it: as tall as its content at the full
    /// width, up to the space left (then it scrolls), so the actions sit right under it. In
    /// the transcript (earlier turns) it is the content's whole height, and the transcript scrolls.
    private func updateFullScreenGeometry(_ answer: Answer, style: Placer.Style, bounds: CGRect) {
        let frame = Placer.fullScreenFrame(in: bounds)
        let chrome = measure(answer, style: style, width: frame.width, webHeight: 0).height
        model.fullScreenFrame = frame
        // No web view (no or empty card_html): no web area, rather than a blank band.
        guard let web = model.web else {
            model.fullScreenWebHeight = 0
            return
        }
        let content = model.fullScreenContentHeight ?? web.contentHeight ?? model.webHeight
        // With earlier turns the transcript scrolls, so the card takes its whole height.
        model.fullScreenWebHeight = answer.earlier.isEmpty
            ? Self.fullScreenWebHeight(available: frame.height - chrome - 12, content: content)
            : Self.transcriptWebHeight(content: content)
    }

    /// Until the web view reports its height at the full width, the card's own height stands in.
    static func fullScreenWebHeight(available: CGFloat, content: CGFloat) -> CGFloat {
        max(80, min(available, content))
    }

    static func transcriptWebHeight(content: CGFloat) -> CGFloat { max(80, content) }

    /// The snapshot, if it shows the anchor's display as it is now: the same display and
    /// the same frame (a resolution or arrangement change since the capture gives wrong
    /// pixels), and the anchor on it.
    static func usableSnapshot(_ snapshot: DisplaySnapshot?, for anchor: Anchor, displayID: UInt32,
                               displayFrame: CGRect) -> DisplaySnapshot? {
        guard let snapshot, snapshot.displayID == displayID, snapshot.frame == displayFrame,
              snapshot.frame.contains(CGPoint(x: anchor.rect.midX, y: anchor.rect.midY)) else { return nil }
        return snapshot
    }

    static func usableSnapshot(_ snapshot: DisplaySnapshot?, for anchor: Anchor, on screen: NSScreen) -> DisplaySnapshot? {
        usableSnapshot(snapshot, for: anchor, displayID: screen.displayID, displayFrame: ScreenSpace.topLeft(screen.frame))
    }

    /// The listening pill and every status line sit at one fixed spot (top or bottom centre,
    /// Settings › Appearance) on the display under `pointer`, wherever the user's pointer is.
    private func placePill(at pointer: CGPoint, on screen: NSScreen) {
        model.pillBounds = ScreenSpace.topLeft(screen.visibleFrame)
        model.placeStatusPill()
    }

    static func width(for style: Placer.Style) -> CGFloat {
        switch style {
        case .chip: chipMaxWidth
        case .card: cardWidth
        case .centered: richWidth
        }
    }

    /// The pointer, global top-left. Injectable so click-through can be tested.
    var pointerLocation: () -> CGPoint = { ScreenSpace.topLeft(NSEvent.mouseLocation) }

    /// Makes every panel click-blocking, as if the pointer had just been over a surface (tests).
    func makePanelsBlockClicksForTesting() { for panel in panels.values { panel.ignoresMouseEvents = false } }
    var anyPanelBlocksClicksForTesting: Bool { panels.values.contains { !$0.ignoresMouseEvents } }
    /// What a mouse move does: re-evaluate click-through at `pointerLocation` (tests).
    func pointerMovedForTesting() { updateClickThrough() }

    /// Whether every visible panel lets clicks through (tests).
    var allVisiblePanelsClickThroughForTesting: Bool { panels.values.filter(\.isVisible).allSatisfy(\.ignoresMouseEvents) }

    /// Panels currently on screen, and installed peek monitors (tests).
    var visiblePanelCountForTesting: Int { panels.values.filter(\.isVisible).count }
    var peekMonitorCountForTesting: Int { peekMonitors.count }

    /// Whether the panel may take keyboard focus now (tests).
    var focusableForTesting: Bool { panels.values.contains { $0.acceptsFocus } }

    func measureForTesting(_ answer: Answer, style: Placer.Style, webHeight: CGFloat = 0) -> CGSize {
        return measure(answer, style: style, width: Self.width(for: style), webHeight: webHeight)
    }

    // MARK: Panels and screens

    /// A display to fall back on, or nil when none is attached (e.g. asleep with the lid shut).
    static var fallbackScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    enum DisplayRecheck: Equatable {
        case unchanged
        /// Use display `id`; `gone` when the captured one was removed (re-centre the anchor).
        case changed(id: CGDirectDisplayID, gone: Bool)
        case noScreens
    }

    /// Whether the display chosen before an await is still there, as it was.
    nonisolated static func recheckDisplay(captured: CGDirectDisplayID, capturedFrame: CGRect,
                                           live: [(id: CGDirectDisplayID, frame: CGRect)],
                                           main: CGDirectDisplayID?) -> DisplayRecheck {
        guard let first = live.first else { return .noScreens }
        if let same = live.first(where: { $0.id == captured }) {
            return same.frame == capturedFrame ? .unchanged : .changed(id: captured, gone: false)
        }
        let fallback = live.first(where: { $0.id == main }) ?? first
        return .changed(id: fallback.id, gone: true)
    }

    @discardableResult
    private func activate(screenContaining point: CGPoint) -> NSScreen {
        let screen = ScreenSpace.screen(containing: point) ?? Self.fallbackScreen!
        activate(screen)
        return screen
    }

    private func activate(_ screen: NSScreen) {
        let panel = ensurePanel(for: screen)
        model.screenFrame = ScreenSpace.topLeft(screen.frame)
        activeDisplay = screen.displayID
        // The caller sets the surface next; surfaceChanged() then refreshes every panel.
        panel.orderFrontRegardless()
    }

    /// Each display's panel is up only while it shows something: the pill or answer on the
    /// active display, the capsule on the display with the active menu bar.
    private func refreshPanels() {
        for (id, panel) in panels {
            let shows = model.displayFrames[id].map { model.shows(onDisplay: $0) } ?? false
            if shows {
                if !panel.isVisible {
                    panel.ignoresMouseEvents = true  // click-through until the pointer is over something
                    panel.orderFrontRegardless()
                }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    /// The panel for a display, created on first use, with its frames recorded.
    @discardableResult
    private func ensurePanel(for screen: NSScreen) -> OverlayPanel {
        let panel = panels[screen.displayID] ?? makePanel(for: screen)
        let frame = ScreenSpace.topLeft(screen.frame)
        model.displayFrames[screen.displayID] = frame
        panel.fit(to: screen)
        return panel
    }

    // MARK: Toasts and conversation chips

    public func showToast(_ text: String, at pointer: CGPoint) {
        guard Self.fallbackScreen != nil else { return }  // no display attached
        let origin = placeNearPointer(pointer, offset: Placer.toastOffset, size: model.toastSize)
        let toast = OverlayModel.Toast(text: text, origin: origin)
        model.toastBounds = visibleBounds(containing: pointer)
        withAnimation(.easeOut(duration: 0.15)) { model.toast = toast }
        AccessibilityNotification.Announcement(text).post()
        refreshPanels()
        surfaceChanged()
        let lasts = toastDuration ?? Self.toastDuration(for: text)
        // Near an edge the toast can be clamped under a pointer that hasn't moved: only a pointer
        // that moved onto it (to read it) holds it.
        let shownAt = pointerLocation()
        Task { [weak self] in
            try? await Task.sleep(for: lasts)
            // Held while the pointer rests on it, up to a cap so it can't stick.
            var held: Duration = .zero
            while let self, self.model.toast?.id == toast.id, held < Self.toastHoverCap,
                  case let p = self.pointerLocation(), p != shownAt, self.toastFrame.contains(p) {
                try? await Task.sleep(for: .milliseconds(100))
                held += .milliseconds(100)
            }
            guard let self, self.model.toast?.id == toast.id else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.model.toast = nil }
            try? await Task.sleep(for: .milliseconds(220))
            self.refreshPanels()
            self.surfaceChanged()
        }
    }

    public func showBackChip(title: String, at pointer: CGPoint) {
        guard Self.fallbackScreen != nil else { return }  // no display attached
        showConversationChip(.back, title: title, at: pointer, lasts: backChipDuration)
    }

    public func showResumeChip(title: String, detail: String?, at pointer: CGPoint) {
        guard Self.fallbackScreen != nil else { return }  // no display attached
        showConversationChip(.resume, title: title, detail: detail, at: pointer, lasts: nil)
    }

    public func hideConversationChip() {
        guard model.conversationChip != nil else { return }
        withAnimation(.easeIn(duration: 0.2)) { model.conversationChip = nil }
        removeMonitors(&chipMonitors)
        // Let the fade finish before a panel with nothing else on it is ordered out.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, self.model.conversationChip == nil else { return }
            self.refreshPanels()
            self.surfaceChanged()
        }
    }

    /// A toast's time on screen: 1.4 s for up to three words, then 0.25 s a word, at most 4 s,
    /// so a longer line can be read. Nil: by length; tests set a fixed one.
    var toastDuration: Duration?
    static func toastDuration(for text: String) -> Duration {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let ms = 1400 + 250 * max(0, words - 3)
        return .milliseconds(min(ms, 4000))
    }
    /// How long a hovered toast may stay past its time.
    static let toastHoverCap: Duration = .seconds(10)
    private var toastFrame: CGRect {
        guard let toast = model.toast else { return .null }
        return CGRect(origin: toast.origin, size: model.toastSize)
    }
    /// The ↩ Back chip lasts 8 s. Adjustable for tests.
    var backChipDuration: Duration = .seconds(8)
    func chipClickedForTesting(_ event: OverlayEvent) { handleViewEvent(event) }

    private func showConversationChip(_ kind: OverlayModel.ConversationChip.Kind, title: String, detail: String? = nil,
                                      at pointer: CGPoint, lasts: Duration?) {
        let origin = placeNearPointer(pointer, offset: Placer.backChipOffset, size: model.conversationChipSize)
        let chip = OverlayModel.ConversationChip(kind: kind, title: title, detail: detail, origin: origin)
        model.conversationChipBounds = visibleBounds(containing: pointer)
        withAnimation(.smooth(duration: 0.25)) { model.conversationChip = chip }
        installChipClickAway()
        refreshPanels()
        surfaceChanged()
        guard let lasts else { return }
        Task { [weak self] in
            try? await Task.sleep(for: lasts)
            guard let self, self.model.conversationChip?.id == chip.id else { return }
            self.hideConversationChip()
        }
    }

    /// A point near the pointer, kept 12 pt inside its display; creates that display's panel.
    private func placeNearPointer(_ pointer: CGPoint, offset: CGSize, size: CGSize) -> CGPoint {
        let screen = ScreenSpace.screen(containing: pointer) ?? Self.fallbackScreen!
        ensurePanel(for: screen)
        return Placer.pillFrame(size: size, pointer: pointer, in: ScreenSpace.topLeft(screen.visibleFrame), offset: offset).origin
    }

    private func visibleBounds(containing pointer: CGPoint) -> CGRect {
        ScreenSpace.topLeft((ScreenSpace.screen(containing: pointer) ?? Self.fallbackScreen!).visibleFrame)
    }

    private func installChipClickAway() {
        guard chipMonitors.isEmpty else { return }
        if let g = globalMonitor(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hideConversationChip() }
        }) { chipMonitors.append(g) }
    }

    // MARK: Edge strengthening

    public func updateBackdrop(_ snapshot: DisplaySnapshot) { sampleBackdrop(snapshot) }

    /// Samples the 24 pt ring around the visible surface and updates the hysteresis.
    private func sampleBackdrop(_ snapshot: DisplaySnapshot?) {
        // Increase Contrast uses the stronger tokens and turns sampling off.
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return setBright(false) }
        guard let snapshot,
              let frame = model.hitFrames.first, snapshot.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
        if luminance?.image !== snapshot.image {
            guard let map = try? LuminanceMap.make(snapshot.image) else { return }
            luminance = (snapshot.image, map)
        }
        guard let value = luminance?.map.ringLuminance(around: frame, snapshot: snapshot) else { return }
        setBright(brightness.update(luminance: value, at: .now))
    }

    private func setBright(_ bright: Bool) {
        guard bright != model.brightBackdrop else { return }
        withAnimation(.easeInOut(duration: 0.3)) { model.brightBackdrop = bright }
    }

    /// A new surface in a new place starts a fresh decision rather than inheriting the last
    /// one (the dwell only applies to samples of the same surface over time).
    private func resetBrightness() {
        brightness.reset()
        setBright(false)
    }

    // MARK: Rings

    public func showRings(_ rings: [Ring]) {
        guard model.settings.rings else { return }  // "Rings on screen" is off
        // A caret has zero width and still gets a ring (padded); only invalid rects are dropped.
        let valid = rings.filter { !$0.rect.isNull && !$0.rect.isInfinite }
        guard !valid.isEmpty else { return }
        for ring in valid {
            if let screen = ScreenSpace.screen(containing: CGPoint(x: ring.rect.midX, y: ring.rect.midY)) { ensurePanel(for: screen) }
        }
        let added = valid.map { OverlayModel.ActiveRing(ring: $0) }
        withAnimation(.easeOut(duration: 0.3)) {
            // A spot rung again (a jump to it) restarts its ring rather than stacking a second wash.
            model.rings.removeAll { shown in valid.contains { $0.rect == shown.ring.rect } }
            model.rings.append(contentsOf: added)
        }
        refreshPanels()
        let ids = Set(added.map(\.id))
        let duration = ringDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.3)) { self.model.rings.removeAll { ids.contains($0.id) } }
            try? await Task.sleep(for: .milliseconds(320))
            self.refreshPanels()
        }
    }

    /// Jump and clause rings last 6 s (3 s was too short to find them). Adjustable for tests.
    var ringDuration: Duration = .seconds(6)
    /// How long a card's HTML may take to load and report its height before it shows with a
    /// scrolling area instead. Fixed and generous, so a slower Mac doesn't fall back for a card
    /// that was only slow to lay out. The coordinator's presentWait sits just above it.
    static let cardLoadBudget: Duration = .milliseconds(1500)
    /// "Listening" shows this long before the hint (2 s). Injectable so tests don't race the clock.
    var listeningHintDelay: Duration = .seconds(2)

    /// Lets an over-tall card's HTML scroll. Never awaited while presenting: a hung web
    /// process must not keep the card from appearing. Injectable for that test.
    var scrollingEnabler: @MainActor (CardWebContent) async -> Void = { await $0.allowScrolling() }

    private func enableScrolling(_ content: CardWebContent) {
        let enable = scrollingEnabler
        Task { await enable(content) }
    }

    // MARK: Copy

    /// The clipboard; tests inject a recording one.
    var clipboard: any ClipboardWriting = SystemClipboard()

    public func copyAnswer() {
        guard case .answer(let answer, _, _) = model.surface else { return }
        copy(AnswerClipboard.contents(for: answer.block))
    }

    /// A code or draft block's own Copy in the card.
    func copyBlock(_ text: String) {
        copy(ClipboardContents(plain: text, html: nil))
    }

    private func copy(_ contents: ClipboardContents) {
        guard !contents.plain.isEmpty else { return }
        clipboard.write(contents)
        showToast("Copied", at: pointerLocation())
    }

    // MARK: Dragging

    /// A new conversation: the pill and answers go back to their fixed spot and placement mode.
    public func resetPositions() {
        dragStart = nil
        model.pillDrag = .zero
        model.answerOrigin = nil
        model.placeStatusPill()
    }

    /// One gesture's starting state, keyed by where it started: SwiftUI never ends a gesture
    /// whose view went away (the pill became the card, a dismiss), so a new start re-captures.
    private var dragStart: (target: DragTarget, at: CGPoint, pill: CGSize, answer: CGPoint?, capsule: CGSize)?
    private var dragging: Bool { dragStart != nil }

    /// The user drags a surface by its background or rim (buttons, links and fields keep their
    /// clicks). It follows the pointer live, so click-through always matches what's on screen;
    /// where it ends up holds for the rest of the conversation (the capsule: while it shows).
    func drag(_ target: DragTarget, _ phase: DragPhase, translation: CGSize, startedAt: CGPoint = .zero) {
        if dragStart.map({ $0.target != target || $0.at != startedAt }) ?? true {
            guard phase == .changed else { dragStart = nil; return }
            let answerOrigin: CGPoint? = if case .answer(_, let p, _) = model.surface { p.frame.origin } else { nil }
            dragStart = (target, startedAt, model.pillDrag, answerOrigin, model.capsuleDrag)
        }
        guard let start = dragStart else { return }
        defer {
            if phase == .ended {
                dragStart = nil
                updateClickThrough()
            }
        }
        switch target {
        case .pill:
            guard model.surface.isPill else { return }
            model.pillDrag = CGSize(width: start.pill.width + translation.width, height: start.pill.height + translation.height)
            model.placeStatusPill()
            // Kept clamped, so dragging back from an edge moves at once (no dead zone).
            let unmoved = model.pillOrigin
            model.pillDrag = .zero
            let home = model.statusPillOrigin(size: model.pillSize, in: model.pillBounds)
            model.pillDrag = CGSize(width: unmoved.x - home.x, height: unmoved.y - home.y)
            model.pillOrigin = unmoved
        case .answer:
            guard !model.fullScreen, !model.folding, case .answer(let answer, var placement, let style) = model.surface,
                  let origin = start.answer else { return }
            let bounds = NSScreen.screens.first { $0.displayID == activeDisplay }
                .map { ScreenSpace.topLeft($0.visibleFrame) } ?? model.screenFrame
            let moved = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
            placement.frame.origin = OverlayModel.clamp(moved, size: placement.frame.size, in: bounds)
            placement.tailOffset = nil  // moved off its anchor: no tail
            model.answerOrigin = placement.frame.origin
            recalledAnswer = nil  // moved by hand: the drag spot rules from now on
            model.surface = .answer(answer, placement, style)
        case .capsule:
            guard model.capsuleVisible else { return }
            model.capsuleDrag = CGSize(width: start.capsule.width + translation.width, height: start.capsule.height + translation.height)
            let shown = model.capsuleFrame.origin
            model.capsuleDrag = .zero
            let home = model.capsuleFrame.origin
            model.capsuleDrag = CGSize(width: shown.x - home.x, height: shown.y - home.y)
            model.placeStatusPill()  // the pill clears the capsule only at its home spot
        }
        surfaceChanged()
    }

    /// The answer's placement: where the user dragged answers in this conversation, else the mode's.
    private func placeAnswer(_ answer: Answer, size: CGSize, anchor: Anchor, in bounds: CGRect, style: Placer.Style,
                             scores: SmartPlacement.Scores?) -> Placement {
        // A recalled answer goes back where it was, chips too, without its tail.
        if answer == recalledAnswer, let origin = recentPlacements.last(where: { $0.answer == answer })?.origin,
           bounds.contains(origin) {
            let frame = CGRect(origin: OverlayModel.clamp(origin, size: size, in: bounds), size: size)
            return Placement(frame: frame, edge: .centered, tailOffset: nil, avoidsAnchor: !frame.intersects(anchor.rect))
        }
        // Chips always stay next to what was asked about; a spot on another display doesn't apply.
        if style != .chip, let origin = model.answerOrigin, bounds.contains(origin) {
            let frame = CGRect(origin: OverlayModel.clamp(origin, size: size, in: bounds), size: size)
            return Placement(frame: frame, edge: .centered, tailOffset: nil, avoidsAnchor: !frame.intersects(anchor.rect))
        }
        return Self.place(size: size, anchor: anchor, in: bounds, style: style, scores: scores)
    }

    // MARK: Research capsule

    public func updateCapsule(_ jobs: [CapsuleState]) {
        let previous = Dictionary(model.capsules.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        if !jobs.isEmpty, let screen = ScreenSpace.menuBarScreen {
            ensurePanel(for: screen)
            model.capsuleScreenFrame = ScreenSpace.topLeft(screen.frame)
            model.capsuleBounds = ScreenSpace.topLeft(screen.visibleFrame)
        }
        // One nudge when a job finishes.
        let finished = jobs.contains { job in
            job.status == .done && previous[job.id].map { $0 != .done } == true
        }
        withAnimation(.smooth(duration: 0.25)) {
            model.capsules = jobs
            // The peek follows its job: close it when that job is gone or can't be peeked.
            if model.peekOpen, !(model.peekJob.map { Self.peekable($0) } ?? false) { model.peekOpen = false }
        }
        if !model.peekOpen { removeMonitors(&peekMonitors) }
        if jobs.isEmpty { model.capsuleDrag = .zero }
        if finished { model.capsuleNudge += 1 }
        model.placeStatusPill()  // at the top, the pill sits below the capsule
        refreshPanels()
        surfaceChanged()
    }

    static func peekable(_ job: CapsuleState) -> Bool {
        switch job.status {
        case .queued, .running, .failed: true
        case .done, .cancelled: false
        }
    }

    /// Click on the capsule: a finished job opens its report; otherwise the peek toggles.
    func capsuleTapped() {
        guard let job = model.displayedCapsule else { return }
        if job.status == .done {
            model.peekOpen = false
            removeMonitors(&peekMonitors)
            continuation.yield(.openReport(job.id))
        } else if Self.peekable(job) {
            withAnimation(.smooth(duration: 0.2)) {
                model.peekJobID = job.id
                model.peekOpen.toggle()
            }
            if model.peekOpen { installPeekClickAway() } else { removeMonitors(&peekMonitors) }
            updateClickThrough()
        }
    }

    private func installPeekClickAway() {
        guard peekMonitors.isEmpty else { return }
        if let g = globalMonitor(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.peekOpen else { return }
                withAnimation(.smooth(duration: 0.2)) { self.model.peekOpen = false }
                self.removeMonitors(&self.peekMonitors)
                self.updateClickThrough()
            }
        }) { peekMonitors.append(g) }
    }

    private func makePanel(for screen: NSScreen) -> OverlayPanel {
        let root = OverlayRootView(model: model, displayID: screen.displayID,
                                   onEvent: { [weak self] in self?.handleViewEvent($0) },
                                   onClose: { [weak self] in self?.dismiss(.closeButton) },
                                   onToggleFullScreen: { [weak self] in self?.toggleFullScreen() },
                                   onSubmit: { [weak self] in self?.submit($0) },
                                   onCapsuleTap: { [weak self] in self?.capsuleTapped() },
                                   onDrag: { [weak self] in self?.drag($0, $1, translation: $2, startedAt: $3) },
                                   onCopy: { [weak self] in self?.copyAnswer() })
        let panel = OverlayPanel(screen: screen, displayID: screen.displayID, root: root)
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onFocusChange = { [weak self] focused in self?.focusChanged(focused) }
        panels[screen.displayID] = panel
        return panel
    }

    private func screensChanged() {
        let live = Set(NSScreen.screens.map(\.displayID))
        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
            model.displayFrames[id] = nil
        }
        for screen in NSScreen.screens where panels[screen.displayID] != nil {
            model.displayFrames[screen.displayID] = ScreenSpace.topLeft(screen.frame)
            panels[screen.displayID]?.fit(to: screen)
        }
        // The capsule follows the active menu bar.
        if model.capsuleVisible { updateCapsule(model.capsules) }
        guard let active = activeDisplay, model.surface != .none else { return }
        let screen: NSScreen
        if let same = NSScreen.screens.first(where: { $0.displayID == active }) {
            screen = same
        } else if let main = NSScreen.main ?? NSScreen.screens.first {
            // The display went away: continue on the main display, near its centre.
            screen = main
            let centre = ScreenSpace.topLeft(main.visibleFrame)
            let point = CGPoint(x: centre.midX, y: centre.midY)
            if model.surface.isAnswer { model.anchor = (model.anchor?.isPage ?? false) ? .page(point) : .point(point) }
        } else {
            return
        }
        // The snapshot showed the display as it was; its scores no longer map.
        if screen.displayID != active || ScreenSpace.topLeft(screen.frame) != model.screenFrame { model.scores = nil }
        activate(screen)
        // Resolution or visible-frame changes: keep everything inside the display.
        model.pillBounds = ScreenSpace.topLeft(screen.visibleFrame)
        model.placeStatusPill()
        relayoutAnswer()
    }

    /// Drops the answer's state (web view, full screen, brightness) without ordering panels.
    private func clearAnswer() {
        model.web?.tearDown()
        model.web = nil
        model.webHeight = 0
        model.reply = ""
        model.fullScreen = false
        model.scores = nil
        model.speaking = false
        model.speech = 0
        removeMonitors(&clickAwayMonitors)
    }

    private func finishFold() {
        model.foldScale = Motion.foldScale  // a tuck's speck size never carries over
        model.surface = .none
        model.folding = false
        model.web?.tearDown()
        model.web = nil
        model.webHeight = 0
        model.reply = ""
        model.draft = ""
        model.fullScreen = false
        model.scores = nil
        model.speaking = false
        model.speech = 0
        model.brightBackdrop = false
        brightness.reset()
        luminance = nil
        activeDisplay = nil
        refreshPanels()
        surfaceChanged()
    }

    private func cancelFold() {
        guard model.folding else { return }
        // Interrupting a fold into listening drops that listening too, or the flag would stay
        // set and keep the Esc tap on (and make the next dismiss cut instead of fold).
        foldingIntoListening = false
        foldTask?.cancel()
        finishFold()
    }

    /// Events from the views. A conversation chip hides once clicked.
    private func handleViewEvent(_ event: OverlayEvent) {
        if event == .backToPrevious || event == .resumeConversation { hideConversationChip() }
        continuation.yield(event)
    }

    func focusChanged(_ focused: Bool) {
        model.hasFocus = focused
        // AppKit may make the first text field first responder when the panel becomes key.
        // A voice card the user clicked keeps focus on the card, so F and 1–3 act as
        // commands until they click "Reply…".
        if focused, model.surface.isAnswer, !model.typed, let id = activeDisplay, let panel = panels[id] {
            panel.makeFirstResponder(panel.contentView)
        }
        publishWantsEscape()
    }

    /// Keys while the focused panel is key. Never global.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !model.folding, !event.isARepeat else { return false }
        // While an input method is composing, every key (Esc included) belongs to it.
        let editor = event.window?.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return false }
        if case .textBox = model.surface {
            // Only Esc is ours in the text box; ↵ and typing go to the field.
            guard event.keyCode == KeyCommand.escapeKeyCode,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            dismiss(.escape)
            return true
        }
        guard case .answer(let answer, _, let style) = model.surface else { return false }
        let main = answer.block.needsApproval ? nil : answer.mainAction
        let command = KeyCommand.map(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                     modifiers: event.modifierFlags, plainKeysActive: editor == nil,
                                     // Only the actions on screen: a chip shows one, an approval card two beside Cancel.
                                     actionCount: AnswerContent.shownActions(answer.block, isChip: style == .chip, mainAction: main).count,
                                     mainAction: main)
        switch command {
        case .escape:
            if model.fullScreen { toggleFullScreen() } else { dismiss(.escape) }
        case .toggleFullScreen:
            guard style != .chip else { return false }
            toggleFullScreen()
        case .copy:
            // Text selected in the card's HTML: the web view copies that selection itself.
            if event.window?.firstResponder is WKWebView { return false }
            copyAnswer()
        case .event(let e):
            continuation.yield(e)
        case nil:
            return false
        }
        return true
    }

    // MARK: Click-through, click-away, app switch

    /// Called after every surface change, so click-through is right even when the pointer
    /// doesn't move (e.g. a card grows under a still pointer).
    private func surfaceChanged() {
        refreshPanels()
        publishWantsEscape()
        updateFocusability()
        if model.surface == .none { removeMonitors(&clickAwayMonitors) }
        guard model.surface != .none || model.capsuleVisible || model.conversationChip != nil else {
            removeMonitors(&pointerMonitors)
            removeMonitors(&peekMonitors)
            // Nothing clickable is left (rings never take clicks): every panel lets clicks
            // through, or one left click-blocking would swallow clicks until it orders out.
            for panel in panels.values where !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        if pointerMonitors.isEmpty {
            // Mouse monitors need no permission. AppKit calls them on the main thread.
            let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            if let g = globalMonitor(matching: types, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.updateClickThrough() }
            }) { pointerMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] e in
                MainActor.assumeIsolated { self?.updateClickThrough() }
                return e
            }) { pointerMonitors.append(l) }
        }
        updateClickThrough()
    }

    private func updateClickThrough() {
        // Mid-drag the surface may lag the pointer or stop at an edge; the panel keeps the drag.
        guard !dragging else { return }
        let p = pointerLocation()
        for (id, panel) in panels where panel.isVisible {
            guard let frame = model.displayFrames[id] else { continue }
            var frames = model.hitFrames(onDisplay: frame)
            // While folding, the answer no longer takes clicks; the capsule and peek still do.
            if model.folding, frame == model.screenFrame { frames = model.capsuleHitFrames(onDisplay: frame) }
            let inside = frames.contains { $0.contains(p) }
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        }
    }

    private func installClickAway() {
        guard clickAwayMonitors.isEmpty else { return }
        // Clicks over our surfaces reach the panel; anything the global monitor sees is
        // a click in another app, i.e. outside the overlay.
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = globalMonitor(matching: types, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedAway() }
        }) { clickAwayMonitors.append(g) }
    }

    /// Awaits the answer being placed (tests).
    func presentationFinished() async { await answerTask?.value }

    private func clickedAway() {
        guard model.surface.isAnswer || model.surface == .textBox else { return }
        dismiss(.clickAway)
    }

    /// The active menu bar can move with the frontmost app or the Space.
    private func replaceCapsule() {
        if model.capsuleVisible { updateCapsule(model.capsules) }
    }

    private func appActivated() {
        replaceCapsule()
        hideConversationChip()
        guard model.surface.isAnswer || model.surface == .textBox else { return }
        dismiss(.appSwitched)
    }

    private func removeMonitors(_ monitors: inout [Any]) {
        for m in monitors where !(m is InertMonitor) { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func publishWantsEscape() {
        let now = wantsEscape
        guard now != lastWantsEscape else { return }
        lastWantsEscape = now
        continuation.yield(.wantsEscape(now))
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
