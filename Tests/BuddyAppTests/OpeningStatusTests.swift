import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// The pill's first seconds say what was captured ("Looking at Safari"), not a generic "Thinking".
@MainActor
struct OpeningStatusTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()

    func make(_ bridge: FakeBridge) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        return c
    }

    func ask(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + waitCeiling
        while c.phase != .showing, c.phase != .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<50 { await Task.yield() }
    }

    var statuses: [String?] { overlay.calls.compactMap { if case .status(let s) = $0 { s } else { nil } } }

    @Test func theLineSaysWhatWasCaptured() {
        var packet = ContextPacket(askedAt: Date(), utterance: "")
        #expect(BuddyCoordinator.openingStatus(packet) == nil) // no app: the pill's own default
        packet.app = .init(name: "Pages", bundle: "com.apple.iWork.Pages", kind: .other)
        #expect(BuddyCoordinator.openingStatus(packet) == "Looking at Pages")
        packet.selection = .init(text: "Q3 summary")
        #expect(BuddyCoordinator.openingStatus(packet) == "Reading your selection in Pages")
    }

    @Test func quickThinkingKeepsTheLineAndARealStepReplacesIt() async {
        let c = make(FakeBridge(script: [
            .turn(lane: .quick, .status(StatusMapper.thinking)),
            .turn(lane: .quick, .status("Reading report.md")),
            BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row.", shape: .card)),
        ]))
        await ask(c)
        #expect(statuses == ["Looking at Safari", "Reading report.md"], "\(statuses)")
        let opening = overlay.calls.firstIndex(of: .status("Looking at Safari"))
        let answer = overlay.calls.firstIndex { if case .answer = $0 { true } else { false } }
        #expect(opening != nil && answer != nil && opening! < answer!)
    }

    @Test func deepThinkingStillShows() async {
        let c = make(FakeBridge(script: [
            .handingOff(say: "Let me look closer."),
            .turn(lane: .deep, .status(StatusMapper.thinking)),
            BuddyCoordinatorTests.done(BuddyBlock(say: "Found it.", shape: .card), lane: .deep),
        ]))
        await ask(c)
        #expect(overlay.calls.contains(.status(StatusMapper.thinking)))
    }
}

/// A long wait counts itself in the pill ("Thinking · 12 s") once nothing new has shown for a while.
@MainActor
struct QuietStatusTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let bridge = ManualBridge()

    func make() -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer())
        // Wide margins: the "not yet" checks run 100 ms in, so a loaded machine can't reach 600.
        c.quietAfter = .milliseconds(600)
        c.quietTick = .milliseconds(50)
        c.start()
        return c
    }

    func ask(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
        let deadline = ContinuousClock.now + waitCeiling
        while bridge.streamCount == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func settle() async { for _ in 0..<50 { await Task.yield() } }

    func wait(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Every line the pill showed, whether by a status update or a lane's thinking pill.
    var statuses: [String] {
        overlay.calls.compactMap {
            switch $0 {
            case .status(let s?), .thinking(_, let s?), .headline(let s): s
            default: nil
            }
        }
    }
    var counted: [String] { statuses.filter { $0.hasPrefix("Thinking · ") } }

    @Test func aQuietWaitCountsAndANewStepRestartsTheCount() async throws {
        let c = make()
        await ask(c)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counted.isEmpty) // "Looking at Safari" is still new
        await wait { !counted.isEmpty }
        #expect(counted.first?.hasSuffix(" s") == true, "\(statuses)")

        bridge.send(.turn(lane: .quick, .status("Reading report.md")))
        await settle()
        let shown = statuses.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(statuses.count == shown && statuses.last == "Reading report.md", "\(statuses)") // the step stays a while

        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "Found it.", shape: .card)))
        await settle()
        let atAnswer = counted.count
        try await Task.sleep(for: .milliseconds(900))
        #expect(counted.count == atAnswer) // nothing counts over the answer
    }

    @Test func theStreamedHeadlineIsNeverReplacedByTheCount() async throws {
        let c = make()
        await ask(c)
        bridge.send(.turn(lane: .quick, .sayFirstSentence("It's the totals row.")))
        await settle()
        try await Task.sleep(for: .milliseconds(900))
        #expect(statuses.last == "It's the totals row.", "\(statuses)")
    }

    @Test func theHandOffShowsTheSpokenLine() async throws {
        let c = make()
        await ask(c)
        bridge.send(.handingOff(say: "Let me look closer."))
        await settle()
        #expect(overlay.calls.contains { if case .thinking(_, "Let me look closer.") = $0 { true } else { false } })
        #expect(!overlay.calls.contains { if case .thinking(_, "Handing to Deep") = $0 { true } else { false } })
        _ = c
    }
}
