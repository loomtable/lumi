import BuddyApp
import BuddyCompanion
import BuddyContext
import BuddyConversations
import BuddyCore
import BuddyTrace
import BuddyVoice
import SwiftUI

@main
struct LumiApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Conversations", id: WindowID.conversations) {
            ConversationsScene(model: delegate.model)
                .companionServices(delegate.model)
        }

        Settings {
            SettingsView(store: delegate.model.settings, selection: Bindable(delegate.model).settingsPane)
                .companionServices(delegate.model)
        }
        // The app menu's Settings… (⌘, while a Lumi window is key) goes through the same gate.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.model.openSettings() }
                    .keyboardShortcut(",")
            }
        }

        // First run: shown at launch until every step has been completed once.
        Window("Welcome to \(BuddyCore.appName)", id: WindowID.onboarding) {
            OnboardingScene(model: delegate.model)
                .companionServices(delegate.model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(delegate.model.needsOnboarding ? .presented : .suppressed)
    }
}

/// Opens windows the engine and the menu bar item ask for (⌘Y in a card, a menu row). It lives in
/// the status item's button because that exists for the app's whole life, and SwiftUI's
/// `openWindow` and `openSettings` need a SwiftUI view, which the runtime and AppKit aren't.
struct WindowRequests: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onChange(of: model.conversationsRequests) {
                NSApp.activate()
                openWindow(id: WindowID.conversations)
            }
            // A failure chip's Fix: `settingsPane` is already set, so Settings opens at that pane.
            .onChange(of: model.settingsRequests) {
                NSApp.activate()
                openSettings()
            }
            .onChange(of: model.onboardingRequests) {
                NSApp.activate()
                openWindow(id: WindowID.onboarding)
            }
    }
}

/// Onboarding over the shared store; Done closes the window.
struct OnboardingScene: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingView(model: model.onboarding, store: model.settings) {
            dismissWindow(id: WindowID.onboarding)
        }
    }
}

/// The Conversations window over the shared store and the engine's index. Resume makes that
/// conversation current from the next question.
struct ConversationsScene: View {
    let model: AppModel

    var body: some View {
        @Bindable var store = model.settings
        // Resume and temporary mode go through the engine's conversations, in call order.
        ConversationsWindow(source: model.runtime.conversations.map { LiveHistorySource(conversations: $0) },
                            identity: model.runtime.conversations, preferences: $store.conversations)
    }
}

extension View {
    /// The services Settings, onboarding and the Conversations window read from the environment
    /// (BuddyCompanion's CompanionEnvironment). Values the shell doesn't provide yet keep their
    /// defaults, which the panes show as "not available".
    func companionServices(_ model: AppModel) -> some View {
        CompanionServices(model: model, content: self)
    }
}

/// Reads the observable services in a view body, so the panes update when a check lands.
private struct CompanionServices<Content: View>: View {
    let model: AppModel
    let content: Content

    var body: some View {
        let claudeCode = model.runtime.claudeCode
        content
            .environment(\.keyPractice, model.keyPractice)
            .environment(\.openSettingsPane, SettingsPaneOpener { pane in model.openSettings(at: pane) })
            .environment(\.storageLocations, model.storageLocations)
            .environment(\.permissionCenter, model.runtime.permissions)
            .environment(\.mcpServers, model.runtime.mcpServerList)
            .environment(\.connectionActions, AppRuntime.connectionActions(model.runtime.connections))
            .environment(\.traceLogActions, TraceLogActions(delete: { [traceLog = model.runtime.traceLog] in await traceLog.deleteAll() }))
            .environment(\.claudeCodeStatus, claudeCode.status)
            .environment(\.claudeCodeActions, claudeCode.actions)
            .environment(\.conversationManager, model.runtime.conversationManager)
            .environment(\.voicePrepareState, model.voicePrepareState)
            .environment(\.voiceActions, model.voice.actions { [settings = model.settings] in settings.voice.replyVoice })
    }
}

enum WindowID {
    static let conversations = "conversations"
    static let onboarding = "onboarding"
}

/// Starts the engine once AppKit has finished launching, and stops it on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(model: model)
        model.runtime.watchPermissions()
        Task {
            await model.applySettingsToEngine()
            model.observeVoice()
            // Reopened from Settings to apply a grant: back to the pane it was on, through the same
            // request a failure chip's Fix uses (the menu bar label is up by now).
            if let pane = PermissionCenter.takeSettingsResume() { model.openSettings(at: pane) }
            await model.runtime.start()
        }
    }

    /// Stops the engine, then quits; never `.terminateLater` (see QuitSequence).
    private lazy var quit = QuitSequence(
        stop: { [model] in await model.runtime.stop() },
        // Chrome/Electron AX switches Lumi turned on go back off, even if the watchdog ends the quit.
        beforeStop: { AccessibilityEnabler.shared.restoreAll() })

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit.shouldTerminate()
    }

    /// Opened again from Spotlight, Finder or the Dock: the kept answer comes back, or Settings
    /// opens when there's none (onboarding, until setup is finished).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !model.runtime.recallLastAnswer(), !hasVisibleWindows { model.openSettings() }
        return false
    }
}

/// App-wide state owned by the shell.
@Observable
final class AppModel {
    /// The Settings window's pane; the menu bar sets it to open Settings where a problem is fixed.
    var settingsPane: SettingsPane = .keys
    var isPaused = false {
        didSet { Task { await runtime.setPaused(isPaused) } }
    }
    /// The one SettingsStore in the process: Settings, onboarding and the runtime share it.
    let settings: SettingsStore
    /// The one voice stack, built with the stored Voice settings so launch loads the right model.
    let voice: LiveVoice
    let runtime: AppRuntime
    /// Settings › Voice's view of model download and warm-up, from real prepare events.
    private(set) var voicePrepareState: VoiceController.PrepareState = .notStarted
    @ObservationIgnored private var settingsObserver: Task<Void, Never>?
    @ObservationIgnored private var voiceObservers: [Task<Void, Never>] = []

    init() {
        let settings = SettingsStore()
        self.settings = settings
        voice = LiveVoice.live(settings: Self.voiceSettings(settings))
        runtime = AppRuntime(voice: voice)
        // "Try it": done once a real answer has been shown, even before onboarding opens.
        runtime.onOpenConversations = { [weak self] in self?.openConversations() }
        runtime.onOpenSettingsPane = { [weak self] pane in
            self?.openSettings(at: pane)
        }
        runtime.onOpenSettings = { [weak self] in
            self?.openSettings() // the pane it last showed
        }
        runtime.onUseModel = { [weak self] model, mode in await self?.useModel(model, for: mode) }
        runtime.onAnswerShown = { [weak self] in
            guard let self else { return }
            answeredOnce = true
            onboardingIfCreated?.firstQuestionCompleted()
        }
    }

    @ObservationIgnored private var answeredOnce = false
    /// Bumped each time the engine asks for the Conversations window (WindowRequests opens it).
    private(set) var conversationsRequests = 0
    /// Bumped each time the engine asks for a Settings pane (WindowRequests opens it at `settingsPane`).
    private(set) var settingsRequests = 0
    /// Bumped by the menu's "Set Up …" (WindowRequests opens onboarding).
    private(set) var onboardingRequests = 0

    /// Every request for Settings comes here; until setup is finished it opens onboarding instead.
    func openSettings(at pane: SettingsPane?) {
        switch SettingsRoute.route(pane, needsSetUp: needsSetUp) {
        case .onboarding:
            openOnboarding()
        case .settings(let pane):
            if let pane { settingsPane = pane }
            settingsRequests += 1
        }
    }

    /// Settings at the pane it last showed.
    func openSettings() { openSettings(at: nil) }
    /// Read now, not at launch, so Settings opens as soon as onboarding's Done is pressed.
    var needsSetUp: Bool { OnboardingModel.needsOnboarding(external: onboardingSteps) }
    func openConversations() { conversationsRequests += 1 }
    func openOnboarding() { onboardingRequests += 1 }
    /// The onboarding model if its window has been built (it's created lazily).
    @ObservationIgnored private var onboardingIfCreated: OnboardingModel?

    static func voiceSettings(_ store: SettingsStore) -> VoiceSettings {
        // Nothing downloads until a voice setup is chosen (onboarding's step, Settings › Voice).
        VoiceSettings(voiceProcessing: store.voice.voiceIsolation, soundsEnabled: store.appearance.sounds,
                      speechModel: store.voice.speechModel, replyVoice: store.voice.replyVoice,
                      setupChosen: store.voice.setup == .voice)
    }

    /// Settings › Voice and onboarding's voice choice → the voice stack (isolation from the next
    /// listen; a new speech model rebuilds and prepares; a chosen setup or reply voice prepares
    /// what it needs), and prepare progress → the pane.
    func observeVoice() {
        guard voiceObservers.isEmpty else { return }
        let (settings, voice, runtime) = (settings, voice, runtime)
        voiceObservers.append(Task { [weak self] in
            for await state in voice.prepareStates { self?.voicePrepareState = state }
        })
        // ElevenLabs fell back to the on-device voice: one menu line, gone once it speaks again.
        voiceObservers.append(Task {
            for await line in voice.replyVoiceProblems { runtime.setReplyVoiceProblem(line) }
        })
        voiceObservers.append(Task {
            var applied = Self.voiceSettings(settings)
            for await wanted in Observations({ Self.voiceSettings(settings) }) {
                await voice.apply(wanted, over: applied)
                applied = wanted
            }
        })
    }
    @ObservationIgnored private(set) lazy var keyPractice = KeyPracticeCoordinator { [runtime] active in
        runtime.setKeyPractice(active)
    }

    /// Onboarding steps other areas provide: Voice with the model-download chip,
    /// then the optional Connections step. Only for a first run: someone who already finished
    /// onboarding has Settings › Voice and › Connections, and isn't walked back through steps they
    /// completed for a step added later.
    @ObservationIgnored private(set) lazy var onboardingSteps: [ExternalOnboardingStep] =
        OnboardingModel.needsOnboarding(external: []) ? [
            VoiceOnboarding.step(
                store: settings, state: { [weak self] in self?.voicePrepareState ?? .notStarted },
                prepare: { [voice] in try? await voice.prepare() }),
            // Optional: never holds Continue.
            ConnectionsOnboarding.step(),
        ] : []
    /// Whether onboarding opens at launch: some step (including a newly added one) was never completed.
    @ObservationIgnored private(set) lazy var needsOnboarding = OnboardingModel.needsOnboarding(external: onboardingSteps)
    @ObservationIgnored private(set) lazy var onboarding: OnboardingModel = {
        let onboarding = OnboardingModel(permissions: runtime.permissions,
                                         claudeCheck: OnboardingClaudeCheck(service: runtime.claudeCode),
                                         external: onboardingSteps, lowMemory: AppRuntime.isLowMemory())
        if answeredOnce { onboarding.firstQuestionCompleted() }
        onboardingIfCreated = onboarding
        return onboarding
    }()

    /// "Use <model>" on a failure chip: Settings › Models changes for good (the toast says so), and
    /// this returns once the engine runs on it, so the question can be asked again. Applying here
    /// rather than waiting for the observer makes the reload finish first; the observer's own apply
    /// then finds nothing changed.
    func useModel(_ model: ModelID, for mode: Mode) async {
        var config = settings.models.config(mode)
        config.model = model
        settings.models.set(config, for: mode)
        await runtime.apply(Self.engine(settings))
    }

    /// Pushes every engine-facing setting to the engine now, then on every change.
    func applySettingsToEngine() async {
        await runtime.apply(Self.engine(settings))
        guard settingsObserver == nil else { return }
        let (settings, runtime) = (settings, runtime)
        settingsObserver = Task {
            for await prefs in Observations({ Self.engine(settings) }) {
                await runtime.apply(prefs)
            }
        }
    }

    static func engine(_ store: SettingsStore) -> EnginePreferences {
        EnginePreferences(store: store)
    }

    /// Folders Lumi writes to (Settings › Privacy, "Stored on this Mac"). The trace folder
    /// is listed once it exists (turning the trace log on creates it), so "Show in Finder" never
    /// points at nothing.
    var storageLocations: [StorageLocation] {
        var locations = VoiceStorage.locations().map { StorageLocation(title: $0.title, url: $0.url) }
            + [StorageLocation(title: "Screenshots", url: ScreenshotStore.defaultDirectory)]
        if FileManager.default.fileExists(atPath: TraceLog.defaultDirectory.path) {
            locations.append(StorageLocation(title: "Trace log", url: TraceLog.defaultDirectory))
        }
        return locations
    }
}

