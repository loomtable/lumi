import BuddyCore
import Foundation
import Testing
@testable import BuddyCompanion

/// Dictation history (owner, Oct 29): every dictation kept on this Mac, with Settings › Privacy's
/// temporary mode, retention and Forget All applied.
@Suite("DictationHistory")
struct DictationHistoryTests {
    let folder: URL
    var file: URL { folder.appending(path: "dictation-history.json") }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "dictation-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func record(_ text: String, daysAgo: Double = 0, status: DictationRecord.Status = .inserted, now: Date = Date()) -> DictationRecord {
        DictationRecord(date: now.addingTimeInterval(-daysAgo * 86_400), text: text, appName: "Notes", status: status)
    }

    @Test("kept newest first and saved to disk, readable by the user only")
    func persists() throws {
        let history = DictationHistory(file: file)
        history.add(record("first", daysAgo: 1))
        history.add(record("second", status: .notInserted))
        #expect(history.records.map(\.text) == ["second", "first"])
        let reopened = DictationHistory(file: file)
        #expect(reopened.records.map(\.text) == ["second", "first"])
        #expect(reopened.records.map(\.status) == [.notInserted, .inserted])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("delete one and Clear All, on disk too")
    func deleteAndClear() {
        let history = DictationHistory(file: file)
        let a = record("a"), b = record("b")
        history.add(a)
        history.add(b)
        history.delete(a.id)
        #expect(DictationHistory(file: file).records.map(\.text) == ["b"])
        history.clearAll()
        #expect(history.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(DictationHistory(file: file).records.isEmpty)
    }

    @Test("a reopen with a longer \"Keep for\" keeps what the 90-day default would prune (QA gate 4.4)")
    func reopenKeepsTheUsersRetention() {
        DictationHistory(file: file, retentionDays: 365).add(record("old", daysAgo: 200))
        #expect(DictationHistory(file: file, retentionDays: 365).records.map(\.text) == ["old"])
        #expect(DictationHistory(file: file, retentionDays: 365).records.map(\.text) == ["old"], "still on disk")
    }

    @Test("temporary mode: nothing reaches disk, saved ones are hidden, and leaving it drops its own")
    func temporary() {
        let history = DictationHistory(file: file)
        history.add(record("saved"))
        history.setPolicy(temporary: true, retentionDays: 90)
        #expect(history.records.isEmpty)
        history.add(record("secret"))
        #expect(history.records.map(\.text) == ["secret"])
        #expect(DictationHistory(file: file).records.map(\.text) == ["saved"])
        history.setPolicy(temporary: false, retentionDays: 90)
        #expect(history.records.map(\.text) == ["saved"])
    }

    @Test("retention prunes at once, at launch and on each add")
    func retention() {
        let history = DictationHistory(file: file)
        history.add(record("old", daysAgo: 40))
        history.add(record("new", daysAgo: 1))
        history.setPolicy(temporary: false, retentionDays: 30)
        #expect(history.records.map(\.text) == ["new"])
        #expect(DictationHistory(file: file, retentionDays: 30).records.map(\.text) == ["new"])
        let soon = DictationHistory(file: file, retentionDays: 30, now: { Date().addingTimeInterval(30 * 86_400) })
        #expect(soon.records.isEmpty)
    }

    @Test("search matches the words or the app, ignoring case")
    func search() {
        let history = DictationHistory(file: nil)
        history.add(DictationRecord(date: Date(), text: "Lunch at noon", appName: "Mail", status: .inserted))
        history.add(DictationRecord(date: Date(), text: "ship it", appName: "Slack", status: .notInserted))
        #expect(history.matching("LUNCH").map(\.text) == ["Lunch at noon"])
        #expect(history.matching("slack").map(\.text) == ["ship it"])
        #expect(history.matching("  ").count == 2)
    }

    @Test("stored under the app's own folder, per bundle ID")
    func path() {
        let qa = DataPaths(bundleIdentifier: "com.loomtable.lumi.qa", applicationSupport: URL(filePath: "/AS"))
        #expect(qa.dictationHistory.path == "/AS/com.loomtable.lumi.qa/dictation-history.json")
    }

    @Test("the page groups by day: Today, Yesterday, then the date")
    func days() {
        let now = Date()
        let records = [record("a", now: now), record("b", daysAgo: 1, now: now), record("c", daysAgo: 3, now: now),
                       record("d", daysAgo: 3, now: now)]
        let days = DictationHistoryView.days(records, now: now)
        #expect(days.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(days.map { $0.records.map(\.text) } == [["a"], ["b"], ["c", "d"]])
    }
}
