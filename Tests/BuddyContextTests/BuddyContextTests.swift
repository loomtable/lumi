import BuddyCore
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyContext

/// Unit tests for BuddyContext. No real sensors, AX, ScreenCaptureKit or NSWorkspace: only the
/// public fakes and pure functions. Serialized because several tests measure wall-clock time and
/// share the sensor queue.
@Suite("BuddyContext", .serialized)
struct BuddyContextTests {}

// MARK: - Fixtures

private enum Fixture {
    static let askedAt = Date(timeIntervalSince1970: 1_760_000_000)
    static let window = ContextPacket.Window(title: "Pull request #12", document: nil)
    static let selection = ContextPacket.Selection(
        text: "let x = 1", bounds: ContextPacket.Rect(x: 10, y: 20, width: 30, height: 12), boundsSource: .axRange)
    static let cursor = ContextPacket.Cursor(x: 100, y: 200, element: ContextPacket.Element(role: "AXButton", label: "Merge"))
    static let display = ContextPacket.Display(id: 1, scale: 2, appearance: .dark)
    static let recent = [ContextPacket.RecentApp(app: "Terminal", title: "zsh"), ContextPacket.RecentApp(app: "Slack")]

    /// Every fake used by one `ContextSensors`, so tests can inspect call counts.
    struct Fakes {
        var frontApp: FakeSensor<FrontApp?>
        var window = FakeSensor<ContextPacket.Window?>(Fixture.window)
        var selection = FakeSensor<ContextPacket.Selection?>(Fixture.selection)
        var cursor = FakeSensor<ContextPacket.Cursor?>(Fixture.cursor)
        var display = FakeSensor<ContextPacket.Display?>(Fixture.display)
        var recent = FakeSensor<[ContextPacket.RecentApp]>(Fixture.recent)
        var editable = FakeSensor<ContextPacket.Editable?>(ContextPacket.Editable(field: true, selection: true))

        init(front: FrontApp?, frontDelay: Duration = .zero) {
            frontApp = FakeSensor<FrontApp?>(front, delay: frontDelay)
        }

        var sensors: ContextSensors {
            ContextSensors(
                frontApp: frontApp, window: window, selection: selection,
                cursor: cursor, display: display, recent: recent, editable: editable)
        }

        /// Call counts of every sensor except the front app.
        var otherCallCounts: [String: Int] {
            ["window": window.callCount, "selection": selection.callCount, "cursor": cursor.callCount,
             "display": display.callCount, "recent": recent.callCount, "editable": editable.callCount]
        }
    }

    static let chrome = FrontApp(pid: 4242, name: "Google Chrome", bundle: "com.google.Chrome")
    static let sensorNames: Set<String> = ["front_app", "window", "selection", "editable", "cursor", "display", "recent", "kind"]
}

// MARK: - ContextBuilder

extension BuddyContextTests {
    @Suite("ContextBuilder")
    struct ContextBuilderTests {
        @Test("happy path fills every sensor field and leaves shell fields empty")
        func happyPath() async throws {
            let fakes = Fixture.Fakes(front: Fixture.chrome)
            let builder = ContextBuilder(sensors: fakes.sensors)
            let result = await builder.capture(at: Fixture.askedAt)
            guard case .packet(let packet, let timings) = result else {
                Issue.record("expected a packet, got \(result)")
                return
            }
            #expect(packet.v == ContextPacket.currentVersion)
            #expect(packet.askedAt == Fixture.askedAt)
            #expect(packet.app == ContextPacket.App(name: "Google Chrome", bundle: "com.google.Chrome", kind: .browser))
            #expect(packet.window == Fixture.window)
            #expect(packet.selection == Fixture.selection)
            #expect(packet.cursor == Fixture.cursor)
            #expect(packet.display == Fixture.display)
            #expect(packet.recent == Fixture.recent)
            // The shell fills these at send.
            #expect(packet.utterance == "")
            #expect(packet.screenshot == nil)
            #expect(packet.conversation == nil)

            #expect(Set(timings.sensorMs.keys) == Fixture.sensorNames)
            #expect(timings.late.isEmpty)
            #expect(timings.totalMs > 0)
            #expect(fakes.frontApp.callCount == 1)
            #expect(fakes.otherCallCounts.values.allSatisfy { $0 == 1 })
        }

        @Test("a blocked front app gives .blocked and no other sensor runs", arguments: [
            "com.1password.1password",
            "com.apple.Passwords",
            "com.agilebits.onepassword7",
            "com.agilebits.onepassword7-helper",
        ])
        func blockedDefault(bundle: String) async {
            let fakes = Fixture.Fakes(front: FrontApp(pid: 77, name: "Vault", bundle: bundle))
            let result = await ContextBuilder(sensors: fakes.sensors).capture()
            #expect(result == .blocked(app: "Vault"))
            #expect(fakes.otherCallCounts.values.allSatisfy { $0 == 0 }, "\(fakes.otherCallCounts)")
        }

        @Test("a user-blocked front app gives .blocked and no other sensor runs")
        func blockedByUser() async {
            let fakes = Fixture.Fakes(front: FrontApp(pid: 78, name: "Bank", bundle: "com.example.bank"))
            let builder = ContextBuilder(sensors: fakes.sensors, blocklist: Blocklist(userBundleIDs: ["com.example.bank"]))
            #expect(await builder.capture() == .blocked(app: "Bank"))
            #expect(fakes.otherCallCounts.values.allSatisfy { $0 == 0 }, "\(fakes.otherCallCounts)")
        }

        @Test("nil front app gives .noFrontApp")
        func nilFrontApp() async {
            let fakes = Fixture.Fakes(front: nil)
            #expect(await ContextBuilder(sensors: fakes.sensors).capture() == .noFrontApp)
            #expect(fakes.otherCallCounts.values.allSatisfy { $0 == 0 })
        }

        @Test("a front-app read slower than frontAppDeadline gives .noFrontApp")
        func slowFrontApp() async {
            let fakes = Fixture.Fakes(front: Fixture.chrome, frontDelay: .milliseconds(200))
            let builder = ContextBuilder(sensors: fakes.sensors, frontAppDeadline: .milliseconds(20))
            let clock = ContinuousClock()
            let start = clock.now
            #expect(await builder.capture() == .noFrontApp)
            #expect(clock.now - start < .milliseconds(150))
            #expect(fakes.otherCallCounts.values.allSatisfy { $0 == 0 })
        }

        @Test("a sensor over the budget still lands, listed as late (the user is still talking)")
        func overBudgetLands() async throws {
            var fakes = Fixture.Fakes(front: Fixture.chrome)
            fakes.selection = FakeSensor<ContextPacket.Selection?>(Fixture.selection, delay: .milliseconds(150))
            let result = await ContextBuilder(sensors: fakes.sensors, budget: .milliseconds(50)).capture()
            guard case .packet(let packet, let timings) = result else { Issue.record("no packet"); return }
            #expect(packet.selection == Fixture.selection)
            #expect(timings.late == ["selection"])
            #expect(try #require(timings.sensorMs["selection"]) >= 150)
        }

        @Test("a sensor past the hard cap is left out and listed as late; capture keeps to the cap")
        func slowSensor() async {
            var fakes = Fixture.Fakes(front: Fixture.chrome)
            fakes.selection = FakeSensor<ContextPacket.Selection?>(Fixture.selection, delay: .milliseconds(400))
            let builder = ContextBuilder(sensors: fakes.sensors, budget: .milliseconds(50), hardCap: .milliseconds(100))
            let clock = ContinuousClock()
            let start = clock.now
            let result = await builder.capture()
            let elapsed = clock.now - start
            guard case .packet(let packet, let timings) = result else {
                Issue.record("expected a packet, got \(result)")
                return
            }
            #expect(elapsed < .milliseconds(300), "capture took \(elapsed)")
            #expect(packet.selection == nil)
            #expect(timings.late == ["selection"])
            #expect(timings.sensorMs["selection"] == nil)
            #expect(Set(timings.sensorMs.keys) == Fixture.sensorNames.subtracting(["selection"]))
            #expect(packet.app != nil)
            #expect(packet.window == Fixture.window)
            #expect(packet.cursor == Fixture.cursor)
            #expect(packet.display == Fixture.display)
            #expect(packet.recent == Fixture.recent)
        }

        @Test("an empty recent list is left out, not []")
        func emptyRecent() async {
            var fakes = Fixture.Fakes(front: Fixture.chrome)
            fakes.recent = FakeSensor<[ContextPacket.RecentApp]>([])
            guard case .packet(let packet, let timings) = await ContextBuilder(sensors: fakes.sensors).capture() else {
                Issue.record("expected a packet")
                return
            }
            #expect(packet.recent == nil)
            #expect(timings.late.isEmpty)
            #expect(timings.sensorMs["recent"] != nil)
        }

        @Test("a sensor with nothing leaves its field out without being late")
        func sensorWithNothing() async {
            var fakes = Fixture.Fakes(front: Fixture.chrome)
            fakes.selection = FakeSensor<ContextPacket.Selection?>(nil)
            guard case .packet(let packet, let timings) = await ContextBuilder(sensors: fakes.sensors).capture() else {
                Issue.record("expected a packet")
                return
            }
            #expect(packet.selection == nil)
            #expect(timings.late.isEmpty)
        }

        @Test("an unbundled front app has kind .other and no bundle")
        func unbundledFrontApp() async {
            let fakes = Fixture.Fakes(front: FrontApp(pid: 9, name: "tool", bundle: nil))
            guard case .packet(let packet, _) = await ContextBuilder(sensors: fakes.sensors).capture() else {
                Issue.record("expected a packet")
                return
            }
            #expect(packet.app == ContextPacket.App(name: "tool", bundle: nil, kind: .other))
        }

        @Test("encoding the packet leaves absent keys out")
        func encodingOmitsAbsentKeys() async throws {
            var fakes = Fixture.Fakes(front: Fixture.chrome)
            fakes.selection = FakeSensor<ContextPacket.Selection?>(nil)
            fakes.recent = FakeSensor<[ContextPacket.RecentApp]>([])
            guard case .packet(let packet, _) = await ContextBuilder(sensors: fakes.sensors).capture(at: Fixture.askedAt)
            else {
                Issue.record("expected a packet")
                return
            }
            let data = try ContextPacket.makeEncoder(timeZone: .gmt).encode(packet)
            let json = try #require(String(data: data, encoding: .utf8))
            // The selection object, not `editable.selection`.
            for absent in ["\"selection\":{", "\"recent\":", "\"screenshot\":", "\"conversation\":", "\"browser\":", "null"] {
                #expect(!json.contains(absent), "\(absent) in \(json)")
            }
            for present in ["\"app\"", "\"window\"", "\"cursor\"", "\"display\"", "\"utterance\":\"\"", "\"asked_at\""] {
                #expect(json.contains(present), "\(present) missing from \(json)")
            }
        }
    }
}

// MARK: - Blocklist

extension BuddyContextTests {
    @Suite("Blocklist")
    struct BlocklistTests {
        @Test("defaults block the listed password managers", arguments: [
            "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.bitwarden.desktop",
            "org.keepassxc.keepassxc", "org.keepassx.keepassxc", "com.lastpass.LastPass",
            "in.sinew.Enpass-Desktop", "me.proton.pass.electron",
        ])
        func defaults(id: String) {
            #expect(Blocklist.defaultBundleIDs.contains(id))
            #expect(Blocklist().isBlocked(bundleID: id))
        }

        @Test("1Password 7 variants match by prefix")
        func prefix() {
            let list = Blocklist()
            #expect(list.isBlocked(bundleID: "com.agilebits.onepassword7"))
            #expect(list.isBlocked(bundleID: "com.agilebits.onepassword-osx"))
            #expect(!list.isBlocked(bundleID: "com.agilebits.other"))
        }

        @Test("nil and ordinary bundle IDs are not blocked")
        func notBlocked() {
            #expect(!Blocklist().isBlocked(bundleID: nil))
            #expect(!Blocklist().isBlocked(bundleID: "com.google.Chrome"))
            // Sub-IDs are blocked only at a dot boundary, so a lookalike name is not.
            #expect(!Blocklist().isBlocked(bundleID: "com.apple.PasswordsHelper"))
        }

        @Test("user additions are blocked alongside the defaults")
        func userAdditions() {
            let list = Blocklist(userBundleIDs: ["com.example.bank"])
            #expect(list.isBlocked(bundleID: "com.example.bank"))
            #expect(list.isBlocked(bundleID: "com.1password.1password"))
            #expect(!Blocklist().isBlocked(bundleID: "com.example.bank"))
        }

        @Test("Codable round-trip keeps user additions")
        func codable() throws {
            let list = Blocklist(userBundleIDs: ["com.example.bank", "com.example.health"])
            let data = try JSONEncoder().encode(list)
            let decoded = try JSONDecoder().decode(Blocklist.self, from: data)
            #expect(decoded == list)
            #expect(decoded.isBlocked(bundleID: "com.example.health"))
        }
    }
}

// MARK: - AppKinds

extension BuddyContextTests {
    @Suite("AppKinds")
    struct AppKindsTests {
        @Test("known bundle IDs map to their kind", arguments: [
            ("com.google.Chrome", ContextPacket.AppKind.browser),
            ("com.apple.Safari", .browser),
            ("org.mozilla.firefox", .browser),
            ("com.microsoft.VSCode", .editor),
            ("dev.zed.Zed", .editor),
            ("com.apple.dt.Xcode", .editor),
            ("com.apple.Terminal", .terminal),
            ("com.googlecode.iterm2", .terminal),
            ("com.mitchellh.ghostty", .terminal),
            ("com.tinyspeck.slackmacgap", .chat),
            ("com.hnc.Discord", .chat),
            ("com.apple.Preview", .document),
            ("md.obsidian", .document),
            ("com.apple.finder", .finder),
        ])
        func known(id: String, kind: ContextPacket.AppKind) {
            #expect(AppKinds.kind(of: id) == kind)
        }

        @Test("JetBrains IDEs match by prefix", arguments: ["com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.goland"])
        func jetBrains(id: String) {
            #expect(AppKinds.kind(of: id) == .editor)
        }

        @Test("unknown and nil bundle IDs are .other")
        func other() {
            #expect(AppKinds.kind(of: nil) == .other)
            #expect(AppKinds.kind(of: "com.example.unknown") == .other)
            #expect(AppKinds.kind(of: "") == .other)
        }

        @Test("no bundle ID is listed under two kinds")
        func noDuplicates() {
            let all = AppKinds.browsers + AppKinds.editors + AppKinds.terminals + AppKinds.chats + AppKinds.documents
            #expect(Set(all).count == all.count)
        }
    }
}

// MARK: - BoundsCheck

extension BuddyContextTests {
    @Suite("BoundsCheck")
    struct BoundsCheckTests {
        static let element = CGRect(x: 100, y: 100, width: 400, height: 300)

        @Test("non-finite rects are rejected", arguments: [
            CGRect(x: CGFloat.nan, y: 10, width: 10, height: 10),
            CGRect(x: 10, y: CGFloat.infinity, width: 10, height: 10),
            CGRect(x: 10, y: 10, width: CGFloat.nan, height: 10),
            CGRect(x: 10, y: 10, width: 10, height: -CGFloat.infinity),
        ])
        func nonFinite(rect: CGRect) {
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: Self.element) == "non-finite")
        }

        @Test("empty rects are rejected", arguments: [
            CGRect(x: 150, y: 150, width: 0, height: 10),
            CGRect(x: 150, y: 150, width: 10, height: 0),
            CGRect(x: 150, y: 150, width: -5, height: 10),
        ])
        func empty(rect: CGRect) {
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: Self.element) == "empty")
        }

        @Test("a rect at the origin is rejected")
        func atOrigin() {
            let rect = CGRect(x: 0, y: 0, width: 50, height: 12)
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: Self.element) == "at origin")
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: nil) == "at origin")
        }

        @Test("a rect equal to the element frame (within 1 pt) is rejected", arguments: [
            CGRect(x: 100, y: 100, width: 400, height: 300),
            CGRect(x: 101, y: 99, width: 399, height: 302),
            CGRect(x: 99, y: 101, width: 402, height: 299),
        ])
        func wholeElement(rect: CGRect) {
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: Self.element) == "whole element")
        }

        @Test("a rect outside the element is rejected", arguments: [
            CGRect(x: 600, y: 150, width: 40, height: 12),
            CGRect(x: 90, y: 150, width: 40, height: 12),
            CGRect(x: 150, y: 395, width: 40, height: 12),
        ])
        func outside(rect: CGRect) {
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: Self.element) == "outside element")
        }

        @Test("a rect inside the element (including the 2 pt slack) is accepted", arguments: [
            CGRect(x: 150, y: 150, width: 40, height: 12),
            CGRect(x: 98, y: 150, width: 40, height: 12),
            CGRect(x: 150, y: 390, width: 40, height: 12),
        ])
        func inside(rect: CGRect) {
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: Self.element) == nil)
        }

        @Test("a valid rect with no usable element frame is accepted")
        func noElementFrame() {
            let rect = CGRect(x: 150, y: 150, width: 40, height: 12)
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: nil) == nil)
            #expect(BoundsCheck.rejectionReason(rect, elementFrame: CGRect(x: 10, y: 10, width: 0, height: 0)) == nil)
        }
    }
}

// MARK: - Deadline

extension BuddyContextTests {
    @Suite("Deadline")
    struct DeadlineTests {
        @Test("fast work returns its value and duration")
        func fast() async throws {
            let result = try #require(await Deadline.run(within: .milliseconds(500)) { 42 })
            #expect(result.value == 42)
            #expect(result.ms >= 0)
            #expect(result.ms < 500)
        }

        @Test("slow work misses the deadline and returns nil promptly")
        func slow() async {
            let clock = ContinuousClock()
            let start = clock.now
            let result = await Deadline.run(within: .milliseconds(50)) { () -> Int in
                Thread.sleep(forTimeInterval: 0.3)
                return 1
            }
            let elapsed = clock.now - start
            #expect(result == nil)
            #expect(elapsed < .milliseconds(250), "took \(elapsed)")
        }

        @Test("many concurrent runs each resume exactly once")
        func concurrent() async {
            let count = 50
            let results = await withTaskGroup(of: Int?.self) { group in
                for i in 0..<count {
                    group.addTask {
                        // Half finish well before the deadline, half well after; the rest race.
                        let sleep = i % 2 == 0 ? 0 : 0.1
                        return await Deadline.run(within: .milliseconds(30)) { () -> Int in
                            if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
                            return i
                        }?.value
                    }
                }
                var collected: [Int?] = []
                for await r in group { collected.append(r) }
                return collected
            }
            #expect(results.count == count)
            let values = results.compactMap { $0 }
            #expect(Set(values).count == values.count)
            #expect(values.allSatisfy { $0 % 2 == 0 })
        }

        @Test("Duration.milliseconds converts seconds and attoseconds")
        func durationMilliseconds() {
            #expect(Duration.milliseconds(1_500).milliseconds == 1_500)
            #expect(Duration.microseconds(250).milliseconds == 0.25)
            #expect(Duration.seconds(2).timeInterval == 2)
        }
    }
}

// MARK: - ScreenshotStore

extension BuddyContextTests {
    @Suite("ScreenshotStore")
    struct ScreenshotStoreTests {
        static func tempDirectory() throws -> URL {
            let dir = FileManager.default.temporaryDirectory.appending(
                path: "buddy-store-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        static func makeFile(_ name: String, in dir: URL, modified: Date) throws -> URL {
            let url = dir.appending(path: name)
            try Data([0x89, 0x50]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }

        @Test("newFileURL is a unique .png inside the directory, which it creates")
        func newFileURL() throws {
            let root = try Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let dir = root.appending(path: "nested/shots", directoryHint: .isDirectory)
            let store = ScreenshotStore(directory: dir)
            let url = store.newFileURL(now: Date(timeIntervalSince1970: 1_760_000_000))
            #expect(url.pathExtension == "png")
            #expect(url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
            #expect(url.lastPathComponent.hasPrefix("1760000000000-"))
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
            #expect(store.newFileURL() != store.newFileURL())
        }

        @Test("sweep deletes only screenshot files (.png, .jpg) older than 24 h")
        func sweep() throws {
            let dir = try Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let now = Date()
            let old1 = try Self.makeFile("old1.png", in: dir, modified: now.addingTimeInterval(-25 * 3600))
            let old2 = try Self.makeFile("old2.png", in: dir, modified: now.addingTimeInterval(-72 * 3600))
            let fresh = try Self.makeFile("fresh.png", in: dir, modified: now.addingTimeInterval(-23 * 3600))
            let oldText = try Self.makeFile("notes.txt", in: dir, modified: now.addingTimeInterval(-48 * 3600))
            let oldJPEG = try Self.makeFile("photo.jpg", in: dir, modified: now.addingTimeInterval(-48 * 3600))

            let removed = ScreenshotStore(directory: dir).sweep(now: now)
            #expect(removed == 3)
            let fm = FileManager.default
            #expect(!fm.fileExists(atPath: old1.path))
            #expect(!fm.fileExists(atPath: old2.path))
            #expect(fm.fileExists(atPath: fresh.path))
            #expect(fm.fileExists(atPath: oldText.path))
            #expect(!fm.fileExists(atPath: oldJPEG.path))
        }

        @Test("sweep uses the store's current retention, never more than 24 h")
        func sweepRetention() throws {
            let dir = try Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let now = Date()
            let twoHours = try Self.makeFile("two.png", in: dir, modified: now.addingTimeInterval(-2 * 3600))
            let recent = try Self.makeFile("recent.png", in: dir, modified: now.addingTimeInterval(-30 * 60))
            let hours = Mutex(6.0)
            let store = ScreenshotStore(directory: dir, retention: { hours.withLock { $0 } * 3600 })
            #expect(store.sweep(now: now) == 0)
            hours.withLock { $0 = 1 }
            #expect(store.sweep(now: now) == 1, "a shorter setting applies at the next sweep")
            #expect(!FileManager.default.fileExists(atPath: twoHours.path))
            #expect(FileManager.default.fileExists(atPath: recent.path))
            let old = try Self.makeFile("old.png", in: dir, modified: now.addingTimeInterval(-25 * 3600))
            #expect(ScreenshotStore(directory: dir, retention: { 48 * 3600 }).sweep(now: now) == 1, "capped at 24 h")
            #expect(!FileManager.default.fileExists(atPath: old.path))
        }

        @Test("sweep of a missing directory removes nothing")
        func sweepMissing() {
            let dir = FileManager.default.temporaryDirectory.appending(path: "buddy-missing-\(UUID().uuidString)")
            #expect(ScreenshotStore(directory: dir).sweep() == 0)
        }
    }
}

// MARK: - FakeScreenshotter

extension BuddyContextTests {
    @Suite("FakeScreenshotter")
    struct FakeScreenshotterTests {
        @Test("returns its URL or throws its error, and counts requests")
        func fake() async throws {
            let url = URL(fileURLWithPath: "/tmp/shot.png")
            let ok = FakeScreenshotter(result: .success(url))
            #expect(try await ok.capture(displayID: 1, blocklist: Blocklist(), options: .model).file == url)
            #expect(ok.lastOptions == .model)
            #expect(ok.requestCount == 1)

            let denied = FakeScreenshotter(result: .failure(.screenRecordingNotGranted))
            await #expect(throws: ScreenshotError.screenRecordingNotGranted) {
                try await denied.capture(displayID: nil, blocklist: Blocklist(), options: .model)
            }
            #expect(denied.requestCount == 1)
        }
    }
}

// MARK: - ContextTimings

extension BuddyContextTests {
    @Suite("ContextTimings")
    struct ContextTimingsTests {
        @Test("a nil result is recorded as late and gives nil")
        func late() {
            var timings = ContextTimings(totalMs: 0, sensorMs: [:], late: [])
            let value: Int? = timings.take("window", nil as (value: Int?, ms: Double)?)
            #expect(value == nil)
            #expect(timings.late == ["window"])
            #expect(timings.sensorMs.isEmpty)
        }

        @Test("an on-time result records its duration and unwraps its value")
        func onTime() {
            var timings = ContextTimings(totalMs: 0, sensorMs: [:], late: [])
            #expect(timings.take("display", (value: 7, ms: 3.5)) == 7)
            #expect(timings.take("cursor", (value: nil as Int?, ms: 1.0)) == nil)
            #expect(timings.sensorMs == ["display": 3.5, "cursor": 1.0])
            #expect(timings.late.isEmpty)
        }
    }
}

// MARK: - Editable

extension BuddyContextTests {
    /// The summon records whether an editable field is in front (Insert / Replace main button).
    @Suite("Editable")
    struct EditableTests {
        @Test("the packet carries it")
        func inThePacket() async {
            let fakes = Fixture.Fakes(front: Fixture.chrome)
            guard case .packet(let packet, _) = await ContextBuilder(sensors: fakes.sensors).capture() else {
                Issue.record("no packet"); return
            }
            #expect(packet.editable == ContextPacket.Editable(field: true, selection: true))
        }
    
        @Test("absent when nothing editable has focus")
        func absent() async {
            var fakes = Fixture.Fakes(front: Fixture.chrome)
            fakes.editable = FakeSensor<ContextPacket.Editable?>(nil)
            guard case .packet(let packet, _) = await ContextBuilder(sensors: fakes.sensors).capture() else {
                Issue.record("no packet"); return
            }
            #expect(packet.editable == nil)
        }
    
        @Test("a blocked app is never read")
        func blocked() async {
            let fakes = Fixture.Fakes(front: FrontApp(pid: 7, name: "1Password", bundle: "com.1password.1password"))
            _ = await ContextBuilder(sensors: fakes.sensors).capture()
            #expect(fakes.editable.callCount == 0)
        }
    
        @Test("wire format: booleans, absent when nil")
        func wire() throws {
            var packet = ContextPacket(askedAt: Date(timeIntervalSince1970: 0), utterance: "x")
            packet.editable = ContextPacket.Editable(field: true, selection: false)
            let json = String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self)
            #expect(json.contains(#""editable":{"field":true,"selection":false}"#))
            packet.editable = nil
            #expect(!String(decoding: try ContextPacket.makeEncoder().encode(packet), as: UTF8.self).contains("editable"))
        }
    }

    @Suite("Editable decision")
    struct EditableDecisionTests {
        typealias E = ContextPacket.Editable
        func decide(_ role: String?, sub: String? = nil, text: Bool = false, value: Bool = false, range: CFRange? = nil) -> E? {
            AXEditableSensor.decide(role: role, subrole: sub, selectedTextSettable: text, valueSettable: value, range: range)
        }

        @Test("text fields and areas, with and without a selection")
        func fields() {
            #expect(decide("AXTextField", text: true, value: true, range: CFRange(location: 3, length: 0)) == E(field: true, selection: false))
            #expect(decide("AXTextArea", text: true, value: true, range: CFRange(location: 3, length: 5)) == E(field: true, selection: true))
            #expect(decide("AXComboBox", value: true) == E(field: true, selection: false))
            #expect(decide("AXTextField", sub: "AXSearchField", value: true) == E(field: true, selection: false))
        }

        @Test("a contenteditable composer counts by its range, without a text role")
        func composer() {
            #expect(decide("AXGroup", value: true, range: CFRange(location: 0, length: 0)) == E(field: true, selection: false))
        }

        @Test("never: secure fields, pages, sliders, read-only text")
        func never() {
            #expect(decide("AXSecureTextField", text: true, value: true, range: CFRange(location: 0, length: 0)) == nil)
            #expect(decide("AXTextField", sub: "AXSecureTextField", text: true, value: true) == nil)
            #expect(decide("AXWebArea", text: true, value: true, range: CFRange(location: 0, length: 4)) == nil)
            #expect(decide("AXSlider", value: true) == nil)
            #expect(decide("AXIncrementor", value: true) == nil)
            #expect(decide("AXTextArea", range: CFRange(location: 0, length: 4)) == nil) // read-only
            #expect(decide(nil) == nil)
        }
    }
}

