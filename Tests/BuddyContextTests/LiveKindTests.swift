import AppKit
import BuddyCore
import Foundation
import Testing
@testable import BuddyContext

/// M2 sensors against real processes. Opt-in like LiveContextTests. Never prompts: Automation
/// consent is only checked, and the URL is read only if consent already exists.
@Suite("Live kinds", .enabled(if: ProcessInfo.processInfo.environment["BUDDYCONTEXT_LIVE"] == "1"), .serialized)
struct LiveKindTests {
    static func short(_ path: String?) -> String {
        guard let path else { return "nil" }
        return path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }

    @Test("local server: a python http.server on 127.0.0.1 is found by port with its cwd")
    func localServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "buddy-srv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = Int.random(in: 47_000...48_999)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        server.currentDirectoryURL = dir
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        // Wait until it listens.
        var found: ContextPacket.LocalServer?
        for _ in 0..<50 {
            found = LibprocLocalServerSensor().server(for: "http://localhost:\(port)/index.html")
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let s = try #require(found)
        #expect(s.port == port)
        #expect(s.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == dir.resolvingSymlinksInPath().path)
        print("local_server pid=\(s.pid) command=\(s.command ?? "nil") (server pid \(server.processIdentifier))")
        var times: [Double] = []
        for _ in 0..<15 {
            let t = ContinuousClock.now
            _ = LibprocLocalServerSensor().server(for: "http://127.0.0.1:\(port)/")
            times.append((ContinuousClock.now - t).milliseconds)
        }
        print(LiveContextTests.stats("local_server lookup", times))
        let miss = ContinuousClock.now
        #expect(LibprocLocalServerSensor().server(for: "http://localhost:1/") == nil)
        print(String(format: "local_server miss (scans every process): %.2f ms", (ContinuousClock.now - miss).milliseconds))
    }

    @Test("terminal: iTerm2 / Terminal / Ghostty front tab, if running")
    func terminal() {
        for id in ["com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
                print("\(id): not running")
                continue
            }
            let front = FrontApp(pid: app.processIdentifier, name: app.localizedName ?? id, bundle: id)
            var times: [Double] = []
            var last: ContextPacket.Terminal?
            for _ in 0..<10 {
                let t = ContinuousClock.now
                last = ProcessTreeTerminalSensor().terminal(app: front)
                times.append((ContinuousClock.now - t).milliseconds)
            }
            print("\(id): cwd=\(Self.short(last?.cwd)) command=\(last?.command ?? "nil")")
            print(LiveContextTests.stats("  terminal read", times))
        }
    }

    @Test("browser: consent status only; URL read only if already granted")
    func browser() {
        for id in ["com.google.Chrome", "com.apple.Safari", "com.brave.Browser"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
                print("\(id): not running")
                continue
            }
            let t = ContinuousClock.now
            let consent = AutomationConsent.check(pid: app.processIdentifier)
            print(String(format: "\(id): consent=\(consent) (check %.2f ms)", (ContinuousClock.now - t).milliseconds))
            guard consent == .granted else { continue }
            let front = FrontApp(pid: app.processIdentifier, name: id, bundle: id)
            var times: [Double] = []
            var host: String?
            for _ in 0..<10 {
                let t = ContinuousClock.now
                host = AppleEventBrowserSensor().browser(app: front)?.host
                times.append((ContinuousClock.now - t).milliseconds)
            }
            print("  host=\(host ?? "nil")")
            print(LiveContextTests.stats("  browser read", times))
        }
    }

    /// Manual step: shows the system Automation dialog for each running Chromium/Safari browser
    /// (answer OK), then reads the front tab's URL. Run with BUDDYCONTEXT_CONSENT=1. Prints the
    /// host only. Revoke afterwards in System Settings › Privacy & Security › Automation.
    @Test("browser: request consent, then read the URL", .enabled(if: ProcessInfo.processInfo.environment["BUDDYCONTEXT_CONSENT"] == "1"))
    func browserWithConsent() async {
        for id in ["com.google.Chrome", "com.apple.Safari", "com.brave.Browser"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { continue }
            let pid = app.processIdentifier
            // Off the main thread: request blocks until the user answers.
            let consent = await Task.detached { AutomationConsent.request(pid: pid) }.value
            print("\(id): consent after request = \(consent)")
            guard consent == .granted else { continue }
            let front = FrontApp(pid: pid, name: id, bundle: id)
            var times: [Double] = []
            var browser: ContextPacket.Browser?
            for _ in 0..<10 {
                let t = ContinuousClock.now
                browser = AppleEventBrowserSensor().browser(app: front)
                times.append((ContinuousClock.now - t).milliseconds)
            }
            #expect(browser != nil)
            print("  host=\(browser?.host ?? "nil") tabTitle=\(browser?.tabTitle != nil)")
            print(LiveContextTests.stats("  browser read (consented)", times))
        }
    }
}
