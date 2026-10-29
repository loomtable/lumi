import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import BuddyVoice

/// Routes every question to the next id in `ids` and records each request. With `open`, the turn
/// goes to an open session (the session engine); otherwise to the cascade (Quick).
@MainActor
final class ScriptedRouting: TurnRouting {
    var ids: [String]
    let open: Bool
    private(set) var requests: [RouteRequest] = []
    /// `cascadeTurnFinished`: the sessions whose Quick answer finished, with its headline.
    private(set) var finished: [(SessionID, String)] = []

    init(_ ids: [String], open: Bool) {
        self.ids = ids
        self.open = open
    }

    func route(_ request: RouteRequest) async -> RoutedTurn {
        requests.append(request)
        let id = ids.isEmpty ? "s_extra" : ids.removeFirst()
        let launch = open ? SessionLaunch(claudeSession: UUID(), exists: true, cwd: URL(filePath: "/tmp")) : nil
        return RoutedTurn(conversation: ConversationTurn(state: ConversationState(id: id), color: .ember, turn: 0, previous: []),
                          sessionID: SessionID(rawValue: id), kind: request.kind, harness: open ? .open : .quick, launch: launch)
    }

    func cascadeTurnFinished(_ id: SessionID, kind: TurnKind, question: String, block: BuddyBlock) {
        finished.append((id, block.say))
    }
}

/// Records each wait and returns at once, so a reading time passes instantly in tests.
final class ReadingClock: Sendable {
    private let log = Mutex<[Duration]>([])
    var waits: [Duration] { log.withLock { $0 } }
    func wait(_ duration: Duration) async {
        log.withLock { $0.append(duration) }
        await Task.yield()
    }
}

/// Reading times (8 s and more) wait until `release()`; the 1 s hover polls and short waits pass.
final class HeldReadingClock: Sendable {
    private let held = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let released = Mutex(false)
    func wait(_ duration: Duration) async {
        guard duration >= .seconds(8), !released.withLock({ $0 }) else { return await Task.yield() }
        await withCheckedContinuation { c in held.withLock { $0.append(c) } }
    }
    func release() {
        released.withLock { $0 = true }
        held.withLock { list in
            list.forEach { $0.resume() }
            list.removeAll()
        }
    }
}

/// V-02: with sessions on, a new press or the switcher never cancels a running voice turn; it
/// finishes in the background. Esc still cancels.
@MainActor
struct BackgroundTurnTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()

    func make(_ turns: any TurnPort, routing: ScriptedRouting, keepRunning: Bool = true,
              trace: (any TracePort)? = nil) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        settings.voiceReplies = .always
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: turns,
                                 overlay: overlay, pointer: FixedPointer(), trace: trace)
        c.routing = routing
        c.turnsKeepRunning = keepRunning
        c.start()
        return c
    }

    func until(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// Hold, speak, release.
    func ask(_ c: BuddyCoordinator, _ words: String) async {
        voice.setTranscript(words)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
    }

    var answers: [Answer] { overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a } else { nil } } }

    static let ends: Set<TraceEvent> = [.answerShown, .backgroundReady, .researchStarted, .cancelled, .error]

    /// Live (Oct 29): 3 of 5 voice turns pushed behind by a new summon ended with no end trace.
    /// Every sent question ends in exactly one: here the first behind (backgroundReady), the
    /// second in front (answerShown).
    @Test func everySentQuestionEndsInExactlyOneTrace() async {
        let trace = RecordingTrace()
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b"], open: false), trace: trace)
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        // The first question left the front before its first event: that event is traced behind.
        bridge.send(.turn(lane: .quick, .status("Reading")), to: 0)
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "First answer.", shape: .card)), to: 0)
        bridge.finish(0)
        await until { trace.events.contains(.backgroundReady) }
        #expect(trace.events.filter { $0 == .quickFirstEvent }.count == 1, "it ran, behind")
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "Second answer.", shape: .card)), to: 1)
        bridge.finish(1)
        await until { trace.events.contains(.answerShown) }
        #expect(trace.events.filter { $0 == .questionSent }.count == 2)
        #expect(trace.events.filter(Self.ends.contains) == [.backgroundReady, .answerShown])
    }

    /// A turn behind whose stream just stops (no answer) still ends once: an error.
    @Test func aTurnBehindThatStopsWithoutAnAnswerEndsInOneError() async {
        let trace = RecordingTrace()
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b"], open: false), trace: trace)
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        bridge.finish(0)
        await until { trace.events.contains(.error) }
        for _ in 0..<50 { await Task.yield() }
        #expect(trace.events.filter(Self.ends.contains) == [.error])
        _ = c
    }

    @Test func aSecondQuestionLeavesTheFirstRunningAndItsAnswerLandsInTheBackground() async {
        let bridge = ManualBridge()
        let routing = ScriptedRouting(["s_a", "s_b"], open: false)
        let c = make(bridge, routing: routing)
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        #expect(c.glanceSession == SessionID(rawValue: "s_a"))

        // The user presses again and asks something else: nothing is cancelled.
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        #expect(bridge.cancelled.isEmpty)
        // The second question doesn't go into the session still running the first.
        #expect(routing.requests.last?.busy == [SessionID(rawValue: "s_a")])
        #expect(c.glanceSession == SessionID(rawValue: "s_b"))

        // The first answer arrives: no card, no voice; its conversation and session get it.
        bridge.send(.turn(lane: .quick, .sayFirstSentence("First answer.")), to: 0)
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "First answer.", shape: .card)), to: 0)
        bridge.finish(0)
        await until { !routing.finished.isEmpty }
        #expect(!answers.contains { $0.block.say == "First answer." })
        #expect(!voice.calls.contains(.speak("First answer.")))
        #expect(routing.finished.map(\.0) == [SessionID(rawValue: "s_a")], "its session finishes the turn, unread")
        #expect(routing.finished.first?.1 == "First answer.")
        #expect(c.phase == .thinking, "the second question is still the one in front")

        // The second answers in front, as usual.
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "Second answer.", shape: .card)), to: 1)
        bridge.finish(1)
        await until { c.phase == .showing }
        #expect(answers.last?.block.say == "Second answer.")
    }

    @Test func aPressAloneLeavesTheTurnRunningAndEscOnTheListenKeepsIt() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a"], open: false))
        var fronts = 0
        c.onFrontChanged = { fronts += 1 }
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        let shown = fronts
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await until { if case .listening = c.phase { true } else { false } }
        #expect(c.glanceSession == nil, "moved to the background")
        #expect(fronts > shown)
        await c.escapePressed() // discards the listen, not the turn
        #expect(bridge.cancelled.isEmpty)
        #expect(c.busySessions == [SessionID(rawValue: "s_a")])
    }

    /// Hold + Tab only to look at the strip, then let go without speaking: the turn keeps running.
    @Test func lookingAtTheSwitcherDuringATurnDoesNotCancelIt() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a"], open: false))
        let presenter = FakeSwitcher()
        let sessions = FakeSessionsPort([.switcherSample("s_a", used: Date()), .switcherSample("s_b", used: Date().addingTimeInterval(-60))],
                                        current: SessionID(rawValue: "s_a"))
        c.attachSwitcher(SwitcherFlow(presenter: presenter, sessions: sessions, heardSpeech: { 0 }, scheduler: ManualScheduler().scheduler))
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        #expect(presenter.isOpen)
        await c.handle(.gesture(.switcherReleased))
        await until { c.phase == .idle }
        #expect(bridge.cancelled.isEmpty)
        #expect(c.busySessions == [SessionID(rawValue: "s_a")])
    }

    @Test func escStillCancelsTheTurnInFront() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a"], open: false))
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await c.escapePressed()
        #expect(bridge.cancelled == ["s_a"])
        #expect(c.phase == .idle)
    }

    @Test func withSessionsOffAPressStillCancels() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a"], open: false), keepRunning: false)
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await until { !bridge.cancelled.isEmpty }
        #expect(bridge.cancelled == ["s_a"])
    }

    /// 65-SURFACE-RULES C: a running turn never blocks dictation. It moves behind, and its answer
    /// waits as a Ready capsule until the dictation ends.
    @Test func dictationMovesARunningTurnBehindAndItsAnswerWaitsForIt() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a"], open: false))
        let dictation = DictationController(
            voice: voice, overlay: overlay, inserter: FakeDictationInserter(), panel: nil, pointer: FixedPointer(),
            tracer: nil, coordinatorPhase: { [weak c] in c?.phase ?? .idle }, frontmostPID: { 4242 })
        dictation.moveTurnBehind = { [weak c] in c?.moveTurnBehind() ?? false }
        dictation.onIdle = { [weak c] in c?.playNextReady() }
        c.dictation = dictation
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        #expect(c.phase == .thinking)

        await dictation.handle(.began)
        #expect(dictation.isActive, "the running turn didn't block it")
        #expect(c.phase == .idle)
        #expect(bridge.cancelled.isEmpty, "the turn keeps running behind")

        bridge.send(done("First answer."), to: 0)
        bridge.finish(0)
        await until { readyCapsules == 1 }
        #expect(!answers.contains { $0.block.say == "First answer." }, "it waits while the user dictates")

        voice.setTranscript("a note")
        await dictation.handle(.ended)
        await until { answers.contains { $0.block.say == "First answer." } }
        #expect(answers.map(\.block.say) == ["First answer."])
    }

    @Test func withSessionsOffARunningTurnStaysInFront() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a"], open: false), keepRunning: false)
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        #expect(!c.moveTurnBehind())
        #expect(c.phase == .thinking)
    }

    /// An open session's voice turn moved behind a new listen: its answer is recorded, never shown
    /// or spoken.
    @Test func anOpenSessionsTurnFinishesInTheBackground() async {
        let engine = FakeSessionEngine(manual: true)
        let c = make(engine, routing: ScriptedRouting(["s_a"], open: true))
        let s = SessionID(rawValue: "s_a")
        await ask(c, "check the build")
        await until { engine.sent.count == 1 }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        let block = BuddyBlock(say: "It's green.", shape: .chip)
        engine.emit(.sayFirstSentence("It's green."), to: s)
        engine.emit(.turnEnded(TurnEnd(kind: .voice, markdown: "", block: block)), to: s)
        engine.finish(s)
        await until { c.busySessions.isEmpty }
        #expect(engine.cancelled.isEmpty)
        #expect(!answers.contains { $0.block.say == "It's green." })
        #expect(!voice.calls.contains(.speak("It's green.")))
        if case .listening = c.phase {} else { Issue.record("still listening, not \(c.phase)") }
    }

    // MARK: Ready answers take turns (owner, Oct 29)

    func done(_ say: String) -> CascadeEvent { BuddyCoordinatorTests.done(BuddyBlock(say: say, shape: .card)) }
    var readyCapsules: Int { overlay.progress.rows.count { $0.line == ProgressBoard.readyLine } }

    /// Live: answers of voice turns pushed behind finished silently. Now each waits its turn: the
    /// one in front is shown and spoken first, then the one behind, with no second end trace.
    @Test func aVoiceAnswerThatFinishesBehindWaitsItsTurnThenIsShownAndSpoken() async {
        let trace = RecordingTrace()
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b"], open: false), trace: trace)
        let reading = ReadingClock() // reading times pass at once
        c.sleep = { await reading.wait($0) }
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        bridge.send(done("First answer."), to: 0)
        bridge.finish(0)
        await until { readyCapsules == 1 }
        #expect(readyCapsules == 1, "its capsule says Ready")
        #expect(!answers.contains { $0.block.say == "First answer." }, "the turn in front keeps the Glance")

        bridge.send(done("Second answer."), to: 1)
        bridge.finish(1)
        await until { voice.calls.contains(.speak("Second answer.")) }
        for _ in 0..<50 { await Task.yield() }
        #expect(!voice.calls.contains(.speak("First answer.")), "it waits while the second is spoken")

        voice.eventSink.yield(.speakingFinished)
        await until { voice.calls.contains(.speak("First answer.")) }
        #expect(answers.map(\.block.say) == ["Second answer.", "First answer."])
        #expect(overlay.progress.isEmpty, "its capsule went when it showed")
        #expect(trace.events.filter(Self.ends.contains) == [.backgroundReady, .answerShown])
        #expect(trace.events.filter { $0 == .answerQueued || $0 == .answerPlayed } == [.answerQueued, .answerPlayed],
                "one line as it joins the queue, one as it plays")
    }

    /// Live (Oct 29, 13:18): a queued answer played 5.9 s after a hand-off's Deep card appeared,
    /// the moment its voice went quiet, so two answers came one over the other. Every card holds
    /// the Glance until its reading time has passed (65-SURFACE-RULES, rule A).
    @Test func aQueuedAnswerWaitsOutAHandOffsDeepCardNotJustItsVoice() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b"], open: false))
        let reading = HeldReadingClock()
        c.sleep = { await reading.wait($0) }
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        bridge.send(done("First answer."), to: 0)
        bridge.finish(0)
        await until { readyCapsules == 1 }

        bridge.send(.handingOff(say: "Let me look."), to: 1)
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "Deep answer.", shape: .card), lane: .deep), to: 1)
        bridge.finish(1)
        await until { voice.calls.contains(.speak("Deep answer.")) }
        voice.eventSink.yield(.speakingFinished)
        for _ in 0..<100 { await Task.yield() }
        #expect(answers.map(\.block.say) == ["Deep answer."], "the Deep card keeps the Glance after its voice ends")
        #expect(!voice.calls.contains(.speak("First answer.")))
        #expect(readyCapsules == 1, "the waiting answer stays a Ready capsule, not a second card")

        reading.release()
        await until { voice.calls.contains(.speak("First answer.")) }
        #expect(answers.map(\.block.say) == ["Deep answer.", "First answer."])
        #expect(overlay.progress.isEmpty)
    }

    /// A chip that replaces a heard card starts its own turn: the queue doesn't take the
    /// previous card's.
    @Test func aChipHoldsTheGlanceForItsOwnReadingTime() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b"], open: false))
        let reading = HeldReadingClock()
        c.sleep = { await reading.wait($0) }
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        bridge.send(done("Second answer."), to: 1)
        bridge.finish(1)
        await until { voice.calls.contains(.speak("Second answer.")) }
        c.answerHeard = true // the card had its turn
        c.showChip("Saved to Notes.")
        bridge.send(done("First answer."), to: 0)
        bridge.finish(0)
        await until { readyCapsules == 1 }
        voice.eventSink.yield(.speakingFinished)
        for _ in 0..<100 { await Task.yield() }
        #expect(!answers.contains { $0.block.say == "First answer." }, "the chip is the Glance now")
        reading.release()
        await until { answers.contains { $0.block.say == "First answer." } }
    }

    /// First finished, first played. A listen pauses the queue; once it's over the queue goes
    /// on, and Esc on a ready answer skips to the next (the skipped one stays in its session).
    @Test func readyAnswersPlayInTheOrderTheyFinishedAndWaitWhileTheUserTalks() async {
        let bridge = ManualBridge()
        let routing = ScriptedRouting(["s_a", "s_b"], open: false)
        let c = make(bridge, routing: routing)
        let reading = ReadingClock() // reading times pass at once
        c.sleep = { await reading.wait($0) }
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await until { if case .listening = c.phase { true } else { false } }

        bridge.send(done("Second answer."), to: 1)
        bridge.finish(1)
        await until { readyCapsules == 1 }
        bridge.send(done("First answer."), to: 0)
        bridge.finish(0)
        await until { readyCapsules == 2 }
        for _ in 0..<50 { await Task.yield() }
        #expect(answers.isEmpty && !voice.calls.contains { if case .speak = $0 { true } else { false } },
                "nothing plays while the user is talking")

        await c.escapePressed() // the listen is discarded: the queue goes on
        await until { voice.calls.contains(.speak("Second answer.")) }
        #expect(answers.map(\.block.say) == ["Second answer."])
        #expect(readyCapsules == 1)

        await c.escapePressed() // skips it
        voice.eventSink.yield(.speakingFinished) // the voice reports the stop, as the real one does
        await until { voice.calls.contains(.speak("First answer.")) }
        #expect(answers.map(\.block.say) == ["Second answer.", "First answer."])
        #expect(Set(routing.finished.map(\.1)) == ["First answer.", "Second answer."], "both are in their sessions")
        #expect(overlay.progress.isEmpty)
    }

    /// QA gate 4.6: a session forgotten or archived while its answer waits never plays it, and its
    /// "Ready" capsule goes; the others play on.
    @Test func aForgottenSessionsReadyAnswerNeverPlays() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b"], open: false))
        let reading = ReadingClock()
        c.sleep = { await reading.wait($0) }
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await until { if case .listening = c.phase { true } else { false } }
        bridge.send(done("Second answer."), to: 1)
        bridge.finish(1)
        bridge.send(done("First answer."), to: 0)
        bridge.finish(0)
        await until { readyCapsules == 2 }

        c.dropReady(for: SessionID(rawValue: "s_b"))
        await until { readyCapsules == 1 } // its capsule goes
        await c.escapePressed()
        await until { voice.calls.contains(.speak("First answer.")) }
        for _ in 0..<50 { await Task.yield() }
        #expect(answers.map(\.block.say) == ["First answer."])
        #expect(!voice.calls.contains(.speak("Second answer.")))
    }

    /// Live (r5, 14:05:57 → 14:05:58.8): a summon closed the card in front, the strip opened, the
    /// user let go on another session without a word, and the ready answer popped up over the
    /// strip's peek. It waits until the strip and its peek are gone (rule 4), then plays.
    @Test func aReadyAnswerWaitsWhileTheStripOrItsPeekIsUp() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b"], open: false))
        let reading = ReadingClock()
        c.sleep = { await reading.wait($0) }
        let presenter = FakeSwitcher()
        let timers = ManualScheduler()
        let sessions = FakeSessionsPort([.switcherSample("s_a", used: Date()), .switcherSample("s_b", used: Date().addingTimeInterval(-60))],
                                        current: SessionID(rawValue: "s_a"))
        c.attachSwitcher(SwitcherFlow(presenter: presenter, sessions: sessions, heardSpeech: { 0 }, scheduler: timers.scheduler))
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        bridge.send(done("First answer."), to: 0)   // finishes behind: queued
        bridge.finish(0)
        await until { readyCapsules == 1 }

        // The summon: the strip opens, the user lets go on another session without speaking.
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.switcher(.next)))
        #expect(presenter.isOpen)
        await c.handle(.gesture(.switcherReleased))
        await until { c.phase == .idle }
        for _ in 0..<100 { await Task.yield() }
        #expect(!answers.contains { $0.block.say == "First answer." }, "not over the strip's peek")
        #expect(!voice.calls.contains(.speak("First answer.")))

        timers.fire(after: SwitcherFlow.peekAfterSwitch)   // the peek ends
        await until { voice.calls.contains(.speak("First answer.")) }
        #expect(answers.map(\.block.say).contains("First answer."), "then it plays")
    }

    /// Speak answers off: the card in front gets its reading time, and longer while the pointer is
    /// on it; then the ready answer replaces it, silently. A click away doesn't wait.
    @Test func withSpokenAnswersOffAReadyAnswerWaitsOutTheCardsReadingTime() async {
        let bridge = ManualBridge()
        let c = make(bridge, routing: ScriptedRouting(["s_a", "s_b", "s_c"], open: false))
        c.settings.voiceReplies = .off
        let readingTimes = ReadingClock()
        c.sleep = { await readingTimes.wait($0) }
        overlay.pointerOnAnswer = true
        await ask(c, "first question")
        await until { bridge.streamCount == 1 }
        await ask(c, "second question")
        await until { bridge.streamCount == 2 }
        bridge.send(done("First answer."), to: 0)
        bridge.finish(0)
        await until { readyCapsules == 1 }
        bridge.send(done("Second answer."), to: 1)
        bridge.finish(1)
        await until { c.phase == .showing }
        // Its reading time passed, and the hover check is polling.
        await until { readingTimes.waits.contains(.seconds(8)) && readingTimes.waits.contains(.seconds(1)) }
        #expect(readingTimes.waits.contains(.seconds(8)), "a short card's reading time")
        #expect(answers.map(\.block.say) == ["Second answer."], "the pointer is on it: it stays")

        overlay.pointerOnAnswer = false
        await until { answers.count == 2 }
        #expect(answers.last?.block.say == "First answer.")
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })
    }

    @Test func readingTimeIsEightSecondsPlusOnePerTwentyFiveWordsAtMostThirty() {
        func block(words: Int) -> BuddyBlock {
            BuddyBlock(say: "Short.", shape: .card, cardHTML: "<p>" + Array(repeating: "word", count: words).joined(separator: " ") + "</p>")
        }
        #expect(BuddyCoordinator.readingTime(BuddyBlock(say: "It's green.", shape: .chip)) == .seconds(8))
        #expect(BuddyCoordinator.readingTime(block(words: 99)) == .seconds(12))
        #expect(BuddyCoordinator.readingTime(block(words: 2_000)) == .seconds(30))
    }

    @Test func aRequestStaleBeforeItsSendIsCancelledOnlyAfterEsc() {
        let c = make(ManualBridge(), routing: ScriptedRouting([], open: false))
        let mine = c.nextEpoch()
        _ = c.nextEpoch() // a new press: background, keep it
        #expect(!c.cancelsAfterSend(mine))
        c.cancelledEpochs.insert(mine) // Esc while it was being sent
        #expect(c.cancelsAfterSend(mine))
        #expect(!c.cancelsAfterSend(c.epoch), "the current one is never cancelled here")
    }
}

/// V-03: a voice turn's approvals and questions are answerable from the Glance, by click or (tier
/// 1) by a spoken yes or no, in front or after coming back from the background.
@MainActor
struct GlanceApprovalTests {
    let s = SessionID(rawValue: "s_a")
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let answering = FakeAnswering()

    func make() -> (BuddyCoordinator, FakeSessionEngine, PageFlow) {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let engine = FakeSessionEngine(manual: true)
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: engine,
                                 overlay: overlay, pointer: FixedPointer())
        c.routing = ScriptedRouting(["s_a", "s_b"], open: true)
        c.turnsKeepRunning = true
        let f = PageFlow(panel: FakePanel(), turns: engine, permissions: LivePermissionHost(answering: answering))
        c.pageFlow = f
        c.start()
        return (c, engine, f)
    }

    func until(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func ask(_ c: BuddyCoordinator, _ words: String) async {
        voice.setTranscript(words)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.handle(.gesture(.holdEnded))
    }

    /// A voice turn in front that asks.
    func asking(_ tier: ApprovalTier) async -> (BuddyCoordinator, FakeSessionEngine, PageFlow) {
        let (c, engine, f) = make()
        await ask(c, "run the tests")
        await until { engine.sent.count == 1 }
        engine.emit(.permissionRequested(permission(tier)), to: s)
        await until { c.shownApproval != nil }
        return (c, engine, f)
    }

    func permission(_ tier: ApprovalTier) -> PermissionAsk {
        PermissionAsk(id: "r1", title: "Run the tests", toolName: "Bash", detail: .command("npm test"), tier: tier)
    }

    var lastCard: Answer? { overlay.calls.last { if case .answer = $0 { true } else { false } }.flatMap { if case .answer(let a, _, _) = $0 { a } else { nil } } }

    @Test func theGlanceBecomesTheApprovalCardAndAllowAnswersIt() async {
        let (c, _, f) = await asking(.reversible)
        #expect(c.phase == .showing)
        #expect(lastCard?.block.say == "Run the tests?")
        #expect(lastCard?.block.needsApproval == true)
        #expect(lastCard?.block.actions.map(\.label) == ["Allow", "Deny"])
        #expect(f.permissions.pending(in: s).count == 1, "the host knows what's waiting")
        overlay.send(.action(index: 0))
        await until { !answering.recorded.isEmpty }
        #expect(answering.recorded == [.decide("r1", s, .allow(updatedInput: nil))])
        await until { c.phase == .thinking }
        #expect(c.shownApproval == nil)
        #expect(overlay.calls.last.map { if case .thinking = $0 { true } else { false } } == true, "back to the pill")
    }

    @Test func denyAnswersNo() async {
        let (c, _, _) = await asking(.needsClick)
        overlay.send(.action(index: 1))
        await until { !answering.recorded.isEmpty }
        #expect(answering.recorded == [.decide("r1", s, .deny(message: nil))])
        await until { c.phase == .thinking }
        #expect(c.shownApproval == nil)
    }

    @Test func aSpokenYesOverTheCardAllowsATierOneAskAndTheTurnComesBack() async {
        let (c, engine, _) = await asking(.reversible)
        await ask(c, "Yes.")
        await until { !answering.recorded.isEmpty }
        #expect(answering.recorded == [.decide("r1", s, .allow(updatedInput: nil))])
        #expect(engine.sent.count == 1, "no new turn")
        #expect(c.phase == .thinking)
        #expect(c.glanceSession == s, "its turn is in front again")
        // Its answer shows and speaks in front, as before.
        engine.emit(.turnEnded(TurnEnd(kind: .voice, markdown: "", block: BuddyBlock(say: "All green.", shape: .chip))), to: s)
        await until { c.phase == .showing }
        #expect(lastCard?.block.say == "All green.")
    }

    @Test func aSpokenNoDeniesAnyTier() async {
        let (c, _, _) = await asking(.needsClick)
        await ask(c, "no")
        await until { !answering.recorded.isEmpty }
        #expect(answering.recorded == [.decide("r1", s, .deny(message: nil))])
    }

    @Test func aSpokenYesNeverAllowsANeedsClickAskAndTheCardComesBack() async {
        let (c, engine, _) = await asking(.needsClick)
        await ask(c, "go ahead")
        await until { voice.calls.contains(.speak(LivePermissionHost.needsClickLine)) }
        #expect(answering.recorded.isEmpty)
        #expect(engine.sent.count == 1)
        #expect(c.shownApproval?.ask.id == "r1")
        #expect(overlay.calls.contains(.toast(LivePermissionHost.needsClickLine)))
    }

    @Test func anythingElseSaidOverTheCardIsANewQuestionAndTheTurnWaitsBehind() async {
        let (c, engine, _) = await asking(.reversible)
        await ask(c, "what's the weather")
        await until { engine.sent.count == 2 }
        #expect(answering.recorded.isEmpty)
        #expect(engine.cancelled.isEmpty)
        #expect(c.glanceSession == SessionID(rawValue: "s_b"))
        // A click on its needs-you capsule brings the card back, and the new question moves behind.
        #expect(c.openWaiting(s))
        #expect(c.shownApproval?.ticket.session == s)
        #expect(c.glanceSession == s)
    }

    @Test func closingTheCardLeavesTheTurnWaitingAndEscCancelsIt() async {
        let (c, engine, _) = await asking(.reversible)
        overlay.dismiss(.clickAway)
        await until { c.shownApproval == nil }
        #expect(c.glanceSession == nil, "waiting in the background, with an amber capsule")
        #expect(engine.cancelled.isEmpty)
        #expect(c.openWaiting(s))
        await c.escapePressed()
        await until { !engine.cancelled.isEmpty }
        #expect(engine.cancelled == ["s_a"])
        #expect(c.phase == .idle)
    }

    /// Behind the Glance, the waiting turn has its capsule; a click on it brings the card back.
    @Test func aClickOnTheWaitingTurnsCapsuleBringsTheCardBack() async {
        let (c, _, _) = await asking(.reversible)
        #expect(overlay.progress.isEmpty, "the card shows it")
        overlay.dismiss(.clickAway)
        await until { !overlay.progress.isEmpty }
        #expect(overlay.progress.rows.count == 1)
        overlay.send(.progressClicked(s))
        await until { c.shownApproval != nil }
        #expect(c.shownApproval?.ask.id == "r1")
        #expect(overlay.progress.isEmpty)
    }

    @Test func discardingTheListenBegunOverTheCardBringsItBack() async {
        let (c, _, _) = await asking(.reversible)
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.holdBegan))
        await c.escapePressed()
        await until { c.shownApproval != nil }
        #expect(c.shownApproval?.ask.id == "r1")
        #expect(c.phase == .showing)
    }

    @Test func anAskAnsweredElsewhereTurnsTheCardBackIntoThePill() async {
        let (c, engine, _) = await asking(.reversible)
        engine.emit(.permissionResolved(id: "r1"), to: s)
        await until { c.phase == .thinking }
        #expect(c.shownApproval == nil)
    }

    @Test func aShortQuestionShowsItsOptionsAndALongOneOpensLumi() async {
        let (c, engine, _) = make()
        var opened: [SessionID] = []
        c.pageFlow?.onExpand = { opened.append($0) }
        await ask(c, "rename it")
        await until { engine.sent.count == 1 }
        let short = QuestionAsk(id: "q1", items: [.init(question: "Which name?", header: "Name", options: [.init(label: "Lumi"), .init(label: "Loom")])])
        engine.emit(.questionAsked(short), to: s)
        await until { c.shownApproval != nil }
        #expect(lastCard?.block.say == "Which name?")
        #expect(lastCard?.block.actions.map(\.label) == ["Lumi", "Loom"])
        overlay.send(.action(index: 1))
        await until { !answering.recorded.isEmpty }
        #expect(answering.recorded == [.answer("q1", s, ["Which name?": "Loom"])])

        let long = QuestionAsk(id: "q2", items: [.init(question: "Pick", header: "P", options: [.init(label: "A"), .init(label: "B"), .init(label: "C")])])
        engine.emit(.questionAsked(long), to: s)
        await until { c.shownApproval?.ask.id == "q2" }
        #expect(lastCard?.block.actions.map(\.label) == ["Answer in Lumi"])
        overlay.send(.action(index: 0))
        await until { !opened.isEmpty }
        #expect(opened == [s])
        #expect(c.shownApproval == nil)
    }

    /// A Quick hand-off's ask (`TurnEvent.hostEvent`) reaches the permission host and the card.
    @Test func aHandOffsAskReachesTheHostAndTheCard() async {
        let bridge = ManualBridge()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
                                 overlay: overlay, pointer: FixedPointer())
        c.routing = ScriptedRouting(["s_a"], open: false)
        c.turnsKeepRunning = true
        let f = PageFlow(panel: FakePanel(), turns: bridge, permissions: LivePermissionHost(answering: answering))
        c.pageFlow = f
        c.start()
        await ask(c, "fix the bug")
        await until { bridge.streamCount == 1 }
        bridge.send(.handingOff(say: "Let me look."))
        for e in SessionTurnEvents.turnEvents(for: .permissionRequested(permission(.reversible)), sessionID: "") {
            bridge.send(.turn(lane: .deep, e))
        }
        await until { c.shownApproval != nil }
        #expect(f.permissions.pending(in: s).map(\.ask.id) == ["r1"])
        #expect(lastCard?.block.say == "Run the tests?")
        bridge.send(.turn(lane: .deep, .status("Reading page.tsx")))
        for _ in 0..<50 { await Task.yield() }
        #expect(c.shownApproval != nil, "its own lines don't turn the card back into the pill")
        // The turn's end clears the host.
        for e in SessionTurnEvents.turnEvents(for: .turnEnded(TurnEnd(kind: .voice, markdown: "Fixed.")), sessionID: "") {
            bridge.send(.turn(lane: .deep, e))
        }
        await until { f.permissions.pending(in: s).isEmpty }
        #expect(f.permissions.pending(in: s).isEmpty)
    }

    @Test func theCardSaysWhatItWantsInPlainWords() {
        let lane = Lane(mode: .deep, model: .sonnet)
        let ask = PermissionAsk(id: "r", title: "Run the tests", toolName: "Bash", detail: .command("npm test && rm -rf <x>"),
                                tier: .reversible, asker: "Scout")
        let card = BuddyCoordinator.approvalCard(.permission(ask), keySymbol: "⌥", lane: lane, color: .ember)
        #expect(card.block.say == "Scout: Run the tests?")
        #expect(card.block.cardHTML == "<p><code>npm test &amp;&amp; rm -rf &lt;x&gt;</code></p><p>Or press ⌥ and say yes or no.</p>")
        let click = PermissionAsk(id: "r", title: "Send the email", toolName: "mcp__mail", detail: .plain("Send the email"), tier: .needsClick)
        #expect(BuddyCoordinator.approvalCard(.permission(click), keySymbol: "⌥", lane: lane, color: .ember).block.cardHTML
            == "<p>\(LivePermissionHost.needsClickLine)</p>")
    }

    @Test(arguments: ["No", "nope.", "Don't.", "do not", "deny it"])
    func negatives(_ t: String) { #expect(BuddyCoordinator.isBareNegative(t)) }

    @Test(arguments: ["no idea what that is", "yes", "not now maybe", ""])
    func notNegatives(_ t: String) { #expect(!BuddyCoordinator.isBareNegative(t)) }
}
