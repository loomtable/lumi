import BuddyKeys
import BuddyVoice
import Foundation
import Testing
@testable import BuddyCompanion

/// A private UserDefaults suite. An absolute path keeps its plist in the temp folder: a plain
/// name lands in ~/Library/Preferences, and removing that domain still leaves a file there.
final class TestDefaults {
    let name = NSTemporaryDirectory() + "LumiTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }
}

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    @Test("defaults on a fresh install match the design")
    func freshDefaults() {
        let t = TestDefaults()
        let store = SettingsStore(defaults: t.defaults)
        #expect(store.keys.key == .rightOption)
        #expect(store.keys.holdThresholdMs == 300)
        #expect(store.keys.doubleTapWindowMs == 300)
        #expect(!store.keys.ignoreDuringSecureInput)
        #expect(store.privacy.screenshotRetentionHours == 24)
        #expect(!store.privacy.traceLogEnabled)
        #expect(store.privacy.blockedBundleIDs.isEmpty)
        #expect(store.conversations.idleTimeoutMinutes == 30)
        #expect(store.conversations.retentionDays == 90)
        #expect(!store.conversations.temporaryMode)
    }

    @Test("changes persist and reload in a new store")
    func persists() {
        let t = TestDefaults()
        let store = SettingsStore(defaults: t.defaults)
        store.keys.key = .function
        store.keys.holdThresholdMs = 350
        store.privacy.blockedBundleIDs = ["com.example.bank"]
        store.privacy.traceLogEnabled = true
        store.conversations.temporaryMode = true
        let reloaded = SettingsStore(defaults: t.defaults)
        #expect(reloaded.keys == store.keys)
        #expect(reloaded.privacy == store.privacy)
        #expect(reloaded.conversations == store.conversations)
        #expect(reloaded.keys.key == .function)
    }

    @Test("every section has its own versioned key")
    func keys() {
        let keys = [KeysPreferences.storageKey, PrivacyPreferences.storageKey, ConversationsPreferences.storageKey,
                    VoicePreferences.storageKey, AppearancePreferences.storageKey, ModelPreferences.storageKey]
        #expect(Set(keys).count == keys.count)
        for key in keys { #expect(key.range(of: #"^settings\.[a-z]+\.v\d+$"#, options: .regularExpression) != nil) }
    }

    @Test("a stored section missing new fields keeps the old values and defaults the rest")
    func lenientDecoding() {
        let t = TestDefaults()
        t.defaults.set(Data(#"{"buddyKey":"function"}"#.utf8), forKey: KeysPreferences.storageKey)
        t.defaults.set(Data(#"{"traceLogEnabled":true,"unknownFutureField":1}"#.utf8), forKey: PrivacyPreferences.storageKey)
        let store = SettingsStore(defaults: t.defaults)
        #expect(store.keys.key == .function)
        #expect(store.keys.holdThresholdMs == 300)
        #expect(store.privacy.traceLogEnabled)
        #expect(store.privacy.screenshotRetentionHours == 24)
    }

    @Test("out-of-range and invalid values are corrected, garbage falls back to defaults")
    func invalidValues() {
        let t = TestDefaults()
        t.defaults.set(Data(#"{"holdThresholdMs":5,"doubleTapWindowMs":99999,"buddyKey":"nope"}"#.utf8), forKey: KeysPreferences.storageKey)
        t.defaults.set(Data(#"{"screenshotRetentionHours":72}"#.utf8), forKey: PrivacyPreferences.storageKey)
        t.defaults.set(Data("not json".utf8), forKey: ConversationsPreferences.storageKey)
        let store = SettingsStore(defaults: t.defaults)
        #expect(store.keys.holdThresholdMs == KeysPreferences.timingRange.lowerBound)
        #expect(store.keys.doubleTapWindowMs == KeysPreferences.timingRange.upperBound)
        #expect(store.keys.key == .rightOption)
        #expect(store.privacy.screenshotRetentionHours == 24)  // never above 24 h
        #expect(store.conversations == ConversationsPreferences())
    }

    @Test("an unchanged section is not rewritten; resetAll restores defaults")
    func writesOnlyChanges() {
        let t = TestDefaults()
        let store = SettingsStore(defaults: t.defaults)
        store.keys = store.keys
        #expect(t.defaults.data(forKey: KeysPreferences.storageKey) == nil)
        store.keys.holdThresholdMs = 400
        #expect(t.defaults.data(forKey: KeysPreferences.storageKey) != nil)
        store.resetAll()
        #expect(SettingsStore(defaults: t.defaults).keys == KeysPreferences())
    }

    @Test("voice setup: not chosen on a fresh install, already chosen for someone who finished onboarding, kept by a reset")
    func voiceSetup() throws {
        let fresh = TestDefaults()
        #expect(SettingsStore(defaults: fresh.defaults).voice.setup == .notChosen)
        let old = try JSONDecoder().decode(VoicePreferences.self, from: Data(#"{"voiceReplies":"off"}"#.utf8))
        #expect(old.setup == .notChosen)
        let onboarded = TestDefaults()
        onboarded.defaults.set(OnboardingModel.version, forKey: OnboardingModel.completedKey)
        let store = SettingsStore(defaults: onboarded.defaults)
        #expect(store.voice.setup == .voice, "their voice keeps loading at launch")
        #expect(SettingsStore(defaults: onboarded.defaults).voice.setup == .voice, "saved")
        store.voice.setup = .typeOnly
        store.resetAll()
        #expect(store.voice.setup == .typeOnly)
    }

    @Test("someone who finished the old Voice step but not onboarding keeps the voice")
    func voiceStepDoneMigrates() {
        let t = TestDefaults()
        t.defaults.set(["welcome", "permissions", "external.voice"], forKey: OnboardingModel.completedStepsKey)
        #expect(SettingsStore(defaults: t.defaults).voice.setup == .voice)
    }

    @Test("someone onboarded with no saved voice section keeps Parakeet and Kokoro; a fresh install gets the Mac's")
    func onboardedWithoutVoiceSectionKeepsOldModels() {
        let onboarded = TestDefaults()
        onboarded.defaults.set(OnboardingModel.version, forKey: OnboardingModel.completedKey)
        let store = SettingsStore(defaults: onboarded.defaults)
        #expect(store.voice.speechModel == .parakeetTDTv2)
        #expect(store.voice.replyVoice == .onDevice)
        let reloaded = SettingsStore(defaults: onboarded.defaults).voice
        #expect(reloaded.speechModel == .parakeetTDTv2 && reloaded.replyVoice == .onDevice, "saved")
        let fresh = SettingsStore(defaults: TestDefaults().defaults).voice
        #expect(fresh.speechModel == .appleOnDevice && fresh.replyVoice == .system)
    }

    @Test("the migration runs once: finishing onboarding later never chooses a voice by itself")
    func voiceSetupMigratesOnce() {
        let t = TestDefaults()
        #expect(SettingsStore(defaults: t.defaults).voice.setup == .notChosen)  // first launch
        t.defaults.set(OnboardingModel.version, forKey: OnboardingModel.completedKey)
        #expect(SettingsStore(defaults: t.defaults).voice.setup == .notChosen)
    }

    @Test("a test's suite writes nothing to ~/Library/Preferences")
    func staysOutOfPreferences() {
        let t = TestDefaults()
        SettingsStore(defaults: t.defaults).keys.holdThresholdMs = 400
        t.defaults.synchronize()
        let file = (t.name as NSString).lastPathComponent + ".plist"
        #expect(FileManager.default.fileExists(atPath: t.name + ".plist"))
        #expect(!FileManager.default.fileExists(atPath: URL.libraryDirectory.appending(path: "Preferences/" + file).path))
    }
}
