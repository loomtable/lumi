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

/// Mic, transcription, speech and sounds. Mirrors BuddyVoice's `VoiceController`; a question's
/// transcript only ever travels from `finishListening` to the bridge and is never shown. A
/// dictation's goes to the cursor and to Dictation history.
public protocol VoicePort: AnyObject, Sendable {
    /// Loads and warms the speech models. Listening before it finishes fails with a true line.
    func prepare() async throws
    func startListening() async throws
    /// A dictation's listen: no stop on silence, a 60-minute limit, transcribed in chunks.
    func startDictation() async throws
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
    /// Seconds of speech the VAD has heard in the current listen; 0 when not listening.
    func heardSpeechSeconds() async -> Double
}

extension VoicePort {
    /// Fakes: a dictation listens like a question.
    public func startDictation() async throws { try await startListening() }

    /// Fakes and voices without a VAD hear nothing.
    public func heardSpeechSeconds() async -> Double { 0 }

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

/// Runs a question through Quick and Deep. Every bridge is a `TurnPort` for cascade turns.
public protocol BridgePort: TurnPort {
    func ask(_ question: Question, state: ConversationState) async -> AsyncStream<CascadeEvent>
    func goDeeper(_ question: Question, state: ConversationState) async -> AsyncStream<CascadeEvent>
    func cancel(conversation: String) async
}

/// One user turn for `TurnPort`: Quick/Deep through the cascade, or an open session's turn.
public struct TurnRequest: Sendable {
    public enum Target: Sendable {
        /// Quick first, as `BridgePort.ask`.
        case cascade
        /// Straight to Deep, as `BridgePort.goDeeper`.
        case deeper
        /// One turn in an open session (the session engine).
        case session(SessionID, SessionLaunch)
    }

    public var question: Question
    public var state: ConversationState
    public var kind: TurnKind
    public var target: Target
    /// A Quick or v1 session continued as an open one: its recap, for the first message.
    public var seed: String?
    /// Files the user attached in a page's composer (Panel, Studio), for a typed open-session turn.
    public var attachments: [TurnAttachment]

    public init(question: Question, state: ConversationState, kind: TurnKind, target: Target, seed: String? = nil,
                attachments: [TurnAttachment] = []) {
        self.question = question
        self.state = state
        self.kind = kind
        self.target = target
        self.seed = seed
        self.attachments = attachments
    }
}

public enum TurnStreamEvent: Sendable, Equatable {
    case cascade(CascadeEvent)
    case session(SessionEvent)
}

/// Runs user turns: the cascade's lanes and, once the engine lands, open sessions.
public protocol TurnPort: Sendable {
    func send(_ request: TurnRequest) async -> AsyncStream<TurnStreamEvent>
    func cancel(conversation: String) async
}

/// The sessions the switcher, capsules, Studio and attention read and act on. Real: `LiveSessions`.
@MainActor public protocol SessionsPort: AnyObject {
    /// Every session that isn't forgotten, most recently used first.
    var snapshots: [SessionSnapshot] { get }
    var current: SessionID? { get }
    /// Sessions a Lumi page or the Glance shows now: their answers are already seen.
    var onScreen: Set<SessionID> { get }
    /// The snapshots now, then after every change.
    func changes() -> AsyncStream<[SessionSnapshot]>
    /// The next summon continues `id`.
    func setCurrent(_ id: SessionID) async
    func setPinned(_ pinned: Bool, for id: SessionID) async
    func setArchived(_ archived: Bool, for id: SessionID) async
    /// Locks the title against automatic re-titling.
    func rename(_ id: SessionID, to title: String) async
    /// Deletes the session, its Claude sessions' transcripts and its screenshots.
    func forget(_ id: SessionID) async throws
    /// One event from the session's stream: status, live line, teammates.
    func apply(_ event: SessionEvent, to id: SessionID)
    /// A Lumi page (Panel, Studio) started or stopped showing a session: seen, kept warm, and
    /// continued by a summon soon after.
    func pageShown(_ id: SessionID, kind: PageKind)
    func pageHidden(_ id: SessionID, kind: PageKind)
}

extension SessionsPort {
    public var onScreen: Set<SessionID> { [] }
    public func pageShown(_ id: SessionID, kind: PageKind) {}
    public func pageHidden(_ id: SessionID, kind: PageKind) {}
}

/// The Lumi pages on screen (Panel, Studio), for routing a talk-key turn into the page.
@MainActor public protocol PageSurfaces: AnyObject {
    var visiblePage: (id: SessionID, kind: PageKind)? { get }
}

/// No page on screen: the stub until the Panel and Studio land.
@MainActor public final class NoPageSurfaces: PageSurfaces {
    public init() {}
    public var visiblePage: (id: SessionID, kind: PageKind)? { nil }
}

extension BridgePort {
    /// `.cascade` asks, `.deeper` goes deeper; a session turn has no bridge yet and ends at once.
    public func send(_ request: TurnRequest) async -> AsyncStream<TurnStreamEvent> {
        let stream: AsyncStream<CascadeEvent>
        switch request.target {
        case .cascade: stream = await ask(request.question, state: request.state)
        case .deeper: stream = await goDeeper(request.question, state: request.state)
        case .session: return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let relay = Task {
                for await event in stream { continuation.yield(.cascade(event)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
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

    public init(state: ConversationState, color: ConversationColor, turn: Int, previous: [String],
                turns: [TranscriptTurn] = []) {
        self.state = state
        self.color = color
        self.turn = turn
        self.previous = previous
        self.turns = turns
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
    /// The conversation the next question belongs to: continue, or fresh after the idle limit.
    /// Updates `current`.
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
    /// A pick from the history: that conversation is current from the next question. Nil if it's gone.
    func switchTo(_ id: String) async -> ConversationTurn?
    /// The summon screenshot a turn of `conversationID` was asked with, so Forget deletes it.
    func recordScreenshot(_ path: String, conversationID: String) async
}

extension ConversationPort {
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
    /// With why it was dropped. Default: recorded without the reason.
    func record(_ event: TraceEvent, duration: Duration?, outcome: TraceOutcome?, reason: TraceReason)
    /// With a surface's frame (`cardShown`). Default: recorded without it.
    func record(_ event: TraceEvent, frame: CGRect)
}

extension TracePort {
    public func record(_ event: TraceEvent, duration: Duration?, outcome: TraceOutcome?, reason: TraceReason) {
        record(event, duration: duration, lane: nil, outcome: outcome, count: nil)
    }

    public func record(_ event: TraceEvent, frame: CGRect) {
        record(event, duration: nil, lane: nil, outcome: nil, count: nil)
    }
}

extension TraceLog: TracePort {}

/// Where the pointer is, in global points with a top-left origin.
public protocol PointerPort: Sendable {
    func location() -> CGPoint
}
