import AppKit
import BuddyAct
import BuddyBridge
import BuddyCompanion
import BuddyContext
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import Foundation
import Observation
import Synchronization

/// Builds the live engine at launch and keeps it running: plugin install, Claude Code lanes,
/// context, the buddy key, the overlay and the coordinator.
///
/// `problems` lists what stops the buddy from working, each a true line with nothing estimated.
/// The menu shows them.
@MainActor
@Observable
public final class AppRuntime {
    public private(set) var problems: [AppProblem] = []
    /// The menu bar icon's state, from the coordinator's phase and the Research jobs.
    public private(set) var activity: MenuBarActivity = .idle
    @ObservationIgnored private var phase: BuddyCoordinator.Phase = .idle
    /// The kept answer is on screen: a click on the menu bar item tucks it away.
    public private(set) var answerShowing = false
    /// This conversation's last answer can come back (menu bar item, Show Last Answer, reopen),
    /// shown or tucked. Follows the coordinator on each phase change; a Forget shows on the next
    /// one, and a recall then simply finds nothing.
    public private(set) var answerKept = false
    /// Where the menu bar item is on screen (AppKit coordinates), for the overlay's fold; nil while
    /// it isn't shown. Set by the shell.
    @ObservationIgnored public var statusItemFrame: (@MainActor () -> CGRect?)?
    @ObservationIgnored private var researchRunning = false
    public private(set) var isRunning = false

    @ObservationIgnored private var coordinator: BuddyCoordinator?
    @ObservationIgnored var monitor: BuddyKeyMonitor?
    @ObservationIgnored private var quick: QuickLane?
    /// The Quick spec for a model choice, once Claude Code and the plugin are known.
    @ObservationIgnored private var quickSpec: (@Sendable (ModeConfig) -> LaunchSpec)?
    @ObservationIgnored private var overlay: (any OverlayPresenting)?
    /// Builds the overlay at `start` (tests pass a fake, so no live panels are made).
    private let makeOverlay: @MainActor () -> any OverlayPresenting
    @ObservationIgnored private var deep: DeepLane?
    /// Open sessions' processes (`LumiFeatures.sessions`); nil when off.
    @ObservationIgnored var sessionEngine: SessionEngine?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// While Settings › Keys or onboarding practises the buddy key, its gestures don't summon.
    @ObservationIgnored public private(set) var isPractisingKey = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var replyVoiceProblemLine: String?
    @ObservationIgnored private var permissionModeLine: String?
    @ObservationIgnored private var mcpServers: [Mode: [String]] = [:]
    @ObservationIgnored private var mcpStatus: [String: String] = [:]
    @ObservationIgnored private var mcpLine: String?
    /// Settings › Connections: every MCP server the lanes' sessions reported, each as last reported
    /// (status and where it's defined), the same rule as the menu line. Empty until the first
    /// session of this run starts.
    public private(set) var mcpServerList: [StreamEvent.MCPServer] = []
    @ObservationIgnored private var mcpEntries: [String: StreamEvent.MCPServer] = [:]
    /// Adds and removes Settings › Connections' recommended servers in the user's Claude Code
    /// (`claude mcp … --scope user`), only on the user's click. Nil until Claude Code is found.
    public private(set) var connections: ClaudeCodeMCP?

    /// Settings › Connections' Add, Remove and requirement check. All nil (the rows hide Add and
    /// Remove; claude.ai connectors and links still work) until Claude Code is found.
    public static func connectionActions(_ mcp: ClaudeCodeMCP?) -> ConnectionActions {
        guard let mcp else { return ConnectionActions() }
        return ConnectionActions(add: { await mcp.add($0, token: $1) }, remove: { await mcp.remove($0) },
                                 hasRequirement: { mcp.hasRequirement($0) })
    }
    /// Every grant's state; its missing ones are problem lines that go once granted.
    public let permissions: PermissionCenter
    @ObservationIgnored private var permissionLines: [AppProblem] = []
    /// Why the buddy key listener isn't running, if its start failed.
    @ObservationIgnored var keyListenerFailure: KeySourceError?
    /// Starts the key listener again after a late grant (set by `start`).
    @ObservationIgnored var startKeyListener: (@MainActor () async throws(KeySourceError) -> Void)?
    /// Called each time a model answer is shown (onboarding's "Try it" step listens).
    @ObservationIgnored public var onAnswerShown: (@MainActor () -> Void)?
    /// ⌘Y in a card: the shell opens the Lumi window.
    @ObservationIgnored public var onOpenLumiWindow: (@MainActor () -> Void)?
    /// A failure chip's "Use <model>": the shell writes Settings › Models and applies it (which
    /// reloads the lane), returning once that's done.
    @ObservationIgnored public var onUseModel: (@MainActor (ModelID, Mode) async -> Void)?
    /// A failure chip's "Fix" / "Open Settings": the shell opens Settings at that pane.
    @ObservationIgnored public var onOpenSettingsPane: (@MainActor (SettingsPane) -> Void)?
    /// ⌘, in a card: the shell opens Settings at its last pane.
    @ObservationIgnored public var onOpenSettings: (@MainActor () -> Void)?
    /// "Saved in Dictation history" › Open: the Lumi window on its Dictation page. Set by the app.
    @ObservationIgnored public var onOpenDictationHistory: (@MainActor () -> Void)?
    /// Every dictation's words (Settings › Privacy applies; `applyConversations`). In memory only
    /// unless the app passes the file-backed one, so tests never touch the user's history.
    @ObservationIgnored public let dictationHistory: DictationHistory
    /// ⌘⇧E in the Panel: the Lumi window (Studio) opens on that session. Set by the app.
    @ObservationIgnored public var onOpenStudioSession: (@MainActor (SessionID) -> Void)?
    /// The Studio window's sessions and engine calls (AppRuntime+Studio).
    @ObservationIgnored public let studioSource = SessionsStudioSource()
    @ObservationIgnored private var appliedConversations = false

    private let voice: any VoicePort
    /// The conversation index, shared with the session store. Nil if it couldn't
    /// be opened: questions still work, in conversations kept in memory, and `problems` says so.
    public let conversationManager: ConversationManager?
    /// The coordinator's conversations over that index.
    public let conversations: LiveConversations?
    /// The saved index itself, for the v2 session store.
    let savedIndex: ConversationIndex?
    /// v2 sessions over the same index (LumiFeatures.sessions); nil while the flag is off.
    @ObservationIgnored public internal(set) var sessions: LiveSessions?
    private let indexProblem: String?
    let preferences = EnginePreferencesBox()

    /// Settings › Claude Code and onboarding step 2: real checks of the user's install, and
    /// Repair (fresh plugin copy, every lane restarted onto it).
    @ObservationIgnored public private(set) lazy var claudeCode: ClaudeCodeService = {
        let service = ClaudeCodeService(
            probe: { await AppRuntime.checkClaudeCode() },
            install: { try PluginInstaller.install() },
            restartLanes: { [weak self] in await self?.restartAfterRepair() })
        service.onChecked = { [weak self] previous, new in
            guard let self, !self.isRunning, Self.startsAfterCheck(previous: previous, new: new) else { return }
            Task { await self.start() }
        }
        return service
    }()

    /// The opt-in trace log (Settings › Privacy): kinds and timings only, off by default.
    public let traceLog: TraceLog
    private let traceDirectory: URL
    private let physicalMemory: UInt64

    public init(voice: any VoicePort, conversationIndex: () throws -> ConversationIndex = { try ConversationIndex() },
                overlay makeOverlay: @escaping @MainActor () -> any OverlayPresenting = { BuddyOverlayController() },
                traceDirectory: URL = TraceLog.defaultDirectory,
                physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                permissions: PermissionCenter = PermissionCenter(),
                dictationHistory: DictationHistory = DictationHistory(file: nil)) {
        self.voice = voice
        self.dictationHistory = dictationHistory
        self.permissions = permissions
        self.makeOverlay = makeOverlay
        self.traceDirectory = traceDirectory
        self.physicalMemory = physicalMemory
        traceLog = TraceLog(directory: traceDirectory, enabled: false)
        if let index = try? conversationIndex() {
            let manager = ConversationManager(index: index, screenshotDirectory: ScreenshotStore.defaultDirectory,
                                              reportsDirectory: ResearchController.reportsDirectory)
            conversationManager = manager
            conversations = LiveConversations(manager: manager)
            savedIndex = index
            indexProblem = nil
        } else {
            conversationManager = nil
            conversations = nil
            savedIndex = nil
            indexProblem = Self.indexFailed
        }
        problems = indexProblem.map { [AppProblem(text: $0, fix: Self.fix(for: $0))] } ?? []
        conversations?.setSaveProblemHandler { [weak self] failed in
            self?.setProblem(LiveConversations.saveFailed, active: failed)
        }
    }

    /// Never shows a permission prompt: a missing grant becomes a true line in `problems`, and
    /// asking is onboarding's and Settings › Privacy's job (a prompt mid-use after a reset is
    /// worse than a menu line). Safe to call again after a failed start (e.g. once onboarding
    /// has found Claude Code).
    public func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        // A retry clears only the lines an earlier failed start wrote; others stay true.
        problems.removeAll {
            $0.text == Self.claudeMissing || $0.text == Self.claudeTooOld || $0.text.hasPrefix(Self.pluginFailedPrefix)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Claude Code: login-shell PATH (GUI apps get a minimal one), then the CLI itself.
        let env = await Self.launchEnvironment(home: home)
        let claudeCode = claudeCode
        guard let claude = LaunchEnvironment.locateClaude(
            preferred: nil, path: env["PATH"] ?? "", home: home.path)
        else {
            report(Self.claudeMissing)
            Task { await claudeCode.refresh() }
            return
        }
        // Quick and Deep pass a flag an older CLI rejects, so it would fail every launch. An
        // unreadable version doesn't block: the launch itself then says what's wrong.
        if let version = await ClaudeCodeProbe().version(of: claude, environment: env),
           !ClaudeCodeProbe.isSupported(version) {
            report(Self.claudeTooOld)
            Task { await claudeCode.refresh() }
            return
        }
        let plugin: URL
        do {
            plugin = try PluginInstaller.install()
        } catch {
            report(Self.pluginFailedPrefix + error.localizedDescription)
            Task { await claudeCode.refresh() }
            return
        }
        // Off the launch path: the check takes seconds.
        Task { await claudeCode.refresh() }
        // The same CLI and environment the lanes run with. Its calls are never logged: a token may
        // be part of what it writes.
        connections = ClaudeCodeMCP(claude: claude, environment: env)

        // Models come from Settings: Quick's spec is rebuilt on a change (`apply`); Deep reads the
        // current choice each time it starts a process.
        let preferences = preferences
        let quickSpec: @Sendable (ModeConfig) -> LaunchSpec = { config in
            .quick(executable: claude, home: home, plugin: plugin, config: config, environment: env)
        }
        self.quickSpec = quickSpec
        // Idle processes are freed: Quick's spare after 30 min, Deep's
        // 200–400 MB process after 10. Each conversation resumes its session next time. An 8 GB
        // Mac keeps less alive (`ProcessLimits`).
        let limits = ProcessLimits(physicalMemory: physicalMemory)
        let researchRunner = ResearchController.manager(
            executable: claude, plugin: plugin, reportsDir: ResearchController.reportsDirectory,
            home: home, environment: env, maxConcurrent: limits.researchJobs, config: researchConfig)
        let holdResearch: (@Sendable (Bool) async -> Void)? = limits.holdResearchDuringDeep
            ? { @Sendable busy in await researchRunner.setHeld(busy) } : nil
        let quick = QuickLane(spec: quickSpec(preferences.current.coordinator.quick), idleAfter: limits.quickIdle,
                              keepSpare: limits.keepQuickSpare)
        let deep = DeepLane(spec: { folder, resume in
            let config = preferences.current.coordinator.deep
            return .deep(executable: claude, folder: folder, plugin: plugin, resume: resume, config: config,
                         fallbackModels: Self.deepFallbacks(for: config.model), environment: env)
        }, idleAfter: limits.deepIdle,
           onBusy: holdResearch)
        self.quick = quick
        self.deep = deep
        // The v2 flags, read once for the whole start (each `v2.<name>` set to false turns one off).
        let features = LumiFeatures.current()
        let sessionEngine = makeSessionPool(claude: claude, environment: env, plugin: plugin, home: home,
                                            features: features)
        let cascade = Cascade(quick: quick, deep: deep, home: home, openHandoff: sessionHandoff(sessionEngine),
                              trust: { FolderTrust.load(home: home) })

        // Context: AX timeout and screenshot retention, then a long-lived recent-apps observer.
        // Blocked apps and retention are read from Settings each time they're needed.
        let blocklist: @Sendable () -> Blocklist = { preferences.current.blocklist }
        let shots = Self.screenshotStore(preferences)
        ContextBuilder.prepare(store: shots)
        tasks.append(shots.startPeriodicSweep(every: Self.sweepInterval))
        let recent = WorkspaceRecentApps(blocklist: blocklist)
        let context = LiveContext(
            builder: ContextBuilder(sensors: .live(recent: recent), blocklist: blocklist()),
            shooter: ScreenCaptureKitShooter(store: shots),
            blocklist: blocklist)

        let overlay = makeOverlay()
        overlay.settings = preferences.current.overlay
        // A tucked answer folds into the menu bar item, wherever it is at that moment.
        overlay.foldTarget = { [weak self] in self?.statusItemFrame?() }
        // Every card's frame and close in the trace log: qa-ui checks there's never two at once.
        (overlay as? BuddyOverlayController)?.onCard = { [traceLog] change in Self.traceCard(change, to: traceLog) }
        self.overlay = overlay
        let inserter = LiveInserter(inserter: TextInserter(isBlocked: { blocklist().isBlocked(bundleID: $0) }))

        // The buddy key. Input Monitoring is checked without prompting first.
        let monitor = Self.makeKeyMonitor(preferences.current.keys, features: features)
        self.monitor = monitor
        // Research jobs run sandboxed in their reports folder; the coordinator activates the capsule.
        // Settings › Models › Research isn't fed in yet.
        let research = ResearchController(
            runner: researchRunner,
            overlay: overlay, model: { [researchConfig] in researchConfig().model })
        let coordinator = BuddyCoordinator(
            voice: voice, context: context, turns: LiveBridge(cascade: cascade, sessions: sessionEngine?.turns),
            overlay: overlay, inserter: inserter, escape: LiveEscape(), pointer: LivePointer(),
            locator: LiveLocator(blocklist: blocklist),
            interruptions: SystemInterruptions(),
            trace: traceLog,
            research: research,
            conversations: conversations,
            openURL: LiveOpenURL(),
            setKeyListening: { await monitor.setListening($0) })
        self.coordinator = coordinator
        coordinator.onPhaseChange = { [weak self] phase in
            self?.phase = phase
            self?.updateActivity()
            self?.updateKeptAnswer()
        }
        research.onRecord = { [conversations] job in
            Task { await conversations?.recordResearchJob(job) }
        }
        research.onJobsChange = { [weak self] jobs in
            self?.researchRunning = jobs.contains(where: \.isActive)
            self?.updateActivity()
        }
        coordinator.settings = Self.coordinatorSettings(preferences.current)
        // v2 streams attach here, each behind its LumiFeatures flag. Order matters: the session store
        // first (the Panel, switcher and Studio read it), the Panel before dictation (its composer).
        makeSessionEngine(coordinator, features: features)
        // Typed sessions (and voice answers without a topic) are named after their first answer.
        sessions?.titler = ClaudeTitler(claude: claude, environment: env)
        makePanel(coordinator, features: features, sessions: sessions)
        makeSwitcher(coordinator, features: features)
        makeDictation(coordinator, features: features)
        makeStudioBridge(coordinator, features: features)
        coordinator.onAnswerShown = { [weak self] in self?.onAnswerShown?() }
        coordinator.onOpenLumiWindow = { [weak self] in self?.onOpenLumiWindow?() }
        coordinator.onRepairPlugin = { [weak self] in self?.repairPluginFromChip() }
        coordinator.onPermissionMode = { [weak self] mode in self?.setPermissionMode(mode) }
        coordinator.onMCPServers = { [weak self] lane, servers in self?.setMCPServers(servers, lane: lane) }
        coordinator.onUseModel = { [weak self] model, mode in await self?.onUseModel?(model, mode) }
        coordinator.onOpenSettingsPane = { [weak self] pane in self?.onOpenSettingsPane?(pane) }
        coordinator.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        coordinator.onOpenDictationHistory = { [weak self] in self?.onOpenDictationHistory?() }
        coordinator.hintDefaults = .standard // the reply hint, once learned, stays hidden
        coordinator.onGrantPermission = { [weak self] kind in Task { await self?.permissions.fix(kind) } }
        coordinator.setMissingPermission(Self.missingForChip(permissions)) // watched before it existed
        coordinator.doubleTapAvailable = { !StickyKeys.isEnabled() } // as the key monitor decides
        coordinator.start()

        // The listener's own start says whether Input Monitoring is granted; nothing prompts here.
        // Stops first, so a start after a revoke and re-grant gets a new tap, not the dead one.
        startKeyListener = { () async throws(KeySourceError) in
            await monitor.stop()
            try await monitor.start()
        }
        await startKeyListenerIfNeeded()
        let events = monitor.events
        tasks.append(Task { [weak self, weak coordinator, quick] in
            for await event in events where self?.isPractisingKey != true {
                // The key is down: bring Quick's spare back now if idle freed it, so its start-up
                // overlaps the user's speech instead of the answer (a no-op while it's alive).
                if case .gesture(.pressBegan) = event { Task { await quick.prewarm() } }
                await coordinator?.handle(event)
            }
        })

        // Voice models load in the background; until then the buddy key says "Still setting up voice".
        let voice = voice
        tasks.append(Task { [weak self] in
            do {
                try await voice.prepare()
            } catch is CancellationError {
                // Quitting mid-download isn't a problem to report.
            } catch {
                self?.report(Self.voiceFailedPrefix + error.localizedDescription)
            }
        })
        await quick.prewarm()
        // Retention, daily for as long as the app runs.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                await self?.pruneConversations()
            }
        })
        isRunning = true
    }

    /// The menu bar item, Show Last Answer and reopening the app: the kept answer comes back, where
    /// it last sat. False when there's none to bring back (the caller opens the menu instead).
    @discardableResult
    public func recallLastAnswer() -> Bool {
        let shown = coordinator?.recallLastAnswer() ?? false
        updateKeptAnswer()
        return shown
    }

    /// The menu bar item while the kept answer shows: it folds into the item and stays kept.
    public func tuckAnswer() {
        coordinator?.tuckAnswer()
        updateKeptAnswer()
    }

    /// A short note near the pointer, the same toast a turn shows (e.g. after a menu action).
    public func showNote(_ text: String) {
        overlay?.showToast(text, at: LivePointer().location())
    }

    /// Re-reads the coordinator's kept answer (each phase change, and when the menu opens).
    public func updateKeptAnswer() {
        answerKept = coordinator?.hasKeptAnswer ?? false
        answerShowing = coordinator?.isShowingKeptAnswer ?? false
    }

    /// Menu bar Pause: gestures are ignored and anything in flight is discarded or cancelled.
    public func setPaused(_ paused: Bool) async {
        await coordinator?.setPaused(paused)
    }

    /// Every engine-facing setting, at launch (before `start`) and on every change: blocked apps
    /// and retention apply at the next capture or sweep, a key change rebinds the running
    /// listener, and models, routing, voice replies, sounds and appearance apply straight away.
    public func apply(_ new: EnginePreferences) async {
        let old = preferences.set(new)
        traceLog.setEnabled(new.traceLogEnabled)
        if new.traceLogEnabled, !old.traceLogEnabled {
            // So Settings › Privacy can show the folder straight away, before the first entry.
            try? FileManager.default.createDirectory(at: traceDirectory, withIntermediateDirectories: true)
        }
        await applyConversations(new, old: old)
        coordinator?.settings = Self.coordinatorSettings(new)
        overlay?.settings = new.overlay
        if new.keys != old.keys {
            await monitor?.update(Self.keyOptions(new.keys))
            // "1 waiting · Tab" names the new key's next key.
            coordinator?.switcherFlow?.nextKeyName = Self.switcherNextKeyName(new.keys.key)
        }
        // A new Quick model: the spare restarts on it and the current conversation moves over at
        // its next turn. A new Deep model: the idle Deep process stops; the next handoff uses it.
        if new.coordinator.quick != old.coordinator.quick, let quickSpec {
            await quick?.reload(spec: quickSpec(new.coordinator.quick))
        }
        if new.coordinator.deep != old.coordinator.deep { await deep?.reload() }
    }

    /// The coordinator's settings, with the hint symbol always from the bound key.
    /// `cardShown frame=x,y,w,h` and `cardClosed reason=…`: where cards sat and why they left, no content.
    static func traceCard(_ change: BuddyOverlayController.CardChange, to trace: any TracePort) {
        switch change {
        case .shown(let frame):
            trace.record(.cardShown, frame: frame)
        case .closed(let close):
            let reason: TraceReason = switch close {
            case .dismissed(.escape): .escape
            case .dismissed(.clickAway): .clickAway
            case .dismissed(.appSwitched): .appSwitched
            case .dismissed(.closeButton): .closeButton
            case .dismissed(.requested): .requested
            case .replaced: .replaced
            case .summon: .summon
            }
            trace.record(.cardClosed, duration: nil, outcome: nil, reason: reason)
        }
    }

    static func coordinatorSettings(_ prefs: EnginePreferences) -> BuddyCoordinator.Settings {
        var settings = prefs.coordinator
        settings.keySymbol = prefs.keys.key.symbol
        settings.research = prefs.research
        return settings
    }

    /// Idle timeout and temporary mode apply at once; a shorter retention prunes at once.
    private func applyConversations(_ new: EnginePreferences, old: EnginePreferences) async {
        dictationHistory.setPolicy(temporary: new.temporaryConversations, retentionDays: new.retentionDays)
        guard let manager = conversationManager else { return }
        let first = !appliedConversations
        appliedConversations = true
        if first || new.idleTimeout != old.idleTimeout {
            await manager.setPolicy(ConversationPolicy(idleTimeout: new.idleTimeout))
            sessions?.policy.idleLimit = new.idleTimeout
        }
        sessions?.maxSubagents = new.sessions.maxSubagents
        if first || new.temporaryConversations != old.temporaryConversations, let conversations {
            do {
                try await conversations.setTemporary(new.temporaryConversations)
                setProblem(Self.temporaryFailed, active: false)
                await sessions?.setStore(SessionStore(index: await manager.activeIndex))
            } catch {
                setProblem(Self.temporaryFailed, active: true)
            }
        }
        if first || new.retentionDays != old.retentionDays { await pruneConversations() }
    }

    /// Settings › Conversations "Keep for": run at launch, on a change and once a day.
    func pruneConversations() async {
        guard let manager = conversationManager else { return }
        let days = preferences.current.retentionDays
        _ = try? await manager.prune(unusedSince: Date().addingTimeInterval(-TimeInterval(days) * 86_400))
    }

    /// 8 GB or less: the engine keeps fewer processes (`ProcessLimits`) and onboarding says so once.
    public nonisolated static func isLowMemory(_ physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory <= ProcessLimits.lowMemoryLimit
    }

    /// How many `claude` processes stay alive, by the Mac's memory.
    /// 16 GB and up: Quick's spare stays warm and idles out after 30 min, Deep's process after
    /// 10, two Research jobs at a time. 8 GB or less: no Quick spare beside the current process
    /// (the buddy key's prewarm brings it back), Deep stops as each question ends, one Research
    /// job at a time, and queued jobs wait while Deep answers. Deep never waits for Research.
    struct ProcessLimits: Equatable {
        var quickIdle: Duration = .seconds(30 * 60)
        var deepIdle: Duration = .seconds(10 * 60)
        var keepQuickSpare = true
        var researchJobs = ResearchManager.maxConcurrent
        var holdResearchDuringDeep = false

        static let lowMemoryLimit: UInt64 = 8 << 30

        init(physicalMemory: UInt64) {
            guard AppRuntime.isLowMemory(physicalMemory) else { return }
            deepIdle = .zero
            keepQuickSpare = false
            researchJobs = 1
            holdResearchDuringDeep = true
        }
    }

    /// Deep's `--fallback-model` list (re-passed on every resume): Sonnet, then Haiku, so an
    /// overloaded or unavailable Deep model still answers. Never the model already in use.
    nonisolated static func deepFallbacks(for model: ModelID) -> [ModelID] {
        [.sonnet, .haiku].filter { $0 != model }
    }

    /// The Research model and effort for a job starting now (ResearchController.manager's config).
    public nonisolated var researchConfig: @Sendable () -> ModeConfig {
        let preferences = preferences
        return { preferences.current.research }
    }

    /// Short enough that a 1 h retention is honoured within minutes, not up to an hour late.
    static let sweepInterval: Duration = .seconds(300)

    static func screenshotStore(_ preferences: EnginePreferencesBox) -> ScreenshotStore {
        ScreenshotStore(retention: { preferences.current.screenshotRetention })
    }

    /// The child environment every `claude` gets: the login shell's PATH (GUI apps get a
    /// minimal one) on top of the app's own.
    nonisolated static func launchEnvironment(home: URL) async -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        let loginPath = await LaunchEnvironment.loginShellPath(shell: base["SHELL"] ?? "/bin/zsh", home: home.path)
        return LaunchEnvironment.make(base: base, loginShellPath: loginPath, home: home.path)
    }

    /// One full check of Claude Code and the installed plugin (BuddyBridge's probe).
    nonisolated static func checkClaudeCode() async -> ClaudeCodeReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = await launchEnvironment(home: home)
        return await ClaudeCodeProbe().check(preferred: nil, plugin: PluginInstaller.destination,
                                             environment: env, home: home.path)
    }

    /// A check after a launch that couldn't start: start now, whichever window ran it, when Claude
    /// Code has turned up (installed after a launch that couldn't find it) or been updated past
    /// the minimum.
    nonisolated static func startsAfterCheck(previous: ClaudeCodeStatus, new: ClaudeCodeStatus) -> Bool {
        guard new.executablePath != nil else { return false }
        let updated = previous.version.map(ClaudeCodeProbe.isSupported) == false
            && new.version.map(ClaudeCodeProbe.isSupported) == true
        return previous.executablePath == nil || updated
    }

    /// "Repair plugin" pressed on a failure chip: the same repair as Settings › Claude Code. A copy
    /// that fails becomes a true problem line instead of vanishing.
    func repairPluginFromChip() {
        let claudeCode = claudeCode
        Task { [weak self] in
            do {
                try await claudeCode.repairPlugin()
            } catch {
                self?.report(Self.pluginFailedPrefix + error.localizedDescription)
            }
        }
    }

    /// Repair plugin: every Claude Code process restarts onto the fresh copy (answers in flight
    /// finish first; each conversation resumes its session). If the engine never started (the
    /// plugin couldn't be installed at launch), it starts now.
    func restartAfterRepair() async {
        guard isRunning else { return await start() }
        await quick?.reload()
        await deep?.reload()
    }

    /// Fed by the companion's `KeyPracticeCoordinator`: practice taps go to the practice area only.
    public func setKeyPractice(_ active: Bool) {
        isPractisingKey = active
    }

    /// The Settings pane that fixes a problem line, or nil when none can.
    static func fix(for problem: String) -> SettingsPane? {
        if problem == claudeMissing || problem == claudeTooOld || problem.hasPrefix(pluginFailedPrefix) { return .claudeCode }
        if problem.contains("Input Monitoring") || problem.contains("Accessibility")
            || problem == message(for: .tapCreationFailed) { return .privacy }
        if problem.hasPrefix(voiceFailedPrefix) { return .voice }
        if problem == temporaryFailed || problem == LiveConversations.saveFailed || problem == indexFailed {
            return .conversations
        }
        return nil
    }

    static let voiceFailedPrefix = "Voice couldn't start: "
    static let indexFailed = "Conversation history couldn't be opened, so conversations won't be kept."

    private func updateActivity() {
        let new = MenuBarActivity.from(phase: phase, researchRunning: researchRunning)
        // Research updates come often (each source); only a real change redraws the menu bar.
        if new != activity { activity = new }
    }

    /// The reply voice's problem line (ElevenLabs fell back to the on-device voice), shown with a
    /// link to Settings › Voice until ElevenLabs works again, the key changes or the voice does.
    public func setReplyVoiceProblem(_ line: String?) {
        if let shown = replyVoiceProblemLine { problems.removeAll { $0.text == shown } }
        replyVoiceProblemLine = line
        if let line, !problems.contains(where: { $0.text == line }) {
            problems.append(AppProblem(text: line, fix: .voice))
        }
    }

    /// The permission-mode line: shown while a session reports a mode that blocks actions, replaced
    /// if the mode changes, gone once a session reports auto again.
    public func setPermissionMode(_ mode: String) {
        if let shown = permissionModeLine { problems.removeAll { $0.text == shown } }
        permissionModeLine = TurnFailureLine.permissionModeLine(mode)
        if let line = permissionModeLine, !problems.contains(where: { $0.text == line }) {
            problems.append(AppProblem(text: line, fix: nil))
        }
    }

    /// The MCP line, from every lane's `system/init`. A server's status is the latest any lane
    /// reported (`pending` keeps the one before), so a stale lane can't contradict a fresh one; a
    /// server counts while any lane's latest list still names it. Replaced as statuses change.
    public func setMCPServers(_ servers: [StreamEvent.MCPServer], lane: Mode) {
        mcpServers[lane] = servers.map(\.name)
        for server in servers where server.status != "pending" { mcpStatus[server.name] = server.status }
        for server in servers where server.status != "pending" || mcpEntries[server.name] == nil { mcpEntries[server.name] = server }
        let named = Mode.allCases.flatMap { mcpServers[$0] ?? [] }
        mcpStatus = mcpStatus.filter { named.contains($0.key) }
        mcpEntries = mcpEntries.filter { named.contains($0.key) }
        var listed: Set<String> = []
        mcpServerList = named.filter { listed.insert($0).inserted }.compactMap { mcpEntries[$0] }
        let current = named.map { (name: $0, status: mcpStatus[$0] ?? "pending") }
        if let shown = mcpLine { problems.removeAll { $0.text == shown } }
        mcpLine = TurnFailureLine.mcpProblemLine(statuses: current)
        if let line = mcpLine, !problems.contains(where: { $0.text == line }) {
            problems.append(AppProblem(text: line, fix: nil))
        }
    }

    static let temporaryFailed = "Temporary mode couldn't be changed."
    static let claudeMissing = "Claude Code isn't installed, or isn't on your PATH."
    static let claudeTooOld = "Claude Code is too old for Lumi. Update it to \(ClaudeCodeProbe.minimumVersion) or newer: run claude update in Terminal."
    static let pluginFailedPrefix = "The Lumi plugin couldn't be installed: "

    /// A problem line that can resolve (a later save or switch worked).
    private func setProblem(_ problem: String, active: Bool) {
        if active { report(problem) } else { problems.removeAll { $0.text == problem } }
    }

    private func report(_ problem: String) {
        if !problems.contains(where: { $0.text == problem }) {
            problems.append(AppProblem(text: problem, fix: Self.fix(for: problem)))
        }
    }

    public func stop() async {
        phase = .idle
        researchRunning = false
        updateActivity()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        coordinator?.stop()
        await shutdownSessions()
        await monitor?.stop()
        await quick?.shutdown()
        await deep?.shutdown()
        isRunning = false
    }

    // MARK: Permissions

    /// Shows the permission lines now, then keeps them true for the app's life: a grant turned on
    /// removes its line (and starts the buddy key if that was what it lacked), one turned off adds it.
    public func watchPermissions() {
        observePermissions()
        tasks.append(Task { [permissions] in await permissions.watch() })
    }

    /// The lines now and on every change, without polling (tests refresh the center themselves).
    func observePermissions() {
        permissions.onChange = { [weak self] in self?.permissionsChanged() }
        permissionsChanged()
    }

    func permissionsChanged() {
        problems.removeAll { line in permissionLines.contains(line) }
        permissionLines = Self.permissionLines(permissions)
        problems.insert(contentsOf: permissionLines, at: 0)
        // Input Monitoring turned off while the key ran: its tap gets no events again, even after
        // a re-grant, so the grant below starts a fresh one.
        if keyListenerStarted, !permissions.launchedFromTerminal, permissions.state(.inputMonitoring) == .missing {
            keyListenerStarted = false
            keyListenerFailure = .inputMonitoringNotGranted
        }
        if keyListenerFailure == .inputMonitoringNotGranted, permissions.state(.inputMonitoring) != .missing {
            Task { await startKeyListenerIfNeeded() }
        }
        coordinator?.setMissingPermission(Self.missingForChip(permissions))
    }

    /// Starts the buddy key listener unless it's running. Only a failure other than a missing
    /// grant is a line of its own: a missing grant is already a permission line.
    func startKeyListenerIfNeeded() async {
        guard let startKeyListener, !keyListenerStarted else { return }
        do {
            try await startKeyListener()
            // Started after a late grant: Input Monitoring works in this process, no reopen needed.
            if keyListenerFailure == .inputMonitoringNotGranted { permissions.markAppliedLive(.inputMonitoring) }
            keyListenerFailure = nil
            keyListenerStarted = true
        } catch .alreadyStarted {
            keyListenerFailure = nil
            keyListenerStarted = true
        } catch {
            if keyListenerFailure != error, error == .inputMonitoringNotGranted { traceLog.record(.permissionMissing) }
            keyListenerFailure = error
            if error != .inputMonitoringNotGranted { report(Self.message(for: error)) }
        }
    }

    @ObservationIgnored private var keyListenerStarted = false

    /// The permission the answer chip offers to fix: Accessibility first. Input Monitoring never
    /// (without it there's no summon), nor a grant waiting on a reopen (the menu's Reopen line).
    static func missingForChip(_ center: PermissionCenter) -> PermissionKind? {
        guard !center.launchedFromTerminal else { return nil }
        return [.accessibility, .screenRecording].first { center.policy.required.contains($0) && center.state($0) == .missing }
    }

    /// One line per required grant that's missing, then one to reopen for those waiting on it.
    static func permissionLines(_ center: PermissionCenter) -> [AppProblem] {
        // From a terminal the checks are about the terminal's grants: no line would be true.
        guard !center.launchedFromTerminal else { return [] }
        let order: [PermissionKind] = [.inputMonitoring, .accessibility, .screenRecording]
        var lines = order.filter { center.policy.required.contains($0) && center.state($0) == .missing }
            .map { AppProblem(text: missingLine($0), fix: .privacy) }
        let waiting = order.filter { center.state($0) == .grantedNeedsRelaunch }
        if !waiting.isEmpty {
            let names = waiting.map(\.title).joined(separator: " and ")
            lines.append(AppProblem(text: "Reopen \(BuddyCore.appName) to finish turning on \(names).", fix: nil, relaunches: true))
        }
        return lines
    }

    static func missingLine(_ kind: PermissionKind) -> String {
        let name = BuddyCore.appName
        return switch kind {
        case .inputMonitoring: "\(name) needs Input Monitoring to hear your Lumi key."
        case .accessibility: "\(name) needs Accessibility for Esc, your selection and inserting text."
        case .screenRecording: "\(name) needs Screen Recording to see your screen."
        case .microphone: "\(name) needs the microphone to hear you. You can still type."
        }
    }

    static func message(for error: KeySourceError) -> String {
        switch error {
        case .inputMonitoringNotGranted: "Lumi needs Input Monitoring to hear your Lumi key."
        case .accessibilityNotGranted: "Lumi needs Accessibility."
        case .tapCreationFailed: "The Lumi key listener couldn't start."
        case .alreadyStarted: "The Lumi key listener is already running."
        }
    }
}

/// The live voice: BuddyVoice's controller, with its events and errors turned into the
/// coordinator's port types. The transcript only ever comes back from `finishListening` /
/// `sendHeld`; events and levels carry no words.
public final class LiveVoice: VoicePort {
    public let levels: AsyncStream<VoiceLevel>
    public let events: AsyncStream<VoiceEvent>
    /// Every prepare step as it happens (Settings › Voice, the setup chip). One consumer.
    public let prepareStates: AsyncStream<VoiceController.PrepareState>
    /// The reply voice's problem line (ElevenLabs fell back to the on-device voice), or nil once
    /// ElevenLabs speaks again. One consumer.
    public let replyVoiceProblems: AsyncStream<String?>
    private let prepareFailure = PrepareFailure()
    /// Prepares running or queued, on any controller: one replaced by a new speech model may
    /// still be downloading into the same folders, so Remove waits for all of them.
    private let preparing = Mutex(0)
    private let makeController: @Sendable (VoiceSettings) -> VoiceController
    private let output: Output
    private let state: Mutex<Current>

    /// The controller in use and the settings it was built with. Settings › Voice swaps it for a
    /// new speech model; the streams above carry on across the swap.
    private struct Current {
        var controller: VoiceController
        var settings: VoiceSettings
        var forwarding: Task<Void, Never>
    }

    private struct Output: Sendable {
        let levels: AsyncStream<VoiceLevel>.Continuation
        let events: AsyncStream<VoiceEvent>.Continuation
        let prepare: AsyncStream<VoiceController.PrepareState>.Continuation
        let replyVoiceProblems: AsyncStream<String?>.Continuation
    }

    private var controller: VoiceController { state.withLock { $0.controller } }

    /// The real stack (Kokoro, Parakeet per `settings.speechModel`, voice processing per Settings).
    public static func live(settings: VoiceSettings = VoiceSettings()) -> LiveVoice {
        LiveVoice(settings: settings, makeController: { .live(settings: $0) })
    }

    public convenience init(controller: VoiceController) {
        self.init(controller: controller, settings: VoiceSettings(), makeController: { _ in controller })
    }

    /// `makeController` builds the controller for a settings change (tests pass fakes).
    public convenience init(settings: VoiceSettings, makeController: @escaping @Sendable (VoiceSettings) -> VoiceController) {
        self.init(controller: makeController(settings), settings: settings, makeController: makeController)
    }

    private init(controller: VoiceController, settings: VoiceSettings,
                 makeController: @escaping @Sendable (VoiceSettings) -> VoiceController) {
        let (levels, levelsOut) = AsyncStream.makeStream(of: VoiceLevel.self, bufferingPolicy: .bufferingNewest(8))
        let (events, eventsOut) = AsyncStream.makeStream(of: VoiceEvent.self)
        let (prepareStates, prepareOut) = AsyncStream.makeStream(of: VoiceController.PrepareState.self)
        let (replyVoiceProblems, replyOut) = AsyncStream.makeStream(of: String?.self)
        self.levels = levels
        self.events = events
        self.prepareStates = prepareStates
        self.replyVoiceProblems = replyVoiceProblems
        self.makeController = makeController
        let output = Output(levels: levelsOut, events: eventsOut, prepare: prepareOut, replyVoiceProblems: replyOut)
        self.output = output
        let forwarding = Self.forward(controller, to: output, failure: prepareFailure)
        state = Mutex(Current(controller: controller, settings: settings, forwarding: forwarding))
    }

    deinit {
        state.withLock { $0.forwarding.cancel() }
        output.levels.finish()
        output.events.finish()
        output.prepare.finish()
        output.replyVoiceProblems.finish()
    }

    /// Forwards one controller's levels and events, mapped to the port's types, until cancelled.
    private static func forward(_ controller: VoiceController, to output: Output, failure: PrepareFailure) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await level in controller.levels {
                        switch level {
                        case .mic(let value): output.levels.yield(.mic(Double(value)))
                        case .reply(let value): output.levels.yield(.reply(Double(value)))
                        }
                    }
                }
                group.addTask {
                    var lastProblem: String?
                    for await event in controller.events {
                        if case .prepare(let step) = event { output.prepare.yield(step) }
                        if case .replyVoiceProblem(let line) = event { output.replyVoiceProblems.yield(line) }
                        if case .replyVoiceRecovered = event { output.replyVoiceProblems.yield(nil) }
                        if case .prepare(.failed(let detail)) = event { failure.set(detail) }
                        if case .prepare(.ready) = event { failure.set(nil) }
                        if case .micProblem(let problem) = event { lastProblem = Self.message(for: problem) }
                        if case .micProblem(.permissionDenied) = event { output.events.yield(.permissionDenied) }
                        if let mapped = Self.map(event, lastProblem: lastProblem) { output.events.yield(mapped) }
                    }
                }
            }
        }
    }

    /// Settings › Voice › Speech to text. A new model means a new controller. It takes over at once,
    /// so every later call reaches it; whatever the old one was hearing or saying then stops (a
    /// listen in progress ends with a true line), and the new model prepares in the background
    /// (its progress shows in `prepareStates`). No-op for the model already in use.
    public func setSpeechModel(_ model: SpeechModel) async {
        let (old, settings) = state.withLock { ($0.controller, $0.settings) }
        guard settings.speechModel != model else { return }
        var updated = settings
        updated.speechModel = model
        updated.soundsEnabled = await old.soundsEnabled
        let new = makeController(updated)
        let output = output, failure = prepareFailure
        let replaced: Task<Void, Never>? = state.withLock { current in
            // Another change swapped first while this one waited: the newer one stands.
            guard current.controller === old else { return nil }
            let previous = current.forwarding
            current = Current(controller: new, settings: updated,
                              forwarding: Self.forward(new, to: output, failure: failure))
            return previous
        }
        guard let replaced else { return }
        // The new controller knows nothing of the old one's ElevenLabs problem, so it would never
        // report it recovered: the line ends here.
        output.replyVoiceProblems.yield(nil)
        if case .discarded = await old.discard(confirmed: true, playSound: false) {
            // The coordinator was listening on the old controller: end that listen truthfully.
            output.events.yield(.autoStopped(held: false, message: Self.speechModelChanged))
        }
        await old.stopSpeaking()
        replaced.cancel()
        prepareInBackground()
    }

    static let speechModelChanged = "The speech model changed. Tap to ask again."
    static let notSetUp = "Voice isn't set up."

    /// Settings › Voice › reply voice (on-device or ElevenLabs). Kept in the stored settings, so a
    /// controller rebuilt for a new speech model speaks with the same voice. Also called after an
    /// ElevenLabs key is saved, replaced or removed, so a remembered key problem is cleared.
    public func setReplyVoice(_ voice: ReplyVoice) async {
        let controller = state.withLock { current in
            current.settings.replyVoice = voice
            return current.controller
        }
        await controller.setReplyVoice(voice)
    }

    /// The voice setup was chosen (onboarding's voice step, Settings › Voice › Set Up Voice) or
    /// not yet. Kept in the stored settings, so a controller rebuilt for a new speech model keeps it.
    public func setSetupChosen(_ chosen: Bool) async {
        let controller = state.withLock { current in
            current.settings.setupChosen = chosen
            return current.controller
        }
        await controller.setSetupChosen(chosen)
    }

    /// Settings › Voice and onboarding's choice, applied over what's in use. The reply voice goes
    /// before the setup choice, so choosing the Mac voice or ElevenLabs never starts loading
    /// Kokoro first; then one `prepare()` loads whatever the new settings need (a choice made
    /// before it would otherwise leave a mic-only "ready" showing). The prepare runs in the
    /// background, like a new speech model's, so a long first download never holds up the next
    /// settings change.
    public func apply(_ wanted: VoiceSettings, over applied: VoiceSettings) async {
        if wanted.voiceProcessing != applied.voiceProcessing { try? await setVoiceProcessing(wanted.voiceProcessing) }
        if wanted.speechModel != applied.speechModel { await setSpeechModel(wanted.speechModel) }
        // A new choice starts clean: the voice reports any earlier problem recovered, in order on
        // the same stream, so its menu line goes.
        if wanted.replyVoice != applied.replyVoice { await setReplyVoice(wanted.replyVoice) }
        if wanted.setupChosen != applied.setupChosen { await setSetupChosen(wanted.setupChosen) }
        if wanted.replyVoice != applied.replyVoice || wanted.setupChosen != applied.setupChosen {
            prepareInBackground()
        }
    }

    /// What Settings › Voice and onboarding's voice step call: Set Up / Try Again, an ElevenLabs
    /// key saved, replaced or removed (re-applies the reply voice, which clears a remembered key
    /// problem and its menu line, in order), and Remove.
    public func actions(replyVoice: @escaping @MainActor () -> ReplyVoice) -> VoiceActions {
        VoiceActions(
            prepare: { [weak self] in try? await self?.prepare() },
            elevenLabsKeyChanged: { [weak self] in
                let voice = await MainActor.run { replyVoice() }
                await self?.setReplyVoice(voice)
            },
            removeModels: { [weak self] part in try await self?.removeModels(part) })
    }

    /// Settings › Voice › Remove: deletes a downloaded part from the controller in use. Throws
    /// `VoiceError.busy` while voice is loading, listening or speaking. The caller then changes the
    /// settings, so nothing downloads the part again unasked.
    public func removeModels(_ part: VoiceModelPart) async throws {
        guard preparing.withLock({ $0 }) == 0 else { throw VoiceController.VoiceError.busy }
        try await controller.removeModels(part)
    }

    /// Counted from now, before the task runs, so Remove can't slip in between.
    private func prepareInBackground() {
        preparing.withLock { $0 += 1 }
        Task {
            defer { preparing.withLock { $0 -= 1 } }
            try? await prepare()
        }
    }

    /// Settings › Voice › Voice Isolation: applies from the next listen.
    public func setVoiceProcessing(_ enabled: Bool) async throws {
        let controller = state.withLock { current in
            current.settings.voiceProcessing = enabled
            return current.controller
        }
        try await controller.setVoiceProcessing(enabled)
    }

    /// Loads the speech models and warms Kokoro (the first run downloads and compiles them).
    /// A failure is remembered so the buddy key can say so, and the next press retries.
    public func prepare() async throws {
        self.preparing.withLock { $0 += 1 }
        defer { self.preparing.withLock { $0 -= 1 } }
        let preparing = controller
        do {
            try await preparing.prepare()
            guard controller === preparing else { throw CancellationError() }
            prepareFailure.set(nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A controller replaced meanwhile (a new speech model) reports nothing: its model is
            // no longer the one in use.
            guard controller === preparing else { throw CancellationError() }
            prepareFailure.set(error.localizedDescription)
            throw error
        }
    }

    public func startListening() async throws {
        try await start(.question)
    }

    public func startDictation() async throws {
        try await start(.dictation)
    }

    private func start(_ kind: ListenKind) async throws {
        do {
            try await controller.startListening(kind)
        } catch VoiceController.VoiceError.stillSettingUp where prepareFailure.message != nil {
            // Setup failed earlier: say so, and retry in the background.
            Task { [weak self] in try? await self?.prepare() }
            throw VoicePortError("Voice setup failed. Trying again…", stillSettingUp: true) // the chip follows the retry
        } catch {
            throw Self.portError(error)
        }
    }

    public func interrupt(_ reason: ListenInterruption) async {
        let mapped: ListenStopReason = switch reason {
        case .screenLocked: .screenLocked
        case .systemSleep: .systemSleep
        case .screenSharing: .screenSharing
        case .typing: .typing
        case .confirmingDiscard: .confirmingDiscard
        }
        await controller.interrupt(mapped)
    }

    public func setSoundsEnabled(_ enabled: Bool) async { await controller.setSoundsEnabled(enabled) }

    public func finishListening() async throws -> String {
        do { return try await controller.finishListening() } catch { throw Self.portError(error) }
    }

    public func discard(confirmed: Bool, playSound: Bool) async -> VoiceDiscard {
        switch await controller.discard(confirmed: confirmed, playSound: playSound) {
        case .discarded: .discarded
        case .needsConfirmation(let seconds): .needsConfirmation(speechSeconds: seconds)
        case .nothingToDiscard: .nothingToDiscard
        }
    }

    public func sendHeld() async throws -> String? {
        do { return try await controller.sendHeld() } catch { throw Self.portError(error) }
    }

    public func speak(_ text: String, continuing: Bool) async throws -> Bool {
        try await controller.speak(text, continuing: continuing)
    }
    public func stopSpeaking() async { await controller.stopSpeaking() }
    public func play(_ sound: BuddySound) async { await controller.play(sound) }
    public func heardSpeechSeconds() async -> Double { await controller.heardSpeechSeconds() }

    static func message(for problem: MicProblem) -> String {
        switch problem {
        case .permissionDenied: "Microphone access is off. You can still type."
        case .silentInput: "The microphone isn't picking anything up."
        case .engineFailed: "The microphone stopped working."
        }
    }

    static func map(_ event: VoiceController.Event, lastProblem: String? = nil) -> VoiceEvent? {
        switch event {
        case .autoStopped(.micFailed, let held):
            .autoStopped(held: held, message: lastProblem ?? "The microphone stopped working.")
        // A revoked permission ends the listen with no auto-stop event after it: end it here.
        case .micProblem(.permissionDenied):
            .autoStopped(held: false, message: message(for: .permissionDenied))
        case .autoStopped(.confirmingDiscard, _): nil // the coordinator asked for this hold
        case .autoStopped(_, let held): .autoStopped(held: held, message: nil)
        case .micProblem(let problem): .micProblem(message(for: problem))
        case .speakingFinished: .speakingFinished
        case .nearLimit: .nearLimit
        case .transcribing(let long): .transcribing(long: long)
        case .prepare(let state): .setup(state)
        case .micRebuilt: nil
        case .replyVoiceProblem, .replyVoiceRecovered: nil // on `replyVoiceProblems`: a menu problem line
        }
    }

    /// One true line per voice error.
    static func portError(_ error: any Error) -> any Error {
        switch error as? VoiceController.VoiceError {
        case .stillSettingUp: VoicePortError("Still setting up voice.", stillSettingUp: true)
        // No voice chosen yet ("Not now, I'll type", or onboarding not done): nothing downloads
        // until the user sets it up.
        case .notSetUp: VoicePortError(notSetUp, notSetUp: true)
        case .recordingHeld: VoicePortError("A recording is waiting. Tap to send it, or press Esc to discard.")
        case .notListening: VoicePortError("I wasn't listening.")
        case .transcriptionTimedOut: VoicePortError("Speech recognition isn't responding. Try again in a moment, or type it.")
        default: error
        }
    }
}

/// The last prepare() failure, shared between the launch task and key presses.
final class PrepareFailure: Sendable {
    private let state = Mutex<String?>(nil)
    var message: String? { state.withLock { $0 } }
    func set(_ message: String?) { state.withLock { $0 = message } }
}

/// Stands in where voice isn't available (tests, previews): every listen fails with a true line.
public final class UnavailableVoice: VoicePort {
    public let levels: AsyncStream<VoiceLevel> = AsyncStream { $0.finish() }
    public let events: AsyncStream<VoiceEvent> = AsyncStream { $0.finish() }

    public init() {}

    public func prepare() async throws {}
    public func interrupt(_ reason: ListenInterruption) async {}
    public func setSoundsEnabled(_ enabled: Bool) async {}
    public func startListening() async throws { throw VoicePortError("Voice isn't set up yet.") }
    public func finishListening() async throws -> String { throw VoicePortError("Voice isn't set up yet.") }
    public func discard(confirmed: Bool, playSound: Bool) async -> VoiceDiscard { .nothingToDiscard }
    public func sendHeld() async throws -> String? { nil }
    public func speak(_ text: String, continuing: Bool) async throws -> Bool { false }
    public func stopSpeaking() async {}
    public func play(_ sound: BuddySound) async {}
}
