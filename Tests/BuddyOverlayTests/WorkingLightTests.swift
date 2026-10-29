import Foundation
import QuartzCore
import Testing
@testable import BuddyOverlay

/// QA U22: the working light sweeps the top edge once per 2.4 s, from off one edge to off the other.
struct WorkingLightTests {
    @Test func oneSweepCrossesTheWholeEdge() throws {
        let a = WorkingLight.sweep(width: 800)
        // The 160 pt light's centre starts with all of it off the leading edge and ends off the trailing one.
        let from = try #require(a.fromValue as? CGFloat), to = try #require(a.toValue as? CGFloat)
        #expect(from + WorkingLight.sweepWidth / 2 == 0)
        #expect(to - WorkingLight.sweepWidth / 2 == 800)
        #expect(a.duration == 2.4)
        #expect(a.repeatCount == .infinity)
        #expect(a.timingFunction == nil)  // linear, so the light never stalls at an edge
        #expect(Motion.workingSweep == 2.4)
    }
}
