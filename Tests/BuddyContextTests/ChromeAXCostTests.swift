import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import BuddyContext

/// What `AXEnhancedUserInterface` costs Chrome: CPU at idle and while
/// scrolling, and whether AX-driven window resizes land and how fast, with EUI off, then on.
/// Also whether this Chrome accepts `AXManualAccessibility` instead. Its own Chrome process
/// (temporary profile, launched directly, tracked by pid), never the user's.
/// `BUDDYCONTEXT_AX_COST=1 BUDDYCONTEXT_AX_OUT=<dir> Scripts/test.sh --filter ChromeAXCost`
@Suite("Chrome AX cost", .enabled(if: ProcessInfo.processInfo.environment["BUDDYCONTEXT_AX_COST"] == "1"), .serialized)
@MainActor
struct ChromeAXCostTests {
    struct Phase: Codable {
        var name: String
        var idleCPU = 0.0       // CPU seconds per wall second, whole Chrome process tree
        var scrollCPU = 0.0
        var resizeSetMs: [Double] = []
        var resizeLanded = 0     // resizes whose final size matched the request
        var resizeSettleMs: [Double] = []
        var webAreas = 0         // AX web areas visible in the window (0 = no tree)
    }

    struct Report: Codable {
        var chromeVersion: String?
        var manualAXError: Int32?
        var manualAXWebAreas = 0
        var phases: [Phase] = []
    }

    @Test func manualAXCostInVSCode() async throws {
        AX.setProcessTimeout()
        let dir = AXSelectionLiveTests.scratch
        let file = try AXSelectionLiveTests.throwaway("ax-cost.md", (0..<300).map { "Line \($0) of the quarterly review." }.joined(separator: "\n"))
        let code = Process()
        code.executableURL = URL(fileURLWithPath: AXSelectionLiveTests.vscodeBinary)
        code.arguments = ["--user-data-dir=\(dir.appending(path: "vscode-cost-data").path)", "--extensions-dir=\(dir.appending(path: "vscode-ext").path)",
                          "--disable-extensions", "--disable-workspace-trust", "--skip-welcome", "--new-window", file.path]
        try code.run()
        defer { code.terminate() }
        let pid = code.processIdentifier
        try await Task.sleep(for: .seconds(6))
        try AXSelectionLiveTests.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"])
        try await Task.sleep(for: .seconds(1))
        var report = Report()
        let app = AXUIElementCreateApplication(pid)
        report.phases.append(try await Self.phase("ManualAX off", pid: pid))
        report.manualAXError = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
        try await Task.sleep(for: .seconds(3))
        report.phases.append(try await Self.phase("ManualAX on", pid: pid))
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: AXSelectionLiveTests.out.appending(path: "ax-vscode-cost.json"))
    }

    @Test func enhancedUICost() async throws {
        AX.setProcessTimeout()
        let dir = AXSelectionLiveTests.scratch
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paragraphs = (0..<400).map { "<p>Paragraph \($0): the quarterly totals and regional growth figures, reviewed line by line for the report.</p>" }
        let page = dir.appending(path: "ax-long.html")
        try "<!doctype html><body style='font:16px -apple-system;margin:40px'>\(paragraphs.joined())</body>".write(to: page, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appending(path: "chrome-cost-profile")) // no restored windows
        let chrome = Process()
        chrome.executableURL = URL(fileURLWithPath: AXSelectionLiveTests.chromeBinary)
        chrome.arguments = ["--user-data-dir=\(dir.appending(path: "chrome-cost-profile").path)", "--no-first-run",
                            "--no-default-browser-check", "--disable-extensions", "--window-size=1000,800", page.path]
        try chrome.run()
        defer { chrome.terminate() }
        let pid = chrome.processIdentifier
        try await Task.sleep(for: .seconds(6))
        try AXSelectionLiveTests.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"])
        try await Task.sleep(for: .seconds(1))

        var report = Report()
        report.chromeVersion = Bundle(url: URL(fileURLWithPath: "/Applications/Google Chrome.app"))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let app = AXUIElementCreateApplication(pid)

        // ManualAX first, on the fresh process.
        report.manualAXError = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
        try await Task.sleep(for: .seconds(3))
        report.manualAXWebAreas = Self.webAreas(pid: pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        try await Task.sleep(for: .seconds(2))

        report.phases.append(try await Self.phase("EUI off", pid: pid))
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .seconds(3)) // the tree builds
        report.phases.append(try await Self.phase("EUI on", pid: pid))
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AXSelectionLiveTests.out, withIntermediateDirectories: true)
        try encoder.encode(report).write(to: AXSelectionLiveTests.out.appending(path: "ax-chrome-cost.json"))
    }

    static func phase(_ name: String, pid: Int32) async throws -> Phase {
        var phase = Phase(name: name)
        phase.webAreas = webAreas(pid: pid)
        // Idle: 8 s with nothing happening.
        var start = cpuSeconds(tree: pid)
        try await Task.sleep(for: .seconds(8))
        phase.idleCPU = used(from: start, to: cpuSeconds(tree: pid)) / 8

        // Scrolling: 60 wheel events over 3 s at the window's centre.
        guard let window = window(pid: pid), let frame = AX.frame(window) else { return phase }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        start = cpuSeconds(tree: pid)
        for i in 0..<60 {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: i < 30 ? -60 : 60, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(50))
        }
        phase.scrollCPU = used(from: start, to: cpuSeconds(tree: pid)) / 3

        // Resizes through AX, as a window manager does.
        for i in 0..<10 {
            var size = CGSize(width: i.isMultiple(of: 2) ? 900 : 1100, height: i.isMultiple(of: 2) ? 700 : 820)
            let value = AXValueCreate(.cgSize, &size)!
            let t0 = ContinuousClock.now
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
            phase.resizeSetMs.append((ContinuousClock.now - t0).milliseconds)
            while ContinuousClock.now - t0 < .seconds(1) {
                if let now = AX.size(window, kAXSizeAttribute), abs(now.width - size.width) < 2, abs(now.height - size.height) < 2 {
                    phase.resizeLanded += 1
                    phase.resizeSettleMs.append((ContinuousClock.now - t0).milliseconds)
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return phase
    }

    static func window(pid: Int32) -> AXUIElement? {
        (AX.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    static func webAreas(pid: Int32) -> Int {
        guard let window = window(pid: pid) else { return 0 }
        var queue = [window]
        var head = 0
        var count = 0
        while head < queue.count, head < 2000 {
            let el = queue[head]
            head += 1
            if AX.string(el, kAXRoleAttribute) == "AXWebArea" { count += 1 }
            queue += (AX.value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return count
    }

    /// CPU used between two samples by the processes alive in both (helpers come and go).
    static func used(from a: [Int32: Double], to b: [Int32: Double]) -> Double {
        b.reduce(0) { sum, entry in sum + max(0, entry.value - (a[entry.key] ?? entry.value)) }
    }

    /// CPU time (user + system) per process for `pid` and every descendant, from ps.
    static func cpuSeconds(tree root: Int32) -> [Int32: Double] {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "pid=,ppid=,time="]
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var parent: [Int32: Int32] = [:]
        var time: [Int32: Double] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            parent[pid] = ppid
            // [[dd-]hh:]mm:ss.cc
            let parts = f[2].split(separator: ":").compactMap { Double($0.replacingOccurrences(of: "-", with: ".")) }
            time[pid] = parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
        }
        func inTree(_ pid: Int32) -> Bool {
            var p = pid
            for _ in 0..<10 { if p == root { return true }; guard let up = parent[p], up > 1 else { return false }; p = up }
            return false
        }
        return time.filter { inTree($0.key) }
    }
}
