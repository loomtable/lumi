import BuddyCore
import BuddyKeys
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("v2 session preferences")
@MainActor
struct SessionsPreferencesTests {
    @Test("defaults on a fresh install match the lead's decisions")
    func freshDefaults() {
        let store = SettingsStore(defaults: TestDefaults().defaults)
        #expect(store.sessions.voiceLayer == .voiceTurns)
        #expect(!store.sessions.speakTypedAnswers)
        #expect(store.notifications.notifyWhenAway)
        #expect(store.teammates.mode == .askFirst)
        #expect(store.teammates.maxSubagents == 3)
        #expect(store.dictation.enabled)
        #expect(store.dictation.key == nil)
        #expect(store.dictation.choice == .auto)
    }

    @Test("each new section has its own versioned key, distinct from the old ones")
    func keys() {
        let keys = [SessionsPreferences.storageKey, NotificationsPreferences.storageKey, TeammatesPreferences.storageKey,
                    DictationPreferences.storageKey, KeysPreferences.storageKey, PrivacyPreferences.storageKey,
                    ConversationsPreferences.storageKey, VoicePreferences.storageKey, AppearancePreferences.storageKey,
                    ModelPreferences.storageKey, ConnectionsPreferences.storageKey]
        #expect(Set(keys).count == keys.count)
        #expect(SessionsPreferences.storageKey == "settings.sessions.v1")
        #expect(DictationPreferences.storageKey == "settings.dictation.v1")
        #expect(NotificationsPreferences.storageKey == "settings.notifications.v1")
        #expect(TeammatesPreferences.storageKey == "settings.teammates.v1")
    }

    @Test("changes persist; resetAll restores them")
    func persists() {
        let t = TestDefaults()
        let store = SettingsStore(defaults: t.defaults)
        store.sessions.voiceLayer = .everyTurn
        store.teammates.maxSubagents = 5
        store.dictation.key = .rightControl
        store.notifications.notifyWhenAway = false
        let reloaded = SettingsStore(defaults: t.defaults)
        #expect(reloaded.sessions.voiceLayer == .everyTurn)
        #expect(reloaded.teammates.maxSubagents == 5)
        #expect(reloaded.dictation.key == .rightControl)
        #expect(!reloaded.notifications.notifyWhenAway)
        reloaded.resetAll()
        let reset = SettingsStore(defaults: t.defaults)
        #expect(reset.sessions == SessionsPreferences())
        #expect(reset.teammates == TeammatesPreferences())
        #expect(reset.dictation == DictationPreferences())
        #expect(reset.notifications == NotificationsPreferences())
    }

    @Test("bad stored values fall back to defaults field by field")
    func lenient() {
        let t = TestDefaults()
        t.defaults.set(Data(#"{"mode":"automatic","maxSubagents":9}"#.utf8), forKey: TeammatesPreferences.storageKey)
        t.defaults.set(Data(#"{"voiceLayer":"sometimes","speakTypedAnswers":"x"}"#.utf8), forKey: SessionsPreferences.storageKey)
        t.defaults.set(Data(#"{"dictationKey":"nope"}"#.utf8), forKey: DictationPreferences.storageKey)
        let store = SettingsStore(defaults: t.defaults)
        #expect(store.teammates.mode == .automatic)
        #expect(store.teammates.maxSubagents == 3)
        #expect(store.sessions.voiceLayer == .voiceTurns)
        #expect(!store.sessions.speakTypedAnswers)
        #expect(store.dictation.choice == .auto)
    }

    @Test("the stored choice: auto by default, a picked key, or off; resolved by DictationKeyResolver")
    func dictationChoice() {
        var d = DictationPreferences()
        #expect(d.choice == .auto)
        #expect(d.dictationKey == "auto")
        let emoji = KeyEnvironment(globeKeyUsage: 2)
        #expect(d.resolved(buddyKey: .rightOption, in: emoji).key == .rightCommand)
        d.choice = .key(.rightControl)
        #expect(d.key == .rightControl && d.enabled)
        #expect(d.resolved(buddyKey: .rightOption, in: emoji).key == .rightControl)
        #expect(d.resolved(buddyKey: .rightControl, in: emoji).key == nil)
        d.choice = .off
        #expect(!d.enabled)
        #expect(d.resolved(buddyKey: .rightOption, in: emoji).key == nil)
        d.choice = .auto
        #expect(d.enabled && d.key == nil)
        // A key stored before Auto existed keeps working.
        d.dictationKey = BuddyKey.rightCommand.rawValue
        #expect(d.choice == .key(.rightCommand))
    }
}
