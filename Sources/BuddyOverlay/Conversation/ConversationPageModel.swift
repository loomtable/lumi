import BuddyCore
import Foundation
import Observation

/// A file, image or screen area attached in the composer (a 32 pt token above the field).
nonisolated public struct PageAttachment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case file, image, screenArea }

    public var url: URL
    public var kind: Kind
    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"]

    /// A dropped or picked file: an image by its extension, else a file.
    public static func file(_ url: URL) -> PageAttachment {
        PageAttachment(url: url, kind: imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .file)
    }
}

/// One composer send.
nonisolated public struct PageSubmit: Sendable, Equatable {
    public var text: String
    /// `.typed`, or `.steer` while a turn runs.
    public var kind: TurnKind
    /// The ▣ chip: re-read the origin window.
    public var withScreen: Bool
    public var attachments: [PageAttachment]
    /// An edited prompt's user uuid: this send replaces it and every turn after it.
    public var replacing: String?

    public init(text: String, kind: TurnKind = .typed, withScreen: Bool = false, attachments: [PageAttachment] = [],
                replacing: String? = nil) {
        self.text = text
        self.kind = kind
        self.withScreen = withScreen
        self.attachments = attachments
        self.replacing = replacing
    }
}

/// An earlier prompt being edited in place: its turn, the new words, whether the one-line
/// "Later replies changed files" note is showing (the next Send goes ahead), and whether Send
/// went and the app is going back (the page changes only once it has).
/// What came of an edited prompt, for each page showing its session.
nonisolated public enum PageEdit: Sendable, Equatable {
    /// The session went back: prompt `prompt` and everything after it are replaced by `question`.
    case applied(prompt: String, question: String)
    /// It couldn't: the page that edited keeps its turns and gets `text` back in its composer.
    case failed(text: String)
}

nonisolated public struct PromptEdit: Sendable, Equatable {
    public var turnID: String
    public var text: String
    public var confirming = false
    public var sending = false
}

/// "Something else…": the composer answers a question card's questions one by one, then sends
/// them together.
nonisolated public struct ComposerAnswer: Sendable, Equatable {
    public var requestID: String
    public var questions: [String]
    public var index = 0
    public var answers: [String: String] = [:]

    /// The question the composer is answering now.
    public var question: String { questions[min(index, questions.count - 1)] }
    /// "2/3" when there's more than one.
    public var step: String? { questions.count > 1 ? "\(index + 1)/\(questions.count)" : nil }
}

/// What the user did on a conversation page (Panel or Studio column).
nonisolated public enum PageAction: Sendable, Equatable {
    /// The composer's send.
    case submit(PageSubmit)
    /// ⌘⇧↩: the text starts a new session that runs in the background; this page stays.
    case submitToNewSession(PageSubmit)
    /// "Started in a new session" pressed: open the session this page last started.
    case openStartedSession
    /// ■ or ⌘. while a turn runs.
    case stop
    /// An approval card. `always`: "Always for this session". `message`: "Tell Lumi something
    /// instead" (deny with a reason).
    case approve(requestID: String, allow: Bool, always: Bool, message: String?)
    /// A question card's choice: question → label(s).
    case answer(requestID: String, answers: [String: String])
    /// A message to a teammate, relayed through the lead ("The user says to @name: …").
    case relay(teammate: String, text: String)
    case stopTeammate(taskID: String)
    /// ◉ pressed or released.
    case mic(down: Bool)
    /// "Continue" on a turn Lumi's quit interrupted: the engine resumes it.
    case continueInterrupted
}

/// The observable page the Panel and the Studio column both render. It owns the pure
/// `ConversationPage`, coalesces streamed text to about 30 Hz and schedules the Trail's
/// verb ticks.
@MainActor @Observable
public final class ConversationPageModel {
    public private(set) var page: ConversationPage
    /// The composer: text, attachments, collapsed pastes, the `/` and `@` menu and ↑/↓ history.
    public let composer = ComposerState()
    /// The composer's text.
    public var draft: String {
        get { composer.text }
        set { composer.text = newValue }
    }
    /// The ▣ chip: each send re-reads the origin window. Off gives "Text only".
    public var withScreen: Bool
    /// The origin app's name for the ▣ chip, when the session started over an app.
    public var screenAppName: String?
    /// The lane that's open (a teammate's task id), or nil for the main thread.
    public var openLane: String?
    /// Settings › Model › "Show thinking".
    public var showThinking = false
    /// The mic is listening (the composer's ember ring).
    public var listening = false
    /// The composer's attachments, sent with the next submit.
    public var attachments: [PageAttachment] {
        get { composer.attachments }
        set { composer.draft.attachments = newValue }
    }
    /// "Something else…" on a question card: the composer answers that question in the user's
    /// own words (AskUserQuestion takes free text) instead of sending a turn.
    public private(set) var answering: ComposerAnswer?
    /// Bumped to move keyboard focus into the composer.
    public private(set) var focusRequest = 0
    /// The earlier prompt being edited, if any.
    public var editing: PromptEdit?
    /// One plain line above the composer (an edit that couldn't go back); cleared by the next send.
    public private(set) var notice: String?

    /// The page is on screen: its window is visible on the active Space and shows this session.
    /// Hosts set it (the Panel, the Studio column); delivered-in-place reads it (04 §3.4 rule 1).
    public var isVisible = false
    /// The current time, advanced by `now()`; the view's TimelineView redraws clocks.
    @ObservationIgnored public var clock: @MainActor () -> Date = { Date() }
    /// Where actions go: the Panel's controller or the Studio's.
    @ObservationIgnored public var onAction: @MainActor (PageAction) -> Void = { _ in }

    @ObservationIgnored private var pendingText: [String?: String] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// About 30 Hz: a burst of deltas is one update.
    public static let textInterval: Duration = .milliseconds(33)

    public init(page: ConversationPage, withScreen: Bool = true, screenAppName: String? = nil) {
        self.page = page
        self.withScreen = withScreen && screenAppName != nil
        self.screenAppName = screenAppName
        composer.history = ComposerHistory(page.turns.map(\.question))
        composer.teammates = { [weak self] in self?.page.teammates.map(\.name) ?? [] }
    }

    public convenience init(snapshot: SessionSnapshot, history: [TranscriptTurn] = []) {
        var page = ConversationPage(snapshot: snapshot)
        page.load(history: history, at: Date())
        page.seed(teammates: snapshot.teammates, live: snapshot.teamLive, at: Date())
        page.seed(ask: snapshot.ask, at: Date())
        if case .interrupted = snapshot.status { page.markInterrupted() }
        self.init(page: page, screenAppName: snapshot.origin?.appName)
    }

    public var session: SessionID { page.session }

    // MARK: Feeding the page

    /// One session event. Text is coalesced; anything else flushes the text first, so order holds.
    public func apply(_ event: SessionEvent) {
        if case .text(let s, let subagent) = event {
            pendingText[subagent, default: ""] += s
            scheduleFlush()
            return
        }
        flushText()
        if case .initialized(let summary) = event, !summary.commands.isEmpty { composer.liveCommands = summary.commands }
        page.apply(event, at: clock())
        scheduleTick()
    }

    public func load(history: [TranscriptTurn]) {
        flushText()
        page.load(history: history, at: clock())
        composer.history = ComposerHistory(page.turns.map(\.question))
    }

    /// Teammates that existed before the page opened, with their lanes' earlier text and steps by
    /// tool use id (TranscriptReader's teammate lanes). Idempotent (QA U30).
    public func seed(teammates: [TeammateSnapshot], live: Bool, lanes: [String: LaneHistory]) {
        flushText()
        page.seed(teammates: teammates, live: live, lanes: lanes, at: clock())
    }

    /// The turn still running when the page opened (QA U7).
    public func showRunning(userUUID: String, question: String, kind: TurnKind, since: Date, live: String?) {
        flushText()
        page.showRunning(userUUID: userUUID, question: question, kind: kind, since: since, live: live)
        scheduleTick()
    }

    /// Earlier lane text and steps for the teammates the page already has (seeded from the snapshot).
    public func seedLanes(_ lanes: [String: LaneHistory]) {
        seed(teammates: page.team.members, live: page.team.isLive, lanes: lanes)
    }

    /// Updates the header from a fresh snapshot.
    public func update(_ snapshot: SessionSnapshot) {
        if case .interrupted = snapshot.status { page.markInterrupted() }
        page.seed(teammates: snapshot.teammates, live: snapshot.teamLive, at: clock())
        page.seed(ask: snapshot.ask, at: clock())
        page.title = snapshot.title
        page.symbol = snapshot.symbol
        page.color = snapshot.color
        if let app = snapshot.origin?.appName { page.subtitle = "From \(app)" }
    }

    /// Adds a turn the coordinator sent for this page (a voice-in-page transcript).
    public func record(question: String, kind: TurnKind, context: ContextStrip?) {
        flushText()
        page.send(question, kind: kind, context: context, at: clock())
    }

    // MARK: User actions

    /// Sends the draft: a new turn, or a steer while one runs.
    public func submit() {
        let text = composer.expandedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notice = nil
        let files = attachments
        // An answer or a relay is text only: the files wait for the next send.
        let textOnly = answering != nil || page.teammates.contains(where: { $0.id == openLane }) || Self.addressed(text, teammates: page.teammates.map(\.name)) != nil
        composer.clear(sent: text, keepAttachments: textOnly)
        if var target = answering {
            target.answers[target.question] = text
            target.index += 1
            if target.index < target.questions.count {
                answering = target // the next question
                focusRequest += 1
            } else {
                answering = nil
                answer(target.requestID, answers: target.answers)
            }
            return
        }
        if let lane = openLane, let mate = page.teammates.first(where: { $0.id == lane }) {
            onAction(.relay(teammate: mate.name, text: text))
            return
        }
        if let (mate, message) = Self.addressed(text, teammates: page.teammates.map(\.name)) {
            onAction(.relay(teammate: mate, text: message))
            return
        }
        flushText()
        let context = page.isRunning ? nil : ContextStrip(appName: screenAppName, readScreen: withScreen)
        let sent = page.send(text, kind: .typed, context: context, at: clock())
        onAction(.submit(PageSubmit(text: text, kind: sent == .steer ? .steer : .typed, withScreen: withScreen,
                                    attachments: files)))
    }

    /// When ⌘⇧↩ last started a session from this page: the "Started in a new session" toast shows
    /// for a few seconds after it. Nil when there's nothing to show.
    public var startedSession: Date?

    /// ⌘⇧↩: the text (and attachments) go to a new session that runs in the background. Nothing
    /// is added to this page; a toast says where it went. Not while answering a question card.
    public func submitToNewSession() {
        let text = composer.expandedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, answering == nil else { return }
        let files = attachments
        composer.clear(sent: text, keepAttachments: false)
        onAction(.submitToNewSession(PageSubmit(text: text, withScreen: withScreen, attachments: files)))
        startedSession = clock()
    }

    /// The toast pressed: that session opens.
    public func openStartedSession() {
        startedSession = nil
        onAction(.openStartedSession)
    }

    // MARK: Editing an earlier prompt

    /// A prompt Lumi sent (it has a user uuid) can be edited while nothing runs on the page.
    public func canEdit(_ turn: PageTurn) -> Bool {
        turn.userUUID != nil && !turn.question.isEmpty && !page.isRunning && openLane == nil && answering == nil
    }

    public func beginEdit(_ turnID: String) {
        guard editing?.sending != true, let turn = page.turns.first(where: { $0.id == turnID }), canEdit(turn) else { return }
        notice = nil
        editing = PromptEdit(turnID: turnID, text: turn.question)
    }

    public func cancelEdit() {
        guard editing?.sending != true else { return }
        editing = nil
    }

    /// Send on the editor: the new words go to the host, which takes the session back to just
    /// before this prompt; the page changes only when it has (`applyEdit`, or `editFailed`). When
    /// this turn or a later one changed files, the first Send only shows that the changes stay;
    /// the next one goes ahead.
    public func sendEdit() {
        guard var edit = editing, !edit.sending, let i = page.turns.firstIndex(where: { $0.id == edit.turnID }),
              canEdit(page.turns[i]), let uuid = page.turns[i].userUUID else { return }
        let text = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !edit.confirming, page.turns[i...].contains(where: \.changedFiles) {
            edit.confirming = true
            editing = edit
            return
        }
        edit.sending = true
        editing = edit
        onAction(.submit(PageSubmit(text: text, kind: .typed, withScreen: withScreen, replacing: uuid)))
    }

    public func apply(_ edit: PageEdit) {
        switch edit {
        case .applied(let prompt, let question): applyEdit(prompt: prompt, question: question)
        case .failed(let text): editFailed(text: text)
        }
    }

    /// The session went back to just before prompt `uuid`: it and every turn after it leave the
    /// page, and `question` starts the turn that replaces them. Every page showing the session gets
    /// this, the one that edited and the other (Panel or Studio).
    public func applyEdit(prompt uuid: String, question: String) {
        flushText()
        let editedHere = editing?.sending == true
        if let i = page.turns.firstIndex(where: { $0.userUUID == uuid }) {
            if let edit = editing, page.turns[i...].contains(where: { $0.id == edit.turnID }) { editing = nil }
            page.rewind(from: page.turns[i].id)
        }
        let context = editedHere ? ContextStrip(appName: screenAppName, readScreen: withScreen) : nil
        page.send(question, kind: .typed, context: context, at: clock())
    }

    /// The edit couldn't go back: the page stays as it was, and the edited words wait in the
    /// composer, so nothing the user wrote is lost.
    public func editFailed(text: String) {
        editing = nil
        draft = text
        notice = Self.editFailedNotice
        focusRequest += 1
    }

    public static let editFailedNotice = "Couldn't edit that message. Your text is in the box."

    /// "@Writer keep it short" → ("Writer", "keep it short") when Writer is one of this session's
    /// teammates (case-insensitive, an optional ":" after the name). Anything else is a normal send.
    nonisolated static func addressed(_ text: String, teammates: [String]) -> (String, String)? {
        guard text.hasPrefix("@") else { return nil }
        let rest = text.dropFirst()
        // Longest name first, so "@Writer 2 hi" picks "Writer 2" over "Writer".
        for name in teammates.sorted(by: { $0.count > $1.count }) where !name.isEmpty {
            guard rest.count > name.count, rest.prefix(name.count).caseInsensitiveCompare(name) == .orderedSame else { continue }
            let after = rest.dropFirst(name.count)
            guard let first = after.first, first == ":" || first == "," || first.isWhitespace else { continue }
            let message = after.drop(while: { $0 == ":" || $0 == "," || $0.isWhitespace })
            guard !message.isEmpty else { continue }
            return (name, String(message))
        }
        return nil
    }

    public func stop() {
        guard page.isRunning else { return }
        flushText()
        page.stop(at: clock())
        onAction(.stop)
    }

    public func approve(_ id: String, allow: Bool, always: Bool = false, message: String? = nil) {
        page.resolveApproval(id, allow: allow, at: clock())
        onAction(.approve(requestID: id, allow: allow, always: always, message: message))
    }

    public func answer(_ id: String, answers: [String: String]) {
        page.answerQuestion(id, answers: answers, at: clock())
        onAction(.answer(requestID: id, answers: answers))
    }

    public func stopTeammate(_ taskID: String) { onAction(.stopTeammate(taskID: taskID)) }

    /// "Continue" on the interrupted turn.
    public func continueInterrupted() {
        guard page.turns.last?.interrupted == true else { return }
        page.resumeInterrupted(at: clock())
        onAction(.continueInterrupted)
    }

    /// ◉: starts listening for a voice-in-page turn, or sends what was heard. The host sets
    /// `listening` back when the turn is sent or discarded.
    public func toggleMic() {
        listening.toggle()
        onAction(.mic(down: listening))
    }

    /// Prefills the composer ("Change the plan: ") and focuses it.
    public func prefill(_ text: String) {
        draft = text
        focusRequest += 1
    }

    /// "Something else…": the composer, focused, answers each of the card's questions in turn,
    /// then sends them all (QA U6, U28). Esc leaves the question card waiting.
    public func answerInComposer(_ requestID: String, questions: [String]) {
        guard !questions.isEmpty else { return }
        answering = ComposerAnswer(requestID: requestID, questions: questions)
        focusRequest += 1
    }

    public func cancelAnswering() { answering = nil }

    public func attach(_ urls: [URL]) { composer.attach(urls) }

    public func detach(_ attachment: PageAttachment) { composer.detach(attachment) }

    /// What the coordinator read for the latest turn: the real "Read from" strip.
    public func setContext(_ strip: ContextStrip) {
        page.setContext(strip)
    }

    // MARK: Timing

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.textInterval)
            self?.flushTask = nil
            self?.flushText()
        }
    }

    /// Applies the coalesced text now.
    public func flushText() {
        guard !pendingText.isEmpty else { return }
        let now = clock()
        let pending = pendingText
        pendingText = [:]
        // The lead's text first, then lanes, each as one event.
        if let lead = pending[nil] { page.apply(.text(lead, subagent: nil), at: now) }
        for (subagent, text) in pending where subagent != nil {
            page.apply(.text(text, subagent: subagent), at: now)
        }
        scheduleTick()
    }

    private func scheduleTick() {
        tickTask?.cancel()
        guard let next = page.nextTick else { return }
        let wait = max(0, next.timeIntervalSince(clock()))
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.page.tick(at: self.clock())
            self.scheduleTick()
        }
    }
}
