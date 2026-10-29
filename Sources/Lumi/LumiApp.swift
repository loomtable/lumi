import BuddyApp
import BuddyCompanion
import BuddyContext
import BuddyConversations
import BuddyCore
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import SwiftUI

@main
struct LumiApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    /// The app's two windows (`LumiWindow`). Every scene says how it launches: SwiftUI presents
    /// a scene left on `.automatic`, the first one declared, at launch, which is how the v1
    /// Conversations window (declared first, never suppressed) opened in v2 (owner, QA 0.2.0).
    var body: some Scene {
        // The Lumi window, with Settings in its sidebar: only ever opened when asked.
        Window(BuddyCore.appName, id: LumiWindow.studio.id) {
            StudioScene(model: delegate.model)
                .companionServices(delegate.model)
                .lumiTheme()
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1120, height: 760)
        .commandsRemoved()

        // First run: shown at launch until every step has been completed once.
        Window("Welcome to \(BuddyCore.appName)", id: LumiWindow.onboarding.id) {
            OnboardingScene(model: delegate.model)
                .companionServices(delegate.model)
                .lumiTheme()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(LumiWindow.atLaunch(needsOnboarding: delegate.model.needsOnboarding).contains(.onboarding)
                               ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        // The app menu's Settings… (⌘, while a Lumi window is key): Studio's Settings, through the
        // same setup gate as every other request.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.model.openSettings() }
                    .keyboardShortcut(",")
            }
            SessionCommands(app: delegate.model, studio: delegate.model.studio)
            // Help: the site and feedback (QA S-17); macOS's own Help book doesn't exist.
            CommandGroup(replacing: .help) {
                Button("\(BuddyCore.appName) Website") { NSWorkspace.shared.open(StatusMenuItem.siteURL) }
                Button("Send Feedback…") { delegate.model.sendFeedback() }
            }
        }
    }
}

/// The menu bar's Session menu (QA S-17): what the Lumi window does to a session, so its keys are
/// findable. Rename, Archive and Stop act on the session open in the Lumi window.
struct SessionCommands: Commands {
    let app: AppModel
    let studio: StudioModel

    var body: some Commands {
        CommandMenu("Session") {
            Button("New Session") { app.openNewSession() }
                .keyboardShortcut("n")
            Divider()
            Button("Rename…") { studio.requestRename() }
                .disabled(studio.selectedSession == nil)
            Button(studio.selectedSession?.archived == true ? "Unarchive" : "Archive") {
                guard let session = studio.selectedSession else { return }
                Task { await studio.setArchived(!session.archived, for: session.id) }
            }
            .disabled(studio.selectedSession == nil)
            Button("Stop") { studio.stopSelected() }
                .keyboardShortcut(".")
                .disabled(!studio.canStop)
        }
    }
}

/// Opens the windows the engine and the menu bar item ask for (⌘Y in a card, a menu row, a Fix
/// chip). It lives in the status item's button because that exists for the app's whole life, and
/// SwiftUI's `openWindow` needs a SwiftUI view, which the runtime and AppKit aren't.
struct WindowRequests: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onChange(of: model.onboardingRequests) {
                NSApp.activate()
                openWindow(id: LumiWindow.onboarding.id)
            }
            .onChange(of: model.studioRequests) {
                NSApp.activate()
                openWindow(id: LumiWindow.studio.id)
            }
    }
}

/// Studio over the shared store.
struct StudioScene: View {
    let model: AppModel

    var body: some View {
        StudioView(model: model.studio, store: model.settings)
    }
}

/// Onboarding over the shared store; Done closes the window.
struct OnboardingScene: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingView(model: model.onboarding, store: model.settings) {
            dismissWindow(id: LumiWindow.onboarding.id)
            LumiWindow.afterOnboarding.forEach(model.show)
        }
    }
}

extension View {
    /// The services Studio (its Settings pages) and onboarding read from the environment
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
            .environment(\.forgetAllSessions, ForgetAllAction(
                available: { [studio = model.studio] in studio.hasSessions || studio.showsDictation },
                run: { [studio = model.studio] in
                    studio.dictationHistory?.clearAll()
                    return await studio.forgetAll()
                }))
            .environment(\.voicePrepareState, model.voicePrepareState)
            .environment(\.voiceActions, model.voice.actions { [settings = model.settings] in settings.voice.replyVoice })
    }
}

/// Starts the engine once AppKit has finished launching, and stops it on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(model: model)
        model.observeTheme()
        model.observeDock()
        model.runtime.watchPermissions()
        Task {
            await model.applySettingsToEngine()
            model.observeVoice()
            // Reopened from Settings to apply a grant: back to the pane it was on, through the same
            // request a failure chip's Fix uses (the menu bar label is up by now).
            if let page = PermissionCenter.takeSettingsPageResume() { model.openStudio(at: .settings(page)) }
            await model.runtime.start()
        }
    }

    /// Stops the engine, then quits; never `.terminateLater` (see QuitSequence).
    private lazy var quit = QuitSequence(
        stop: { [model] in await model.runtime.stop() },
        // Chrome/Electron AX switches Lumi turned on go back off, even if the watchdog ends the quit.
        beforeStop: { AccessibilityEnabler.shared.restoreAll() },
        // Sessions still working: ask before their turns are interrupted (QA S-08).
        working: { [model] in model.studio.workingCount })

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit.shouldTerminate()
    }

    /// A click on the Dock icon, or opened again from Spotlight or Finder: the Lumi window
    /// (onboarding until setup is finished). The menu bar's Show Last Answer brings back a kept answer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.reopen()
        return false
    }

    /// The Dock icon's menu: Open Lumi, New Session, Settings (setup until it's finished).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for row in StatusMenuItem.dockMenu(needsSetUp: model.needsSetUp) {
            guard let title = row.title, let action = row.action else { continue }
            let item = NSMenuItem(title: title, action: #selector(dockMenuChose), keyEquivalent: "")
            item.target = self
            item.representedObject = DockAction(action)
            menu.addItem(item)
        }
        return menu
    }

    private final class DockAction: NSObject {
        let action: StatusMenuItem.Action
        init(_ action: StatusMenuItem.Action) { self.action = action }
    }

    @objc private func dockMenuChose(_ sender: NSMenuItem) {
        switch (sender.representedObject as? DockAction)?.action {
        case .openStudio: model.openStudio(at: .home)
        case .newSession: model.openNewSession()
        case .openSettings: model.openSettings()
        case .setUp: model.openOnboarding()
        default: break
        }
    }
}

/// App-wide state owned by the shell.
@Observable
final class AppModel {
    /// The Lumi window's state.
    @ObservationIgnored let studio: StudioModel
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
        runtime = AppRuntime(voice: voice, dictationHistory: DictationHistory(retentionDays: settings.conversations.retentionDays))
        studio = StudioModel(source: runtime.studioSource, dictationHistory: runtime.dictationHistory)
        runtime.studioSource.pageHost = studio
        // The Panel's ⌘⇧E: the session in the Lumi window.
        runtime.onOpenStudioSession = { [weak self] id in self?.openStudio(at: .session(id)) }
        // ⌘Y in a card (and ⇱ with the Panel off): history is the Lumi window's sidebar.
        runtime.onOpenLumiWindow = { [weak self] in self?.openStudio() }
        runtime.onOpenDictationHistory = { [weak self] in self?.openStudio(at: .dictation) }
        runtime.onOpenSettingsPane = { [weak self] pane in
            self?.openSettings(at: pane)
        }
        runtime.onOpenSettings = { [weak self] in
            self?.openSettings() // the pane it last showed
        }
        runtime.onUseModel = { [weak self] model, mode in await self?.useModel(model, for: mode) }
        // "Try it": done once a real answer has been shown, even before onboarding opens.
        runtime.onAnswerShown = { [weak self] in
            guard let self else { return }
            answeredOnce = true
            onboardingIfCreated?.firstQuestionCompleted()
        }
    }

    @ObservationIgnored private var answeredOnce = false
    /// Bumped by the menu's "Set Up …" (WindowRequests opens onboarding).
    private(set) var onboardingRequests = 0
    /// Bumped each time something asks for the Lumi window (WindowRequests opens it).
    private(set) var studioRequests = 0

    /// Every request for Settings comes here; until setup is finished it opens onboarding instead.
    /// Settings is a page of the Lumi window: an old pane opens the page that holds it.
    func openSettings(at pane: SettingsPane?) {
        switch SettingsRoute.route(pane, needsSetUp: needsSetUp) {
        case .onboarding:
            openOnboarding()
        case .settings(let pane):
            studio.showSettings(pane.map(SettingsPage.init))
            show(.studio)
        }
    }

    /// The Lumi window (Studio) at `selection`; onboarding instead until setup is finished, as for
    /// Settings, which it contains.
    func openStudio(at selection: StudioModel.Selection? = nil) {
        if needsSetUp { return openOnboarding() }
        if let selection { studio.selection = selection }
        show(.studio)
    }

    /// Settings at the pane it last showed.
    func openSettings() { openSettings(at: nil) }
    /// New Session (the Dock menu): Home, ready to type.
    func openNewSession() {
        if needsSetUp { return openOnboarding() }
        studio.newSession()
        show(.studio)
    }
    /// Send Feedback… (the menu bar item, Help): a new email in the user's mail app; with no mail
    /// app set up, the address goes to the clipboard instead and a note says so.
    func sendFeedback() {
        guard !NSWorkspace.shared.open(StatusMenuItem.feedbackURL()) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(StatusMenuItem.feedbackAddress, forType: .string)
        runtime.showNote("Copied \(StatusMenuItem.feedbackAddress)")
    }

    /// A Dock click or reopen (`LumiWindow.onReopen`).
    func reopen() { show(LumiWindow.onReopen(needsSetUp: needsSetUp)) }

    /// "Show in Dock", now and on every change (no relaunch).
    @ObservationIgnored private let dock = DockPresence.live()
    @ObservationIgnored private var dockObserver: Task<Void, Never>?
    @ObservationIgnored private var themeObserver: Task<Void, Never>?
    /// Settings › Appearance › Theme, applied now and on every change (no relaunch).
    func observeTheme() {
        ThemeSelection.shared.theme = settings.appearance.theme
        guard themeObserver == nil else { return }
        let settings = settings
        themeObserver = Task { @MainActor in
            for await theme in Observations({ settings.appearance.theme }) { ThemeSelection.shared.theme = theme }
        }
    }

    func observeDock() {
        dock.show(inDock: settings.dock.showInDock)
        guard dockObserver == nil else { return }
        let (settings, dock) = (settings, dock)
        dockObserver = Task { @MainActor in
            for await showInDock in Observations({ settings.dock.showInDock }) { dock.show(inDock: showInDock) }
        }
    }
    /// Read now, not at launch, so Settings opens as soon as onboarding's Done is pressed.
    var needsSetUp: Bool { OnboardingModel.needsOnboarding(external: onboardingSteps) }
    func openOnboarding() { show(.onboarding) }
    /// Asks WindowRequests to bring `window` forward.
    func show(_ window: LumiWindow) {
        switch window {
        case .studio: studioRequests += 1
        case .onboarding: onboardingRequests += 1
        }
    }
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

    /// Only the dictation key reads the Mac's key environment, so it's skipped while dictation is
    /// off and cached while it's on (QA R15: this runs on every settings change).
    static func engine(_ store: SettingsStore) -> EnginePreferences {
        let features = LumiFeatures.current()
        let environment = features.dictation ? KeyEnvironmentCache.shared.current() : KeyEnvironment()
        return EnginePreferences(store: store, keyEnvironment: environment, features: features)
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

