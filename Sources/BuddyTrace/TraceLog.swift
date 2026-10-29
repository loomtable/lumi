import BuddyCore
import CoreGraphics
import Darwin
import Foundation
import os
import Synchronization

/// What happened, from the turn's flow and quality bar. Kinds only: there is no
/// way to attach text, so a transcript, answer, title or screenshot can never reach the log.
public enum TraceEvent: String, Sendable, CaseIterable {
    case summon
    case micLive
    case contextPacket
    case screenshot
    case transcriptFinal
    case questionSent
    case quickFirstEvent
    case firstSpokenWord
    case answerShown
    /// A turn's answer finished behind (a newer question took the Glance): ready, unread.
    case backgroundReady
    /// That voice answer joined the queue of answers waiting to be spoken (`count`: waiting now).
    case answerQueued
    /// A queued answer took the Glance after waiting (`duration`): spoken (`ok`), or shown silently
    /// with Speak answers off (`skipped`); `count`: still waiting.
    case answerPlayed
    case handoff
    case deepStarted
    case deepFinished
    case researchStarted
    case researchFinished
    case rings
    case insert
    case cancelled
    case processRestart
    case permissionMissing
    case error
    // v2 sessions
    case switcherShown
    case sessionLaunched
    case sessionResumed
    case sessionSuspended
    case permissionAsked
    case dictationInserted
    case routeDecided
    /// A Glance (card, chip, approval, report) appeared: `frame` (global points, no content).
    case cardShown
    /// It left: `reason` (escape, clickAway, appSwitched, closeButton, requested, replaced, summon).
    case cardClosed

    /// os_signpost names must be static strings.
    var signpostName: StaticString {
        switch self {
        case .summon: "summon"
        case .micLive: "micLive"
        case .contextPacket: "contextPacket"
        case .screenshot: "screenshot"
        case .transcriptFinal: "transcriptFinal"
        case .questionSent: "questionSent"
        case .quickFirstEvent: "quickFirstEvent"
        case .firstSpokenWord: "firstSpokenWord"
        case .answerShown: "answerShown"
        case .backgroundReady: "backgroundReady"
        case .answerQueued: "answerQueued"
        case .answerPlayed: "answerPlayed"
        case .handoff: "handoff"
        case .deepStarted: "deepStarted"
        case .deepFinished: "deepFinished"
        case .researchStarted: "researchStarted"
        case .researchFinished: "researchFinished"
        case .rings: "rings"
        case .insert: "insert"
        case .cancelled: "cancelled"
        case .processRestart: "processRestart"
        case .permissionMissing: "permissionMissing"
        case .error: "error"
        case .switcherShown: "switcherShown"
        case .sessionLaunched: "sessionLaunched"
        case .sessionResumed: "sessionResumed"
        case .sessionSuspended: "sessionSuspended"
        case .permissionAsked: "permissionAsked"
        case .dictationInserted: "dictationInserted"
        case .routeDecided: "routeDecided"
        case .cardShown: "cardShown"
        case .cardClosed: "cardClosed"
        }
    }
}

public enum TraceOutcome: String, Sendable, CaseIterable {
    case ok, failed, cancelled, late, skipped
}

/// Why something was dropped: a closed set, never text. A key code appears only for keys that
/// don't type text; the caller leaves it nil for the others.
public enum TraceReason: Sendable, Equatable {
    case release, otherKey(UInt16?), otherModifier, click, scroll, tapInterrupted
    /// Esc, and a listen the voice ended on its own (a limit, sleep, a mic failure).
    case escape, autoStop
    /// Why a dictation's words didn't go in (the user still gets them: copied or kept in history).
    case noField, focusChanged, secureField, blockedApp, ownApp, multilineTerminal, emptyText,
         pasteUnconfirmed, pasteFailed, busy
    /// Why the pool suspended a session's process.
    case suspendIdle, suspendCap, memoryPressure, absorb, released
    /// Why a Glance card left (besides `escape`): a click outside it, an app switch, its ✕, Lumi's
    /// own close, a new Glance in its place, or the key pressed over it.
    case clickAway, appSwitched, closeButton, requested, replaced, summon

    var field: String {
        switch self {
        case .release: "release"
        case .otherKey(let code): code.map { "otherKey(\($0))" } ?? "otherKey"
        case .otherModifier: "otherModifier"
        case .click: "click"
        case .scroll: "scroll"
        case .tapInterrupted: "tapInterrupted"
        case .escape: "escape"
        case .autoStop: "autoStop"
        case .noField: "noField"
        case .focusChanged: "focusChanged"
        case .secureField: "secure"
        case .blockedApp: "blocked"
        case .ownApp: "ownApp"
        case .multilineTerminal: "multilineTerminal"
        case .emptyText: "emptyText"
        case .pasteUnconfirmed: "pasteUnconfirmed"
        case .pasteFailed: "pasteFailed"
        case .busy: "busy"
        case .suspendIdle: "idle"
        case .suspendCap: "cap"
        case .memoryPressure: "memoryPressure"
        case .absorb: "absorb"
        case .released: "released"
        case .clickAway: "clickAway"
        case .appSwitched: "appSwitched"
        case .closeButton: "closeButton"
        case .requested: "requested"
        case .replaced: "replaced"
        case .summon: "summon"
        }
    }
}

/// An interval in progress; pass it back to `end`.
public struct TraceSpan: Sendable {
    let event: TraceEvent
    let start: ContinuousClock.Instant
    let signpost: OSSignpostIntervalState?
}

/// The opt-in trace log (Settings › Privacy): one line per event with its timing, in
/// ~/Library/Logs/<bundle id>/trace-YYYY-MM-DD.log, a file per local day, kept 7 days.
///
/// Recording is synchronous and never blocks: entries go, in order, to a writer that owns the
/// files. If the writer falls `maxPending` entries behind, new entries are dropped; flush,
/// prune and delete commands never are. While disabled nothing is recorded and no signposts are
/// emitted, but old files are still pruned (at creation and when switched off).
public final class TraceLog: Sendable {
    public static var defaultDirectory: URL {
        BuddyCore.paths.logs
    }

    public static let retentionDays = 7
    /// Entries waiting for the writer beyond this are dropped.
    public static let maxPending = 10_000

    enum Command: Sendable {
        case entry(TraceEntry)
        case prune(Date)
        case flush(CheckedContinuation<Void, Never>)
        case deleteAll(CheckedContinuation<Void, Never>)
    }

    private let enabledFlag: Atomic<Bool>
    private let pending: Pending
    private let continuation: AsyncStream<Command>.Continuation
    private let now: @Sendable () -> Date
    private let signposter = OSSignposter(subsystem: BuddyCore.bundleIdentifier, category: "trace")

    /// `now` and `calendar` are injectable for tests; the app uses the defaults.
    public init(
        directory: URL = TraceLog.defaultDirectory, enabled: Bool,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .autoupdatingCurrent
    ) {
        enabledFlag = Atomic(enabled)
        self.now = now
        let pending = Pending()
        self.pending = pending
        // Unbounded so commands are never lost; `pending` bounds the entries in it.
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        self.continuation = continuation
        let writer = TraceWriter(directory: directory, calendar: calendar, retentionDays: Self.retentionDays)
        Task.detached(priority: .utility) {
            for await command in stream {
                switch command {
                case .entry(let entry):
                    await writer.write(entry)
                    pending.count.subtract(1, ordering: .relaxed)
                case .prune(let date): await writer.prune(before: date)
                case .flush(let done): await writer.sync(); done.resume()
                case .deleteAll(let done): await writer.deleteAll(); done.resume()
                }
            }
        }
        continuation.yield(.prune(now()))
    }

    final class Pending: Sendable {
        let count = Atomic(0)
    }

    deinit { continuation.finish() }

    public var isEnabled: Bool { enabledFlag.load(ordering: .relaxed) }

    /// From Settings › Privacy › Trace log.
    public func setEnabled(_ on: Bool) {
        let was = enabledFlag.exchange(on, ordering: .relaxed)
        if was, !on { continuation.yield(.prune(now())) }
    }

    /// One event, optionally with a duration, the lane, an outcome and a count (e.g. sources).
    public func record(
        _ event: TraceEvent, duration: Duration? = nil, lane: Mode? = nil, outcome: TraceOutcome? = nil, count: Int? = nil
    ) {
        guard isEnabled else { return }
        signposter.emitEvent(event.signpostName)
        enqueue(event, duration: duration, lane: lane, outcome: outcome, count: count)
    }

    /// One event with why it was dropped (e.g. a discarded dictation).
    public func record(_ event: TraceEvent, duration: Duration?, outcome: TraceOutcome?, reason: TraceReason) {
        guard isEnabled else { return }
        signposter.emitEvent(event.signpostName)
        enqueue(event, duration: duration, lane: nil, outcome: outcome, count: nil, reason: reason)
    }

    /// One event with a surface's frame (`cardShown`): where it sat, never what it said.
    public func record(_ event: TraceEvent, frame: CGRect) {
        guard isEnabled else { return }
        signposter.emitEvent(event.signpostName)
        enqueue(event, duration: nil, lane: nil, outcome: nil, count: nil, frame: frame)
    }

    private func enqueue(
        _ event: TraceEvent, duration: Duration?, lane: Mode?, outcome: TraceOutcome?, count: Int?, reason: TraceReason? = nil,
        frame: CGRect? = nil
    ) {
        guard pending.count.add(1, ordering: .relaxed).newValue <= Self.maxPending else {
            pending.count.subtract(1, ordering: .relaxed)
            return
        }
        continuation.yield(.entry(TraceEntry(
            date: now(), event: event, milliseconds: duration.map(Self.milliseconds), lane: lane, outcome: outcome,
            count: count, reason: reason, frame: frame)))
    }

    public func begin(_ event: TraceEvent) -> TraceSpan {
        let state = isEnabled ? signposter.beginInterval(event.signpostName, id: signposter.makeSignpostID()) : nil
        return TraceSpan(event: event, start: .now, signpost: state)
    }

    /// Records the span's event with its duration (one signpost interval, no extra event).
    public func end(_ span: TraceSpan, lane: Mode? = nil, outcome: TraceOutcome? = nil, count: Int? = nil) {
        if let state = span.signpost { signposter.endInterval(span.event.signpostName, state) }
        guard isEnabled else { return }
        enqueue(span.event, duration: .now - span.start, lane: lane, outcome: outcome, count: count)
    }

    /// Waits until everything recorded so far is on disk.
    public func flush() async {
        await withCheckedContinuation { continuation.yield(.flush($0)) }
    }

    /// Deletes every trace file ("Delete trace log" in Privacy).
    public func deleteAll() async {
        await withCheckedContinuation { continuation.yield(.deleteAll($0)) }
    }

    static func milliseconds(_ d: Duration) -> Double {
        let (s, attos) = d.components
        return Double(s) * 1_000 + Double(attos) / 1e15
    }
}

/// One line of the log.
struct TraceEntry: Sendable, Equatable {
    let date: Date
    let event: TraceEvent
    let milliseconds: Double?
    let lane: Mode?
    let outcome: TraceOutcome?
    let count: Int?
    var reason: TraceReason? = nil
    var frame: CGRect? = nil

    /// Tab-separated: time, event, then only the fields that are set.
    func line(timeZone: TimeZone) -> String {
        var fields = [Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: timeZone).format(date), event.rawValue]
        if let milliseconds { fields.append(String(format: "ms=%.1f", milliseconds)) }
        if let lane { fields.append("lane=\(lane.rawValue)") }
        if let outcome { fields.append("outcome=\(outcome.rawValue)") }
        if let count { fields.append("count=\(count)") }
        if let reason { fields.append("reason=\(reason.field)") }
        if let f = frame?.integral {
            fields.append("frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
        }
        return fields.joined(separator: "\t") + "\n"
    }
}

/// Owns the files: picks the day's file, appends, prunes old days.
actor TraceWriter {
    let directory: URL
    let calendar: Calendar
    let retentionDays: Int
    private var day: String?
    private var handle: FileHandle?

    init(directory: URL, calendar: Calendar, retentionDays: Int) {
        self.directory = directory
        self.calendar = calendar
        self.retentionDays = retentionDays
    }

    static let prefix = "trace-"

    func fileURL(forDay day: String) -> URL {
        directory.appending(path: "\(Self.prefix)\(day).log")
    }

    func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func write(_ entry: TraceEntry) {
        let today = dayString(entry.date)
        if today != day {
            try? handle?.close()
            handle = open(today)
            // Retried on the next entry if the file couldn't be opened.
            day = handle == nil ? nil : today
            prune(before: entry.date)
        }
        try? handle?.write(contentsOf: Data(entry.line(timeZone: calendar.timeZone).utf8))
    }

    func sync() {
        try? handle?.synchronize()
    }

    func deleteAll() {
        try? handle?.close()
        handle = nil
        day = nil
        for url in traceFiles() { try? FileManager.default.removeItem(at: url) }
    }

    /// Opens the day's file for appending. The folder and file are made user-only every time,
    /// even if they already existed with looser permissions.
    private func open(_ day: String) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = Darwin.open(fileURL(forDay: day).path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        fchmod(fd, 0o600)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Keeps the day of `date` and the `retentionDays - 1` days before it.
    func prune(before date: Date) {
        guard let oldest = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: date) else { return }
        let cutoff = dayString(oldest)
        for url in traceFiles() {
            let name = url.deletingPathExtension().lastPathComponent
            let fileDay = String(name.dropFirst(Self.prefix.count))
            // ISO dates compare correctly as strings.
            if fileDay.count == 10, fileDay < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func traceFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(Self.prefix) && $0.pathExtension == "log" }
    }
}
