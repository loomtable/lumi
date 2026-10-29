import BuddyCore
import Foundation
import Observation

/// One dictation, as the Dictation page lists it.
public nonisolated struct DictationRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// The words were typed where the cursor was.
        case inserted
        /// Not typed: there was no text field (they were copied too), Esc, or the recording
        /// stopped on its own.
        case notInserted
    }

    public var id: UUID
    public var date: Date
    public var text: String
    /// The app the words went to (or were meant for), when known.
    public var appName: String?
    public var status: Status

    public init(id: UUID = UUID(), date: Date, text: String, appName: String?, status: Status) {
        self.id = id
        self.date = date
        self.text = text
        self.appName = appName
        self.status = status
    }
}

/// Every dictation's words, kept on this Mac so nothing said is lost, even when it couldn't be
/// typed (owner, Oct 29): one JSON file in the app's folder (`DataPaths`, per bundle ID),
/// readable by the user only.
///
/// Settings › Privacy applies: in temporary mode nothing is written, and the list holds only
/// dictations from then on, until it's turned off (as for sessions); "Keep for" prunes it;
/// Forget All clears it.
@Observable
public final class DictationHistory {
    /// Newest first.
    public private(set) var records: [DictationRecord] = []
    /// A dictation key is set up (the `dictation` path is on): the Lumi window lists the page.
    public var available = false
    public private(set) var temporary = false
    private var retentionDays: Int
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let now: () -> Date

    /// `file` nil keeps everything in memory (tests).
    public init(file: URL? = BuddyCore.paths.dictationHistory, retentionDays: Int = ConversationsPreferences().retentionDays,
                now: @escaping () -> Date = { Date() }) {
        self.file = file
        self.retentionDays = retentionDays
        self.now = now
        records = Self.load(file)
        prune()
    }

    /// Settings › Privacy: temporary mode and "Keep for".
    public func setPolicy(temporary: Bool, retentionDays: Int) {
        self.retentionDays = retentionDays
        if temporary != self.temporary {
            self.temporary = temporary
            records = temporary ? [] : Self.load(file)  // leaving it drops its dictations
        }
        prune()
    }

    /// Keeps a dictation, newest first.
    public func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        save()
    }

    public func delete(_ id: DictationRecord.ID) {
        records.removeAll { $0.id == id }
        save()
    }

    /// The page's Clear All, and Settings › Privacy's Forget All (the saved file too, even in
    /// temporary mode).
    public func clearAll() {
        records = []
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// The records whose words or app match `search` (case and accents ignored); all when empty.
    public func matching(_ search: String) -> [DictationRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.text.localizedStandardContains(query) || ($0.appName?.localizedStandardContains(query) ?? false)
        }
    }

    // MARK: Storage

    /// Drops records older than the retention.
    private func prune() {
        let cutoff = now().addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        guard records.contains(where: { $0.date < cutoff }) else { return }
        records.removeAll { $0.date < cutoff }
        save()
    }

    /// Never in temporary mode. A failed write (disk full) keeps the list for this run.
    private func save() {
        guard let file, !temporary else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(records).write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func load(_ file: URL?) -> [DictationRecord] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([DictationRecord].self, from: data)) ?? []).sorted { $0.date > $1.date }
    }
}
