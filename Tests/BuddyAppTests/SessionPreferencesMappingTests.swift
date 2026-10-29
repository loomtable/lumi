@testable import BuddyApp
import BuddyCompanion
import BuddyCore
import BuddyKeys
import Foundation
import Testing

/// The v2 sections of Settings reach `EnginePreferences`.
@MainActor
struct SessionPreferencesMappingTests {
    private func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: NSTemporaryDirectory() + "session-prefs-\(UUID().uuidString)")!)
    }

    @Test func defaultsMapToTheSessionDefaults() {
        let p = EnginePreferences(store: store())
        #expect(p.sessions == SessionSettings())
        // Auto: fn when the 🌐 key does nothing (the test environment's), else right ⌘.
        #expect(p.dictationKey == .function)
        #expect(EnginePreferences(store: store(), keyEnvironment: KeyEnvironment(globeKeyUsage: 2)).dictationKey == .rightCommand)
    }

    @Test func everyChangedFieldReachesTheEngine() {
        let s = store()
        s.sessions.voiceLayer = .everyTurn
        s.sessions.speakTypedAnswers = true
        s.notifications.notifyWhenAway = false
        s.teammates.mode = .off
        s.teammates.maxSubagents = 1
        s.dictation.key = .rightControl
        let p = EnginePreferences(store: s)
        #expect(p.sessions == SessionSettings(
            voiceLayer: .everyTurn, speakTypedAnswers: true,
            notifyWhenAway: false, teammates: .off, maxSubagents: 1))
        #expect(p.dictationKey == .rightControl)
    }

    @Test func voiceRepliesOffSilencesTypedAnswersToo() {
        // QA S-19: one Off for every spoken answer.
        let s = store()
        s.sessions.speakTypedAnswers = true
        s.voice.voiceReplies = .off
        #expect(!EnginePreferences(store: s).sessions.speakTypedAnswers)
        s.voice.voiceReplies = .onlyWhenISpoke
        #expect(EnginePreferences(store: s).sessions.speakTypedAnswers)
    }

    @Test func theDictationKeyIsUnsetOnAClash() {
        let s = store()
        s.dictation.key = .rightCommand
        s.keys.key = .rightCommand
        #expect(EnginePreferences(store: s).dictationKey == nil, "same as the buddy key")
        s.keys.key = .rightOption
        // A hold can't clash with Siri's "press ⌘ twice".
        #expect(EnginePreferences(store: s, keyEnvironment: KeyEnvironment(siriEnabled: true)).dictationKey == .rightCommand)
        s.dictation.key = .function
        #expect(EnginePreferences(store: s, keyEnvironment: KeyEnvironment(globeKeyUsage: 2)).dictationKey == nil, "🌐 acts on release")
        s.dictation.enabled = false
        #expect(EnginePreferences(store: s).dictationKey == nil)
    }

    @Test func theKeyMonitorGetsTheDictationKeyOnlyWithTheFeatureOn() {
        let s = store()
        var off = LumiFeatures()
        off.dictation = false
        #expect(EnginePreferences(store: s, features: off).keys.dictationKey == nil)
        let p = EnginePreferences(store: s, features: LumiFeatures())
        #expect(p.keys.dictationKey == .function)
        #expect(p.keys.dictationKey == p.dictationKey)
    }
}
