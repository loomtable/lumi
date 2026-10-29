import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// Typed questions (follow-up typing) and the listening pill's hints.
@MainActor
struct TypingTests {
    let voice = FakeVoice()
    let bridge = FakeBridge()
    let overlay = FakeOverlay()
    static let pointer = CGPoint(x: 400, y: 300)

    func make(voiceReplies: BuddyCoordinator.Settings.VoiceReplies = .onlyWhenSpoken,
              bridge: (any BridgePort)? = nil) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        settings.voiceReplies = voiceReplies
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge ?? self.bridge,
            overlay: overlay, pointer: FixedPointer(point: Self.pointer))
        coordinator.start()
        return coordinator
    }

    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func drain() async { for _ in 0..<100 { await Task.yield() } }

    func openTextBox(_ coordinator: BuddyCoordinator) async {
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.doubleTap))
    }

    var hints: [String] { overlay.calls.compactMap { if case .hint(let h) = $0 { h } else { nil } } }

    static let answer = BuddyBlock(say: "It's the totals row.", shape: .card)

    // MARK: - Text box

    @Test func doubleTapDiscardsTheAudioAndOpensTheBoxWhereThePillWas() async {
        let coordinator = make()
        await openTextBox(coordinator)
        #expect(coordinator.phase == .typing)
        #expect(overlay.calls.contains(.textBox(Self.pointer)))
        #expect(voice.calls.contains(.discard))
        #expect(!voice.calls.contains(.play(.discard)))
        #expect(bridge.asked.isEmpty)
    }

    @Test func typedQuestionUsesTheSummonPacketAndIsSilent() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let coordinator = make()
        await openTextBox(coordinator)
        overlay.send(.submitted(text: "  which row is wrong?  ", source: .textBox))
        await settle(until: { coordinator.phase == .showing })

        #expect(bridge.asked.count == 1)
        #expect(bridge.asked.first?.packet.utterance == "which row is wrong?")
        #expect(bridge.asked.first?.packet.app?.name == "Safari") // captured at the first press
        #expect(bridge.asked.first?.packet.screenshot == "/tmp/shot.jpg")
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })
    }

    @Test func aTypedQuestionSeesItsStreamedHeadlineInThePillWithoutSpeech() async {
        bridge.setScript([
            .turn(lane: .quick, .sayFirstSentence("It's the totals row.")),
            .turn(lane: .quick, .status("Reading the sheet")), // the headline stays in the pill
            BuddyCoordinatorTests.done(Self.answer),
        ])
        let coordinator = make()
        await openTextBox(coordinator)
        overlay.send(.submitted(text: "which row is wrong?", source: .textBox))
        await settle(until: { coordinator.phase == .showing })

        let headline = overlay.calls.firstIndex(of: .headline("It's the totals row."))
        let answer = overlay.calls.firstIndex { if case .answer = $0 { true } else { false } }
        #expect(headline != nil && answer != nil && headline! < answer!)
        #expect(!overlay.calls.contains(.status("Reading the sheet")))
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })
    }

    @Test func voiceRepliesAlwaysSpeaksATypedAnswer() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let coordinator = make(voiceReplies: .always)
        await openTextBox(coordinator)
        overlay.send(.submitted(text: "which row?", source: .textBox))
        await settle(until: { voice.calls.contains(.speak("It's the totals row.")) })
        #expect(voice.calls.contains(.speak("It's the totals row.")))
    }

    @Test func emptyTextSendsNothing() async {
        let coordinator = make()
        await openTextBox(coordinator)
        overlay.send(.submitted(text: "   ", source: .textBox))
        await drain()
        #expect(bridge.asked.isEmpty)
        #expect(coordinator.phase == .typing)
    }

    @Test func closingTheBoxEndsTypingAndALateSubmitDoesNothing() async {
        let coordinator = make()
        await openTextBox(coordinator)
        overlay.dismiss(.escape) // Esc reaches the focused box directly
        await settle(until: { coordinator.phase == .idle })
        #expect(coordinator.phase == .idle)

        overlay.send(.submitted(text: "too late", source: .textBox))
        await drain()
        #expect(bridge.asked.isEmpty)
    }

    /// The echo of Lumi's own earlier dismiss (`.requested`) can arrive after a new text box
    /// opened: it must not close that box and drop what the user types (found by TraceTests under
    /// load). Esc or a click away still closes it (above).
    @Test func aLateEchoOfLumisOwnDismissKeepsTheNewTextBox() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let coordinator = make()
        await openTextBox(coordinator)
        overlay.send(.dismissed(.requested))
        await drain()
        #expect(coordinator.phase == .typing, "the box stays open")
        overlay.send(.submitted(text: "which row is wrong?", source: .textBox))
        await settle(until: { coordinator.phase == .showing })
        #expect(bridge.asked.first?.packet.utterance == "which row is wrong?")
    }

    /// Right ⌥ typing é or € in the box: press, then the letter (a cancelled gesture).
    @Test func anOptionChordInTheBoxKeepsTheBox() async {
        let coordinator = make()
        await openTextBox(coordinator)
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.cancelled(.otherKey(14))))
        #expect(coordinator.phase == .typing)
        #expect(voice.calls.filter { $0 == .start }.count == 1)
        #expect(!overlay.calls.contains(.dismiss(.requested)))
    }

    @Test func aCleanTapInTheBoxStartsTapToTalk() async {
        let coordinator = make()
        await openTextBox(coordinator)
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        #expect(coordinator.phase == .listening(confirmedTap: true, holding: false))
        #expect(voice.calls.filter { $0 == .start }.count == 2)
    }

    @Test func aHoldInTheBoxTalksUntilRelease() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let coordinator = make()
        await openTextBox(coordinator)
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.holdBegan))
        #expect(coordinator.phase == .listening(confirmedTap: false, holding: true))
        #expect(hints == ["release to send"])
        await coordinator.handle(.gesture(.holdEnded))
        await settle(until: { coordinator.phase == .showing })
        #expect(bridge.asked.first?.packet.utterance == "what does this mean?")
    }

    @Test func anOptionChordInATypedCardKeepsTheCard() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let coordinator = make()
        await openTextBox(coordinator)
        overlay.send(.submitted(text: "which row?", source: .textBox))
        await settle(until: { coordinator.phase == .showing })

        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.cancelled(.otherKey(14))))
        #expect(coordinator.phase == .showing)
        #expect(voice.calls.filter { $0 == .start }.count == 1)
    }

    // MARK: - Reply field

    @Test func replyFieldFollowsUpInTheSameConversationWithTheSamePacket() async {
        bridge.setScript([BuddyCoordinatorTests.done(Self.answer)])
        let coordinator = make()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.holdBegan))
        await coordinator.handle(.gesture(.holdEnded))
        // The spoken answer starts once its card is on screen.
        await settle(until: { coordinator.phase == .showing && voice.calls.contains { if case .speak = $0 { true } else { false } } })
        let spoken = voice.calls.count { if case .speak = $0 { true } else { false } }

        overlay.send(.submitted(text: "and the column?", source: .reply))
        await settle(until: { bridge.asked.count == 2 && coordinator.phase == .showing })

        guard bridge.asked.count >= 2 else { Issue.record("asked: \(bridge.asked.count) of 2"); return }
        let (first, second) = (bridge.asked[0], bridge.asked[1])
        #expect(second.packet.utterance == "and the column?")
        #expect(second.packet.conversation?.id == first.packet.conversation?.id)
        #expect(second.packet.conversation?.turn == 2)
        #expect(second.packet.app == first.packet.app)
        #expect(second.packet.screenshot == first.packet.screenshot)
        #expect(second.routing == .auto)
        // Typed: the spoken answer stops, and the follow-up's answer is silent.
        #expect(voice.calls.contains(.stopSpeaking))
        #expect(voice.calls.count { if case .speak = $0 { true } else { false } } == spoken)
    }

    @Test func replyIsIgnoredWhenNoCardIsShowing() async {
        let coordinator = make()
        overlay.send(.submitted(text: "hello", source: .reply))
        await drain()
        #expect(bridge.asked.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    // MARK: - Listening hints

    @Test func holdSwitchesTheHintToReleaseToSend() async {
        let coordinator = make()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        #expect(overlay.calls.contains(.listening(Self.pointer, hint: "tap ⌥ to send")))
        await coordinator.handle(.gesture(.holdBegan))
        #expect(hints == ["release to send"])
    }

    @Test func nearLimitWarnsWithTheRightGesture() async {
        let coordinator = make()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        voice.eventSink.yield(.nearLimit)
        await settle(until: { !hints.isEmpty })
        #expect(hints == ["Stopping soon · tap ⌥ to send"])

        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.holdBegan))
        voice.eventSink.yield(.nearLimit)
        await settle(until: { hints.count == 3 })
        #expect(hints.last == "Stopping soon · release to send")
    }

    /// A long transcript says so instead of looking frozen, and the line goes once it's in.
    @Test func aSlowTranscriptShowsTranscribing() async {
        let coordinator = make()
        voice.holdFinish.withLock { $0 = true }
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        let sending = Task { await coordinator.handle(.gesture(.tap)) }
        await settle(until: { self.voice.calls.contains(.finish) })
        voice.eventSink.yield(.transcribing(long: false))
        await settle(until: { self.overlay.calls.contains(.status("Transcribing…")) })
        voice.eventSink.yield(.transcribing(long: true))
        await settle(until: { self.overlay.calls.contains(.status("Still transcribing… Esc to cancel")) })
        #expect(overlay.calls.contains(.status("Transcribing…")))
        voice.holdFinish.withLock { $0 = false }
        _ = await sending.value
        await settle(until: { self.overlay.calls.last == .status(nil) || self.overlay.calls.contains(.status(nil)) })
        #expect(overlay.calls.contains(.status(nil)), "cleared once the transcript is in")
    }

    /// 82: Esc during a slow transcript, then another question. A late notice from the escaped send
    /// must not land on the new question's pill.
    @Test func aLateNoticeAfterEscAndAnotherQuestionShowsNothing() async {
        let coordinator = make(bridge: ManualBridge())   // the new question stays thinking
        voice.holdFinish.withLock { $0 = true }
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        let stale = Task { await coordinator.handle(.gesture(.tap)) }
        await settle(until: { self.voice.calls.contains(.finish) })
        await coordinator.escapePressed()
        voice.holdFinish.withLock { $0 = false }
        _ = await stale.value
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.tap))
        await coordinator.handle(.gesture(.tap))
        await settle(until: { coordinator.phase == .thinking })
        #expect(coordinator.phase == .thinking)
        let before = overlay.calls.count
        voice.eventSink.yield(.transcribing(long: true))   // late, from the escaped send
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!overlay.calls.dropFirst(before).contains { if case .status(let s) = $0 { s?.contains("transcribing") == true } else { false } })
    }

    @Test func nearLimitAfterListeningEndedShowsNothing() async {
        _ = make()
        voice.eventSink.yield(.nearLimit)
        await drain()
        #expect(hints.isEmpty)
    }
}
