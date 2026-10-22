@testable import BuddyCompanion
import BuddyVoice
import Foundation
import Testing

@MainActor
struct VoiceOnboardingTests {
    final class Box { var state: VoiceController.PrepareState = .notStarted }
    typealias V = VoiceOnboarding

    /// A Mac with its English speech files and nothing downloaded.
    static let bare = V.OnMac(macHearing: .installed)

    @Test func continueIsNeverHeldAndTheStepIsDoneWhenTheVoiceIsReady() {
        let box = Box()
        let t = TestDefaults()
        let store = SettingsStore(defaults: t.defaults)
        let step = V.step(store: store, state: { box.state }, prepare: {})
        #expect(step.id == V.stepID && step.headerAccessory != nil)
        #expect(step.onStart == nil, "nothing loads before the step looks at the Mac")
        #expect(store.voice.setup == .notChosen && step.canContinue() && !step.isComplete())
        store.voice = V.initial(store.voice, Self.bare)
        #expect(store.voice.setup == .voice && step.canContinue() && !step.isComplete())
        box.state = .preparing(.speechModel(nil))
        #expect(step.canContinue() && !step.isComplete(), "Continue while it loads")
        box.state = .failed("offline")
        #expect(step.canContinue() && !step.isComplete())
        box.state = .ready
        #expect(step.isComplete())
    }

    @Test func typingForNowDownloadsNothingAndIsDone() {
        let t = TestDefaults()
        let store = SettingsStore(defaults: t.defaults)
        let step = V.step(store: store, state: { .notStarted }, prepare: {})
        store.voice.setup = .typeOnly
        #expect(step.canContinue() && step.isComplete())
        #expect(V.initial(store.voice, Self.bare).setup == .typeOnly, "the step's first look never undoes typing")
    }

    @Test func aFreshInstallStartsOnTheMacsHearingAndVoiceWithNothingToDownload() {
        let fresh = VoicePreferences()
        #expect(V.listen(fresh) == .mac && V.speak(fresh) == .mac)
        #expect(!V.downloads(fresh, Self.bare))
        #expect(V.initial(fresh, Self.bare).setup == .voice, "preselected: Continue is enough")
        #expect(V.initial(fresh, V.OnMac()).setup == .notChosen, "not before the Mac was checked")
    }

    @Test func choosingMacHearingSetsItUpEvenWhenMacOSStillNeedsItsSpeechFiles() {
        // Regression: the Mac row looked chosen, but setup stayed .notChosen until a "Get" click,
        // so voice later said "not set up". Now the preselected Mac hearing is always prepared.
        let fresh = VoicePreferences()
        let noFiles = V.OnMac(macHearing: .needsLanguageFiles)
        #expect(!V.downloads(fresh, noFiles), "macOS's own speech files aren't a model download")
        #expect(V.initial(fresh, noFiles).setup == .voice, "set up at once; the step shows macOS fetching its files")
        var parakeetChosen = fresh
        parakeetChosen.speechModel = .parakeetTDTv2
        #expect(V.settle(parakeetChosen, noFiles).setup == .notChosen, "a model still waits for its Download")
    }

    @Test func aMacThatCantRecogniseUSEnglishIsNeverSetUpOnIt() {
        let fresh = VoicePreferences()
        #expect(V.initial(fresh, V.OnMac(macHearing: .unsupported)).setup == .notChosen)
        #expect(V.initial(fresh, V.OnMac(macHearing: .unsupported, parakeet: true)).setup == .notChosen,
                "the stored choice is still Mac hearing: Parakeet is picked, not assumed")
    }

    @Test func aBetterModelDownloadsOnlyFromItsButton() {
        var v = V.initial(VoicePreferences(), Self.bare)
        v.setup = .notChosen
        v.speechModel = V.speechModel(.parakeet, current: v.speechModel)
        #expect(v.speechModel == .parakeetTDTv2 && V.downloads(v, Self.bare))
        #expect(V.settle(v, Self.bare).setup == .notChosen, "picking alone downloads nothing")
        #expect(V.settle(v, Self.bare, downloadClicked: true).setup == .voice)
        let downloaded = V.OnMac(macHearing: .installed, parakeet: true, kokoro: true)
        #expect(V.settle(v, downloaded).setup == .voice, "already on this Mac: a plain choice")
        v.replyVoice = .onDevice
        #expect(V.speak(v) == .kokoro && V.downloads(v, V.OnMac(macHearing: .installed, parakeet: true)))
    }

    @Test func parakeetKeepsAParakeetAlreadyChosenAndMacSwitchesBack() {
        #expect(V.speechModel(.parakeet, current: .parakeetUnified) == .parakeetUnified)
        #expect(V.speechModel(.parakeet, current: .appleOnDevice) == .default)
        #expect(V.speechModel(.mac, current: .parakeetUnified) == .appleOnDevice)
    }

    @Test func aVoiceAlreadySetUpStaysSetUp() {
        var v = VoicePreferences()
        v.setup = .voice
        v.replyVoice = .onDevice
        #expect(V.settle(v, V.OnMac(macHearing: .installed)).setup == .voice)
    }

    @Test func speakingChoicesFollowElevenLabsRules() {
        let setup = ElevenLabsSetup(account: FakeElevenLabsAccount(), current: .system)
        #expect(setup.chooseEngine(false, current: .system, local: .onDevice) == .onDevice)
        #expect(setup.chooseEngine(true, current: .onDevice) == .onDevice, "no key yet: the Mac voice on this Mac stays")
        #expect(setup.wantsElevenLabs)
        #expect(setup.chooseEngine(false, current: .onDevice, local: .system) == .system && !setup.wantsElevenLabs)
        #expect(V.speak(VoicePreferences()) == .mac)
        var eleven = VoicePreferences()
        eleven.replyVoice = .elevenLabs(voiceID: "a")
        #expect(V.speak(eleven) == .elevenLabs && !V.downloads(eleven, Self.bare), "ElevenLabs downloads nothing")
    }

    @Test func aNewExternalStepCountsAsNotDoneInTheModel() {
        let t = TestDefaults()
        let d = t.defaults
        let step = V.step(store: SettingsStore(defaults: d), state: { .ready }, prepare: {})
        let done = OnboardingModel.steps(external: []).map(\.id)
        d.set(done, forKey: OnboardingModel.completedStepsKey)
        #expect(!OnboardingModel.needsOnboarding(external: [], defaults: d))
        #expect(OnboardingModel.needsOnboarding(external: [step], defaults: d), "the new step was never completed")
        #expect(OnboardingModel.steps(external: [step]).contains(.external(id: "voice")))
    }
}
