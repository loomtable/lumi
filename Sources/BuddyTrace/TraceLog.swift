import BuddyCore
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
        }
    }
}

public enum TraceOutcome: String, Sendable, CaseIterable {
    case ok, failed, cancelled, late, skipped
}

/// An interval in progress; pass it back to `end`.
public struct TraceSpan: Sendable {
    let event: TraceEvent
    let start: ContinuousClock.Instant
    let signpost: OSSignpostIntervalState?
}

/// The opt-in trace log (Settings › Privacy): one line per event with its timing, in
/// ~/Library/Logs/com.loomtable.lumi/trace-YYYY-MM-DD.log, a file per local day, kept 7 days.
///
/// Recording is synchronous and never blocks: entries go, in order, to a writer that owns the
/// files. If the writer falls `maxPending` entries behind, new entries are dropped; flush,
/// prune and delete commands never are. While disabled nothing is recorded and no signposts are
/// emitted, but old files are still pruned (at creation and when switched off).
public final class TraceLog: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/\(BuddyCore.folderName)", directoryHint: .isDirectory)
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

    private func enqueue(_ event: TraceEvent, duration: Duration?, lane: Mode?, outcome: TraceOutcome?, count: Int?) {
        guard pending.count.add(1, ordering: .relaxed).newValue <= Self.maxPending else {
            pending.count.subtract(1, ordering: .relaxed)
            return
        }
        continuation.yield(.entry(TraceEntry(
            date: now(), event: event, milliseconds: duration.map(Self.milliseconds), lane: lane, outcome: outcome,
            count: count)))
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

    /// Tab-separated: time, event, then only the fields that are set.
    func line(timeZone: TimeZone) -> String {
        var fields = [Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: timeZone).format(date), event.rawValue]
        if let milliseconds { fields.append(String(format: "ms=%.1f", milliseconds)) }
        if let lane { fields.append("lane=\(lane.rawValue)") }
        if let outcome { fields.append("outcome=\(outcome.rawValue)") }
        if let count { fields.append("count=\(count)") }
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
