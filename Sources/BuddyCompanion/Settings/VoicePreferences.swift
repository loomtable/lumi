import BuddyVoice
import Foundation

/// Settings › Voice.
/// The fields here hold the defaults. Speed, language and custom vocabulary wait
/// until BuddyVoice supports them; ElevenLabs waits for its speaker.
public nonisolated struct VoicePreferences: SettingsSection {
    public static let storageKey = "settings.voice.v1"

    public nonisolated enum VoiceReplies: String, Codable, Sendable, CaseIterable {
        case always, onlyWhenISpoke, off
    }

    /// "Voice replies": Only when I spoke by default.
    public var voiceReplies: VoiceReplies = .onlyWhenISpoke
    /// Voice Isolation when other audio is playing (option C): on, voice processing
    /// is used only while another app plays sound; otherwise listening starts plain. Off: never.
    public var voiceIsolation: Bool = true
    /// Speech-to-text. Fresh installs use the Mac's own recognition; Parakeet
    /// TDT v2 is the download, Unified selectable as experimental. It takes effect when the shell
    /// rebuilds the voice controller and prepares it again.
    public var speechModel: SpeechModel = .appleOnDevice
    /// Fresh installs reply in the Mac voice; Kokoro is the download, ElevenLabs only
    /// once its key checks out.
    public var replyVoice: ReplyVoice = .system
    /// Whether the voice models may load. Nothing downloads until the user picks a voice;
    /// typing works either way.
    public var setup: VoiceSetup = .notChosen

    public nonisolated enum VoiceSetup: String, Codable, Sendable {
        /// A fresh install before onboarding's Voice step: nothing loads.
        case notChosen
        /// Load what `speechModel` and `replyVoice` need.
        case voice
        /// "Not now, I'll type": nothing loads until Settings › Voice › Set Up Voice.
        case typeOnly
    }

    public init() {}

    /// What a stored value without the field reads as: the defaults before fresh installs moved to the
    /// Mac's own hearing and voice, so stored settings never change under the user.
    static let storedSpeechModel: SpeechModel = .default
    static let storedReplyVoice: ReplyVoice = .onDevice

    enum CodingKeys: String, CodingKey {
        case voiceReplies, voiceIsolation, speechModel, replyVoice, setup
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        voiceReplies = c.value(.voiceReplies, default: d.voiceReplies)
        voiceIsolation = c.value(.voiceIsolation, default: d.voiceIsolation)
        // A value stored before the Oct 17 defaults keeps what it had then: Parakeet and Kokoro.
        speechModel = c.value(.speechModel, default: Self.storedSpeechModel)
        replyVoice = c.value(.replyVoice, default: Self.storedReplyVoice)
        setup = c.value(.setup, default: d.setup)
    }
}
