import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyContext

/// Records the exclusion closures the builder hands to sensors, so tests can probe them.
private final class ProbingCursor: CursorSensor {
    let skipped = Mutex<[Int32: Bool]>([:])
    let pids: [Int32]

    init(probing pids: [Int32]) { self.pids = pids }

    func cursor(skip: @Sendable (Int32) -> Bool) -> ContextPacket.Cursor? {
        let results = Dictionary(uniqueKeysWithValues: pids.map { ($0, skip($0)) })
        skipped.withLock { $0 = results }
        return ContextPacket.Cursor(x: 1, y: 2)
    }
}

private final class ProbingRecent: RecentAppsSensor {
    let seen = Mutex<(pid: Int32, blocked: [String: Bool])?>(nil)

    func recent(excluding pid: Int32, isBlocked: @Sendable (String?) -> Bool) -> [ContextPacket.RecentApp] {
        let ids = ["com.1password.1password", "com.apple.Passwords.MenuBarExtra", "com.google.Chrome", "user.added"]
        seen.withLock { $0 = (pid, Dictionary(uniqueKeysWithValues: ids.map { ($0, isBlocked($0)) })) }
        return []
    }
}

private func sensors(front: FrontApp?, cursor: any CursorSensor = FakeSensor<ContextPacket.Cursor?>(nil),
                     recent: any RecentAppsSensor = FakeSensor<[ContextPacket.RecentApp]>([])) -> ContextSensors {
    ContextSensors(
        frontApp: FakeSensor<FrontApp?>(front), window: FakeSensor<ContextPacket.Window?>(nil),
        selection: FakeSensor<ContextPacket.Selection?>(nil), cursor: cursor,
        display: FakeSensor<ContextPacket.Display?>(nil), recent: recent)
}

@Suite("Privacy")
struct PrivacyTests {
    @Test("sub-IDs of blocked apps are blocked at dot boundaries", arguments: [
        "com.apple.Passwords.MenuBarExtra", "com.1password.1password.helper", "com.bitwarden.desktop.autofill",
        "com.agilebits.onepassword7", "com.agilebits.onepassword-osx-helper",
    ])
    func subIDsBlocked(id: String) {
        #expect(Blocklist().isBlocked(bundleID: id))
    }

    @Test("user-added IDs block their sub-IDs too")
    func userSubIDs() {
        let list = Blocklist(userBundleIDs: ["com.example.bank"])
        #expect(list.isBlocked(bundleID: "com.example.bank.helper"))
        #expect(!list.isBlocked(bundleID: "com.example.banking"))
    }

    @Test("our own app in front gives noFrontApp and reads nothing else")
    func ownAppFront() async {
        let me = FrontApp(pid: getpid(), name: "Lumi", bundle: "com.loomtable.lumi")
        let cursor = ProbingCursor(probing: [])
        let result = await ContextBuilder(sensors: sensors(front: me, cursor: cursor)).capture()
        #expect(result == .noFrontApp)
        #expect(cursor.skipped.withLock { $0.isEmpty })
    }

    @Test("cursor sensor is told to skip our own process; ordinary pids are not skipped")
    func cursorSkipsOwnPID() async {
        let other: Int32 = 1  // launchd: running, not blocked
        let cursor = ProbingCursor(probing: [getpid(), other])
        let front = FrontApp(pid: 4242, name: "Google Chrome", bundle: "com.google.Chrome")
        _ = await ContextBuilder(sensors: sensors(front: front, cursor: cursor)).capture()
        let skipped = cursor.skipped.withLock { $0 }
        #expect(skipped[getpid()] == true)
        #expect(skipped[other] == false)
    }

    @Test("recent apps are filtered with the builder's current blocklist")
    func recentUsesBuilderBlocklist() async {
        let recent = ProbingRecent()
        let front = FrontApp(pid: 4242, name: "Google Chrome", bundle: "com.google.Chrome")
        let builder = ContextBuilder(
            sensors: sensors(front: front, recent: recent), blocklist: Blocklist(userBundleIDs: ["user.added"]))
        _ = await builder.capture()
        let seen = recent.seen.withLock { $0 }
        #expect(seen?.pid == 4242)
        #expect(seen?.blocked == [
            "com.1password.1password": true, "com.apple.Passwords.MenuBarExtra": true,
            "com.google.Chrome": false, "user.added": true,
        ])
    }
}

@Suite("WorkspaceRecentApps")
struct RecentAppsTrackerTests {
    typealias Entry = WorkspaceRecentApps.Entry

    func entry(_ pid: Int32, _ name: String, bundle: String? = nil) -> Entry {
        Entry(pid: pid, bundle: bundle, app: ContextPacket.RecentApp(app: name))
    }

    @Test("most recent first, re-activation moves to the front, front app excluded, limit applied")
    func ordering() {
        let tracker = WorkspaceRecentApps(blocklist: { Blocklist() })
        for (pid, name) in [(1, "A"), (2, "B"), (3, "C"), (4, "D"), (5, "E")] { tracker.record(entry(Int32(pid), name)) }
        tracker.record(entry(2, "B"))
        let names = tracker.recent(excluding: 5, isBlocked: { _ in false }).map(\.app)
        #expect(names == ["B", "D", "C"])
        #expect(names.count == WorkspaceRecentApps.limit)
    }

    @Test("an app blocked after it was recorded is no longer returned")
    func blockedLater() {
        let list = Mutex(Blocklist())
        let tracker = WorkspaceRecentApps(blocklist: { list.withLock { $0 } })
        tracker.record(entry(7, "Bank", bundle: "com.example.bank"))
        #expect(tracker.recent(excluding: 0, isBlocked: { _ in false }).map(\.app) == ["Bank"])
        list.withLock { $0 = Blocklist(userBundleIDs: ["com.example.bank"]) }
        #expect(tracker.recent(excluding: 0, isBlocked: { _ in false }).isEmpty)
    }

    @Test("a blocked app being left is not recorded (its title is never read)")
    func blockedNotRecorded() {
        let tracker = WorkspaceRecentApps(blocklist: { Blocklist() })
        tracker.activated(FrontApp(pid: 900, name: "1Password", bundle: "com.1password.1password"))
        tracker.activated(FrontApp(pid: 901, name: "Notes", bundle: "com.apple.Notes"))
        // Leaving 1Password would queue a title read; give the serial queue a moment.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!tracker.recent(excluding: 0, isBlocked: { _ in false }).contains { $0.app == "1Password" })
    }
}
