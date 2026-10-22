import AppKit
import ApplicationServices
import CoreGraphics
import BuddyCore
import Foundation
import Synchronization
import Testing
import Vision
@testable import BuddyContext

/// In real apps, does AX give the selected text and its on-screen rect,
/// and is Electron's `AXManualAccessibility` or Chromium's `AXEnhancedUserInterface` needed?
///
/// Opt-in, drives real apps (it moves the pointer and double-clicks a word):
/// `BUDDYCONTEXT_AX_LIVE=1 BUDDYCONTEXT_AX_OUT=<dir> Scripts/test.sh --filter AXSelectionLive`
/// Throwaway content where possible (local page, temp file, temporary browser/editor profiles).
/// In apps holding the user's data (Slack, Mail, Notes) it only double-clicks a visible word,
/// read-only, and records lengths, never text. It restores any accessibility switch it set and
/// quits only the apps it launched. Ground truth is the word's rect from OCR of a screenshot.
@Suite("AX selection live", .enabled(if: ProcessInfo.processInfo.environment["BUDDYCONTEXT_AX_LIVE"] == "1"), .serialized)
@MainActor
struct AXSelectionLiveTests {
    static let marker = "zebrafluxion"
    static let chromeBinary = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    static let vscodeBinary = "/Applications/Visual Studio Code.app/Contents/MacOS/Code"
    /// Measure the product's AccessibilityEnabler instead of the raw switches.
    static let useEnabler = ProcessInfo.processInfo.environment["BUDDYCONTEXT_AX_ENABLER"] == "1"
    static let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ax-live", directoryHint: .isDirectory)
    static let out = ProcessInfo.processInfo.environment["BUDDYCONTEXT_AX_OUT"].map { URL(fileURLWithPath: $0) } ?? scratch

    // MARK: Scenarios

    @Test("TextEdit (native AppKit)")
    func textEdit() async throws {
        let file = try Self.throwaway("ax.txt", Self.prose)
        try await measure(name: "TextEdit", bundle: "com.apple.TextEdit", open: ["-a", "TextEdit", file.path])
    }

    @Test("Safari (WebKit)")
    func safari() async throws {
        let file = try Self.throwaway("ax.html", Self.html)
        try await measure(name: "Safari", bundle: "com.apple.Safari", open: ["-a", "Safari", file.path])
    }

    @Test("Chrome (Chromium), temporary profile")
    func chrome() async throws {
        let file = try Self.throwaway("ax.html", Self.html)
        let profile = Self.scratch.appending(path: "chrome-profile").path
        // Its own process, never the user's Chrome: launched directly and tracked by pid.
        try await measure(name: "Chrome", bundle: "com.google.Chrome", binary: Self.chromeBinary, open: [
            "--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check", "--disable-extensions", file.path,
        ], switches: [.manualAX, .enhancedUI])
    }

    @Test("VS Code (Electron), temporary profile")
    func vscode() async throws {
        let file = try Self.throwaway("ax.md", Self.prose)
        let data = Self.scratch.appending(path: "vscode-data").path
        let ext = Self.scratch.appending(path: "vscode-ext").path
        try await measure(name: "VS Code", bundle: "com.microsoft.VSCode", binary: Self.vscodeBinary, open: [
            "--user-data-dir=\(data)", "--extensions-dir=\(ext)",
            "--disable-extensions", "--disable-workspace-trust", "--skip-welcome", "--new-window", file.path,
        ], switches: [.manualAX, .enhancedUI])
    }

    @Test("VS Code (Electron), screen reader mode in the temporary profile")
    func vscodeScreenReader() async throws {
        let file = try Self.throwaway("ax.md", Self.prose)
        let data = Self.scratch.appending(path: "vscode-data-sr")
        try FileManager.default.createDirectory(at: data.appending(path: "User"), withIntermediateDirectories: true)
        try #"{"editor.accessibilitySupport": "on"}"#.write(to: data.appending(path: "User/settings.json"), atomically: true, encoding: .utf8)
        let ext = Self.scratch.appending(path: "vscode-ext").path
        try await measure(name: "VS Code SR", bundle: "com.microsoft.VSCode", binary: Self.vscodeBinary, open: [
            "--user-data-dir=\(data.path)", "--extensions-dir=\(ext)",
            "--disable-extensions", "--disable-workspace-trust", "--skip-welcome", "--new-window", file.path,
        ], switches: [.manualAX])
    }

    @Test("Xcode, throwaway file")
    func xcode() async throws {
        let file = try Self.throwaway("Probe.swift", "// \(Self.prose)\nlet x = 1\n")
        try await measure(name: "Xcode", bundle: "com.apple.dt.Xcode", open: ["-a", "Xcode", file.path], settle: 12)
    }

    @Test("Notes, read-only")
    func notes() async throws {
        try await measure(name: "Notes", bundle: "com.apple.Notes", open: ["-a", "Notes"], privateText: true, bodyPane: true)
    }

    @Test("Mail, read-only")
    func mail() async throws {
        try await measure(name: "Mail", bundle: "com.apple.mail", open: ["-a", "Mail"], privateText: true, settle: 6, bodyPane: true)
    }

    @Test("Slack (Electron), read-only")
    func slack() async throws {
        try await measure(name: "Slack", bundle: "com.tinyspeck.slackmacgap", open: ["-a", "Slack"],
                          switches: [.manualAX], privateText: true, settle: 8)
    }

    // MARK: Measurement

    enum Switch: String { case manualAX = "AXManualAccessibility", enhancedUI = "AXEnhancedUserInterface" }

    struct Run: Codable {
        var variant: String
        var selectionFound = false
        var textMatches = false
        var textLength = 0
        var boundsSource: String?
        var boundsDeltaPt: Double?
        var boundsSizeRatio: Double?
        var p50ms = 0.0
        var maxMs = 0.0
        var locateSource: String?
        var locateDeltaPt: Double?
        var locateMs = 0.0
        var focusedRole: String?
        var note: String?
        /// After setting the switch: until the selection reads (the tree is built), polled.
        var readyMs: Double?
    }

    struct Report: Codable {
        var app: String
        var bundle: String
        var launchedByProbe: Bool
        var targetFound: Bool
        var runs: [Run] = []
    }

    func measure(
        name: String, bundle: String, binary: String? = nil, open args: [String], switches: [Switch] = [],
        privateText: Bool = false, settle: Double = 4, bodyPane: Bool = false
    ) async throws {
        AX.setProcessTimeout()
        // With `binary`: our own process (temporary profile), tracked by pid, so a copy of the app
        // the user has open is never measured, switched or quit.
        var own: Process?
        let wasRunning: Bool
        if let binary {
            wasRunning = false
            // A fresh profile each run: a reused one restores the last run's windows.
            for arg in args where arg.hasPrefix("--user-data-dir=") {
                try? FileManager.default.removeItem(atPath: String(arg.dropFirst("--user-data-dir=".count)))
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args
            try p.run()
            own = p
        } else {
            wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
            try Self.run("/usr/bin/open", args)
        }
        try await Task.sleep(for: .seconds(settle))
        let pid: Int32
        if let own {
            pid = own.processIdentifier
            try Self.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set frontmost of (first process whose unix id is \(pid)) to true"])
        } else {
            try Self.activate(bundle)
            guard let found = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else {
                Issue.record("\(name) didn't start")
                return
            }
            pid = found
        }
        try await Task.sleep(for: .seconds(1))
        var report = Report(app: name, bundle: bundle, launchedByProbe: !wasRunning, targetFound: false)
        defer {
            try? Self.write(report)
            if let own {
                own.terminate() // SIGTERM to our pid only
            } else if !wasRunning {
                // Quit only what this run launched (terminate() from a test process can be ignored).
                try? Self.run("/usr/bin/osascript", ["-e", "tell application id \"\(bundle)\" to quit"])
            }
        }

        // The word to select, from OCR of the app's front window.
        var found: Target?
        for _ in 0..<4 where found == nil { // slow apps draw late
            found = try Self.findWord(pid: pid, marker: privateText ? nil : Self.marker, bodyPane: bodyPane)
            if found == nil { try await Task.sleep(for: .seconds(1.5)) }
        }
        guard let target = found else {
            report.runs.append(Run(variant: "baseline", note: "no target word found by OCR"))
            return
        }
        report.targetFound = true
        Self.doubleClick(CGPoint(x: target.rect.midX, y: target.rect.midY))
        try await Task.sleep(for: .milliseconds(400))
        report.runs.append(Self.sample("baseline", pid: pid, target: target))

        // The product's own path: AccessibilityEnabler, as on app activation.
        if Self.useEnabler, AccessibilityEnabler.kind(
            bundleID: bundle, bundleURL: NSRunningApplication(processIdentifier: pid)?.bundleURL,
            electron: AccessibilityEnabler.isElectron) != nil {
            let enabler = AccessibilityEnabler()
            let setAt = ContinuousClock.now
            enabler.enable(pid: pid, bundleID: bundle, bundleURL: NSRunningApplication(processIdentifier: pid)?.bundleURL)
            var readyMs: Double?
            while readyMs == nil, ContinuousClock.now - setAt < .seconds(4) {
                if AXSelectionSensor().selection(pid: pid) != nil { readyMs = (ContinuousClock.now - setAt).milliseconds }
                else { try await Task.sleep(for: .milliseconds(25)) }
            }
            var run = Self.sample("enabler", pid: pid, target: target)
            run.readyMs = readyMs
            report.runs.append(run)
            enabler.restoreAll()
            try await Task.sleep(for: .milliseconds(300))
        }

        let app = AXUIElementCreateApplication(pid)
        for s in switches where !Self.useEnabler {
            let before = AX.value(app, s.rawValue) as? Bool
            // Select first, then switch on, so the poll times only the tree being built.
            Self.doubleClick(CGPoint(x: target.rect.midX, y: target.rect.midY))
            try await Task.sleep(for: .milliseconds(400))
            let setAt = ContinuousClock.now
            let set = AXUIElementSetAttributeValue(app, s.rawValue as CFString, kCFBooleanTrue)
            var readyMs: Double?
            while readyMs == nil, ContinuousClock.now - setAt < .seconds(4) {
                if AXSelectionSensor().selection(pid: pid) != nil { readyMs = (ContinuousClock.now - setAt).milliseconds }
                else { try await Task.sleep(for: .milliseconds(25)) }
            }
            var run = Self.sample("+\(s.rawValue)", pid: pid, target: target)
            run.readyMs = readyMs
            run.note = "set: \(set == .success ? "ok" : "AXError \(set.rawValue)")"
            report.runs.append(run)
            AXUIElementSetAttributeValue(app, s.rawValue as CFString, (before ?? false) ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    struct Target { var word: String; var rect: CGRect }

    /// Production code paths only: the packet's selection sensor and the rings' locator (AX only,
    /// no screenshot, so OCR can't hide an AX miss).
    static func sample(_ variant: String, pid: Int32, target: Target) -> Run {
        var run = Run(variant: variant)
        let sensor = AXSelectionSensor()
        var times: [Double] = []
        var last: ContextPacket.Selection?
        for _ in 0..<15 {
            let start = ContinuousClock.now
            last = sensor.selection(pid: pid)
            times.append((ContinuousClock.now - start).milliseconds)
        }
        times.sort()
        run.p50ms = times[times.count / 2]
        run.maxMs = times.last ?? 0
        let app = AXUIElementCreateApplication(pid)
        run.focusedRole = AX.element(app, kAXFocusedUIElementAttribute).flatMap { AX.string($0, kAXRoleAttribute) }
        if let sel = last {
            run.selectionFound = true
            let text = sel.text ?? ""
            run.textLength = text.count
            run.textMatches = text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(target.word) == .orderedSame
            run.boundsSource = sel.boundsSource?.rawValue
            if let b = sel.bounds {
                let r = CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
                run.boundsDeltaPt = hypot(r.midX - target.rect.midX, r.midY - target.rect.midY)
                run.boundsSizeRatio = (r.width * r.height) / max(target.rect.width * target.rect.height, 1)
            }
        }
        let partial = AXTextSearch.Partial()
        let start = ContinuousClock.now
        AXTextSearch.find([target.word], pid: pid, limits: .init(elements: 4_000, depth: 40, budget: .milliseconds(150)), into: partial)
        run.locateMs = (ContinuousClock.now - start).milliseconds
        if let found = partial.points.withLock({ $0[target.word] }) {
            run.locateSource = found.source.rawValue
            run.locateDeltaPt = hypot(found.rect.midX - target.rect.midX, found.rect.midY - target.rect.midY)
        }
        return run
    }

    // MARK: Helpers

    /// The marker's rect, or (no marker) a longish word near the middle of the front window.
    /// `bodyPane`: the rightmost pane (a note's or a message's body), not the list beside it.
    static func findWord(pid: Int32, marker: String?, bodyPane: Bool = false) throws -> Target? {
        guard let window = frontWindow(pid: pid) else { return nil }
        let shotURL = scratch.appending(path: "shot.png")
        try run("/usr/sbin/screencapture", ["-x", "-m", shotURL.path])
        defer { try? FileManager.default.removeItem(at: shotURL) }
        guard let src = CGImageSourceCreateWithURL(shotURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let display = CGDisplayBounds(CGMainDisplayID())
        let scale = Double(image.width) / display.width
        guard let crop = image.cropping(to: CGRect(
            x: (window.minX - display.minX) * scale, y: (window.minY - display.minY) * scale,
            width: window.width * scale, height: window.height * scale).integral) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: crop).perform([request])
        if ProcessInfo.processInfo.environment["BUDDYCONTEXT_AX_DEBUG"] == "1", marker != nil {
            print("AXDEBUG window=\(window) image=\(image.width)x\(image.height) lines=\(request.results?.count ?? 0)")
            for o in (request.results ?? []).prefix(12) { print("AXDEBUG line: \(o.topCandidates(1).first?.string ?? "")") }
            if let dest = CGImageDestinationCreateWithURL(out.appending(path: "debug-crop.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, crop, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        var candidates: [Target] = []
        for observation in request.results ?? [] {
            guard let top = observation.topCandidates(1).first else { continue }
            let line = top.string
            for token in line.split(whereSeparator: { !$0.isLetter }) where marker.map({ token.lowercased() == $0 }) ?? (token.count >= 7) {
                let range = line.range(of: String(token))!
                let found = Result { try top.boundingBox(for: range) }
                if ProcessInfo.processInfo.environment["BUDDYCONTEXT_AX_DEBUG"] == "1" { print("AXDEBUG token=\(token) box=\(found)") }
                guard let box = (try? found.get())??.boundingBox else { continue }
                // Vision: normalised, bottom-left origin, in the crop.
                let r = CGRect(
                    x: window.minX + box.minX * window.width, y: window.minY + (1 - box.maxY) * window.height,
                    width: box.width * window.width, height: box.height * window.height)
                candidates.append(Target(word: String(token), rect: r))
            }
        }
        if marker != nil { return candidates.first }
        // Away from sidebars and toolbars: nearest the window's centre (or the body pane's).
        let centre = bodyPane ? CGPoint(x: window.minX + window.width * 0.78, y: window.midY) : CGPoint(x: window.midX, y: window.midY)
        if bodyPane { candidates.removeAll { $0.rect.midX < window.minX + window.width * 0.55 } }
        return candidates.min { hypot($0.rect.midX - centre.x, $0.rect.midY - centre.y) < hypot($1.rect.midX - centre.x, $1.rect.midY - centre.y) }
    }

    static func frontWindow(pid: Int32) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let b = mine?[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    static func doubleClick(_ p: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for click in 1...2 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                e?.post(tap: .cghidEventTap)
            }
            usleep(60_000)
        }
    }

    static func activate(_ bundle: String) throws {
        try run("/usr/bin/osascript", ["-e", "tell application id \"\(bundle)\" to activate"])
    }

    static func throwaway(_ name: String, _ content: String) throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appending(path: name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }

    static func write(_ report: Report) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let name = report.app.lowercased().replacingOccurrences(of: " ", with: "-")
        try encoder.encode(report).write(to: out.appending(path: "ax-\(name).json"))
    }

    static let prose = "The quarterly totals moved after the review. A \(marker) appears once in this paragraph, between ordinary words, so it can be found and selected."
    static let html = """
        <!doctype html><html><body style="font: 18px -apple-system; margin: 80px; max-width: 640px">
        <h1>AX probe page</h1><p>\(prose)</p><p>Another paragraph follows with plain words only.</p>
        </body></html>
        """
}
