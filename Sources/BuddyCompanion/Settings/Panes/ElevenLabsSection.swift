import BuddyOverlay
import BuddyVoice
import Observation
import SwiftUI

/// The ElevenLabs opt-in in Settings › Voice: check a key, save it only if it works,
/// pick a voice. The voice on this Mac (Kokoro or the Mac voice) stays until all of that succeeds.
@Observable
final class ElevenLabsSetup {
    var keyDraft = ""
    /// ElevenLabs chosen in the picker. The preference only changes once a key works.
    var wantsElevenLabs: Bool
    /// The voice on this Mac that replies when ElevenLabs isn't the voice: the last one picked,
    /// else the Mac voice, so removing a key never starts a download.
    private(set) var localVoice: ReplyVoice
    /// "Change Key…": the key field shows although a key is saved.
    var replacingKey = false
    private(set) var checking = false
    /// The last check's result, shown under the key field.
    private(set) var lastCheck: ElevenLabsCheck?
    private(set) var voices: [ElevenLabsVoice] = []
    private(set) var hasKey: Bool
    /// A Keychain error saving or removing the key.
    private(set) var keyError: String?

    @ObservationIgnored let account: any ElevenLabsAccounting

    init(account: any ElevenLabsAccounting, current: ReplyVoice = .onDevice) {
        self.account = account
        hasKey = account.hasKey
        wantsElevenLabs = current.isElevenLabs
        localVoice = current.isElevenLabs ? .system : current
    }

    /// A key saved for ElevenLabs is missing (removed in Keychain Access, say): replies use the
    /// voice on this Mac.
    func keyMissing(for current: ReplyVoice) -> Bool { current.isElevenLabs && !hasKey }

    /// The picker. A voice on this Mac (`local`, else the last one) applies at once; ElevenLabs
    /// only with a saved key (otherwise the key field shows and the voice stays until a key checks out).
    func chooseEngine(_ wants: Bool, current: ReplyVoice, local: ReplyVoice? = nil) -> ReplyVoice {
        wantsElevenLabs = wants
        guard wants else {
            keyDraft = ""
            replacingKey = false
            if let local { localVoice = local }
            return localVoice
        }
        return hasKey ? .elevenLabs(voiceID: Self.voiceID(keeping: current, from: voices)) : current
    }

    /// Checks `keyDraft` before saving it. On success: saves it, loads the voices and returns the
    /// voice to use (the current one if it's still offered, else the first, else the default).
    func saveAndCheck(current: ReplyVoice) async -> ReplyVoice? {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return nil }
        checking = true
        defer { checking = false }
        let result = await account.validate(key: key)
        lastCheck = result
        guard result == .ok else { return nil }
        do {
            try account.saveKey(key)
        } catch {
            keyError = "Couldn't save the key in the Keychain."
            return nil
        }
        keyError = nil
        keyDraft = ""
        replacingKey = false
        hasKey = true
        await loadVoices()
        // A voice on this Mac picked while the check ran: the key is kept, the voice stays.
        return wantsElevenLabs ? .elevenLabs(voiceID: Self.voiceID(keeping: current, from: voices)) : nil
    }

    func loadVoices() async {
        hasKey = account.hasKey  // a key may have been added or removed elsewhere
        guard hasKey else { voices = []; return }
        voices = (try? await account.voices()) ?? []
    }

    /// Removes the key; the caller switches the reply voice back to `localVoice`.
    func removeKey() {
        do {
            try account.deleteKey()
            hasKey = false
            voices = []
            lastCheck = nil
            keyError = nil
        } catch {
            keyError = "Couldn't remove the key from the Keychain."
        }
    }

    static func voiceID(keeping current: ReplyVoice, from voices: [ElevenLabsVoice]) -> String {
        if case .elevenLabs(let id) = current, voices.isEmpty || voices.contains(where: { $0.id == id }) { return id }
        return voices.first?.id ?? ElevenLabsAccount.defaultVoiceID
    }

    static func message(_ check: ElevenLabsCheck) -> String {
        switch check {
        case .ok: "Key works."
        case .invalidKey: "ElevenLabs didn't accept this key."
        case .quotaExceeded: "This ElevenLabs account is out of credits."
        case .unreachable(let why): "Couldn't reach ElevenLabs: \(why)"
        }
    }
}

struct ElevenLabsSection: View {
    @Binding var replyVoice: ReplyVoice
    /// The voices on this Mac the picker offers before ElevenLabs.
    let localVoices: [ReplyVoice]
    let keyChanged: (@Sendable () async -> Void)?
    @State private var setup: ElevenLabsSetup

    init(replyVoice: Binding<ReplyVoice>, localVoices: [ReplyVoice] = [.onDevice, .system],
         account: any ElevenLabsAccounting, keyChanged: (@Sendable () async -> Void)?) {
        _replyVoice = replyVoice
        self.localVoices = localVoices
        self.keyChanged = keyChanged
        _setup = State(initialValue: ElevenLabsSetup(account: account, current: replyVoice.wrappedValue))
    }

    var body: some View {
        Section {
            Picker("Reply voice", selection: engineChoice) {
                ForEach(localVoices.indices, id: \.self) { Text(Self.title(localVoices[$0])).tag($0) }
                Text("ElevenLabs Eleven v4 Turbo").tag(-1)
            }
            .pickerStyle(.radioGroup)
            if setup.wantsElevenLabs {
                ElevenLabsKeyFields(setup: setup, replyVoice: $replyVoice, keyChanged: keyChanged)
            }
        } header: {
            // Not "Voice": that's the page's own title.
            Text("Reply voice")
        } footer: {
            Text(setup.wantsElevenLabs
                 ? "The most human-sounding voice. \(ElevenLabsAccount.privacyNote) If ElevenLabs can't be reached, that reply uses the Mac voice."
                 : replyVoice == .system ? "The voice built into macOS. Nothing leaves this Mac to be spoken."
                 : "Kokoro speaks on this Mac. Nothing leaves it to be spoken.")
        }
        .task { await setup.loadVoices() }
    }

    /// An index into `localVoices`, or -1 for ElevenLabs.
    private var engineChoice: Binding<Int> {
        // The stored preference changes here; the shell applies it to the voice on every change.
        Binding(get: { setup.wantsElevenLabs ? -1 : localVoices.firstIndex(of: replyVoice) ?? 0 },
                set: { replyVoice = setup.chooseEngine($0 < 0, current: replyVoice,
                                                       local: localVoices.indices.contains($0) ? localVoices[$0] : nil) })
    }

    static func title(_ voice: ReplyVoice) -> String {
        voice == .system ? "Mac voice, no download" : "Kokoro, on this Mac"
    }
}

/// ElevenLabs' key and voice: the key field with Save & Check until a key works, then the voice
/// picker with Change Key… and Remove Key. Settings › Voice and onboarding's Voice step show it once
/// ElevenLabs is chosen. In a Form, each part is its own row.
struct ElevenLabsKeyFields: View {
    @Bindable var setup: ElevenLabsSetup
    @Binding var replyVoice: ReplyVoice
    let keyChanged: (@Sendable () async -> Void)?

    var body: some View {
        if setup.keyMissing(for: replyVoice) {
            Text("The ElevenLabs key is missing, so replies use the Mac voice. Add a key to use ElevenLabs again.")
                .font(.caption).foregroundStyle(.lumiAmber)
        }
        if setup.hasKey, !setup.replacingKey {
            Picker("Voice", selection: voiceID) {
                if setup.voices.isEmpty {
                    Text("Default voice").tag(ElevenLabsAccount.defaultVoiceID)
                }
                ForEach(setup.voices) { Text($0.name).tag($0.id) }
            }
            HStack {
                Button("Change Key…") { setup.replacingKey = true }
                Button("Remove Key", role: .destructive) {
                    setup.removeKey()
                    replyVoice = setup.chooseEngine(false, current: replyVoice)
                    Task { await keyChanged?() }
                }
            }
        } else {
            HStack {
                SecureField("ElevenLabs API key", text: $setup.keyDraft)
                Button(setup.checking ? "Checking…" : "Save & Check") {
                    Task {
                        let voice = await setup.saveAndCheck(current: replyVoice)
                        if let voice { replyVoice = voice }
                        // A new or replaced key: the controller retries ElevenLabs.
                        if setup.lastCheck == .ok, setup.hasKey { await keyChanged?() }
                    }
                }
                .disabled(setup.checking || setup.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if setup.replacingKey {
                    Button("Cancel") { setup.replacingKey = false; setup.keyDraft = "" }
                }
            }
        }
        if let check = setup.lastCheck, check != .ok || !setup.hasKey {
            Text(ElevenLabsSetup.message(check)).font(.caption)
                .foregroundStyle(check == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.lumiAmber))
        }
        if let error = setup.keyError {
            Text(error).font(.caption).foregroundStyle(.lumiAmber)
        }
    }

    private var voiceID: Binding<String> {
        Binding(get: { ElevenLabsSetup.voiceID(keeping: replyVoice, from: setup.voices) },
                set: { replyVoice = .elevenLabs(voiceID: $0) })
    }
}

extension ReplyVoice {
    var isElevenLabs: Bool {
        if case .elevenLabs = self { true } else { false }
    }
}
