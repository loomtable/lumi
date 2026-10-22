import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import CoreGraphics
import Foundation

// The coordinator talks to every module through these ports, so the whole flow runs in tests
// with fakes. Live adapters live in `LiveAdapters.swift`.

/// Mic, transcription, speech and sounds. Mirrors BuddyVoice's `VoiceController`; the transcript
/// only ever travels from `finishListening` to the bridge and is never shown.
public protocol VoicePort: AnyObject, Sendable {
    /// Loads and warms the speech models. Listening before it finishes fails with a true line.
    func prepare() async throws
    func startListening() async throws
    /// Finalises on the send gesture and returns the transcript ("" when nothing was said).
    func finishListening() async throws -> String
    /// Esc. More than 30 s of speech needs `confirmed: true` (safeguards).
    func discard(confirmed: Bool, playSound: Bool) async -> VoiceDiscard
    /// Sends a recording kept after an auto-stop; nil when nothing is held.
    func sendHeld() async throws -> String?
    /// Stops listening and keeps the recording (screen lock, sleep, screen sharing, typing).
    func interrupt(_ reason: ListenInterruption) async
    /// Settings › Sounds; gates every sound the voice plays.
    func setSoundsEnabled(_ enabled: Bool) async
    /// Returns once playback starts; false when it was skipped (user talking, recording held).
    /// `continuing`: the next piece of the reply in flight, queued after it instead of cutting it
    /// off (a stopped reply isn't revived: it returns false). With nothing in flight it starts one.
    @discardableResult func speak(_ text: String, continuing: Bool) async throws -> Bool
    func stopSpeaking() async
    func play(_ sound: BuddySound) async
    /// Mic and reply levels (0...1, envelopes applied) for the dots, rim and glow.
    var levels: AsyncStream<VoiceLevel> { get }
    var events: AsyncStream<VoiceEvent> { get }
}

extension VoicePort {
    /// A new reply: cuts whatever is speaking.
    @discardableResult public func speak(_ text: String) async throws -> Bool {
        try await speak(text, continuing: false)
    }
}

/// A voice failure with a line that's true to show the user.
public struct VoicePortError: Error, Sendable, Equatable {
    public var message: String
    /// The speech models are still loading: the buddy key then shows the real progress.
    public var stillSettingUp: Bool
    /// No voice setup chosen yet: nothing was downloaded, and Settings › Voice sets it up.
    public var notSetUp: Bool
    public init(_ message: String, stillSettingUp: Bool = false, notSetUp: Bool = false) {
        self.message = message
        self.stillSettingUp = stillSettingUp
        self.notSetUp = notSetUp
    }
}

/// Why listening was stopped from outside (safeguards).
public enum ListenInterruption: Sendable, Equatable {
    case screenLocked, systemSleep, screenSharing, typing
    /// Esc on a long recording: stop the mic and keep it while asking to confirm.
    case confirmingDiscard
}

public enum VoiceDiscard: Sendable, Equatable {
    case discarded
    case needsConfirmation(speechSeconds: Double)
    case nothingToDiscard
}

public enum VoiceLevel: Sendable, Equatable {
    case mic(Double)
    case reply(Double)
}

public enum VoiceEvent: Sendable, Equatable {
    /// Listening stopped by itself (silence, length limit, lock, typing...). Nothing is sent;
    /// `held` is true when the recording was kept for the user to send or discard.
    case autoStopped(held: Bool, message: String?)
    case micProblem(String)
    /// Microphone access is off (the trace notes it; the listen ends with `.autoStopped`).
    case permissionDenied
    case speakingFinished
    /// 1:45 of listening; the voice stops recording at 2:00 (safeguards).
    case nearLimit
    /// Where loading the speech models is (setup chip), with the downloader's real progress.
    case setup(VoiceController.PrepareState)
    /// The transcript is taking a while: the thinking pill says "Transcribing…" (over 1.5 s), then
    /// "Still transcribing… Esc to cancel" (`long`, over 10 s).
    case transcribing(long: Bool)
}

/// The context packet and screenshot, captured while the user speaks.
public protocol ContextPort: Sendable {
    func capture() async -> SummonContext
    func screenshot(displayID: UInt32?) async -> ShotOutcome
    /// The model's image shows the front window (`focus`), or the whole display when
    /// `ModelRegion.choose` says so.
    func screenshot(displayID: UInt32?, focus: ModelRegion.Focus?) async -> ShotOutcome
}

extension ContextPort {
    public func screenshot(displayID: UInt32?, focus: ModelRegion.Focus?) async -> ShotOutcome {
        await screenshot(displayID: displayID)
    }
}

/// A screenshot, or why there isn't one (it goes in the packet as `screenshot_unavailable`).
public enum ShotOutcome: Sendable, Equatable {
    case shot(CapturedShot)
    case unavailable(ContextPacket.ScreenshotUnavailable)

    public var shot: CapturedShot? { if case .shot(let s) = self { s } else { nil } }
    public var unavailable: ContextPacket.ScreenshotUnavailable? { if case .unavailable(let u) = self { u } else { nil } }
}

/// The summon's packet, plus the front app's process for locating points in its window.
public struct SummonContext: Sendable, Equatable {
    public var result: ContextResult
    /// Nil unless the packet was built (never for a blocked app).
    public var pid: Int32?

    public init(result: ContextResult, pid: Int32? = nil) {
        self.result = result
        self.pid = pid
    }
}

/// What the coordinator needs from a screenshot: a path for the packet and bytes for the model.
public struct CapturedShot: Sendable, Equatable {
    public var path: String
    public var data: Data
    public var mediaType: String
    /// The full capture, for OCR when locating points. Nil in tests.
    public var screenshot: Screenshot?
    /// The close-up around the selected text, sent as a second image.
    public var detail: ScreenshotDetail?

    public init(path: String, data: Data, mediaType: String, screenshot: Screenshot? = nil, detail: ScreenshotDetail? = nil) {
        self.path = path
        self.data = data
        self.mediaType = mediaType
        self.screenshot = screenshot
        self.detail = detail
    }

    /// The file is the identity; `screenshot` is the same capture in memory.
    public static func == (a: CapturedShot, b: CapturedShot) -> Bool {
        a.path == b.path && a.data == b.data && a.mediaType == b.mediaType
    }
}

/// Finds an answer's `points` quotes on screen for the one-shot rings. Only when
/// an answer has points: AX first, OCR of the summon screenshot only for quotes AX can't find,
/// so OCR no longer competes with speech for the Neural Engine on every summon.
public protocol LocatePort: Sendable {
    /// Where each quote is in `pid`'s window, in input order. Quotes it can't find are left out.
    func locate(_ quotes: [String], pid: Int32, shot: CapturedShot?) async -> [LocatedPoint]
}

/// Runs a question through Quick and Deep.
public protocol BridgePort: Sendable {
    func ask(_ question: Question, state: ConversationState) async -> AsyncStream<CascadeEvent>
    func goDeeper(_ question: Question, state: ConversationState) async -> AsyncStream<CascadeEvent>
    func cancel(conversation: String) async
}

/// Inserts drafts into the user's app.
@MainActor public protocol InsertPort: AnyObject {
    /// Into `pid`'s focused field (the app the user summoned in; our card may be key). Returns a
    /// short, true description of what happened, or nil on success.
    func insert(_ text: String, into pid: Int32?) async -> String?
}

/// Consumes Esc while a card or the pill is visible (scoped event tap).
public protocol EscapePort: Sendable {
    func activate() throws -> AsyncStream<Void>
    func deactivate()
}

/// Background Research jobs and their capsule. Real: `ResearchController`.
@MainActor public protocol ResearchPort: AnyObject {
    /// Called with a job that finished with its report: play the chime and speak its line.
    var onDone: ((ResearchJob) -> Void)? { get set }
    /// Subscribes to job updates; call once.
    func activate()
    @discardableResult func start(_ request: ResearchRequest) async -> ResearchJob
    /// The capsule's own events (Stop, open the report). True when it handled `event`.
    @discardableResult func handle(_ event: OverlayEvent) async -> Bool
}

extension ResearchController: ResearchPort {}

/// What the shell offers after the conversation changed under the user.
public enum ConversationNotice: Sendable, Equatable {
    /// Started fresh on request: "↩ Back to '…'" for 8 s.
    case back(title: String)
    /// Started fresh after the idle limit: "Resume '…' · yesterday" until the next summon.
    case resume(id: String, title: String, lastUsed: Date)
}

/// One conversation as the coordinator uses it (Conversations).
public struct ConversationTurn: Sendable, Equatable {
    public var state: ConversationState
    public var color: ConversationColor
    /// Completed turns; the header says "new" for the first answer, then "continuing · N".
    public var turn: Int
    /// The last three turns as "Q: …\nA: …", for Quick follow-ups.
    public var previous: [String]
    /// Every finished turn, oldest first, the one just recorded included: full screen's transcript.
    /// Empty when the port doesn't keep them.
    public var turns: [TranscriptTurn]
    /// Set by the call that started this conversation fresh, when there's one to go back to.
    public var notice: ConversationNotice?

    public init(state: ConversationState, color: ConversationColor, turn: Int, previous: [String],
                turns: [TranscriptTurn] = [], notice: ConversationNotice? = nil) {
        self.state = state
        self.color = color
        self.turn = turn
        self.previous = previous
        self.turns = turns
        self.notice = notice
    }
}

/// The current conversation and its turns. Real: the shell's index over BuddyConversations.
/// Default: `MemoryConversations`.
///
/// Contract the coordinator relies on:
/// - Calls take effect in the order they're made, even if they suspend (e.g. a serial queue),
///   so a question asked right after ⌘N lands in the new conversation, and a stale `.done`'s
///   `update` can't roll back a newer one.
/// - `current` reflects each call's change by the time that call returns.
@MainActor public protocol ConversationPort: AnyObject {
    /// Cached, so Esc, Go deeper and typed replies read it without a suspension point.
    var current: ConversationTurn? { get }
    /// The conversation the next question belongs to: continue, or fresh after the idle limit or
    /// when a different project is in front. Updates `current`.
    func prepare(project: String?) async -> ConversationTurn
    /// Session ids and last lane from the cascade's `.done`; ignored unless `state.id` is current.
    func update(_ state: ConversationState) async
    /// A finished turn; nil when that conversation is no longer current (⌘N meanwhile).
    func recordTurn(conversationID: String, question: String, answer: String) async -> ConversationTurn?
    /// The same, with the whole turn for the transcript: the result's `turns` end with `turn`.
    /// By default it records the text only, so a port that keeps no transcript needs nothing new.
    func record(_ turn: TranscriptTurn, conversationID: String) async -> ConversationTurn?
    /// ⌘N, ＋ or "new topic".
    @discardableResult func startNew() async -> ConversationTurn
    /// "↩ Back" or "go back": the conversation before the last ⌘N, while its window is open.
    /// Nil when there's nothing to go back to.
    func goBack() async -> ConversationTurn?
    /// The Resume chip: that conversation is current from the next question. Nil if it's gone.
    func switchTo(_ id: String) async -> ConversationTurn?
    /// The summon screenshot a turn of `conversationID` was asked with, so Forget deletes it.
    func recordScreenshot(_ path: String, conversationID: String) async
}

extension ConversationPort {
    public func goBack() async -> ConversationTurn? { nil }
    public func switchTo(_ id: String) async -> ConversationTurn? { nil }
    public func recordScreenshot(_ path: String, conversationID: String) async {}

    public func record(_ turn: TranscriptTurn, conversationID: String) async -> ConversationTurn? {
        await recordTurn(conversationID: conversationID, question: turn.question, answer: turn.block.say)
    }
}

/// In memory only, for tests and until the index is wired in: `ConversationBook`'s rules.
@MainActor public final class MemoryConversations: ConversationPort {
    private var book: ConversationBook

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        book = ConversationBook(clock: clock)
    }

    public var current: ConversationTurn? { book.current.map(Self.turn) }
    public func prepare(project: String?) async -> ConversationTurn { Self.turn(book.prepare(project: project)) }
    public func update(_ state: ConversationState) async { book.update(state) }
    public func recordTurn(conversationID: String, question: String, answer: String) async -> ConversationTurn? {
        book.recordTurn(conversationID: conversationID, question: question, answer: answer).map(Self.turn)
    }
    public func record(_ turn: TranscriptTurn, conversationID: String) async -> ConversationTurn? {
        book.recordTurn(conversationID: conversationID, question: turn.question, answer: turn.block.say, transcript: turn)
            .map(Self.turn)
    }
    @discardableResult public func startNew() async -> ConversationTurn { Self.turn(book.startNew()) }

    private static func turn(_ c: ConversationBook.Conversation) -> ConversationTurn {
        ConversationTurn(state: c.state, color: c.color, turn: c.turn, previous: c.previous, turns: c.turns)
    }
}

/// The opt-in trace log: kinds, timings and counts only, never text. Real: `TraceLog`.
public protocol TracePort: Sendable {
    func record(_ event: TraceEvent, duration: Duration?, lane: Mode?, outcome: TraceOutcome?, count: Int?)
}

extension TraceLog: TracePort {}

/// Where the pointer is, in global points with a top-left origin.
public protocol PointerPort: Sendable {
    func location() -> CGPoint
}
