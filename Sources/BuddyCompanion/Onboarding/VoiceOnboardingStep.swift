import BuddyVoice
import SwiftUI

/// Onboarding's Voice step and the model-download chip shown in its header on every
/// step. Split in two halves: how Lumi listens and how it speaks. Each half
/// starts on what's built into the Mac, which the step sets up at once (macOS's English speech files
/// if they're missing, and voice detection), with its progress shown. Parakeet and Kokoro are marked
/// Recommended and download only when their Download button is clicked. Typing always works, so
/// there's no separate "type instead" choice. Progress is only what BuddyVoice reports,
/// worded and drawn as in Settings › Voice.
public enum VoiceOnboarding {
    public static let stepID = "voice"

    /// `state` reads the shell's mirror of `VoiceController.prepareState` (observable, so the step
    /// and chip update); `prepare` retries loading. A choice sets `VoicePreferences`, and the shell
    /// loads from that.
    public static func step(store: SettingsStore, state: @escaping @MainActor () -> VoiceController.PrepareState,
                            prepare: @escaping @Sendable () async -> Void) -> ExternalOnboardingStep {
        ExternalOnboardingStep(
            id: stepID, title: "Voice",
            headerAccessory: AnyView(VoicePrepareChip(state: state)),
            isComplete: { store.voice.setup == .typeOnly || (store.voice.setup == .voice && state() == .ready) }
        ) {
            VoiceStepView(store: store, state: state, prepare: prepare)
        }
    }

    enum Listen: Equatable { case mac, parakeet }
    enum Speak: Equatable { case mac, kokoro, elevenLabs }

    /// What's already on this Mac, so a choice knows whether it would download anything.
    struct OnMac: Equatable {
        /// Nil until checked.
        var macHearing: AppleSpeechTranscriber.Availability?
        var parakeet = false
        var kokoro = false
    }

    static func listen(_ voice: VoicePreferences) -> Listen {
        voice.speechModel.isParakeet ? .parakeet : .mac
    }

    static func speak(_ voice: VoicePreferences) -> Speak {
        switch voice.replyVoice {
        case .system: .mac
        case .onDevice: .kokoro
        case .elevenLabs: .elevenLabs
        }
    }

    /// The speech model for `listen`. Parakeet keeps a Parakeet already chosen (Unified, say).
    static func speechModel(_ listen: Listen, current: SpeechModel) -> SpeechModel {
        switch listen {
        case .mac: .appleOnDevice
        case .parakeet: current.isParakeet ? current : .default
        }
    }

    /// Whether setting up `voice` would download a model: Parakeet or Kokoro not on this Mac yet.
    /// The Mac's own hearing never counts: choosing it sets it up, English speech files included.
    static func downloads(_ voice: VoicePreferences, _ onMac: OnMac) -> Bool {
        (listen(voice) == .parakeet && !onMac.parakeet) || (speak(voice) == .kokoro && !onMac.kokoro)
    }

    /// After a choice: voice is set up when the user clicked Download (or Get), or when nothing would
    /// download. Otherwise the setup stays as it was, so nothing downloads unasked.
    static func settle(_ voice: VoicePreferences, _ onMac: OnMac, downloadClicked: Bool = false) -> VoicePreferences {
        var voice = voice
        if downloadClicked || (voice.setup != .voice && !downloads(voice, onMac)) { voice.setup = .voice }
        return voice
    }

    /// The step's first look at a fresh setup: the Mac's own hearing and voice are preselected and set
    /// up at once (the shell prepares them, with progress in the step), so voice works after Continue
    /// and never shows "not set up" later. Not on a Mac whose recognition can't do US English: there
    /// Parakeet is the way to talk. A setup already chosen (typing, say) is left alone.
    static func initial(_ voice: VoicePreferences, _ onMac: OnMac) -> VoicePreferences {
        guard voice.setup == .notChosen, let hearing = onMac.macHearing else { return voice }
        if listen(voice) == .mac, hearing == .unsupported { return voice }
        return settle(voice, onMac)
    }
}

struct VoiceStepView: View {
    @Bindable var store: SettingsStore
    @Environment(\.elevenLabsAccount) private var account
    @Environment(\.voiceActions) private var actions
    let state: @MainActor () -> VoiceController.PrepareState
    let prepare: @Sendable () async -> Void

    var body: some View {
        VoiceHalves(store: store, state: state, prepare: prepare, account: account,
                    keyChanged: actions.elevenLabsKeyChanged)
    }
}

private struct VoiceHalves: View {
    @Bindable var store: SettingsStore
    let state: @MainActor () -> VoiceController.PrepareState
    let prepare: @Sendable () async -> Void
    let keyChanged: (@Sendable () async -> Void)?
    @State private var onMac = VoiceOnboarding.OnMac()
    @State private var elevenLabs: ElevenLabsSetup

    init(store: SettingsStore, state: @escaping @MainActor () -> VoiceController.PrepareState,
         prepare: @escaping @Sendable () async -> Void, account: any ElevenLabsAccounting,
         keyChanged: (@Sendable () async -> Void)?) {
        self.store = store
        self.state = state
        self.prepare = prepare
        self.keyChanged = keyChanged
        _elevenLabs = State(initialValue: ElevenLabsSetup(account: account, current: store.voice.replyVoice))
    }

    var body: some View {
        let listen = VoiceOnboarding.listen(store.voice)
        let speak = elevenLabs.wantsElevenLabs ? VoiceOnboarding.Speak.elevenLabs : VoiceOnboarding.speak(store.voice)
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Lumi uses your Mac's own hearing and voice. For better quality, download the recommended models. Nothing downloads until you click.")
                .fixedSize(horizontal: false, vertical: true)

            HalfHeader(title: "Listens", detail: "speech to text")
            OptionBox {
                VoiceOptionRow(title: "Mac speech recognition", detail: macHearingDetail,
                               selected: listen == .mac,
                               selectable: onMac.macHearing != nil && onMac.macHearing != .unsupported,
                               select: { pick(listen: .mac) }) {
                    switch onMac.macHearing {
                    case nil: ProgressView().controlSize(.small)
                    case .installed?: ReadyLabel()
                    case .needsLanguageFiles?: Text("Built in").font(.callout).foregroundStyle(.secondary)
                    case .unsupported?: Text("Not on this Mac").foregroundStyle(.secondary)
                    }
                }
                Divider()
                VoiceOptionRow(title: "Parakeet", detail: "More accurate. Runs on this Mac.", recommended: true,
                               selected: listen == .parakeet, selectable: onMac.parakeet,
                               select: { pick(listen: .parakeet) }) {
                    DownloadControl(downloaded: onMac.parakeet, bytes: VoiceDownloadSize.listening,
                                    chosen: listen == .parakeet && store.voice.setup == .voice) {
                        pick(listen: .parakeet, download: true)
                    }
                }
            }

            HalfHeader(title: "Speaks", detail: "text to speech")
            OptionBox {
                VoiceOptionRow(title: "Mac voice", detail: "Built into macOS.", selected: speak == .mac,
                               selectable: true, select: { pick(speak: .mac) }) { ReadyLabel() }
                Divider()
                VoiceOptionRow(title: "Kokoro", detail: "More natural. Runs on this Mac.", recommended: true,
                               selected: speak == .kokoro, selectable: onMac.kokoro,
                               select: { pick(speak: .kokoro) }) {
                    DownloadControl(downloaded: onMac.kokoro, bytes: VoiceDownloadSize.lumiVoice,
                                    chosen: speak == .kokoro && store.voice.setup == .voice) {
                        pick(speak: .kokoro, download: true)
                    }
                }
                Divider()
                VoiceOptionRow(title: "ElevenLabs", detail: "The most human-sounding. Needs your API key.",
                               selected: speak == .elevenLabs, selectable: true, select: { pick(speak: .elevenLabs) }) {
                    EmptyView()
                }
                if speak == .elevenLabs {
                    VStack(alignment: .leading, spacing: 8) {
                        ElevenLabsKeyFields(setup: elevenLabs, replyVoice: $store.voice.replyVoice,
                                            keyChanged: keyChanged)
                        Text("\(ElevenLabsAccount.privacyNote) Until a key works, replies use the Mac voice.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 28)
                }
            }

            if store.voice.setup == .voice {
                // The same row as Settings › Voice: real progress, Try Again.
                VoiceSetupRow(state: state(), prepare: prepare)
                if VoiceSetupRow.status(state()).isFailure {
                    Text("You can type for now: double-tap the Lumi key.").font(.callout)
                }
                Picker("Speak replies", selection: $store.voice.voiceReplies) {
                    Text("Always").tag(VoicePreferences.VoiceReplies.always)
                    Text("Only when I spoke").tag(VoicePreferences.VoiceReplies.onlyWhenISpoke)
                    Text("Off").tag(VoicePreferences.VoiceReplies.off)
                }
                .fixedSize()
            }
        }
        // Re-checked when a download finishes, so a downloaded model reads as such.
        .task(id: state() == .ready) {
            onMac = await Self.check(parakeet: VoiceOnboarding.speechModel(.parakeet, current: store.voice.speechModel))
            let first = VoiceOnboarding.initial(store.voice, onMac)
            if first.setup != store.voice.setup { store.voice = first }
        }
        .task { await elevenLabs.loadVoices() }
    }

    private var macHearingDetail: String {
        onMac.macHearing == .needsLanguageFiles
            ? "Built into macOS. English (US). macOS adds its speech files as it's set up."
            : "Built into macOS. English (US)."
    }

    private func pick(listen: VoiceOnboarding.Listen, download: Bool = false) {
        var voice = store.voice
        voice.speechModel = VoiceOnboarding.speechModel(listen, current: voice.speechModel)
        store.voice = VoiceOnboarding.settle(voice, onMac, downloadClicked: download)
    }

    private func pick(speak: VoiceOnboarding.Speak, download: Bool = false) {
        var voice = store.voice
        // ElevenLabs' own rules: a voice on this Mac applies at once, ElevenLabs once a key works.
        voice.replyVoice = switch speak {
        case .mac: elevenLabs.chooseEngine(false, current: voice.replyVoice, local: .system)
        case .kokoro: elevenLabs.chooseEngine(false, current: voice.replyVoice, local: .onDevice)
        case .elevenLabs: elevenLabs.chooseEngine(true, current: voice.replyVoice)
        }
        store.voice = VoiceOnboarding.settle(voice, onMac, downloadClicked: download)
    }

    /// Reads what's on this Mac without prompting or downloading.
    static func check(parakeet: SpeechModel) async -> VoiceOnboarding.OnMac {
        let hearing = await AppleSpeechTranscriber.availability()
        let disk = await Task.detached(priority: .utility) {
            (VoiceStorage.isDownloaded(parakeet), VoiceStorage.isDownloaded(.lumiVoice))
        }.value
        return VoiceOnboarding.OnMac(macHearing: hearing, parakeet: disk.0, kokoro: disk.1)
    }
}

private struct HalfHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct OptionBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One option in a half, read as a radio button. `selectable` is false for an option that needs a
/// download first: only its Download button chooses it.
private struct VoiceOptionRow<Trailing: View>: View {
    let title: String
    let detail: String
    var recommended = false
    let selected: Bool
    let selectable: Bool
    let select: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                            if recommended { RecommendedBadge() }
                        }
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selectable && !selected)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            trailing
        }
    }
}

private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.12), in: Capsule())
    }
}

private struct ReadyLabel: View {
    var body: some View {
        Text("Ready · no download").font(.callout).foregroundStyle(.secondary)
    }
}

/// "466 MB  Download" until it's on this Mac or chosen (then the progress row below takes over).
private struct DownloadControl: View {
    let downloaded: Bool
    let bytes: Int64
    let chosen: Bool
    let download: () -> Void

    var body: some View {
        if downloaded {
            Text("Downloaded").font(.callout).foregroundStyle(.secondary)
        } else if !chosen {
            HStack(spacing: 8) {
                Text(VoicePane.size(bytes)).font(.callout).foregroundStyle(.secondary)
                Button("Download", action: download)
            }
        }
    }
}

/// The header chip: while the voice models load, on every onboarding step.
struct VoicePrepareChip: View {
    let state: @MainActor () -> VoiceController.PrepareState

    var body: some View {
        let current = state()
        let status = VoiceSetupRow.status(current)
        if status.isWorking {
            HStack(spacing: 6) {
                if let fraction = status.fraction {
                    ProgressView(value: fraction).frame(width: 48)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(status.label)
            }
            .accessibilityElement(children: .combine)
        } else if current == .ready {
            Label("Voice ready", systemImage: "checkmark.circle.fill")
        } else if status.isFailure {
            Label("Voice needs attention", systemImage: "exclamationmark.triangle")
        }
    }
}
