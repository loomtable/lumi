import CoreGraphics
import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCompanion
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyVoice

/// "Model download or compile running": the buddy key answers with the real setup progress.
@MainActor
struct SetupChipTests {
    let voice = FakeVoice()
    let overlay = FakeOverlay()
    let bridge = FakeBridge()

    func make() -> BuddyCoordinator {
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let c = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer())
        c.start()
        return c
    }

    func settle(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + waitCeiling
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    static func loading(_ fraction: Double) -> VoiceController.PrepareState {
        .preparing(.speechModel(ModelLoadProgress(fraction: fraction, phase: .downloading(completedFiles: 1, totalFiles: 4))))
    }

    var chips: [String] { overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block.say } else { nil } } }
    var chipTexts: [String] { overlay.calls.compactMap { if case .chipText(let t) = $0 { t } else { nil } } }

    @Test func setupLines() {
        #expect(BuddyCoordinator.setupLine(Self.loading(0.426), key: "⌥") == "Still setting up voice · 42% · double-tap ⌥ to type")
        #expect(BuddyCoordinator.setupLine(.preparing(.speechModel(nil)), key: "⌥") == "Still setting up voice · double-tap ⌥ to type")
        #expect(BuddyCoordinator.setupLine(.preparing(.voice(nil)), key: "⌥") == "Still setting up voice · loading the voice · double-tap ⌥ to type")
        #expect(BuddyCoordinator.setupLine(.ready, key: "⌥") == nil)
        #expect(BuddyCoordinator.setupLine(.failed("x"), key: "⌥") == nil)
        #expect(BuddyCoordinator.setupLine(.notStarted, key: "⌥") == nil)
    }

    @Test func theKeyAnswersWithLiveProgressThenReady() async {
        let c = make()
        voice.eventSink.yield(.setup(Self.loading(0.42)))
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        for _ in 0..<50 { await Task.yield() }

        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(chips == ["Still setting up voice · 42% · double-tap ⌥ to type"])

        voice.eventSink.yield(.setup(Self.loading(0.61)))
        voice.eventSink.yield(.setup(.preparing(.voice(nil))))
        voice.eventSink.yield(.setup(.ready))
        await settle(until: { chipTexts.count == 3 })
        #expect(chipTexts == [
            "Still setting up voice · 61% · double-tap ⌥ to type", "Still setting up voice · loading the voice · double-tap ⌥ to type",
            "Voice is ready. Tap ⌥ to talk.",
        ])
    }

    @Test func noVoiceChosenSaysSoAndItsButtonOpensVoiceSettings() async {
        let c = make()
        var opened: [SettingsPane] = []
        c.onOpenSettingsPane = { opened.append($0) }
        voice.setStartError(VoicePortError("Voice isn't set up.", notSetUp: true))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(chips == ["Voice isn't set up · double-tap ⌥ to type"])
        let actions = overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block.actions.map(\.label) } else { nil } }
        #expect(actions.last == ["Set Up Voice"])

        overlay.send(.action(index: 0))
        await settle(until: { !opened.isEmpty })
        #expect(opened == [.voice])
    }

    @Test func typingWorksWhileVoiceSetsUp() async {
        let c = make()
        bridge.setScript([BuddyCoordinatorTests.done(BuddyBlock(say: "Typed fine.", shape: .chip))])
        voice.eventSink.yield(.setup(Self.loading(0.3)))
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        for _ in 0..<50 { await Task.yield() }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(chips.last?.hasSuffix("double-tap ⌥ to type") == true)
        await c.handle(.gesture(.tap))
        // The double-tap the chip suggests: two presses, the second recognised as a double-tap.
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.doubleTap))
        await settle(until: { c.phase == .typing })
        #expect(c.phase == .typing)
        #expect(overlay.calls.contains { if case .textBox = $0 { true } else { false } })
        overlay.send(.submitted(text: "what does this mean?", source: .textBox))
        await settle(until: { bridge.asked.count == 1 && c.phase == .showing })
        #expect(bridge.asked.first?.packet.utterance == "what does this mean?")
        #expect(chips.last == "Typed fine.")
        // Setup carries on: its progress never rewrites the answer.
        voice.eventSink.yield(.setup(Self.loading(0.5)))
        voice.eventSink.yield(.setup(.ready))
        for _ in 0..<100 { await Task.yield() }
        #expect(chipTexts.isEmpty)
    }

    @Test func aDoubleTapFromIdleDuringSetupOpensTheTextBox() async {
        let c = make()
        voice.eventSink.yield(.setup(Self.loading(0.3)))
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        for _ in 0..<50 { await Task.yield() }
        // A real double-tap: press, then the second press recognised as one, with no tap between.
        await c.handle(.gesture(.pressBegan(fresh: false)))
        await c.handle(.gesture(.doubleTap))
        await settle(until: { c.phase == .typing })
        #expect(c.phase == .typing)
    }

    @Test func everySetupChipSaysHowToType() async {
        let c = make()
        // No progress yet: the voice's own line, with the hint.
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(chips.last == "Still setting up voice · double-tap ⌥ to type")
        // A failed setup being retried.
        overlay.dismiss(.clickAway)
        await settle(until: { c.phase == .idle })
        voice.setStartError(VoicePortError("Voice setup failed. Trying again…", stillSettingUp: true))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(chips.last == "Voice setup failed. Trying again · double-tap ⌥ to type")
    }

    @Test func withStickyKeysOnNoChipOffersTheDoubleTap() async {
        #expect(BuddyCoordinator.setupLine(Self.loading(0.426), key: nil) == "Still setting up voice · 42%.")
        #expect(BuddyCoordinator.withTypeHint("Voice setup failed. Trying again…", key: nil) == "Voice setup failed. Trying again…")
        let c = make()
        c.doubleTapAvailable = { false }
        voice.eventSink.yield(.setup(Self.loading(0.42)))
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        for _ in 0..<50 { await Task.yield() }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.setup(.failed("x")))
        await settle(until: { chipTexts.count == 1 })
        #expect(chips == ["Still setting up voice · 42%."])
        #expect(chipTexts == ["Voice setup failed. Tap ⌥ to try again."])
    }

    @Test func progressWithoutTheChipChangesNothing() async {
        let c = make()
        voice.eventSink.yield(.setup(Self.loading(0.5)))
        for _ in 0..<100 { await Task.yield() }
        #expect(chipTexts.isEmpty)
        #expect(chips.isEmpty)
        withExtendedLifetime(c) {}
    }

    @Test func aClosedChipStopsFollowingProgress() async {
        let c = make()
        voice.eventSink.yield(.setup(Self.loading(0.1)))
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        for _ in 0..<50 { await Task.yield() }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        overlay.dismiss(.clickAway)
        await settle(until: { c.phase == .idle })
        voice.eventSink.yield(.setup(Self.loading(0.2)))
        for _ in 0..<100 { await Task.yield() }
        #expect(chipTexts.isEmpty)
    }

    @Test func liveVoiceForwardsSetupProgress() {
        #expect(LiveVoice.map(.prepare(Self.loading(0.3))) == .setup(Self.loading(0.3)))
        #expect(LiveVoice.map(.prepare(.ready)) == .setup(.ready))
    }

    @Test func aRealMicFailureDuringSetupSaysWhatItIs() async {
        let c = make()
        voice.eventSink.yield(.setup(.preparing(.microphone)))
        voice.setStartError(VoicePortError("Microphone access is off. You can still type."))
        for _ in 0..<50 { await Task.yield() }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(chips == ["Microphone access is off. You can still type."])
        voice.eventSink.yield(.setup(.ready))
        for _ in 0..<100 { await Task.yield() }
        #expect(chipTexts.isEmpty) // never "Voice is ready" over a denied mic
    }

    @Test func aFailedSetupSaysSo() async {
        let c = make()
        voice.eventSink.yield(.setup(Self.loading(0.42)))
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        for _ in 0..<50 { await Task.yield() }
        await c.handle(.gesture(.pressBegan(fresh: false)))
        voice.eventSink.yield(.setup(.failed("disk full")))
        await settle(until: { !chipTexts.isEmpty })
        #expect(chipTexts == ["Voice setup failed. Tap ⌥ to try again, or double-tap ⌥ to type."])
    }

    @Test func withoutProgressYetTheGenericLineShows() async {
        let c = make()
        voice.setStartError(VoicePortError("Still setting up voice.", stillSettingUp: true))
        await c.handle(.gesture(.pressBegan(fresh: false)))
        #expect(chips == ["Still setting up voice · double-tap ⌥ to type"])
    }
}
