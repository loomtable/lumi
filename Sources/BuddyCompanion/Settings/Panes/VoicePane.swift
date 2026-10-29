import BuddyCore
import BuddyOverlay
import BuddyVoice
import SwiftUI

/// Settings › Voice: voice replies, the voice, speech-to-text, Voice Isolation, and
/// model download and pre-warm progress. Where the models are stored is
/// in Settings › Privacy.
struct VoicePane: View {
    @Binding var settings: VoicePreferences
    /// Studio only: Lumi's voice layer and speech for typed answers.
    var sessions: Binding<SessionsPreferences>?
    @Environment(\.voicePrepareState) private var prepareState
    @Environment(\.voiceActions) private var actions
    @Environment(\.elevenLabsAccount) private var elevenLabs

    var body: some View {
        PaneForm {
            // Not set up yet: that comes first, before the settings it unlocks (QA S-20).
            if settings.setup != .voice {
                Section {
                    // Nothing downloads until this is clicked.
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice isn't set up. You type your questions.")
                            Text(Self.setUpSize(settings.replyVoice, speechModel: settings.speechModel)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Set Up Voice") { settings.setup = .voice }
                    }
                }
            }

            // Every spoken-answer choice in one place (QA S-19): Off silences them all.
            Section {
                Picker("Voice replies", selection: $settings.voiceReplies) {
                    Text("Always").tag(VoicePreferences.VoiceReplies.always)
                    Text("Only when I spoke").tag(VoicePreferences.VoiceReplies.onlyWhenISpoke)
                    Text("Off").tag(VoicePreferences.VoiceReplies.off)
                }
                if let sessions {
                    Toggle("Also speak answers to typed questions", isOn: sessions.speakTypedAnswers)
                        .disabled(settings.voiceReplies == .off)
                }
            } header: {
                Text("Spoken answers")
            } footer: {
                Text("It speaks only the headline. The details stay on screen.")
            }

            ElevenLabsSection(replyVoice: replyVoiceChoice, account: elevenLabs,
                              keyChanged: actions.elevenLabsKeyChanged)
            if pendingReplyVoice != nil {
                Section {
                    PendingDownloadRow(title: "Kokoro isn't on this Mac yet.", keeps: "the Mac voice",
                                       bytes: VoiceDownloadSize.lumiVoice) {
                        settings.replyVoice = .onDevice
                        pendingReplyVoice = nil
                    }
                }
            }

            Section {
                Picker("Speech to text", selection: speechModelChoice) {
                    ForEach(SpeechModel.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
                Text(Self.speechModelHelp(pendingSpeechModel ?? settings.speechModel))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let pending = pendingSpeechModel {
                    PendingDownloadRow(title: "\(Self.title(pending)) isn't on this Mac yet.",
                                       keeps: Self.title(settings.speechModel), bytes: Self.downloadSize(pending)) {
                        settings.speechModel = pending
                        pendingSpeechModel = nil
                    }
                }
            } footer: {
                Text("Runs on this Mac. What you say is never shown while you speak, and your audio is never saved.")
            }

            Section {
                Toggle(isOn: $settings.voiceIsolation) {
                    Text("Voice Isolation when other audio is playing")
                    Text("While another app is playing sound, this keeps it out of what you say. Otherwise the microphone starts plain, so your first word isn't cut off. Applies from the next question.")
                }
            }

            if let sessions {
                VoiceLayerSection(settings: sessions)
            }

            if settings.setup == .voice || !downloaded.isEmpty {
                Section("Speech models") {
                    if settings.setup == .voice { VoiceSetupRow(state: prepareState, prepare: actions.prepare) }
                    DownloadedModelRows(settings: settings, bytes: downloaded, busy: VoiceSetupRow.status(prepareState).isWorking,
                                        remove: actions.removeModels, removed: measure)
                }
            }
        }
        // Re-read when a download finishes or the speech model changes.
        .task(id: "\(settings.speechModel)\(prepareState == .ready)") { await measure() }
    }

    @State private var downloaded: [VoiceModelPart: Int64] = [:]
    /// What's on this Mac, so a choice knows whether it would download.
    @State private var onMac = OnMac()
    /// A choice that needs a download, waiting for its Download button (nothing downloads unasked).
    @State private var pendingSpeechModel: SpeechModel?
    @State private var pendingReplyVoice: ReplyVoice?

    struct OnMac: Equatable {
        var speechModels: Set<SpeechModel> = [.appleOnDevice]
        var kokoro = false
    }

    private var speechModelChoice: Binding<SpeechModel> {
        Binding(get: { pendingSpeechModel ?? settings.speechModel },
                set: { (settings, pendingSpeechModel) = Self.choose(speechModel: $0, in: settings, onMac: onMac) })
    }

    private var replyVoiceChoice: Binding<ReplyVoice> {
        // The radio stays on the voice in use; a pending Kokoro shows as its Download row.
        Binding(get: { settings.replyVoice },
                set: { (settings, pendingReplyVoice) = Self.choose(replyVoice: $0, in: settings, onMac: onMac) })
    }

    /// Switching to a model that isn't on this Mac while voice is set up would download it at once, so
    /// the setting stays and the choice waits (`pending`) for its Download button. Without voice set up
    /// nothing loads, so it switches; Set Up Voice downloads it later, on its own click.
    static func choose(speechModel model: SpeechModel, in voice: VoicePreferences,
                       onMac: OnMac) -> (VoicePreferences, pending: SpeechModel?) {
        var voice = voice
        guard model != voice.speechModel else { return (voice, nil) }
        if voice.setup == .voice, !onMac.speechModels.contains(model) { return (voice, model) }
        voice.speechModel = model
        return (voice, nil)
    }

    /// As `choose(speechModel:)`, for Kokoro. The Mac voice and ElevenLabs download nothing.
    static func choose(replyVoice: ReplyVoice, in voice: VoicePreferences,
                       onMac: OnMac) -> (VoicePreferences, pending: ReplyVoice?) {
        var voice = voice
        if replyVoice == .onDevice, voice.replyVoice != .onDevice, voice.setup == .voice, !onMac.kokoro {
            return (voice, .onDevice)
        }
        voice.replyVoice = replyVoice
        return (voice, nil)
    }

    private func measure() async {
        let settings = VoiceSettings(speechModel: settings.speechModel)
        (downloaded, onMac) = await Task.detached(priority: .utility) {
            let bytes = Dictionary(uniqueKeysWithValues: VoiceModelPart.allCases.map {
                ($0, VoiceStorage.bytesOnDisk($0, settings: settings))
            })
            let models = Set(SpeechModel.allCases.filter { VoiceStorage.isDownloaded($0, settings: settings) })
            return (bytes, OnMac(speechModels: models, kokoro: VoiceStorage.isDownloaded(.lumiVoice, settings: settings)))
        }.value
    }

    /// What choosing `model` downloads. Unified isn't sized up front: nil shows no size.
    static func downloadSize(_ model: SpeechModel) -> Int64? {
        model == .parakeetTDTv2 ? VoiceDownloadSize.listening : nil
    }

    /// What Set Up Voice downloads: Parakeet when it's the speech model, Kokoro when it's the reply voice.
    static func setUpSize(_ replyVoice: ReplyVoice, speechModel: SpeechModel = .default) -> String {
        switch (speechModel.isParakeet, replyVoice == .onDevice) {
        case (true, true): "Downloads about \(size(VoiceDownloadSize.listening + VoiceDownloadSize.lumiVoice)): listening and the Kokoro voice."
        case (true, false): "Downloads about \(size(VoiceDownloadSize.listening)) for listening."
        case (false, true): "Downloads about \(size(VoiceDownloadSize.lumiVoice)) for the Kokoro voice. Listening uses the Mac's own speech recognition."
        case (false, false): "Uses the Mac's own speech recognition. macOS adds its English speech files if they aren't on this Mac yet."
        }
    }

    /// As Finder shows it.
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func title(_ model: SpeechModel) -> String {
        switch model {
        case .appleOnDevice: "Mac speech recognition"
        case .parakeetTDTv2: "Parakeet TDT v2"
        case .parakeetUnified: "Parakeet Unified (experimental)"
        }
    }

    static func speechModelHelp(_ model: SpeechModel) -> String {
        switch model {
        case .appleOnDevice:
            "Built into macOS: nothing for Lumi to download. macOS adds its English speech files if they aren't on this Mac yet."
        case .parakeetTDTv2:
            "More accurate. About \(size(VoiceDownloadSize.listening)), downloaded when you choose it. Transcribes the moment you send."
        case .parakeetUnified:
            "About as accurate, but it has dropped the last word in testing, so it's experimental. Downloaded when you choose it."
        }
    }
}

/// "Parakeet TDT v2 isn't on this Mac yet. · 466 MB · Download": a choice waiting for its download.
struct PendingDownloadRow: View {
    let title: String
    /// What stays in use until the download is clicked.
    let keeps: String
    let bytes: Int64?
    let download: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("Lumi keeps using \(keeps) until you download it.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let bytes { Text(VoicePane.size(bytes)).font(.callout).foregroundStyle(.secondary) }
            Button("Download", action: download)
        }
    }
}

/// Model download and pre-warm progress (step 8), from BuddyVoice's `prepareState`.
struct VoiceSetupRow: View {
    let state: VoiceController.PrepareState
    let prepare: (@Sendable () async -> Void)?

    var body: some View {
        let status = Self.status(state)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.label)
                Spacer()
                if let prepare, status.canStart {
                    Button(status.isFailure ? "Try Again" : "Set Up") { Task { await prepare() } }
                }
            }
            if let detail = status.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if status.isWorking {
                if let fraction = status.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
    }

    struct Status: Equatable {
        var label: String
        var detail: String?
        /// Download share, 0…1; nil while working shows an indeterminate bar.
        var fraction: Double?
        var isWorking = false
        var canStart = false
        var isFailure = false
    }

    /// Only what BuddyVoice reported, never an estimate. FluidAudio's `fraction` covers
    /// the whole load (download then compile, half each for repo models), so one bar follows it
    /// through both phases instead of stopping at the download's share.
    static func status(_ state: VoiceController.PrepareState) -> Status {
        switch state {
        case .notStarted:
            return Status(label: "Not set up yet", canStart: true)
        case .ready:
            return Status(label: "Ready")
        case .failed(let reason):
            return Status(label: "Couldn't set up voice", detail: reason, canStart: true, isFailure: true)
        case .preparing(.speechModel(let progress)):
            return loading(progress, model: "the speech model", waiting: "Getting the speech model…")
        case .preparing(.voiceActivity):
            return Status(label: "Loading voice detection…", isWorking: true)
        case .preparing(.voice(let progress)):
            return loading(progress, model: "the voice", waiting: "Warming up the voice…")
        case .preparing(.microphone):
            return Status(label: "Preparing the microphone…", isWorking: true)
        }
    }

    private static func loading(_ progress: ModelLoadProgress?, model: String, waiting: String) -> Status {
        guard let progress else { return Status(label: waiting, isWorking: true) }
        switch progress.phase {
        case .listing:
            return Status(label: waiting, isWorking: true)
        case .downloading(let done, let total):
            // The voice's download has no file list up front (total 0): the bar alone.
            return Status(label: "Downloading \(model)", detail: total > 0 ? "\(done) of \(total) files" : nil,
                          fraction: clamped(progress.fraction), isWorking: true)
        case .compiling:
            return Status(label: "Preparing \(model) for this Mac…", fraction: clamped(progress.fraction), isWorking: true)
        }
    }

    private static func clamped(_ fraction: Double) -> Double { min(max(fraction, 0), 1) }
}

/// "Downloaded on this Mac · 466 MB · Remove…" for each voice part that's on disk. Only a part not in
/// use can be removed (the one in use says so): nothing loaded is deleted, no setting changes, and
/// voice keeps working on what's chosen.
struct DownloadedModelRows: View {
    let settings: VoicePreferences
    let bytes: [VoiceModelPart: Int64]
    /// Voice is loading: Remove waits.
    let busy: Bool
    let remove: (@Sendable (VoiceModelPart) async throws -> Void)?
    /// Re-reads the sizes after a removal.
    let removed: () async -> Void
    @State private var confirming: VoiceModelPart?
    @State private var problem: String?

    var body: some View {
        ForEach(VoiceModelPart.allCases.filter { (bytes[$0] ?? 0) > 0 }, id: \.self) { part in
            let size = VoicePane.size(bytes[part] ?? 0)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(part))
                    Text("Downloaded on this Mac · \(size)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if Self.inUse(part, settings) {
                    Text("In use").font(.callout).foregroundStyle(.secondary)
                } else if remove != nil {
                    Button("Remove…") { confirming = part }
                        .disabled(busy)
                        .confirmationDialog(Self.question(part), isPresented: shown(part), titleVisibility: .visible) {
                            // Acts on this row's part, whatever the dialog's dismissal does to `confirming`.
                            Button("Remove", role: .destructive) { Task { await perform(part) } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(Self.consequence(part, size: size))
                        }
                }
            }
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.lumiAmber)
        }
    }

    private func shown(_ part: VoiceModelPart) -> Binding<Bool> {
        Binding(get: { confirming == part }, set: { if !$0 { confirming = nil } })
    }

    private func perform(_ part: VoiceModelPart) async {
        guard let remove else { return }
        problem = nil
        do {
            try await remove(part)
        } catch VoiceController.VoiceError.busy {
            problem = "Lumi is busy with voice (setting up, listening or speaking). Try again in a moment."
        } catch VoiceController.VoiceError.sharedModels {
            problem = "This copy of Lumi shares the main app's voice files, so it doesn't remove them."
        } catch {
            problem = "Couldn't remove the files."
        }
        await removed()
    }

    static func title(_ part: VoiceModelPart) -> String {
        switch part {
        case .speechRecognition: "Parakeet listening model"
        case .lumiVoice: "Kokoro voice"
        }
    }

    static func question(_ part: VoiceModelPart) -> String {
        switch part {
        case .speechRecognition: "Remove the Parakeet listening model?"
        case .lumiVoice: "Remove the Kokoro voice?" // a name: keeps its capital
        }
    }

    static func consequence(_ part: VoiceModelPart, size: String) -> String {
        switch part {
        case .speechRecognition:
            "Frees \(size). Choosing Parakeet again downloads it."
        case .lumiVoice:
            "Frees \(size). Choosing Kokoro again downloads it."
        }
    }

    /// Whether the settings use `part`, so it can't be removed: switch away from it first.
    static func inUse(_ part: VoiceModelPart, _ voice: VoicePreferences) -> Bool {
        switch part {
        case .speechRecognition: voice.speechModel.isParakeet
        case .lumiVoice: voice.replyVoice == .onDevice
        }
    }
}

/// What Settings › Voice needs from the shell, which owns the one `VoiceController`.
public nonisolated struct VoiceActions: Sendable {
    /// Calls `VoiceController.prepare()` (it retries after a failure). Nil hides the button.
    public var prepare: (@Sendable () async -> Void)?
    /// After an ElevenLabs key is saved, replaced or removed: the shell calls
    /// `setReplyVoice(store.voice.replyVoice)` again, which clears a remembered key problem.
    public var elevenLabsKeyChanged: (@Sendable () async -> Void)?
    /// `VoiceController.removeModels` (throws `.busy` while voice is loading, listening or
    /// speaking). Nil hides Remove.
    public var removeModels: (@Sendable (VoiceModelPart) async throws -> Void)?

    public init(prepare: (@Sendable () async -> Void)? = nil, elevenLabsKeyChanged: (@Sendable () async -> Void)? = nil,
                removeModels: (@Sendable (VoiceModelPart) async throws -> Void)? = nil) {
        self.prepare = prepare
        self.elevenLabsKeyChanged = elevenLabsKeyChanged
        self.removeModels = removeModels
    }
}

extension EnvironmentValues {
    /// The shell mirrors `VoiceController.prepareState` (or its `.prepare(_)` events) here.
    @Entry public var voicePrepareState: VoiceController.PrepareState = .notStarted
    @Entry public var voiceActions = VoiceActions()
    /// ElevenLabs' key and voices; the Keychain-backed one unless tests inject a fake.
    @Entry public var elevenLabsAccount: any ElevenLabsAccounting = SharedElevenLabs.account
}

/// One Keychain-backed account for the environment default (an `@Entry` default needs a shared instance).
enum SharedElevenLabs {
    static let account = ElevenLabsAccount()
}

/// Settings › Voice (v2): where Lumi's voice layer applies. Speaking typed answers lives with the
/// other spoken-answer choices (QA S-19).
struct VoiceLayerSection: View {
    @Binding var settings: SessionsPreferences

    var body: some View {
        Section {
            Picker("Use Lumi's voice layer for", selection: $settings.voiceLayer) {
                Text("Voice turns").tag(VoiceLayerScope.voiceTurns)
                Text("Every turn").tag(VoiceLayerScope.everyTurn)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Lumi's voice layer")
        } footer: {
            Text("Typed chats get your full Claude Code: your skills, commands, connections and project rules. Lumi only shapes spoken answers.")
        }
    }
}
