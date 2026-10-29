import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace

/// Records what the coordinator traces. The port can't carry text, only kinds and numbers.
final class RecordingTrace: TracePort {
    struct Entry: Equatable {
        var event: TraceEvent
        var lane: Mode?
        var outcome: TraceOutcome?
        var count: Int?
        var timed: Bool
    }

    private let state = Mutex<[Entry]>([])
    private let times = Mutex<[(TraceEvent, Duration?)]>([])
    var entries: [Entry] { state.withLock { $0 } }
    func duration(of event: TraceEvent) -> Duration? { times.withLock { $0.last { $0.0 == event }?.1 } }
    var events: [TraceEvent] { entries.map(\.event) }

    func record(_ event: TraceEvent, duration: Duration?, lane: Mode?, outcome: TraceOutcome?, count: Int?) {
        state.withLock { $0.append(Entry(event: event, lane: lane, outcome: outcome, count: count, timed: duration != nil)) }
        times.withLock { $0.append((event, duration)) }
    }
}

@MainActor
struct TraceTests {
    let trace = RecordingTrace()
    let overlay = FakeOverlay()

    let voice = FakeVoice()

    func make(_ bridge: any BridgePort) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer(), trace: trace)
        c.start()
        return c
    }

    func ask(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
    }

    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @Test func aSpokenQuestionTracesEachStep() async {
        let c = make(FakeBridge(script: [
            .turn(lane: .quick, .sayFirstSentence("It's the totals row.")),
            BuddyCoordinatorTests.done(BuddyBlock(say: "It's the totals row.", shape: .chip)),
        ]))
        await ask(c)
        await settle(until: { trace.events.contains(.answerShown) })
        // The capture runs alongside the listen, so its two events can land anywhere after summon.
        #expect(trace.events.filter { $0 != .contextPacket && $0 != .screenshot } == [
            .summon, .micLive, .transcriptFinal, .routeDecided, .questionSent, .quickFirstEvent, .firstSpokenWord, .answerShown,
        ])
        // Where it went (V-17): Quick, the cascade. Kinds only, no words.
        #expect(trace.entries.first { $0.event == .routeDecided }?.lane == .quick)
        #expect(trace.events.filter { $0 == .contextPacket || $0 == .screenshot } == [.contextPacket, .screenshot])
        // Latencies are timed from the step before (summon, the send gesture, the request).
        let timed = Dictionary(trace.entries.map { ($0.event, $0.timed) }, uniquingKeysWith: { a, _ in a })
        #expect(timed[.micLive] == true && timed[.firstSpokenWord] == true && timed[.answerShown] == true)
        #expect(trace.entries.first { $0.event == .contextPacket }?.outcome == .ok)
        #expect(trace.entries.first { $0.event == .answerShown }?.lane == .quick)
    }

    @Test func aHandoffTracesDeep() async {
        let c = make(FakeBridge(script: [
            .handingOff(say: "Let me check the repo."),
            .turn(lane: .deep, .status("Reading files")),
            BuddyCoordinatorTests.done(BuddyBlock(say: "Your filter drops it.", shape: .card), lane: .deep),
        ]))
        await ask(c)
        await settle(until: { trace.events.contains(.answerShown) })
        let deep = trace.events.drop { $0 != .handoff }
        #expect(Array(deep) == [.handoff, .firstSpokenWord, .deepStarted, .answerShown, .deepFinished])
        #expect(trace.entries.first { $0.event == .answerShown }?.lane == .deep)
    }

    @Test func escWhileThinkingTracesACancel() async {
        let bridge = ManualBridge()
        let c = make(bridge)
        await ask(c)
        await settle(until: { bridge.streamCount == 1 })
        await c.escapePressed()
        #expect(trace.entries.last == .init(event: .cancelled, outcome: .cancelled, timed: false))
    }

    @Test func aFailedTurnTracesAnError() async {
        let c = make(FakeBridge(script: [.turn(lane: .quick, .failed(.timedOut)), BuddyCoordinatorTests.done(nil)]))
        await ask(c)
        await settle(until: { trace.events.contains(.error) })
        #expect(trace.entries.last == .init(event: .error, lane: .quick, outcome: .failed, timed: false))
        withExtendedLifetime(c) {}
    }

    @Test func aLaneRestartIsTraced() async {
        let c = make(FakeBridge(script: [
            .turn(lane: .quick, .reconnecting(attempt: 2)),
            BuddyCoordinatorTests.done(BuddyBlock(say: "Back.", shape: .chip)),
        ]))
        await ask(c)
        await settle(until: { trace.events.contains(.answerShown) })
        #expect(trace.entries.contains(.init(event: .processRestart, lane: .quick, count: 2, timed: false)))
    }

    @Test func anAbandonedSendDoesntTimeTheNextQuestion() async {
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let c = make(bridge)
        voice.setTranscript("") // nothing said: the send is discarded
        await ask(c)
        #expect(trace.entries.contains(.init(event: .transcriptFinal, outcome: .skipped, timed: true)))
        // The discarded send is over before the next press.
        await settle(until: { c.phase == .idle })
        try? await Task.sleep(for: .milliseconds(50))

        // Timed from the typed request, the answer can't take longer than the time since it; timed
        // from the old gesture it would be longer. No wall-clock budget, so load can't fail it.
        let typedAt = ContinuousClock.now
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "which row?", source: .textBox))
        await settle(until: { trace.events.contains(.answerShown) })
        let sinceTyped = ContinuousClock.now - typedAt
        let shown = trace.duration(of: .answerShown)
        #expect(shown != nil && shown! <= sinceTyped, "from the typed request, not the old gesture")
    }

    @Test func speechOnlyAtTheEndIsTheFirstSpokenWord() async {
        let c = make(FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes, it's C.", shape: .chip))]))
        await ask(c)
        await settle(until: { trace.events.contains(.firstSpokenWord) })
        #expect(trace.events.contains(.firstSpokenWord))
    }

    @Test func goDeeperStartsInDeepWithoutAQuickFirstEvent() async {
        let bridge = FakeBridge(script: [BuddyCoordinatorTests.done(BuddyBlock(say: "Yes.", shape: .card))])
        let c = make(bridge)
        await ask(c)
        // The first answer's speech (and its trace) follows its card.
        await settle(until: { c.phase == .showing && trace.events.contains(.firstSpokenWord) })
        bridge.setScript([
            .turn(lane: .deep, .status("Reading files")),
            BuddyCoordinatorTests.done(BuddyBlock(say: "Deeper.", shape: .card), lane: .deep),
        ])
        let before = trace.events.count
        overlay.send(.goDeeper)
        await settle(until: { trace.events.dropFirst(before).contains(.answerShown) })
        #expect(Array(trace.events.dropFirst(before)) == [.questionSent, .deepStarted, .answerShown, .deepFinished])
    }

    @Test func aFailedDeepRunStillFinishesDeep() async {
        let c = make(FakeBridge(script: [
            .handingOff(say: "Let me check."),
            .turn(lane: .deep, .failed(.timedOut)),
            BuddyCoordinatorTests.done(BuddyBlock(say: "Let me check.", shape: .chip, handoff: .deep), lane: .quick),
        ]))
        await ask(c)
        await settle(until: { trace.events.contains(.error) })
        #expect(trace.entries.contains(.init(event: .deepFinished, lane: .deep, outcome: .failed, timed: true)))
        withExtendedLifetime(c) {}
    }
}
