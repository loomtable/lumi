import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
@testable import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// Races where speech or the mic is still starting when the user moves on (second review).
@MainActor
struct GatedVoiceRaceTests {
    let overlay = FakeOverlay()

    func make(voice: any VoicePort, bridge: any BridgePort) -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        return c
    }

    func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    var answers: [String] {
        overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block.say } else { nil } }
    }

    func tapToTalk(_ c: BuddyCoordinator) async {
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.tap))
    }

    @Test func staleReplyThatStartsPlayingIsStoppedAtOnce() async {
        let voice = GatedVoice(gateSpeak: true)
        let bridge = ManualBridge()
        let c = make(voice: voice, bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }
        bridge.send(.turn(lane: .quick, .sayFirstSentence("Old reply.")))
        await waitFor { voice.waiting == 1 } // synthesising

        let press = Task { // the user asks again
            await c.handle(.gesture(.pressBegan(fresh: false)))
            await c.handle(.gesture(.holdBegan))
        }
        await waitFor { voice.calls.contains(.start) && voice.calls.filter { $0 == .start }.count == 2 }
        voice.release() // the old reply's playback starts now
        await press.value
        await waitFor { voice.calls.last == .stopSpeaking }

        let afterSpeak = voice.calls.drop { $0 != .speak("Old reply.") }
        #expect(afterSpeak.dropFirst().contains(.stopSpeaking))
        #expect(!overlay.calls.contains(.speaking(true)))
    }

    /// V-09: Esc while the next ask still transcribes cancels nothing that ask didn't send: the
    /// earlier turn's session may be running a page turn of its own.
    @Test func escapeWhileTranscribingCancelsNoEarlierTurn() async {
        let voice = GatedVoice()
        let bridge = ManualBridge()
        let c = make(voice: voice, bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "Done.", shape: .chip)))
        bridge.finish()
        await waitFor { c.phase == .showing }

        voice.holdTranscripts()
        let ask = Task { await tapToTalk(c) }
        await waitFor { voice.waiting == 1 } // "Transcribing…"
        await c.escapePressed()
        voice.release()
        await ask.value
        #expect(bridge.cancelled.isEmpty, "the earlier turn's session isn't interrupted")
        #expect(bridge.streamCount == 1, "the cancelled ask is never sent")
    }

    @Test func escapeWhileTheMicStartsLeavesItOff() async {
        let voice = GatedVoice(gateStart: true)
        let c = make(voice: voice, bridge: FakeBridge())
        let press = Task { await c.handle(.gesture(.pressBegan(fresh: false))) }
        await waitFor { voice.waiting == 1 } // mic starting

        await c.escapePressed()
        voice.release()
        await press.value
        #expect(c.phase == .idle)
        // Esc discarded once; the listen that came up afterwards was discarded again.
        #expect(voice.calls.filter { $0 == .discard }.count == 2)
        #expect(voice.calls.last == .discard)
    }

    @Test func pauseWhileTheMicStartsLeavesItOff() async {
        let voice = GatedVoice(gateStart: true)
        let c = make(voice: voice, bridge: FakeBridge())
        let press = Task { await c.handle(.gesture(.pressBegan(fresh: false))) }
        await waitFor { voice.waiting == 1 }

        await c.setPaused(true)
        voice.release()
        await press.value
        #expect(c.phase == .idle)
        #expect(voice.calls.last == .discard)
    }

    @Test func stopSpeakingDoesNotDetachTheTurn() async {
        let voice = FakeVoice()
        let bridge = ManualBridge()
        let c = make(voice: voice, bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }
        bridge.send(.handingOff(say: "Let me check the repo."))
        overlay.send(.stopSpeaking) // the 🔈 button during Deep's turn
        await waitFor { voice.calls.contains(.stopSpeaking) }
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "Found it.", shape: .card), lane: .deep))
        bridge.finish()
        await waitFor { c.phase == .showing }
        #expect(answers == ["Found it."])
    }

    @Test func multiSentenceHandoffLineIsSpokenOnce() async {
        let voice = FakeVoice()
        let bridge = FakeBridge(script: [
            .turn(lane: .quick, .sayFirstSentence("Let me check.")),
            .turn(lane: .quick, .say("Let me check. One moment.")),
            .handingOff(say: "Let me check. One moment."),
            BuddyCoordinatorTests.done(BuddyBlock(say: "Done.", shape: .chip), lane: .deep),
        ])
        let c = make(voice: voice, bridge: bridge)
        await tapToTalk(c)
        await waitFor { c.phase == .showing && voice.calls.contains(.speak("Done.")) } // after its card
        let spoken = voice.calls.compactMap { if case .speak(let t) = $0 { t } else { nil } }
        #expect(spoken == ["Let me check.", "One moment.", "Done."])
    }

    @Test func researchHandoffShowsATrueLineNotAFailure() async {
        let bridge = FakeBridge(script: [
            .researchRequested(say: "I'll research that."),
            BuddyCoordinatorTests.done(
                BuddyBlock(say: "I'll research that.", shape: .chip, handoff: .research), lane: .quick),
        ])
        let c = make(voice: FakeVoice(), bridge: bridge)
        await tapToTalk(c)
        await waitFor { c.phase == .showing }
        #expect(answers == ["Research isn't available right now."]) // no ResearchController composed
    }

    @Test func newConversationWhileThinkingCancelsTheTurn() async {
        let bridge = ManualBridge()
        let c = make(voice: FakeVoice(), bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }
        overlay.send(.newConversation)
        await waitFor { bridge.cancelled.count == 1 }
        #expect(bridge.cancelled.count == 1)
        #expect(c.phase == .idle)
    }

    @Test func escapeWhileThinkingHidesARealLateAnswer() async {
        let bridge = ManualBridge()
        let c = make(voice: FakeVoice(), bridge: bridge)
        await tapToTalk(c)
        await waitFor { bridge.streamCount == 1 }
        await c.escapePressed()
        bridge.send(BuddyCoordinatorTests.done(BuddyBlock(say: "Too late.", shape: .chip)))
        bridge.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(answers.isEmpty)
        #expect(c.phase == .idle)
    }
}
