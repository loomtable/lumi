import AppKit
import BuddyCore
import Foundation
import ImageIO
import Testing
@testable import BuddyContext

/// Real sensors on the dev Mac. Off by default (CI has no grants); run with
/// `BUDDYCONTEXT_LIVE=1 Scripts/test.sh --filter LiveContext` once the host terminal has
/// Accessibility and Screen Recording. Prints p50/p95; never prints selected text.
@Suite("Live context", .enabled(if: ProcessInfo.processInfo.environment["BUDDYCONTEXT_LIVE"] == "1"), .serialized)
struct LiveContextTests {
    static func pct(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int((p / 100 * Double(s.count)).rounded(.up)) - 1))]
    }

    static func stats(_ label: String, _ v: [Double]) -> String {
        guard !v.isEmpty else { return "\(label): n=0" }
        return String(format: "%@: n=%d p50=%.2f p95=%.2f max=%.2f ms", label, v.count, pct(v, 50), pct(v, 95), v.max()!)
    }

    @Test("packet build: 30 captures of the front app within budget")
    func packetBudget() async throws {
        ContextBuilder.prepare()
        let builder = ContextBuilder(sensors: .live(recent: WorkspaceRecentApps(blocklist: { Blocklist() })))
        var totals: [Double] = []
        var perSensor: [String: [Double]] = [:]
        var late: [String: Int] = [:]
        var fields: Set<String> = []
        for _ in 0..<30 {
            guard case .packet(let p, let t) = await builder.capture() else {
                Issue.record("no packet")
                return
            }
            totals.append(t.totalMs)
            for (k, v) in t.sensorMs { perSensor[k, default: []].append(v) }
            for k in t.late { late[k, default: 0] += 1 }
            if p.window != nil { fields.insert("window") }
            if p.selection != nil { fields.insert("selection") }
            if p.cursor?.element != nil { fields.insert("cursor.element") }
            if p.display != nil { fields.insert("display") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .packet(let last, _) = await builder.capture() else { return }
        print("front app: \(last.app?.name ?? "?") [\(last.app?.bundle ?? "?")] kind=\(last.app?.kind.rawValue ?? "?")")
        print(Self.stats("TOTAL", totals))
        for (k, v) in perSensor.sorted(by: { $0.key < $1.key }) { print(Self.stats("  \(k)", v)) }
        print("late: \(late)  fields seen: \(fields.sorted())")
        #expect(Self.pct(totals, 95) < 200)
    }

    @Test("per-app window and selection reads by pid (no activation)")
    func perApp() {
        ContextBuilder.prepare()
        let ids = ["com.apple.Safari", "com.google.Chrome", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode",
                   "com.googlecode.iterm2", "com.apple.finder"]
        for id in ids {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
                print("\(id): not running")
                continue
            }
            var w: [Double] = [], s: [Double] = []
            var hasWindow = false, hasSel = false, hasBounds = false
            var source: String?
            for _ in 0..<15 {
                var t = ContinuousClock.now
                hasWindow = AXWindowSensor().window(pid: app.processIdentifier) != nil || hasWindow
                w.append((ContinuousClock.now - t).milliseconds)
                t = ContinuousClock.now
                let sel = AXSelectionSensor().selection(pid: app.processIdentifier)
                s.append((ContinuousClock.now - t).milliseconds)
                if let sel {
                    hasSel = true
                    if sel.bounds != nil { hasBounds = true; source = sel.boundsSource?.rawValue }
                }
            }
            print("\(id): window=\(hasWindow) selection=\(hasSel) bounds=\(hasBounds) source=\(source ?? "-")")
            print(Self.stats("  window read", w))
            print(Self.stats("  selection read", s))
        }
    }

    @Test("screenshot: capture time, then encode cost and size per format; files deleted")
    func screenshot() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "buddy-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScreenshotStore(directory: dir)
        let shooter = ScreenCaptureKitShooter(store: store)
        var captureTimes: [Double] = []
        var shot: Screenshot?
        for _ in 0..<5 {
            let t = ContinuousClock.now
            let s = try await shooter.capture(displayID: nil, blocklist: Blocklist(), options: .model)
            captureTimes.append((ContinuousClock.now - t).milliseconds)
            #expect(try Data(contentsOf: s.file) == s.fileData)
            #expect(s.fileWidth == 1568 || s.fileHeight == 1568)
            shot = s
        }
        print(Self.stats("capture + encode(.model)", captureTimes))
        // A window region: the file is that part of the display, `full` still all of it.
        let frame = try #require(shot).displayFrame
        let region = CGRect(x: frame.minX + 100, y: frame.minY + 80, width: 900, height: 600)
        let w = try await shooter.capture(displayID: nil, blocklist: Blocklist(), options: .model, region: region)
        #expect(abs(w.fileRect.minX - region.minX) < 1 && abs(w.fileRect.width - region.width) < 2)
        let edge = min(1568.0, 900 * w.scale)
        #expect(w.fileWidth == Int(edge.rounded()) && w.fileHeight == Int((edge * 600 / 900).rounded()))
        #expect((w.full.width, w.full.height) == (shot!.full.width, shot!.full.height))
        print("window region: \(w.fileWidth)×\(w.fileHeight) px for 900×600 pt")
        let full = try #require(shot).full
        print("full image: \(full.width)×\(full.height) px, scale \(shot!.scale)")
        var backdropTimes: [Double] = []
        for _ in 0..<5 {
            let t = ContinuousClock.now
            let b = try #require(shot!.backdrop())
            backdropTimes.append((ContinuousClock.now - t).milliseconds)
            #expect(b.width == Int((shot!.displayFrame.width * 0.25).rounded()))
        }
        print(Self.stats("backdrop (0.25 per point, from full)", backdropTimes))
        let options: [(String, ScreenshotOptions)] = [
            ("full PNG", .fullPNG),
            ("full JPEG q0.7", .init(maxLongEdge: nil, format: .jpeg(quality: 0.7))),
            ("1568 JPEG q0.7", .init(maxLongEdge: 1568, format: .jpeg(quality: 0.7))),
            ("1280 JPEG q0.7", .init(maxLongEdge: 1280, format: .jpeg(quality: 0.7))),
            ("1024 JPEG q0.7", .init(maxLongEdge: 1024, format: .jpeg(quality: 0.7))),
            ("1024 JPEG q0.5", .init(maxLongEdge: 1024, format: .jpeg(quality: 0.5))),
            ("1024 PNG", .init(maxLongEdge: 1024, format: .png)),
        ]
        for (label, o) in options {
            var times: [Double] = []
            var bytes = 0
            var dims = (0, 0)
            for _ in 0..<5 {
                let url = store.newFileURL(extension: o.fileExtension)
                let t = ContinuousClock.now
                let size = try ImageFile.write(full, to: url, options: o)
                times.append((ContinuousClock.now - t).milliseconds)
                bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                dims = (size.width, size.height)
                // Check the file's real pixel size matches what we report.
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    #expect(props[kCGImagePropertyPixelWidth] as? Int == size.width)
                }
                try? FileManager.default.removeItem(at: url)
            }
            let tokens = dims.0 * dims.1 / 750
            print(Self.stats("  encode \(label) \(dims.0)×\(dims.1) \(bytes / 1024) KB ~\(tokens) tok", times))
        }
    }

    @Test("stress: 20 overlapping captures (concurrent AX calls) all complete")
    func concurrentCaptures() async {
        ContextBuilder.prepare()
        let builder = ContextBuilder(sensors: .live(recent: WorkspaceRecentApps(blocklist: { Blocklist() })))
        let results = await withTaskGroup(of: Double?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    if case .packet(_, let t) = await builder.capture() { return t.totalMs }
                    return nil
                }
            }
            var out: [Double?] = []
            for await r in group { out.append(r) }
            return out
        }
        let totals = results.compactMap { $0 }
        #expect(totals.count == 20)
        print(Self.stats("overlapping captures", totals))
    }
}

/// AX locate against a real app window (Numbers, if a document is open). Read-only. Opt-in.
@Suite("Live locate", .enabled(if: ProcessInfo.processInfo.environment["BUDDYCONTEXT_LIVE"] == "1"))
struct LiveLocateTests {
    @Test("Numbers toolbar: a control's label is not a quote")
    func numbers() async {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Numbers").first else {
            Issue.record("Numbers isn't running: open a Numbers document to run this live test")
            return
        }
        ContextBuilder.prepare()
        let locator = ScreenPointLocator()
        let t = ContinuousClock.now
        let points = await locator.locate(["Chart"], pid: app.processIdentifier, screenshot: nil, blocklist: Blocklist())
        print(String(format: "Numbers: quote %d found via %@ (%.0f ms)",
                     points.count, points.first?.source.rawValue ?? "-", (ContinuousClock.now - t).milliseconds))
        // "Chart" is a toolbar checkbox's description, not body text, so the quote search skips it.
        #expect(points.isEmpty)
    }
}
