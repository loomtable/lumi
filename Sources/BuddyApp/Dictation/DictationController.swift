import AppKit
import BuddyAct
import BuddyCompanion
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import CoreGraphics

/// Types dictated text where the user is: into Lumi's composer when it has the keyboard, else at
/// the cursor of the app in front (paste-first). Real: `LiveDictationInserter`.
@MainActor
public protocol DictationInserting: AnyObject {
    func insert(_ text: String, into pid: Int32?) async -> InsertResult
    /// Puts the words on the clipboard when they couldn't be typed, so nothing said is lost.
    func copy(_ text: String)
}

/// A Lumi composer that can take dictated words directly (the Studio window's). Lumi's own window
/// can't be pasted into (`InsertResult.refusedOwnApp`), so its composers take the text instead.
@MainActor
public protocol DictationComposer: AnyObject {
    /// True while this composer has the keyboard.
    var composerIsKey: Bool { get }
    func insertIntoComposer(_ text: String)
}

/// The dictation key (10-ENGINEERING §1.11): tap to start and tap again (or hold and release),
/// and the words are typed at the cursor. Nothing goes to Claude: this type has no turn or
/// session port at all.
///
/// - `began` (on the press for fn, 120 ms into a clean press for ⌘ and other chord keys, so ⌘C
///   never lights the mic: `DictationKeyGate`): listen now, as a dictation (no stop on silence,
///   chunked transcription). The pill says "Dictating" with the time so far, over an answer too
///   (it closes the answer, which comes back the usual way). Ignored unless the
///   coordinator is idle or showing an answer: the mic has one owner, and the talk key wins.
/// - `latched` (toggle: a clean tap): keep listening; the pill says how to stop.
/// - `ended` (the stop tap, or a release after a hold): finish, then insert; nothing heard is a toast.
/// - `cancelled` (Esc, another key during a hold, the key monitor stopping) and a listen the voice
///   ended itself (the 60-minute limit, sleep, a mic failure): finish, keep the words in Dictation
///   history, type nothing, and say where they are.
/// - `discarded` (a short press in hold mode, a ⌘ shortcut): drop the audio, type nothing. A bare
///   short press says how hold mode works, at most once per 30 s.
///
/// - A press while an answer is on its way says so and types nothing (V-10).
///
/// Every transcript is kept in `history` (Settings › Privacy applies), typed or not, so nothing
/// said is lost (owner, Oct 29), except words refused by a password field, which are never kept.
@MainActor
public final class DictationController {
    public enum State: Equatable {
        case idle
        case listening(Listen)
        case finishing
    }

    public struct Listen: Equatable {
        /// The app in front at the press: the words go there.
        public var pid: Int32?
        public var startedAt: ContinuousClock.Instant
        /// Toggle: a clean tap; the next tap stops it.
        public var latched = false
        /// The voice said its length limit is near.
        public var nearLimit = false
    }

    public private(set) var state: State = .idle {
        didSet { if state == .idle, oldValue != .idle { onIdle?() } }
    }
    /// The dictation is over: the coordinator's ready answers may play again.
    public var onIdle: (@MainActor () -> Void)?
    /// A turn is running in front: move it behind, as a new talk-key press does (V-02), so its
    /// answer waits as a Ready capsule. False when it can't (sessions off): the press is refused.
    public var moveTurnBehind: (@MainActor () -> Bool)?
    /// While true the buddy key is ignored (the coordinator asks).
    public var isActive: Bool { state != .idle }

    private let voice: any VoicePort
    private let overlay: any OverlayPresenting
    private let inserter: any DictationInserting
    /// Lumi's Panel, once the conversation stream sets it: its composer takes the words directly.
    public var panel: (any PanelPresenting)?
    /// The Studio window's composer (Home or the open session page), set by the studio stream.
    public var studio: (any DictationComposer)?
    /// Any other Lumi field with the keyboard (Glance reply, search, rename, Settings), U64. The
    /// runtime sets the live one; nil types nothing in process.
    public var ownField: (any OwnTextInserting)?
    /// The Lumi field that had the keyboard at this dictation's press (before the pill took it).
    private var ownTarget: OwnFieldTarget?
    /// Where every transcript is kept; nil keeps none (and says nothing about it).
    public var history: DictationHistory?
    /// Shows a line with a button that opens Dictation history; nil shows a plain toast.
    public var showSaved: (@MainActor (String) -> Void)?
    /// Tells the key monitor the dictation ended without the key (Esc to Lumi's own Esc tap, or
    /// the voice stopping it), so the next tap starts a new one.
    public var endGesture: (@MainActor () async -> Void)?
    /// The dictation key, for the pill's "tap fn to stop".
    public var dictationKey: @MainActor () -> BuddyKey? = { nil }
    private let pointer: any PointerPort
    private let tracer: (any TracePort)?
    /// The coordinator's phase, read at each press.
    private let coordinatorPhase: @MainActor () -> BuddyCoordinator.Phase
    private let frontmostPID: @MainActor () -> Int32?
    private let appName: @MainActor (Int32?) -> String?
    private let now: @MainActor () -> ContinuousClock.Instant
    private let date: @MainActor () -> Date
    /// When the short-press hint last showed.
    private var hintShownAt: ContinuousClock.Instant?
    static let hintInterval: Duration = .seconds(30)
    /// Updates the pill's clock once a second.
    private var ticker: Task<Void, Never>?

    static let copiedLine = "Couldn't type it here. It's on your clipboard."
    static let copiedSavedLine = "Couldn't type it here. It's copied and saved in Dictation history."
    static let heardNothingLine = "Didn't catch that."
    static let cancelledLine = "Cancelled. Saved in Dictation history."
    static let stoppedLine = "Dictation stopped. Saved in Dictation history."
    static let answeringLine = "Lumi is answering. Dictate when it's done."
    static let secureLine = "Not saved: Lumi doesn't type into password fields."

    public init(
        voice: any VoicePort, overlay: any OverlayPresenting, inserter: any DictationInserting,
        panel: (any PanelPresenting)? = nil, pointer: any PointerPort, tracer: (any TracePort)? = nil,
        history: DictationHistory? = nil,
        coordinatorPhase: @escaping @MainActor () -> BuddyCoordinator.Phase,
        frontmostPID: @escaping @MainActor () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        appName: @escaping @MainActor (Int32?) -> String? = { pid in
            pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        date: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.voice = voice
        self.overlay = overlay
        self.inserter = inserter
        self.panel = panel
        self.pointer = pointer
        self.tracer = tracer
        self.history = history
        self.coordinatorPhase = coordinatorPhase
        self.frontmostPID = frontmostPID
        self.appName = appName
        self.now = now
        self.date = date
    }

    public func handle(_ gesture: DictationGesture) async {
        switch gesture {
        case .began: await begin()
        case .latched: latch()
        case .ended: await finish(.insert)
        case .cancelled(let why): await finish(.keep(Self.traceReason(why), line: why == .escape ? Self.cancelledLine : Self.stoppedLine))
        case .discarded(let why): await discard(why)
        }
    }

    /// Esc while dictating, through Lumi's own Esc tap (it takes Esc while the pill shows, so the
    /// key monitor never sees it).
    public func cancel() async {
        guard case .listening = state else { return }
        await finish(.keep(.escape, line: Self.cancelledLine))
        await endGesture?()
    }

    /// The voice ended the listen itself (`VoiceEvent.autoStopped`): its 60-minute limit, sleep,
    /// a locked screen or a mic failure. What was heard is kept, never typed blind.
    public func voiceStopped(message: String?) async {
        guard case .listening = state else { return }
        await finish(.keep(.autoStop, line: message.map { "\($0) \(Self.savedSuffix)" } ?? Self.stoppedLine))
        await endGesture?()
    }

    static let savedSuffix = "What you said is in Dictation history."

    /// `VoiceEvent.nearLimit`: the pill says when it stops.
    public func voiceNearLimit() {
        guard case .listening(var listen) = state else { return }
        listen.nearLimit = true
        state = .listening(listen)
        refreshHint()
    }

    private func begin() async {
        guard state == .idle else { return }
        var phase = coordinatorPhase()
        // A running turn never blocks dictation (65-SURFACE-RULES C).
        if phase == .thinking, moveTurnBehind?() == true { phase = .idle }
        guard phase == .idle || phase == .showing else {
            // While an answer is on its way the press would do nothing at all: say why (V-10). The
            // talk key's own listen, the text box and a held recording need no line.
            if phase == .thinking { overlay.showToast(Self.answeringLine, at: pointer.location()) }
            return
        }
        let listen = Listen(pid: frontmostPID(), startedAt: now())
        // Now, before the mic, the pill or an overlay can take Lumi's keyboard (U64).
        ownTarget = ownField?.capture()
        state = .listening(listen)
        do {
            try await voice.startDictation()
        } catch {
            state = .idle
            overlay.showToast((error as? VoicePortError)?.message ?? "The microphone didn't start.", at: pointer.location())
            await endGesture?()
            return
        }
        guard case .listening = state else { return }  // ended while the mic started
        // Over an answer too: a dictation can run for minutes, so the pill and its clock show it
        // the whole time. The answer closes as for the talk key, and comes back the usual way.
        // Dictation isn't a session: the pill shows no session orb or title.
        overlay.setPillTarget(.none)
        overlay.showListening(at: pointer.location(), hint: hint(for: listen))
        startTicker()
    }

    private func latch() {
        guard case .listening(var listen) = state else { return }
        listen.latched = true
        state = .listening(listen)
        refreshHint()
    }

    private enum Ending {
        /// Type the words (and keep them).
        case insert
        /// Keep them in history only, and say so with `line`.
        case keep(TraceReason, line: String)
    }

    private func finish(_ ending: Ending) async {
        guard case .listening(let listen) = state else { return }
        state = .finishing
        stopTicker()
        defer { state = .idle }
        // Read before finishing: after it the voice is no longer listening and reports 0.
        let heard = await voice.heardSpeechSeconds()
        let text: String
        do {
            text = try await voice.finishListening().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            overlay.dismiss(.requested)
            overlay.showToast((error as? VoicePortError)?.message ?? "Dictation didn't work. Try again.", at: pointer.location())
            return
        }
        overlay.dismiss(.requested)
        switch ending {
        case .keep(let reason, let line):
            tracer?.record(.dictationInserted, duration: nil, outcome: .cancelled, reason: reason)
            guard !text.isEmpty else { return }
            keep(text, status: .notInserted, pid: listen.pid)
            say(history == nil ? nil : line, saved: true)
        case .insert:
            // Heard nothing (QA U44): say so, and count it, rather than end in silence. `ms` is the
            // speech the VAD heard: 0 means the mic got nothing, more means the transcript was empty.
            guard !text.isEmpty else {
                tracer?.record(.dictationInserted, duration: .seconds(heard), lane: nil, outcome: .skipped, count: 0)
                overlay.showToast(Self.heardNothingLine, at: pointer.location())
                return
            }
            await insert(text, listen: listen)
        }
    }

    private func insert(_ text: String, listen: Listen) async {
        if let panel, panel.composerIsKey {
            panel.insertIntoComposer(text)
            inserted(text, app: BuddyCore.appName)
            return
        }
        if let studio, studio.composerIsKey {
            studio.insertIntoComposer(text)
            inserted(text, app: BuddyCore.appName)
            return
        }
        // Lumi's own field with the keyboard: typed in here (Lumi can't paste into itself).
        let target = ownTarget
        ownTarget = nil
        let own = ownField?.insert(text, into: target) ?? .none
        if own == .inserted {
            inserted(text, app: BuddyCore.appName)
            return
        }
        let pid = listen.pid
        // A Lumi field that's gone (`.lost`) counts as focus moved: copied and kept, never pasted
        // into the app behind (QA gate 4.5).
        let result: InsertResult = switch own {
        case .secure: .refusedSecureField
        case .lost: .focusChanged
        case .inserted, .none: await inserter.insert(text, into: pid)
        }
        let outcome = Self.outcome(result)
        if let reason = Self.failureReason(result) {
            tracer?.record(.dictationInserted, duration: nil, outcome: outcome, reason: reason)
        } else {
            tracer?.record(.dictationInserted, duration: nil, lane: nil, outcome: outcome, count: text.count)
        }
        // A password field's words are never kept (lead, Oct 29: privacy over "never lose speech").
        let kept = result != .refusedSecureField && history != nil
        if result != .refusedSecureField { keep(text, status: outcome == .ok ? .inserted : .notInserted, pid: pid) }
        say(Self.problem(for: result, text: text, inserter: inserter, saved: kept), saved: kept && outcome != .ok)
    }

    private func inserted(_ text: String, app: String) {
        tracer?.record(.dictationInserted, duration: nil, lane: nil, outcome: .ok, count: text.count)
        history?.add(DictationRecord(date: date(), text: text, appName: app, status: .inserted))
    }

    private func keep(_ text: String, status: DictationRecord.Status, pid: Int32?) {
        history?.add(DictationRecord(date: date(), text: text, appName: appName(pid), status: status))
    }

    /// A line after the dictation: with the button to Dictation history when the words were kept
    /// there and not typed.
    private func say(_ line: String?, saved: Bool) {
        guard let line else { return }
        if saved, history != nil, let showSaved {
            showSaved(line)
        } else {
            overlay.showToast(line, at: pointer.location())
        }
    }

    private func discard(_ why: DictationDiscard) async {
        guard case .listening = state else { return }
        state = .idle
        stopTicker()
        _ = await voice.discard(confirmed: true, playSound: false)
        overlay.dismiss(.requested)
        // The mic did start: count it, with why (QA U43), e.g. a ⌘ held past the arming delay
        // before a shortcut.
        let (reason, held) = Self.traceReason(why)
        tracer?.record(.dictationInserted, duration: held, outcome: .cancelled, reason: reason)
        // A bare tap of the key in hold mode: say how it works. Never after a shortcut, a key or a click.
        if case .shortPress(let key, _) = why, hintShownAt.map({ now() - $0 >= Self.hintInterval }) ?? true {
            hintShownAt = now()
            overlay.showToast(Self.holdHint(key), at: pointer.location())
        }
    }

    // MARK: The pill

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refreshHint()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// The pill's line, now.
    func refreshHint() {
        guard case .listening(let listen) = state else { return }
        overlay.updateListeningHint(hint(for: listen))
    }

    private func hint(for listen: Listen) -> String {
        Self.hint(elapsed: now() - listen.startedAt, latched: listen.latched, nearLimit: listen.nearLimit, key: dictationKey())
    }

    /// "Dictating 0:42 · tap fn to stop", "Dictating 0:03 · release to type", and near the limit
    /// "Dictating 58:10 · stops at 60:00".
    static func hint(elapsed: Duration, latched: Bool, nearLimit: Bool, key: BuddyKey?) -> String {
        let how: String
        if nearLimit {
            how = "stops at 60:00"
        } else if latched {
            how = key.map { "tap \(DictationKeyResolver.name($0)) to stop" } ?? "tap again to stop"
        } else {
            how = "release to type"
        }
        return "Dictating \(clock(elapsed)) · \(how)"
    }

    /// m:ss, or h:mm:ss past an hour.
    static func clock(_ elapsed: Duration) -> String {
        let total = max(0, Int(elapsed.components.seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        let ss = s < 10 ? "0\(s)" : "\(s)"
        guard h > 0 else { return "\(total / 60):\(ss)" }
        return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)"
    }

    static func holdHint(_ key: BuddyKey) -> String {
        "Hold \(DictationKeyResolver.name(key)) and speak, release to type."
    }

    static func traceReason(_ why: DictationDiscard) -> (TraceReason, Duration?) {
        switch why {
        case .shortPress(_, let held): (.release, .nanoseconds(Int64(clamping: held)))
        case .interrupted(let reason): (traceReason(reason), nil)
        }
    }

    static func traceReason(_ why: DictationCancel) -> TraceReason {
        switch why {
        case .escape: .escape
        case .interrupted(let reason): traceReason(reason)
        }
    }

    static func traceReason(_ reason: CancelReason) -> TraceReason {
        switch reason {
        case .otherKey(let code): .otherKey(CancelReason.loggableKeyCode(code))
        case .otherModifier: .otherModifier
        case .mouseDown: .click
        case .scroll: .scroll
        case .tapInterrupted: .tapInterrupted
        }
    }

    static func outcome(_ result: InsertResult) -> TraceOutcome {
        switch result {
        case .insertedViaAccessibility, .insertedViaAccessibilityUnverified, .pasted: .ok
        default: .failed
        }
    }

    /// Why the words didn't go in, for the trace (kinds only, never text); nil when they did.
    static func failureReason(_ result: InsertResult) -> TraceReason? {
        switch result {
        case .insertedViaAccessibility, .insertedViaAccessibilityUnverified, .pasted: nil
        case .noFocusedField: .noField
        case .focusChanged: .focusChanged
        case .refusedSecureField: .secureField
        case .refusedBlockedApp: .blockedApp
        case .refusedOwnApp: .ownApp
        case .refusedMultilineInTerminal: .multilineTerminal
        case .refusedEmptyText: .emptyText
        case .pasteUnconfirmed: .pasteUnconfirmed
        case .pasteFailed: .pasteFailed
        case .busy: .busy
        }
    }

    /// The line after an insert, or nil when the words went in. Words that couldn't be typed go on
    /// the clipboard, except where they must not: a password field or a blocked app. `saved`: they
    /// are in Dictation history too, and the line says so.
    static func problem(for result: InsertResult, text: String, inserter: any DictationInserting, saved: Bool = false) -> String? {
        switch result {
        case .insertedViaAccessibility, .insertedViaAccessibilityUnverified, .pasted, .refusedEmptyText:
            return nil
        case .pasteUnconfirmed:
            return LiveInserter.problem(for: result)
        case .refusedSecureField:
            return secureLine
        case .refusedBlockedApp:
            return LiveInserter.problem(for: result).map { saved ? "\($0) \(savedSuffix)" : $0 }
        case .refusedOwnApp, .noFocusedField, .focusChanged, .pasteFailed, .busy, .refusedMultilineInTerminal:
            inserter.copy(text)
            return saved ? copiedSavedLine : copiedLine
        }
    }
}

/// Paste-first insertion (`InsertMode.dictation`) and the clipboard fallback.
@MainActor
public final class LiveDictationInserter: DictationInserting {
    private let inserter: TextInserter

    public init(inserter: TextInserter) {
        self.inserter = inserter
    }

    public func insert(_ text: String, into pid: Int32?) async -> InsertResult {
        await inserter.insert(text, into: pid, mode: .dictation)
    }

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
