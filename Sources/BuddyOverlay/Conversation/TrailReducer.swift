import BuddyCore
import Foundation

/// One row of a turn's Trail: a tool step, a steer the user typed mid-turn, the thinking row,
/// a retry wait or a teammate's handoff.
nonisolated public struct TrailRow: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        case step(TrailStep)
        /// The user's mid-turn direction, shown inside the running Trail.
        case steer(String)
        case thinking(summary: String?)
        case retry(attempt: Int, until: Date?, reason: String?)
        case handoff(name: String, summary: String?)
        /// The context was compacted.
        case compacted
    }

    public enum Status: Sendable, Equatable { case running, done, failed }

    public var id: String
    public var content: Content
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    /// At most 2 KB of the tool's result.
    public var preview: String?

    public var step: TrailStep? {
        if case .step(let s) = content { return s }
        return nil
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    /// Past tense, for the expanded timeline: "Read budget.md", "Ran the auth tests".
    public var line: String {
        switch content {
        case .step(let s): TrailCopy.pastLine(s)
        case .steer(let text): text
        case .thinking: "Thought"
        case .retry: "Waited to retry"
        case .handoff(let name, _): "\(name) handed off"
        case .compacted: "Context compacted"
        }
    }
}

/// Rows as the expanded timeline shows them: three or more consecutive steps of the same kind
/// fold into one row ("Read 7 files ⌄") that expands inline.
nonisolated public struct TrailGroup: Sendable, Equatable, Identifiable {
    public var rows: [TrailRow]
    public var id: String { rows.first?.id ?? "" }
    public var isFolded: Bool { rows.count >= Trail.foldThreshold }

    /// "Read 7 files", or the single row's line.
    public var title: String {
        guard isFolded, let s = rows.first?.step else { return rows.first?.line ?? "" }
        return TrailCopy.pastCount(kind: s.kind, verb: s.verb, count: rows.count)
    }

    public var status: TrailRow.Status {
        if rows.contains(where: { $0.status == .failed }) { return .failed }
        if rows.contains(where: { $0.status == .running }) { return .running }
        return .done
    }
}

/// The live, done and expanded states of one turn's tool activity (04 §4.2). Pure: every
/// mutation takes the time, and the view schedules `tick(at:)` from `nextTick`.
nonisolated public struct Trail: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case working, needsYou, done, stopped
        /// Lumi quit, or the process died, mid-turn: not a failure; the page offers Continue.
        case interrupted
        /// The whole failure line, or nil for "Couldn't finish: <last step>".
        case failed(String?)
    }

    /// The live verb changes at most once per 600 ms, so a burst of reads doesn't flicker.
    public static let verbInterval: TimeInterval = 0.6
    public static let foldThreshold = 3

    public private(set) var rows: [TrailRow] = []
    public private(set) var phase: Phase = .working
    public let startedAt: Date
    public private(set) var endedAt: Date?
    /// The live verb on screen ("Reading budget.md", "Reading 7 files").
    public private(set) var live: String
    private var pending: String?
    private var shownAt: Date?

    /// The Agent tool use whose steps this Trail shows: nil for the lead, a teammate's for its lane.
    public let lane: String?

    /// False when the start time isn't known (a teammate seeded from the store): no clock.
    public let timed: Bool

    /// `live`: the line to show before any step arrives (a seeded teammate's last known line).
    public init(startedAt: Date, lane: String? = nil, live: String? = nil, timed: Bool = true) {
        self.startedAt = startedAt
        self.lane = lane
        self.live = live ?? TrailCopy.thinking
        self.timed = timed
    }

    /// The store's latest line for a lane this page hasn't seen a step of. `overHistory`: the rows
    /// were read back from the file, so the store's line is newer than their last verb (QA U42).
    public mutating func setLive(_ line: String, overHistory: Bool = false) {
        guard rows.isEmpty || overHistory, isWorking else { return }
        live = line
        pending = nil
    }

    public var isWorking: Bool { phase == .working || phase == .needsYou }

    /// Tool steps only: what "6 steps" counts.
    public var stepCount: Int { rows.lazy.filter { $0.step != nil }.count }

    /// When the view should call `tick(at:)` to show a held-back verb.
    public var nextTick: Date? {
        guard pending != nil, let shownAt else { return nil }
        return shownAt.addingTimeInterval(Self.verbInterval)
    }

    public func elapsed(at now: Date) -> TimeInterval { (endedAt ?? now).timeIntervalSince(startedAt) }

    /// The collapsed live row: "Reading budget.md · 6 steps · 0:41".
    public func liveLine(at now: Date) -> String {
        var parts = [live]
        let n = stepCount
        if n > 0 { parts.append(n == 1 ? "1 step" : "\(n) steps") }
        if timed { parts.append(TrailCopy.clock(elapsed(at: now))) }
        return parts.joined(separator: " · ")
    }

    /// The collapsed row after the turn: "Worked for 0:41 · read 9 files, edited 2, checked Slack".
    public var doneLine: String {
        let time = TrailCopy.clock(elapsed(at: endedAt ?? startedAt))
        switch phase {
        case .stopped: return "Stopped after \(time)"
        case .interrupted: return "Interrupted"
        case .failed(let line): return line ?? "Couldn't finish: " + (lastStepLine ?? "the turn ended early")
        case .working, .needsYou, .done:
            let summary = TrailCopy.summary(rows.compactMap(\.step))
            return summary.isEmpty ? "Worked for \(time)" : "Worked for \(time) · \(summary)"
        }
    }

    /// The last step, past tense: the failure line's reason ("Couldn't finish: <step>").
    public var lastStepLine: String? {
        rows.last(where: { $0.step != nil }).map { TrailCopy.presentLine($0.step!).lowercasedFirst }
    }

    /// The expanded timeline with same-kind runs folded.
    public var groups: [TrailGroup] {
        var out: [TrailGroup] = []
        for row in rows {
            if let kind = row.step?.kind, Self.folds(kind), let last = out.last?.rows.last?.step, last.kind == kind,
               out.last?.rows.allSatisfy({ $0.step != nil }) == true {
                out[out.count - 1].rows.append(row)
            } else {
                out.append(TrailGroup(rows: [row]))
            }
        }
        // A run shorter than the threshold shows as separate rows.
        return out.flatMap { $0.rows.count >= Self.foldThreshold ? [$0] : $0.rows.map { TrailGroup(rows: [$0]) } }
    }

    static func folds(_ kind: StepKind) -> Bool {
        switch kind {
        case .read, .search, .edit, .write, .web, .bash, .mcp: true
        case .agent, .plan, .ask, .screen, .other: false
        }
    }

    // MARK: Events

    /// One event from the session's stream. Only steps of this Trail's `lane` count: a
    /// subagent's steps belong to its teammate's lane, which has its own Trail.
    public mutating func apply(_ event: SessionEvent, at now: Date) {
        tick(at: now)
        switch event {
        case .step(let step):
            upsert(step, at: now)
        case .stepFinished(let id, let isError, let preview):
            guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[i].finishedAt = now
            rows[i].status = isError ? .failed : .done
            rows[i].preview = preview
        case .thinking(let summary):
            if let i = rows.indices.last, case .thinking = rows[i].content, rows[i].status == .running {
                rows[i].content = .thinking(summary: summary ?? rows[i].thinkingSummary)
            } else {
                finishOpen(.thinking(summary: nil), at: now)
                rows.append(TrailRow(id: "thinking-\(rows.count)", content: .thinking(summary: summary), startedAt: now, status: .running))
            }
            show(TrailCopy.thinking, at: now)
        case .text(_, let subagent) where subagent == nil:
            finishOpen(.thinking(summary: nil), at: now)
            if !rows.contains(where: { $0.status == .running && $0.step != nil }) { show(TrailCopy.drafting, at: now) }
        case .retrying(let attempt, let delayMS, let reason):
            let until = delayMS.map { now.addingTimeInterval(Double($0) / 1000) }
            rows.append(TrailRow(id: "retry-\(rows.count)", content: .retry(attempt: attempt, until: until, reason: reason),
                                 startedAt: now, finishedAt: until, status: .done))
            show(TrailCopy.retrying, at: now, force: true)
        case .permissionRequested, .questionAsked:
            phase = .needsYou
            show(TrailCopy.waitingForYou, at: now, force: true)
        case .permissionResolved:
            if phase == .needsYou { phase = .working }
            show(currentStepVerb ?? TrailCopy.thinking, at: now, force: true)
        case .compacted:
            rows.append(TrailRow(id: "compact-\(rows.count)", content: .compacted, startedAt: now, finishedAt: now, status: .done))
        case .turnEnded(let e):
            finish(at: now, failed: e.isError ? (Self.reason(e.error) ?? e.error?.lastStep.map { "Couldn't finish: " + $0.lowercasedFirst }) : nil,
                   isError: e.isError)
        case .processEnded(_, let midTurn) where midTurn:
            guard isWorking else { return }
            closeRunning(at: now)
            endedAt = now
            pending = nil
            phase = .interrupted
        default:
            break
        }
    }

    /// A teammate handed its piece back (the lead's handoff row).
    public mutating func handoff(name: String, summary: String?, at now: Date) {
        rows.append(TrailRow(id: "handoff-\(rows.count)", content: .handoff(name: name, summary: summary),
                             startedAt: now, finishedAt: now, status: .done))
    }

    /// The user typed while the turn ran.
    public mutating func steer(_ text: String, at now: Date) {
        rows.append(TrailRow(id: "steer-\(rows.count)", content: .steer(text), startedAt: now, finishedAt: now, status: .done))
    }

    /// The user pressed Stop: the line freezes with "Stopped" and the partial answer is kept.
    public mutating func stop(at now: Date) {
        guard isWorking else { return }
        closeRunning(at: now)
        phase = .stopped
        endedAt = now
        pending = nil
        live = "Stopped"
    }

    /// Shows a held-back verb once its 600 ms are up.
    public mutating func tick(at now: Date) {
        guard let pending, let shownAt, now.timeIntervalSince(shownAt) >= Self.verbInterval else { return }
        live = pending
        self.pending = nil
        self.shownAt = now
    }

    // MARK: Private

    private mutating func upsert(_ step: TrailStep, at now: Date) {
        guard step.subagent == lane else { return }
        if let i = rows.firstIndex(where: { $0.id == step.id }) {
            // The same tool use again: its result's diff or a fuller input.
            rows[i].content = .step(step)
            return
        }
        finishOpen(.thinking(summary: nil), at: now)
        rows.append(TrailRow(id: step.id, content: .step(step), startedAt: now, status: .running))
        if phase == .needsYou { phase = .working }
        show(burstVerb(for: step), at: now)
    }

    private var currentStepVerb: String? {
        rows.last(where: { $0.status == .running && $0.step != nil }).flatMap(\.step).map(TrailCopy.presentLine)
    }

    /// "Reading 7 files" for a burst of same-kind steps, else the step's own line.
    private func burstVerb(for step: TrailStep) -> String {
        var run = 0
        for row in rows.reversed() {
            guard let s = row.step, s.kind == step.kind else { break }
            run += 1
        }
        if run >= 2, let plural = TrailCopy.presentCount(kind: step.kind, verb: step.verb, count: run) { return plural }
        return TrailCopy.presentLine(step)
    }

    private mutating func show(_ verb: String, at now: Date, force: Bool = false) {
        if !force, let shownAt, now.timeIntervalSince(shownAt) < Self.verbInterval {
            pending = verb == live ? nil : verb
            return
        }
        live = verb
        pending = nil
        shownAt = now
    }

    /// Ends a running thinking row when anything else starts.
    private mutating func finishOpen(_ kind: TrailRow.Content, at now: Date) {
        guard let i = rows.indices.last, rows[i].status == .running, case .thinking = rows[i].content else { return }
        rows[i].status = .done
        rows[i].finishedAt = now
    }

    private mutating func closeRunning(at now: Date) {
        for i in rows.indices where rows[i].status == .running {
            rows[i].status = .done
            rows[i].finishedAt = now
        }
    }

    private mutating func finish(at now: Date, failed reason: String?, isError: Bool) {
        guard isWorking else { return }
        closeRunning(at: now)
        endedAt = now
        pending = nil
        phase = isError ? .failed(reason) : .done
    }

    /// The failure line, in the user's words: a whole sentence for a known reason, else
    /// "Couldn't finish: <what it said>"; nil when only the step it stopped on says more. A raw
    /// error code is never shown (Round 3 S-07); it stays in the trace.
    static func reason(_ failure: SessionFailure?) -> String? {
        switch failure?.reason {
        case .rateLimited(let resetsAt)?:
            resetsAt.map { "Your plan's usage limit is reached. It resets at \($0.formatted(date: .omitted, time: .shortened))." }
                ?? "Your plan's usage limit is reached."
        case .crashed?: "Claude Code stopped unexpectedly."
        case .auth?: "Claude Code isn't signed in."
        case .api(let detail)?: apiReason(detail)
        case .unavailable(let m)?: "Couldn't finish: " + m
        case nil: nil
        }
    }

    /// The CLI's error codes (the assistant's `error`, the result's subtype) as plain lines. A
    /// sentence the CLI wrote is kept; another bare code gives nil.
    static func apiReason(_ detail: String) -> String? {
        switch detail {
        case "billing_error": "Your Claude plan is out of credit."
        case "model_not_found": "That model isn't available on your plan."
        case "error_max_turns": "Stopped after too many steps. Say continue to keep going."
        case "error_max_budget_usd": "Stopped at the spending limit."
        case "server_error", "api_error": "Claude had a server problem. Try again."
        case "overloaded_error": "Claude is busy right now. Try again in a moment."
        case "invalid_request": "Claude Code couldn't send that request."
        case "max_output_tokens": "The answer got too long. Ask for a shorter one."
        default: detail.contains(" ") ? "Couldn't finish: " + detail : nil
        }
    }
}

nonisolated extension TrailRow {
    fileprivate var thinkingSummary: String? {
        if case .thinking(let s) = content { return s }
        return nil
    }
}

/// The Trail's words. Verbs arrive present tense from the bridge's StatusMapper; this makes
/// the past forms, the counts and the done-line summary. Never "Analyzing", "Processing" or
/// "Watching" (04 §4.2).
nonisolated public enum TrailCopy {
    public static let thinking = "Thinking"
    public static let drafting = "Drafting"
    public static let waitingForYou = "Waiting for you"
    public static let retrying = "Waiting to retry"

    /// Present-tense verbs from StatusMapper and their past forms.
    static let past: [String: String] = [
        "Reading": "Read", "Editing": "Edited", "Writing": "Wrote", "Searching for": "Searched for",
        "Finding files": "Found files", "Running": "Ran", "Searching the web for": "Searched the web for",
        "Starting": "Started", "Messaging": "Messaged", "Updating the plan": "Updated the plan", "Planning": "Planned",
        "Asking you": "Asked you", "Using": "Used", "Checking": "Checked", "Briefing": "Briefed",
        "Drafting": "Drafted", "Comparing": "Compared", "Thinking": "Thought",
    ]

    /// "Reading budget.md"; a Bash description in its -ing form ("Running the auth tests").
    public static func presentLine(_ s: TrailStep) -> String { s.presentLine }

    /// "Read budget.md", "Ran the auth tests".
    public static func pastLine(_ s: TrailStep) -> String {
        let verb = s.kind == .bash ? TrailStep.bashForm(s.verb, past: true) : pastVerb(s.verb)
        return s.object.map { "\(verb) \($0)" } ?? verb
    }

    public static func pastVerb(_ verb: String) -> String {
        if let p = past[verb] { return p }
        // "Searching for" style: map the longest known prefix.
        if let key = past.keys.filter({ verb.hasPrefix($0 + " ") }).max(by: { $0.count < $1.count }) {
            return past[key]! + verb.dropFirst(key.count)
        }
        return verb
    }

    /// The noun a burst counts, for kinds that read as a count.
    static func noun(_ kind: StepKind, _ n: Int) -> String? {
        switch kind {
        case .read, .edit, .write: n == 1 ? "file" : "files"
        case .web: n == 1 ? "page" : "pages"
        case .bash: n == 1 ? "command" : "commands"
        case .search: n == 1 ? "search" : "searches"
        default: nil
        }
    }

    /// "Reading 7 files" while a burst runs.
    static func presentCount(kind: StepKind, verb: String, count: Int) -> String? {
        guard let noun = noun(kind, count) else { return nil }
        switch kind {
        case .read, .web: return "Reading \(count) \(noun)"
        case .edit: return "Editing \(count) \(noun)"
        case .write: return "Writing \(count) \(noun)"
        case .bash: return "Running \(count) \(noun)"
        case .search: return "Running \(count) \(noun)"
        default: return nil
        }
    }

    /// "Read 7 files" for a folded group.
    static func pastCount(kind: StepKind, verb: String, count: Int) -> String {
        guard let noun = noun(kind, count) else { return "\(pastVerb(verb)) · \(count)" }
        switch kind {
        case .read, .web: return "Read \(count) \(noun)"
        case .edit: return "Edited \(count) \(noun)"
        case .write: return "Wrote \(count) \(noun)"
        case .bash: return "Ran \(count) \(noun)"
        case .search: return "Ran \(count) \(noun)"
        case .mcp(let server): return "Used \(connector(server)) \(count) times"
        default: return "\(pastVerb(verb)) · \(count)"
        }
    }

    /// "read 9 files, edited 2, ran 3 commands, checked Slack, with 2 teammates".
    public static func summary(_ steps: [TrailStep]) -> String {
        var parts: [String] = []
        let read = Set(steps.filter { $0.kind == .read }.map { $0.object ?? $0.id }).count
        if read > 0 { parts.append("read \(read) \(read == 1 ? "file" : "files")") }
        let searches = steps.filter { $0.kind == .search }.count
        if searches > 0 { parts.append("searched \(searches == 1 ? "once" : "\(searches) times")") }
        let edited = Set(steps.filter { $0.kind == .edit || $0.kind == .write }.map { $0.object ?? $0.id }).count
        if edited > 0 { parts.append("edited \(edited)") }
        let commands = steps.filter { $0.kind == .bash }.count
        if commands > 0 { parts.append("ran \(commands) \(commands == 1 ? "command" : "commands")") }
        let web = steps.filter { $0.kind == .web }.count
        if web > 0 { parts.append("searched the web") }
        var servers: [String] = []
        for case .mcp(let server) in steps.map(\.kind) where !servers.contains(server) { servers.append(server) }
        if !servers.isEmpty { parts.append("checked " + servers.map(connector).joined(separator: ", ")) }
        let teammates = Set(steps.filter { $0.kind == .agent && $0.verb == "Starting" }.map(\.id)).count
        if teammates > 0 { parts.append("with \(teammates) \(teammates == 1 ? "teammate" : "teammates")") }
        return parts.joined(separator: ", ")
    }

    /// "claude_ai_Slack" → "Slack", "notion" → "Notion".
    public static func connector(_ server: String) -> String {
        let last = server.split(separator: "_").last.map(String.init) ?? server
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// m:ss, or h:mm:ss from an hour.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension String {
    nonisolated var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
