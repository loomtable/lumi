import BuddyCore
import BuddyKeys
import BuddyVoice
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Preferences defaults")
@MainActor
struct PreferencesDefaultsTests {
    @Test("Voice: Only when I spoke, voice processing on, the Mac's own hearing and voice, not set up")
    func voice() {
        let v = SettingsStore(defaults: TestDefaults().defaults).voice
        #expect(v.voiceReplies == .onlyWhenISpoke)
        #expect(v.voiceIsolation)
        #expect(v.speechModel == .appleOnDevice && v.replyVoice == .system, "fresh installs")
        #expect(v.setup == .notChosen)
    }

    @Test("Appearance: Smart placement, every effect on")
    func appearance() {
        let a = SettingsStore(defaults: TestDefaults().defaults).appearance
        #expect(a.placement == .smart)
        #expect(a.speakingGlow && a.dotField && a.inkIn && a.sounds)
        #expect(a.statusPosition == .top, "the listening pill and status sit at top centre by default")
        #expect(a.showRings && a.insertAndReplace, "answer actions are on by default")
    }

    @Test("Models: ModeConfig.default(for:) per mode and Routing.auto, all marked default")
    func models() {
        let m = SettingsStore(defaults: TestDefaults().defaults).models
        #expect(m.routing == .auto)
        for mode in Mode.allCases {
            #expect(m.config(mode) == .default(for: mode))
            #expect(m.isDefault(mode))
        }
    }

    @Test("Conversations: out-of-range values fall back to the default, not the bound")
    func conversationRanges() throws {
        func decode(_ json: String) throws -> ConversationsPreferences {
            try JSONDecoder().decode(ConversationsPreferences.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"idleTimeoutMinutes":2,"retentionDays":400}"#) == ConversationsPreferences())
        let ok = try decode(#"{"idleTimeoutMinutes":5,"retentionDays":365}"#)
        #expect(ok.idleTimeoutMinutes == 5 && ok.retentionDays == 365)
        #expect(try decode(#"{"idleTimeoutMinutes":240}"#).idleTimeoutMinutes == 240)
    }

    @Test("a field of the wrong JSON type keeps its default while the valid field next to it loads")
    func wrongType() throws {
        let keys = try JSONDecoder().decode(
            KeysPreferences.self, from: Data(#"{"holdThresholdMs":"fast","buddyKey":"function"}"#.utf8))
        #expect(keys.holdThresholdMs == 300)
        #expect(keys.key == .function)
        let voice = try JSONDecoder().decode(
            VoicePreferences.self, from: Data(#"{"voiceReplies":"sometimes","voiceIsolation":false}"#.utf8))
        #expect(voice.voiceReplies == .onlyWhenISpoke)
        #expect(!voice.voiceIsolation)
    }
}
