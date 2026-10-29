import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import BuddyOverlay

/// Motion (docs/v2-sessions/60-MOTION.md): its few named values, Reduce Motion, and the perf
/// budget that keeps idle surfaces from running anything per frame.
struct MotionTests {
    @Test func theNamedAnimationsKeepTheirValues() {
        #expect(Motion.pop == .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.56))
        #expect(Motion.fold == .timingCurve(0.4, 0, 1, 1, duration: 0.2))
        #expect(Motion.settle == .smooth(duration: 0.25))
        #expect(Motion.quick == .easeInOut(duration: 0.15))
        #expect(Motion.crossfade == .easeInOut(duration: 0.2))
        #expect(Motion.Loop.breathe == .init(period: 1.6, low: 0.55))
        #expect(Motion.Loop.pulse == .init(period: 2.4, low: 0.3))
        #expect(Motion.workingSweep == 2.4)
    }

    @Test func reduceMotionCrossfadesEverythingAndMovesNothing() {
        for a in [Motion.pop, Motion.pillIn, Motion.fold, Motion.tuck, Motion.fullScreen, Motion.settle] {
            #expect(Motion.animation(a, reduceMotion: true) == Motion.crossfade)
            #expect(Motion.animation(a, reduceMotion: false) == a)
        }
    }

    @Test func loopsStopWithReduceMotionAndWhenHidden() {
        #expect(Motion.loopRuns(visible: true, reduceMotion: false))
        #expect(!Motion.loopRuns(visible: true, reduceMotion: true))
        #expect(!Motion.loopRuns(visible: false, reduceMotion: false))
        let a = Motion.caBreathe(.breathe)
        #expect(a.keyPath == "opacity" && a.autoreverses && a.repeatCount == .infinity)
        #expect(a.duration == 0.8)  // half a cycle, then back
        #expect(RippleOrb.ripple().duration == Motion.Loop.breathe.period)
    }

    @Test func idleRunsNoGlow() {
        #expect(!OverlayRootView.glowRuns(speaking: false, glow: true))
        #expect(!OverlayRootView.glowRuns(speaking: true, glow: false))
        #expect(OverlayRootView.glowRuns(speaking: true, glow: true))
    }

    /// Every TimelineView in the UI modules, with the state that gates it. A new one has to be
    /// added here on purpose; loops belong to Core Animation (`Motion.Loop`), never to SwiftUI
    /// `repeatForever`, a Timer or a display link.
    static let allowedTimelines: [String: Int] = [
        "BuddyOverlay/OverlayRootView.swift": 2,             // listening rim; speaking glow
        "BuddyOverlay/SurfaceViews.swift": 1,                // dot field, while listening
        "BuddyOverlay/InkText.swift": 2,                     // ink-in until done; level bars while listening
        "BuddyOverlay/Conversation/TrailView.swift": 2,      // 1 s clocks while work runs
        "BuddyOverlay/Conversation/ApprovalCards.swift": 1,  // 1 s countdown on an open approval
        "BuddyOverlay/Conversation/TeammateViews.swift": 1,  // 1 s elapsed while teammates work
        "BuddyOverlay/ProgressViews.swift": 1,               // 30 s quiet age, only while a capsule shows
        "BuddyCompanion/Studio/StudioSidebar.swift": 1,      // relative times: 1 s while running, else 60 s
    ]

    static func uiSources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var out: [(String, String)] = []
        for module in ["BuddyOverlay", "BuddyCompanion", "Lumi"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(module), includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                out.append((String(url.path.dropFirst(root.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    @Test func timelinesAreOnlyWhereTheBudgetAllows() throws {
        let sources = try Self.uiSources()
        #expect(sources.count > 50)  // the scan found the modules
        var found: [String: Int] = [:]
        for (path, text) in sources {
            let n = text.components(separatedBy: "TimelineView(").count - 1
            if n > 0 { found[path] = n }
        }
        #expect(found == Self.allowedTimelines)
    }

    /// The teammate lane's clock ticks only while someone works (final suite, Oct 29).
    @Test func theTeammateLaneTicksOnlyWhileATeammateWorks() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let working = TeamLane.WorkingClock(running: true).entries(from: start, mode: .normal)
        #expect(Array(working.prefix(3)) == [start, start.addingTimeInterval(1), start.addingTimeInterval(2)])
        let done = TeamLane.WorkingClock(running: false).entries(from: start, mode: .normal)
        #expect(Array(done) == [start], "drawn once, never again")
    }

    @Test func noLoopsOutsideCoreAnimation() throws {
        for (path, text) in try Self.uiSources() {
            for banned in ["repeatForever", "Timer.scheduledTimer", "Timer.publish", "CADisplayLink", "displayLink("] {
                #expect(!text.contains(banned), "\(path) uses \(banned)")
            }
        }
    }
}
