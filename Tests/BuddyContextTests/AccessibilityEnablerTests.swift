import AppKit
import Foundation
import Synchronization
import Testing
@testable import BuddyContext

@Suite("Accessibility enabler", .serialized)
struct AccessibilityEnablerTests {
    /// Records writes; `current` is what a read returns.
    final class Fake: Sendable {
        let writes = Mutex<[(Int32, String, Bool)]>([])
        let current = Mutex<[Int32: Bool]>([:])
        let refuse = Mutex(false)
        let launches = Mutex<[Int32: Date]>([:])
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        var now: @Sendable () -> Date { { [self] in clock.withLock { $0 } } }
        func advance(_ s: TimeInterval) { clock.withLock { $0 += s } }

        var setter: @Sendable (Int32, AccessibilityEnabler.Switch, Bool) -> Bool? {
            { [self] pid, kind, on in
                if refuse.withLock({ $0 }) { return nil }
                writes.withLock { $0.append((pid, kind.rawValue, on)) }
                return current.withLock { c in defer { c[pid] = on }; return c[pid] ?? false }
            }
        }
        var reader: @Sendable (Int32, AccessibilityEnabler.Switch) -> Bool? { { [self] pid, _ in current.withLock { $0[pid] } } }
        var launch: @Sendable (Int32) -> Date? { { [self] pid in launches.withLock { $0[pid] ?? Date(timeIntervalSince1970: 1) } } }
        var log: [(Int32, String, Bool)] { writes.withLock { $0 } }
    }

    static let electronApp = URL(fileURLWithPath: "/Applications/Slack.app")

    func make(_ f: Fake) -> AccessibilityEnabler {
        AccessibilityEnabler(linger: 60, now: f.now, setter: f.setter, reader: f.reader,
                             electron: { $0 == Self.electronApp }, launchDate: f.launch)
    }

    /// Runs the enabler's queued work.
    func drain(_ e: AccessibilityEnabler) { e.drainForTests() }

    @Test("Chromium gets EnhancedUI, Electron gets ManualAX, other apps nothing")
    func kinds() {
        let f = Fake(); let e = make(f)
        e.enable(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil)
        e.enable(pid: 11, bundleID: "com.tinyspeck.slackmacgap", bundleURL: Self.electronApp)
        e.enable(pid: 12, bundleID: "com.apple.TextEdit", bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        #expect(f.log.map(\.1) == ["AXEnhancedUserInterface", "AXManualAccessibility"])
        #expect(e.enabledPIDs == [10, 11])
    }

    @Test("activation alone never switches anything on; a summon does")
    func onlyAroundASummon() {
        let f = Fake(); let e = make(f)
        e.activated(pid: 10, bundleID: "com.brave.Browser", bundleURL: nil, blocked: false)
        drain(e)
        #expect(f.log.isEmpty) // the user's browser, merely in front: left alone

        e.summoned(pid: 10, bundleID: "com.brave.Browser", bundleURL: nil, blocked: false)
        drain(e)
        #expect(f.log.map(\.2) == [true])
    }

    @Test("the switch goes back off after the linger; another summon extends it")
    func linger() {
        let f = Fake(); let e = make(f)
        e.summoned(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil, blocked: false)
        drain(e)
        f.advance(40)
        e.summoned(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil, blocked: false) // a follow-up
        drain(e)
        f.advance(40) // 80 s after the first, 40 after the last
        e.expire()
        #expect(e.enabledPIDs == [10])
        f.advance(25)
        e.expire()
        #expect(e.enabledPIDs.isEmpty)
        #expect(f.log.map(\.2) == [true, false]) // one write on, one back off
    }

    @Test("once per process; a recycled pid is a new process")
    func oncePerProcess() {
        let f = Fake(); let e = make(f)
        for _ in 0..<3 { e.enable(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil) }
        #expect(f.log.count == 1)
        f.launches.withLock { $0[10] = Date(timeIntervalSince1970: 99) } // relaunched, same pid
        e.enable(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil)
        #expect(f.log.count == 2)
    }

    @Test("a refused write isn't remembered, so the next try writes again")
    func refused() {
        let f = Fake(); let e = make(f)
        f.refuse.withLock { $0 = true }
        e.enable(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil)
        #expect(e.enabledPIDs.isEmpty)
        f.refuse.withLock { $0 = false }
        e.enable(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil)
        #expect(e.enabledPIDs == [10])
    }

    @Test("restore puts back the value found, unless another tool changed it since")
    func restore() {
        let f = Fake(); let e = make(f)
        e.enable(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil)
        e.enable(pid: 11, bundleID: "com.google.Chrome", bundleURL: nil)
        f.current.withLock { $0[11] = false } // e.g. VoiceOver toggled it meanwhile
        e.restore(pid: 10)
        e.restore(pid: 11)
        #expect(f.log.filter { !$0.2 }.map(\.0) == [10])
        #expect(e.enabledPIDs.isEmpty)
    }

    @Test("an app that becomes blocked gets its switch back")
    func becomesBlocked() {
        let f = Fake(); let e = make(f)
        e.summoned(pid: 10, bundleID: "com.tinyspeck.slackmacgap", bundleURL: Self.electronApp, blocked: false)
        drain(e)
        e.activated(pid: 10, bundleID: "com.tinyspeck.slackmacgap", bundleURL: Self.electronApp, blocked: true)
        drain(e)
        #expect(f.log.map(\.2) == [true, false])
    }

    @Test("blocked apps and Lumi itself are never switched on")
    func blocked() {
        let f = Fake(); let e = make(f)
        e.summoned(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil, blocked: true)
        e.summoned(pid: getpid(), bundleID: "com.google.Chrome", bundleURL: nil, blocked: false)
        drain(e)
        #expect(f.log.isEmpty)
    }

    @Test("after restoreAll nothing is switched on again")
    func closed() {
        let f = Fake(); let e = make(f)
        e.enable(pid: 10, bundleID: "com.google.Chrome", bundleURL: nil)
        e.restoreAll()
        e.summoned(pid: 11, bundleID: "com.google.Chrome", bundleURL: nil, blocked: false)
        drain(e)
        #expect(f.log.map(\.2) == [true, false])
    }

    @Test("Electron is found by its framework")
    func electronDetection() {
        #expect(!AccessibilityEnabler.isElectron(URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
    }
}

@Suite("Web-area selection walk")
struct WebSelectionWalkTests {
    final class Node {
        let role: String
        let selected: String?
        let kids: [Node]
        init(_ role: String, selected: String? = nil, _ kids: [Node] = []) { self.role = role; self.selected = selected; self.kids = kids }
    }

    func walk(_ root: Node, maxNodes: Int = 300, budget: Duration = .seconds(1)) -> String? {
        WebSelectionWalk.first(root: root, maxNodes: maxNodes, budget: budget)
    }

    @Test("finds the web area with a selection")
    func finds() {
        let tree = Node("AXWindow", [Node("AXToolbar"), Node("AXSplitGroup", [Node("AXScrollArea", [Node("AXWebArea", selected: "hello")])])])
        #expect(walk(tree) == "hello")
    }

    @Test("an empty selection (a caret) doesn't hide a later real one")
    func emptyIsSkipped() {
        let tree = Node("AXWindow", [Node("AXWebArea", selected: ""), Node("AXGroup", [Node("AXWebArea", selected: "real")])])
        #expect(walk(tree) == "real")
    }

    @Test("list subtrees aren't walked, so a long list can't use up the budget")
    func listsSkipped() {
        let rows = (0..<500).map { _ in Node("AXRow", [Node("AXWebArea", selected: "inside a row")]) }
        let tree = Node("AXWindow", [Node("AXTable", rows), Node("AXWebArea", selected: "viewer")])
        #expect(walk(tree, maxNodes: 20) == "viewer")
    }

    @Test("the node cap and the clock stop the walk")
    func bounded() {
        let deep = (0..<50).reduce(Node("AXWebArea", selected: "far")) { inner, _ in Node("AXGroup", [inner]) }
        #expect(walk(deep) == nil) // past maxDepth 10
        #expect(walk(Node("AXWindow", [Node("AXWebArea", selected: "x")]), budget: .zero) == nil)
    }
}

/// The walk over the fake tree, through the same function the sensor uses.
enum WebSelectionWalk {
    static func first(root: WebSelectionWalkTests.Node, maxNodes: Int, budget: Duration) -> String? {
        AXSelectionSensor.firstSelection(
            from: root, role: { $0.role }, children: { $0.kids }, selection: { $0.selected },
            maxNodes: maxNodes, budget: budget)?.1
    }
}
