import BuddyVoice
import Foundation
import Testing
@testable import BuddyCompanion

@Suite("Settings › Voice › ElevenLabs")
@MainActor
struct ElevenLabsSetupTests {
    @Test("a working key is saved only after it checks out, and gives a voice")
    func savesAWorkingKey() async {
        let account = FakeElevenLabsAccount(check: .ok)
        let setup = ElevenLabsSetup(account: account)
        _ = setup.chooseEngine(true, current: .onDevice)
        setup.keyDraft = "  sk-good  "
        let voice = await setup.saveAndCheck(current: .onDevice)
        #expect(account.savedKey == "sk-good", "trimmed, then saved")
        #expect(voice == .elevenLabs(voiceID: ElevenLabsAccount.defaultVoiceID))
        #expect(setup.hasKey && setup.keyDraft.isEmpty && setup.lastCheck == .ok)
    }

    @Test("a rejected key is never saved and the voice doesn't change", arguments: [
        ElevenLabsCheck.invalidKey, .quotaExceeded, .unreachable("offline"),
    ])
    func rejectsABadKey(_ check: ElevenLabsCheck) async {
        let account = FakeElevenLabsAccount(check: check)
        let setup = ElevenLabsSetup(account: account)
        setup.keyDraft = "sk-bad"
        #expect(await setup.saveAndCheck(current: .onDevice) == nil)
        #expect(account.savedKey == nil && !setup.hasKey)
        #expect(setup.lastCheck == check)
        #expect(!ElevenLabsSetup.message(check).isEmpty)
    }

    @Test("an empty draft isn't checked")
    func emptyDraft() async {
        let setup = ElevenLabsSetup(account: FakeElevenLabsAccount())
        setup.keyDraft = "   "
        #expect(await setup.saveAndCheck(current: .onDevice) == nil)
        #expect(setup.lastCheck == nil)
    }

    @Test("the chosen voice is kept while it's offered; otherwise the first one, else the default")
    func voiceChoice() {
        let a = ElevenLabsVoice(id: "a", name: "A", category: nil), b = ElevenLabsVoice(id: "b", name: "B", category: nil)
        #expect(ElevenLabsSetup.voiceID(keeping: .elevenLabs(voiceID: "b"), from: [a, b]) == "b")
        #expect(ElevenLabsSetup.voiceID(keeping: .elevenLabs(voiceID: "gone"), from: [a, b]) == "a")
        #expect(ElevenLabsSetup.voiceID(keeping: .onDevice, from: []) == ElevenLabsAccount.defaultVoiceID)
        #expect(ElevenLabsSetup.voiceID(keeping: .elevenLabs(voiceID: "x"), from: []) == "x",
                "a key that can speak but not list voices keeps its voice")
    }

    @Test("removing the key clears it and the voices")
    func removes() async {
        let account = FakeElevenLabsAccount(key: "sk", check: .ok)
        let setup = ElevenLabsSetup(account: account)
        await setup.loadVoices()
        #expect(!setup.voices.isEmpty)
        setup.removeKey()
        #expect(account.savedKey == nil && !setup.hasKey && setup.voices.isEmpty)
    }

    @Test("replyVoice: the Mac voice for fresh installs, Kokoro for a stored value without it, lenient decoding")
    func preference() throws {
        #expect(VoicePreferences().replyVoice == .system)
        let old = try JSONDecoder().decode(VoicePreferences.self, from: Data(#"{"voiceReplies":"off"}"#.utf8))
        #expect(old.replyVoice == .onDevice && old.voiceReplies == .off)
        var p = VoicePreferences(); p.replyVoice = .elevenLabs(voiceID: "v1")
        let round = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(p))
        #expect(round.replyVoice == .elevenLabs(voiceID: "v1"))
    }

    @Test("the picker: Kokoro applies at once and clears a draft; ElevenLabs needs a saved key")
    func engineChoice() async {
        let noKey = ElevenLabsSetup(account: FakeElevenLabsAccount())
        noKey.keyDraft = "sk-half-typed"
        #expect(noKey.chooseEngine(true, current: .onDevice) == .onDevice, "no key yet: stays Kokoro")
        #expect(noKey.wantsElevenLabs)
        #expect(noKey.chooseEngine(false, current: .onDevice) == .onDevice)
        #expect(noKey.keyDraft.isEmpty, "the typed key doesn't linger")
        let withKey = ElevenLabsSetup(account: FakeElevenLabsAccount(key: "sk"))
        await withKey.loadVoices()
        #expect(withKey.chooseEngine(true, current: .onDevice) == .elevenLabs(voiceID: ElevenLabsAccount.defaultVoiceID))
    }

    @Test("the Mac voice: picked like Kokoro, and what removing a key falls back to")
    func macVoice() async {
        let setup = ElevenLabsSetup(account: FakeElevenLabsAccount(key: "sk"), current: .system)
        #expect(!setup.wantsElevenLabs && !setup.keyMissing(for: .system))
        await setup.loadVoices()
        #expect(setup.chooseEngine(true, current: .system) == .elevenLabs(voiceID: ElevenLabsAccount.defaultVoiceID))
        #expect(setup.chooseEngine(false, current: .elevenLabs(voiceID: "v")) == .system, "back to the last voice on this Mac")
        #expect(setup.chooseEngine(false, current: .system, local: .onDevice) == .onDevice)
        let fromElevenLabs = ElevenLabsSetup(account: FakeElevenLabsAccount(key: "sk"), current: .elevenLabs(voiceID: "v"))
        #expect(fromElevenLabs.chooseEngine(false, current: .elevenLabs(voiceID: "v")) == .system,
                "removing a key never starts a download")
    }

    @Test("Kokoro picked while a check runs: the key is saved but the voice stays Kokoro")
    func raceDuringCheck() async {
        let setup = ElevenLabsSetup(account: FakeElevenLabsAccount(check: .ok))
        _ = setup.chooseEngine(true, current: .onDevice)
        setup.keyDraft = "sk"
        setup.wantsElevenLabs = false          // as if Kokoro was clicked mid-check
        #expect(await setup.saveAndCheck(current: .onDevice) == nil)
        #expect(setup.hasKey)
    }

    @Test("saving a replacement key keeps the chosen voice")
    func replacementKeepsVoice() async {
        let account = FakeElevenLabsAccount(key: "old", check: .ok)
        account.setVoices([ElevenLabsVoice(id: "a", name: "A", category: nil), ElevenLabsVoice(id: "b", name: "B", category: nil)])
        let setup = ElevenLabsSetup(account: account, current: .elevenLabs(voiceID: "b"))
        setup.replacingKey = true
        setup.keyDraft = "new"
        #expect(await setup.saveAndCheck(current: .elevenLabs(voiceID: "b")) == .elevenLabs(voiceID: "b"))
        #expect(account.savedKey == "new" && !setup.replacingKey)
    }

    @Test("a key removed elsewhere is noticed on refresh and shown as missing")
    func keyRemovedElsewhere() async {
        let account = FakeElevenLabsAccount(key: "sk")
        let setup = ElevenLabsSetup(account: account, current: .elevenLabs(voiceID: "v"))
        #expect(!setup.keyMissing(for: .elevenLabs(voiceID: "v")))
        try? account.deleteKey()
        await setup.loadVoices()
        #expect(!setup.hasKey && setup.voices.isEmpty)
        #expect(setup.keyMissing(for: .elevenLabs(voiceID: "v")))
        #expect(!setup.keyMissing(for: .onDevice))
    }
}
