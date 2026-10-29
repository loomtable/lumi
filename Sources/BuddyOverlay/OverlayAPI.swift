import BuddyCore
import CoreGraphics
import Foundation

/// The lane a question runs in, as shown in the pill's mode chip and the card header
/// ("Quick · Haiku 5.5").
nonisolated public struct Lane: Sendable, Equatable {
    public var mode: Mode
    public var model: ModelID

    public init(mode: Mode, model: ModelID) {
        self.mode = mode
        self.model = model
    }

    public var label: String { "\(mode.displayName) · \(model.displayName)" }
    /// Deep and Research show in ember (Mode chip).
    public var isEmphasized: Bool { mode != .quick }
}

/// One answer to show. Everything here comes from real events: the `buddy` block from the
/// bridge, the lane that produced it and the conversation it belongs to.
nonisolated public struct Answer: Sendable, Equatable {
    public var block: BuddyBlock
    public var lane: Lane
    public var conversation: ConversationColor
    /// 1 for a new conversation; the header then says "new", otherwise "continuing · N".
    public var turn: Int
    /// The reply line hint with the user's bound key ("tap ⌥ to reply · click to type").
    public var replyHint: String
    /// What the user asked for this answer; full screen shows it above the answer.
    public var question: String?
    /// The conversation's earlier turns, oldest first, not including this one. Full screen
    /// shows them above this answer; empty for chips and a conversation's first answer.
    public var earlier: [TranscriptTurn]
    /// The conversation's context has grown past the point where answers slow down: the header
    /// says so ("continuing · 12 · long").
    public var isLong: Bool
    /// The one primary button, chosen by the shell from what was captured at summon (Insert
    /// into the field you were typing in, Replace an editable selection, else Copy). Nil: the
    /// model's first action is primary, as before.
    public var mainAction: MainAction?
    /// An open session's voice turn that did work worth reviewing (an edit, an approval or a
    /// teammate): its step count, so ⤢ Continue reads "6 steps" (04 §3.3). Nil: "Continue".
    public var reviewSteps: Int?
    /// False for chips the app shows itself (setup, Fix, voice not set up): they are never
    /// recalled, so they don't take up the overlay's remembered spots.
    public var keepsPlacement: Bool

    public init(block: BuddyBlock, lane: Lane, conversation: ConversationColor, turn: Int, replyHint: String,
                question: String? = nil, earlier: [TranscriptTurn] = [], isLong: Bool = false,
                mainAction: MainAction? = nil, keepsPlacement: Bool = true) {
        self.mainAction = mainAction
        self.keepsPlacement = keepsPlacement
        self.block = block
        self.lane = lane
        self.conversation = conversation
        self.turn = turn
        self.replyHint = replyHint
        self.question = question
        self.earlier = earlier
        self.isLong = isLong
    }

    public var headerLabel: String {
        isLong ? "\(shortHeaderLabel) · long" : shortHeaderLabel
    }

    /// The header label when the header is tight: "long" is dropped first (its toast already
    /// said so), then "continuing · 12" becomes "turn 12", so the turn count never truncates.
    public var shortHeaderLabel: String { turn <= 1 ? "new" : "continuing · \(turn)" }
    public var compactHeaderLabel: String { turn <= 1 ? "new" : "turn \(turn)" }
}

nonisolated public enum DismissReason: String, Sendable, Equatable {
    /// Esc while something is visible. The shell decides what it means (discard while
    /// listening, cancel while thinking, close an answer).
    case escape
    /// A click outside the overlay while an answer is visible.
    case clickAway
    /// The user switched apps while an answer was visible.
    case appSwitched
    /// The ✕ in the card header.
    case closeButton
    /// The shell asked (typing in another app, buddy key pressed with a card open, …).
    case requested
}

/// One research job as the capsule shows it (Background task). The shell maps
/// BuddyBridge's ResearchJob onto it 1:1; every value comes from a real event.
nonisolated public struct CapsuleState: Sendable, Equatable, Identifiable {
    /// Matches BuddyBridge's ResearchPhase raw values.
    public enum Phase: String, Sendable, Equatable {
        case planning, searching, reading, writing

        var label: String {
            switch self {
            case .planning: "Planning"
            case .searching: "Searching"
            case .reading: "Reading"
            case .writing: "Writing"
            }
        }
    }

    public enum Status: Sendable, Equatable {
        /// Waiting for a slot (at most 2 jobs run at a time); not started.
        case queued
        case running(Phase)
        case done
        /// A user-facing line from the bridge.
        case failed(String)
        case cancelled
    }

    public var id: UUID
    public var topic: String
    public var status: Status
    /// Distinct URLs or files read so far; counted only after a read succeeds.
    public var sourceCount: Int
    /// Live steps for the peek, newest last, verbatim from the bridge.
    public var steps: [String]
    /// Claude Code is restarting after a crash ("Reconnecting…").
    public var reconnecting: Bool
    /// finishedAt − startedAt, only when both are known.
    public var duration: TimeInterval?

    public init(id: UUID, topic: String, status: Status, sourceCount: Int = 0, steps: [String] = [],
                reconnecting: Bool = false, duration: TimeInterval? = nil) {
        self.id = id
        self.topic = topic
        self.status = status
        self.sourceCount = sourceCount
        self.steps = steps
        self.reconnecting = reconnecting
        self.duration = duration
    }

    /// The capsule's one line ("Reading · 14 sources", "✓ Report ready · open").
    public var line: String {
        if reconnecting { return "Reconnecting…" }
        switch status {
        case .queued: return "Queued"
        case .running(let phase):
            guard sourceCount > 0 else { return phase.label }
            return "\(phase.label) · \(sourceCount) \(sourceCount == 1 ? "source" : "sources")"
        case .done: return "Report ready · open"
        case .failed: return "Research stopped"
        case .cancelled: return "Cancelled"
        }
    }

    public var isRunning: Bool {
        switch status {
        case .queued, .running: true
        case .done, .failed, .cancelled: false
        }
    }
}

/// A spot on screen to ring for 6 s (One-shot ring): a `points` quote or a jump target,
/// located by BuddyContext (AX, then OCR). Global points, top-left origin.
nonisolated public struct Ring: Sendable, Equatable {
    public var rect: CGRect
    /// The point's label ("1", "2") from the buddy block, shown on the ring.
    public var label: String?

    public init(rect: CGRect, label: String? = nil) {
        self.rect = rect
        self.label = label
    }
}

/// Where typed text came from.
nonisolated public enum SubmitSource: String, Sendable, Equatable {
    /// The double-tap text box at the pointer.
    case textBox
    /// The reply field of a focused card (a follow-up in the same conversation).
    case reply
}

/// What the overlay tells the shell.
/// The card's primary button: one, chosen from the summon's context.
nonisolated public enum MainAction: String, Sendable, Equatable, CaseIterable {
    case insert, replace, copy

    public var label: String {
        switch self {
        case .insert: "Insert"
        case .replace: "Replace"
        case .copy: "Copy"
        }
    }
}

nonisolated public enum OverlayEvent: Sendable, Equatable {
    case dismissed(DismissReason)
    /// The main button, or ⌘↵ when the answer has one.
    case mainAction(MainAction)
    /// The answer's link button ("Open draft · mail.google.com"): the shell opens it in the
    /// default browser. Always an https URL (BuddyBlock.Link refuses anything else); the
    /// overlay never opens it itself, and opening never sends anything.
    case openLink(URL)
    /// An action button: index into `block.actions` (0 is primary).
    case action(index: Int)
    case goDeeper
    case stopSpeaking
    /// ＋ on the card, or ⌘N while the card has focus.
    case newConversation
    /// ⌘Y while the card has focus.
    case openConversations
    /// ⌘, while the card has focus.
    case openSettings
    /// ⇱ on a rich card: continue in the Panel, or with the Panel off, open the Lumi window.
    case popOut
    /// Stop in the capsule's peek.
    case stopResearch(UUID)
    /// A click (or ↵) on a finished capsule: show the report, popping out of the capsule
    /// (`showAnswer(_:anchor: .capsule)`).
    case openReport(UUID)
    /// A click on a progress capsule that needs the user: open its session's approval or question.
    case progressClicked(SessionID)
    /// A "jump" link in a card: locate the point with this label and `showRings` it.
    case jump(label: String)
    /// ↵ in the text box or the reply field. Send it like a transcript.
    case submitted(text: String, source: SubmitSource)
    /// The answer from the last `showAnswer` is on screen (it presents asynchronously: measuring,
    /// card HTML, placement). The shell starts the answer's speech on this, so the voice never
    /// comes before the card.
    case answerPresented
    /// Whether Esc should be captured now (anything visible). The shell turns BuddyKeys'
    /// scoped Esc tap on and off from this, so Esc never leaks into the user's app.
    case wantsEscape(Bool)
}

/// Who the pill talks to: a session's orb and title lead the listening and thinking row
/// (63-SWITCHER-UX), ＋ for a new session, or nothing when the send decides.
public enum PillTarget: Sendable, Equatable {
    case none
    case session(SessionSnapshot)
    case new
}

/// What the user drags.
enum DragTarget: Sendable { case pill, answer, capsule }
enum DragPhase: Sendable { case changed, ended }

/// The overlay surface the shell drives. Implemented by `BuddyOverlayController` and
/// `FakeOverlay`.
@MainActor
public protocol OverlayPresenting: AnyObject {
    var events: AsyncStream<OverlayEvent> { get }
    /// True while Esc should be consumed (pill, chip or card visible).
    var wantsEscape: Bool { get }
    /// Where a tucked answer folds to: the menu-bar Lumi item's frame in AppKit screen
    /// coordinates, read at fold time (the item can move or hide). Nil, or a nil result, means
    /// no visible item. Set by the shell.
    var foldTarget: (@MainActor () -> CGRect?)? { get set }
    /// Called once an answer has folded into `foldTarget` (a click elsewhere, an app switch,
    /// Esc or ✕), so the menu-bar orb can catch it. Set by the shell.
    var onFoldedIntoTarget: (@MainActor () -> Void)? { get set }

    /// The listening pill next to `pointer` (global points, top-left origin). "Listening"
    /// shows for 2 s, then `hint` ("tap ⌥ to send", "release to send").
    func showListening(at pointer: CGPoint, hint: String)
    /// A short toast near the pointer for 1.4 s: "Discarded", "Cancelled", "New
    /// conversation", "Running in the background".
    func showToast(_ text: String, at pointer: CGPoint)
    /// One-shot rings for 6 s. Rects that couldn't be found are simply left out;
    /// an empty list does nothing.
    func showRings(_ rings: [Ring])
    /// The research capsule at top centre on the display with the active menu bar.
    /// Shows the most recent job, with "+1" when another runs. Empty hides it.
    func updateCapsule(_ jobs: [CapsuleState])
    /// The running queries' capsules, stacked and centred at the top of the active display
    /// (under the pill while it sits at the top). Never focused; only a needs-you capsule takes a
    /// click (`.progressClicked`). Empty hides them.
    func updateProgress(_ shown: ProgressStack.Shown)
    /// Changes the listening pill's hint (e.g. "release to send" once a hold begins). The
    /// pill still says "Listening" for its first 2 s; a new hint shows after that.
    func updateListeningHint(_ hint: String)
    /// Whether the mic is live yet. The pill never says "Listening" before it is (the first
    /// words would be lost): no label at first, then "Getting ready…" if it takes a while (a cold
    /// voice-processing start can take over a second). `showListening` starts ready.
    func setMicReady(_ ready: Bool)
    /// The session the pill talks to: its orb and title lead the row. Set at the press, as the
    /// switcher's highlight moves, and once a send is routed.
    func setPillTarget(_ target: PillTarget)
    /// The switcher strip is open around the pill (the pill is its header): the progress
    /// capsules step aside, since the strip shows the same sessions.
    func setSwitcherOpen(_ open: Bool)
    /// ⌘ shortcuts (⌘N, ⌘Y, ⌘,) are card shortcuts and don't act in the text box.
    /// The text box at `pointer` (double-tap): "Ask about this…", ↵ sends, Esc closes.
    /// A visible listening pill morphs into it. The box takes keyboard focus; the user's
    /// app is never activated.
    func showTextBox(at pointer: CGPoint)
    /// The same pill, in place: the mode chip and one status line from a real event.
    func showThinking(_ lane: Lane, status: String?)
    func updateStatus(_ status: String?)
    /// The answer's headline in the pill, before the card: up to two lines, a little heavier.
    /// An answer whose headline matches then shows it at once instead of inking it in again.
    func showHeadline(_ headline: String)
    /// Grows the answer out of the pill, placed per `placementMode` and `Placer`'s rule: next
    /// to `anchor`, or centred. `snapshot` (the anchor's display at summon) tunes the outline
    /// for a bright backdrop.
    func showAnswer(_ answer: Answer, anchor: Anchor, snapshot: DisplaySnapshot?)
    /// Brings back an answer that was closed (click-away, app switch, Esc, ✕): it pops in the
    /// spot where it last sat, without inking in again. An answer this overlay hasn't shown
    /// recently is placed next to `anchor` like a new one.
    func recallAnswer(_ answer: Answer, anchor: Anchor)
    /// Replaces the visible chip's line in place, e.g. live setup progress: no pop, no
    /// ink-in rerun, no re-placement. It keeps its origin and re-measures its width, within the
    /// chip's maximum and the display. Does nothing unless a chip is showing.
    func updateChipText(_ text: String)
    /// Settings › Appearance › Placement (the same as `settings.placement`).
    var placementMode: Placer.Mode { get set }
    /// Settings › Appearance: effects toggles and placement.
    var settings: OverlaySettings { get set }
    /// A new conversation: dragged positions reset (the pill to its fixed spot, answers to the
    /// placement mode). An answer with `turn == 1` also resets them.
    func resetPositions()
    /// Copies the shown answer (its paste text, else the headline and card text, as plain and
    /// rich text) and says "Copied". The card's Copy and ⌘C do this themselves.
    func copyAnswer()
    /// A fresher snapshot of the display behind the overlay, which must exclude the
    /// overlay's own windows (DisplaySnapshot does). Edges strengthen over bright backdrops;
    /// with Increase Contrast this does nothing.
    func updateBackdrop(_ snapshot: DisplaySnapshot)
    /// Mic RMS, 0...1, about every 20 ms while listening. Drives the dots and the rim.
    func setMicLevel(_ level: Double)
    /// Reply audio RMS, 0...1, about every 20 ms while speaking. Drives the glow.
    func setSpeechLevel(_ level: Double)
    /// Shows the header's stop-speaking button while true.
    func setSpeaking(_ speaking: Bool)
    /// Folds whatever is visible back toward its source.
    func dismiss(_ reason: DismissReason)
    /// Gives the visible card keyboard focus (e.g. the question was typed). Clicking a card
    /// does the same. While focused, ⌘N, ⌘Y, ⌘,, ⌘↵, 1–3 and F arrive as events.
    func focusAnswer()
    /// Called by the shell when the scoped Esc tap consumed Esc. Returns false when nothing
    /// was visible (the shell should not have been capturing).
    @discardableResult func handleEscape() -> Bool
    /// An answer is on screen, or on its way there, and not folding away. A `.dismissed` event
    /// that arrives while this is true is about an earlier surface.
    var showsAnswer: Bool { get }
    /// The pointer is on the answer card: the user may be reading or about to click it.
    var pointerOnAnswer: Bool { get }
}

extension OverlayPresenting {
    public func showAnswer(_ answer: Answer, anchor: Anchor) { showAnswer(answer, anchor: anchor, snapshot: nil) }
}

/// A recording fake for the shell's tests.
@MainActor
public final class FakeOverlay: OverlayPresenting {
    public enum Call: Sendable, Equatable {
        case listening(CGPoint, hint: String)
        case textBox(CGPoint)
        case capsule([CapsuleState])
        case rings([Ring])
        case backdrop
        case toast(String)
        case hint(String)
        case thinking(Lane, status: String?)
        case status(String?)
        case headline(String)
        case answer(Answer, Anchor, hasSnapshot: Bool)
        case recall(Answer, Anchor)
        case chipText(String)
        case resetPositions
        case copyAnswer
        case micLevel(Double)
        case speechLevel(Double)
        case speaking(Bool)
        case dismiss(DismissReason)
        case focus
        case escape
    }

    public private(set) var calls: [Call] = []
    /// The progress capsules on screen; kept apart from `calls`, which follow the pill and cards.
    public private(set) var progress: ProgressStack.Shown = .empty
    public private(set) var wantsEscape = false
    /// False: `showAnswer` doesn't report `.answerPresented` by itself; the test sends it, to
    /// play an overlay that presents slowly.
    public var presentsAnswersImmediately = true
    public var foldTarget: (@MainActor () -> CGRect?)?
    public var onFoldedIntoTarget: (@MainActor () -> Void)?
    /// Something is showing (Esc via handleEscape closes it, as in the real overlay).
    private var visible = false
    public private(set) var showsAnswer = false
    public var pointerOnAnswer = false
    public var settings = OverlaySettings()
    public var placementMode: Placer.Mode {
        get { settings.placement }
        set { settings.placement = newValue }
    }
    public let events: AsyncStream<OverlayEvent>
    private let continuation: AsyncStream<OverlayEvent>.Continuation

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: OverlayEvent.self)
    }

    /// Simulates a user interaction (button, click-away) in tests.
    public func send(_ event: OverlayEvent) { continuation.yield(event) }

    private func setWantsEscape(_ on: Bool) {
        guard on != wantsEscape else { return }
        wantsEscape = on
        continuation.yield(.wantsEscape(on))
    }

    public func showListening(at pointer: CGPoint, hint: String) {
        calls.append(.listening(pointer, hint: hint))
        visible = true
        showsAnswer = false
        setWantsEscape(true)
    }
    public func updateCapsule(_ jobs: [CapsuleState]) { calls.append(.capsule(jobs)) }
    public func updateProgress(_ shown: ProgressStack.Shown) { progress = shown }
    public func showRings(_ rings: [Ring]) { calls.append(.rings(rings)) }
    public func updateBackdrop(_ snapshot: DisplaySnapshot) { calls.append(.backdrop) }
    public func showToast(_ text: String, at pointer: CGPoint) { calls.append(.toast(text)) }
    public func updateListeningHint(_ hint: String) { calls.append(.hint(hint)) }
    /// Every `setMicReady`, in order (kept out of `calls`, which tests compare whole).
    public private(set) var micReadyHistory: [Bool] = []
    public func setMicReady(_ ready: Bool) { micReadyHistory.append(ready) }
    public private(set) var pillTargets: [PillTarget] = []
    public private(set) var switcherOpen = false
    public func setPillTarget(_ target: PillTarget) { pillTargets.append(target) }
    public func setSwitcherOpen(_ open: Bool) { switcherOpen = open }
    /// Like the real overlay: the text box takes keyboard focus, so Esc reaches it directly
    /// and the shell's Esc tap stays off.
    public func showTextBox(at pointer: CGPoint) {
        calls.append(.textBox(pointer))
        visible = true
        showsAnswer = false
        setWantsEscape(false)
    }
    public func showThinking(_ lane: Lane, status: String?) {
        calls.append(.thinking(lane, status: status))
        visible = true
        showsAnswer = false
        setWantsEscape(true)
    }
    public func updateStatus(_ status: String?) { calls.append(.status(status)) }
    public func showHeadline(_ headline: String) { calls.append(.headline(headline)) }
    public func showAnswer(_ answer: Answer, anchor: Anchor, snapshot: DisplaySnapshot?) {
        calls.append(.answer(answer, anchor, hasSnapshot: snapshot != nil))
        visible = true
        showsAnswer = true
        setWantsEscape(true)
        if presentsAnswersImmediately { continuation.yield(.answerPresented) }
    }
    public func recallAnswer(_ answer: Answer, anchor: Anchor) {
        calls.append(.recall(answer, anchor))
        visible = true
        showsAnswer = true
        setWantsEscape(true)
        if presentsAnswersImmediately { continuation.yield(.answerPresented) }
    }
    public func updateChipText(_ text: String) { calls.append(.chipText(text)) }
    public func resetPositions() { calls.append(.resetPositions) }
    public func copyAnswer() { calls.append(.copyAnswer) }
    public func setMicLevel(_ level: Double) { calls.append(.micLevel(level)) }
    public func setSpeechLevel(_ level: Double) { calls.append(.speechLevel(level)) }
    public func setSpeaking(_ speaking: Bool) { calls.append(.speaking(speaking)) }
    public func dismiss(_ reason: DismissReason) {
        calls.append(.dismiss(reason))
        let was = visible
        visible = false
        showsAnswer = false
        setWantsEscape(false)
        if was { continuation.yield(.dismissed(reason)) }
    }
    public func focusAnswer() { calls.append(.focus) }
    @discardableResult public func handleEscape() -> Bool {
        calls.append(.escape)
        guard visible else { return false }
        dismiss(.escape)
        return true
    }
}

public extension OverlayPresenting {
    func resetPositions() {}
    func copyAnswer() {}
}
