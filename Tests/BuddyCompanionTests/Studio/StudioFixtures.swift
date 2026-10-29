import BuddyCore
import Foundation

/// Fixed sessions and times for Studio's tests.
enum StudioFixtures {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Wed 28 Oct 2026, 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_199_600)

    static func session(_ id: String, _ title: String? = nil, status: SessionStatus = .idle, pinned: Bool = false,
                        archived: Bool = false, ago: TimeInterval = 60, teammates: [TeammateSnapshot] = []) -> SessionSnapshot {
        SessionSnapshot(id: SessionID(rawValue: id), title: title ?? id, color: .ember, harness: .open, status: status,
                        teammates: teammates, pinned: pinned, archived: archived, lastUsed: now.addingTimeInterval(-ago))
    }

    static func needsYou(since ago: TimeInterval) -> SessionStatus {
        .needsYou(NeedsYou(kind: .soft("Which file?"), since: now.addingTimeInterval(-ago)))
    }

    static func thinking(for seconds: TimeInterval, progress: StepProgress? = nil) -> SessionStatus {
        .thinking(since: now.addingTimeInterval(-seconds), progress: progress)
    }

    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400
}
