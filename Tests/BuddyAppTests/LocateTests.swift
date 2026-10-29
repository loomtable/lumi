import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import Synchronization

/// Rings for an answer's `points` (one-shot rings; ones that can't be found are left out).
@MainActor
struct LocateTests {
    let voice = FakeVoice()
    let bridge = FakeBridge()
    let overlay = FakeOverlay()

    static let table = CGRect(x: 10, y: 20, width: 300, height: 40)
    static let total = CGRect(x: 10, y: 80, width: 120, height: 20)

    func make(context: any ContextPort = FakeContext.packet(), locator: FakeLocator, rings: Bool = true) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        settings.rings = rings
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: context, turns: bridge,
            overlay: overlay, pointer: FixedPointer(), locator: locator)
        coordinator.start()
        return coordinator
    }

    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(30) // a condition, not a budget: returns as soon as it holds
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func ask(_ coordinator: BuddyCoordinator) async {
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.holdBegan))
        await coordinator.handle(.gesture(.holdEnded))
        await settle(until: { coordinator.phase != .thinking })
    }

    var rings: [[Ring]] {
        overlay.calls.compactMap { if case .rings(let r) = $0 { r } else { nil } }
    }

    static let answer = BuddyBlock(
        say: "The totals row is off.", shape: .card,
        points: [.init(quote: "Q3 table", label: "1"), .init(quote: "not on screen", label: "2"),
                 .init(quote: "Total", label: "3")])

    @Test func aSummonRunsNoOCRUntilAnAnswerHasPoints() async {
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let locator = FakeLocator()
        let coordinator = make(locator: locator)
        await ask(coordinator)
        for _ in 0..<200 { await Task.yield() }
        #expect(locator.calls.isEmpty) // no OCR at the summon, and no points to find
    }

    @Test func answerRingsTheFoundPointsWithTheirLabels() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let locator = FakeLocator(rects: ["Q3 table": Self.table, "Total": Self.total])
        let coordinator = make(locator: locator)
        await ask(coordinator)
        await settle(until: { !rings.isEmpty })

        #expect(locator.calls.last == .locate(["Q3 table", "not on screen", "Total"], pid: 4242, path: "/tmp/shot.jpg"))
        // The missing quote is skipped, the rest keep their labels.
        #expect(rings == [[Ring(rect: Self.table, label: "1"), Ring(rect: Self.total, label: "3")]])
    }

    @Test func nothingFoundShowsNoRings() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let locator = FakeLocator()
        let coordinator = make(locator: locator)
        await ask(coordinator)
        await settle(until: { locator.returned == 1 })
        for _ in 0..<100 { await Task.yield() }
        #expect(rings.isEmpty)
    }

    @Test func ringsOffMeansNoOCRNoLocateAndTheModelIsTold() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)]) // points arrive anyway
        let locator = FakeLocator(rects: ["Q3 table": Self.table])
        let coordinator = make(locator: locator, rings: false)
        await ask(coordinator)
        for _ in 0..<200 { await Task.yield() }
        #expect(locator.calls.isEmpty) // no locate
        #expect(rings.isEmpty)
        #expect(bridge.asked.first?.packet.features == ContextPacket.Features(rings: false, insert: true))
        _ = coordinator
    }

    @Test func answerWithoutPointsLocatesNothing() async {
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let locator = FakeLocator(rects: ["Q3 table": Self.table])
        let coordinator = make(locator: locator)
        await ask(coordinator)
        #expect(coordinator.phase == .showing)
        #expect(locator.locateCount == 0)
    }

    @Test func blockedAppIsNeverPreparedOrLocated() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let locator = FakeLocator(rects: ["Q3 table": Self.table])
        let coordinator = make(context: FakeContext(result: .blocked(app: "1Password")), locator: locator)
        await ask(coordinator)
        for _ in 0..<50 { await Task.yield() }
        #expect(locator.calls.isEmpty)
        #expect(rings.isEmpty)
    }

    /// Waits for a gated locate to answer, then lets its ring task run.
    func releaseAndDrain(_ locator: FakeLocator) async {
        locator.release()
        await settle(until: { locator.returned == locator.locateCount })
        for _ in 0..<100 { await Task.yield() }
    }

    @Test(arguments: [false, true])
    func ringsFoundAfterTheCardClosedAreDropped(viaCloseButton: Bool) async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let locator = FakeLocator(rects: ["Q3 table": Self.table], gated: true)
        let coordinator = make(locator: locator)
        await ask(coordinator)
        await settle(until: { locator.waiting == 1 })

        // Closed while AX/OCR still runs: Esc starts a new epoch, ✕ only leaves .showing.
        if viaCloseButton {
            overlay.dismiss(.closeButton)
            await settle(until: { coordinator.phase == .idle })
        } else {
            await coordinator.escapePressed()
        }
        await releaseAndDrain(locator)
        #expect(locator.returned == 1)
        #expect(rings.isEmpty)
    }

    @Test func turnWithNoFrontAppNeverRingsThePreviousApp() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let locator = FakeLocator(rects: ["Q3 table": Self.table])
        let context = ScriptedContext([FakeContext.packet(), FakeContext(result: .noFrontApp)])
        let coordinator = make(context: context, locator: locator)
        await ask(coordinator)
        await settle(until: { rings.count == 1 })

        await ask(coordinator)
        for _ in 0..<100 { await Task.yield() }
        #expect(bridge.asked.count == 2)
        #expect(locator.locateCount == 1)
        #expect(rings.count == 1)
    }

    @Test func laterAnswersUseAccessibilityOnly() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let locator = FakeLocator(rects: ["Q3 table": Self.table])
        let coordinator = make(locator: locator)
        await ask(coordinator)
        await settle(until: { rings.count == 1 })

        // Go deeper answers seconds later: the summon screenshot may no longer match the screen.
        overlay.send(.goDeeper)
        await settle(until: { locator.locateCount == 2 })
        #expect(locator.calls.last == .locate(["Q3 table", "not on screen", "Total"], pid: 4242, path: nil))
    }

    @Test func pointsSharingAQuoteKeepTheirOwnLabels() async {
        let block = BuddyBlock(
            say: "Both.", shape: .card,
            points: [.init(quote: "Q3 table", label: "1"), .init(quote: "Q3 table", label: "2")])
        bridge.setScript([BuddyCoordinatorTests.done(block)])
        let locator = FakeLocator(rects: ["Q3 table": Self.table])
        let coordinator = make(locator: locator)
        await ask(coordinator)
        await settle(until: { !rings.isEmpty })
        #expect(locator.calls.last == .locate(["Q3 table"], pid: 4242, path: "/tmp/shot.jpg"))
        #expect(rings == [[Ring(rect: Self.table, label: "1"), Ring(rect: Self.table, label: "2")]])
    }

    @Test func jumpRingsThatPointOnly() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let locator = FakeLocator(rects: ["Q3 table": Self.table, "Total": Self.total])
        let coordinator = make(locator: locator)
        await ask(coordinator)
        await settle(until: { rings.count == 1 })

        overlay.send(.jump(label: "3"))
        await settle(until: { rings.count == 2 })
        #expect(locator.calls.last == .locate(["Total"], pid: 4242, path: "/tmp/shot.jpg"))
        #expect(rings.last == [Ring(rect: Self.total, label: "3")])

        overlay.send(.jump(label: "9")) // no such point
        for _ in 0..<50 { await Task.yield() }
        #expect(locator.locateCount == 2)
    }
}

/// Answers each capture with the next context in the list (the last one repeats).
final class ScriptedContext: ContextPort {
    private let contexts: [FakeContext]
    private let next = Mutex(0)

    init(_ contexts: [FakeContext]) { self.contexts = contexts }

    private var current: FakeContext { contexts[min(next.withLock { $0 }, contexts.count - 1)] }

    func capture() async -> SummonContext {
        let context = contexts[min(next.withLock { n in defer { n += 1 }; return n }, contexts.count - 1)]
        return await context.capture()
    }

    func screenshot(displayID: UInt32?) async -> ShotOutcome { await current.screenshot(displayID: displayID) }
}
