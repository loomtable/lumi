import BuddyBridge
import BuddyConversations
import BuddyCore
import BuddyOverlay
import Foundation

extension AppRuntime {
    /// The conversation Panel, its page flow and the permission host (LumiFeatures.panel).
    /// `sessions` gives composer sends their open launch (and a continued Quick session's recap);
    /// the session pool answers approvals and stops teammates. Without the store a composer send
    /// fails in the page.
    func makePanel(_ coordinator: BuddyCoordinator, features: LumiFeatures, sessions: LiveSessions?) {
        guard features.panel else { return }
        // The pool answers approvals and stops teammates; without it (sessions off) asks stay
        // pending and nothing is sent.
        let pool = sessionEngine?.pool
        let answering: any PermissionAnswering = pool ?? NoPermissionAnswering()
        let stopTeammate: @MainActor (SessionID, String) async -> Void = { id, task in await pool?.stopTask(task, session: id) }
        ContinueInPanel.enabled = true
        let panel = LivePanel()
        panel.composerFolders = { [weak sessions] id in await sessions?.folders(of: id) ?? [] }
        let flow = PageFlow(panel: panel, turns: coordinator.turns, permissions: LivePermissionHost(answering: answering),
                            sessions: sessions)
        flow.makeRequest = { [weak coordinator] id, submit in
            if let prompt = submit.replacing {
                guard let sessions, let pool, await Self.rewind(id, prompt: prompt, sessions: sessions, pool: pool) else { return nil }
            }
            guard let plan = await sessions?.composerPlan(id) else { return nil }
            return await coordinator?.pageRequest(id, submit, plan: plan)
        }
        flow.stopTeammate = stopTeammate
        flow.history = { [weak sessions] id in await sessions?.transcript(id) ?? [] }
        flow.onContinue = { [weak self] id in await self?.continueInterrupted(id) }
        flow.newSession = { [weak sessions] in
            await sessions?.plan(SummonInput(source: .newSession, kind: .typed, command: .newSession, now: Date()), packet: nil).id
        }
        if let pool { flow.liveEvents = { id in Self.relay(pool, id) } }
        let preferences = preferences
        let settings: () -> DeliverySettings = { DeliverySettings(preferences.current.sessions) }
        flow.settings = settings
        flow.onSpeak = { [weak coordinator] text, continuing in coordinator?.speakInPage(text, continuing: continuing) }
        flow.onMic = { [weak coordinator] id, down in Task { await coordinator?.pageMic(down: down, session: id) } }
        flow.onExpand = { [weak self] id in self?.onOpenStudioSession?(id) }
        flow.progress = coordinator.progress
        flow.trace = { [weak coordinator] event, ran, outcome in
            coordinator?.tracer?.record(event, duration: ran, lane: .deep, outcome: outcome, count: nil)
        }
        coordinator.progress.visiblePages = { [weak flow] in flow?.visiblePages ?? [:] }
        coordinator.progress.snapshot = { [weak flow] id in flow?.snapshot(for: id) }
        coordinator.progress.live = sessions
        coordinator.onOpenWaiting = { [weak flow, weak sessions] id in
            guard let flow, let sessions, let snapshot = sessions.snapshots.first(where: { $0.id == id }) else { return }
            Task { flow.show(snapshot, history: await sessions.transcript(id)) }
        }
        coordinator.pageFlow = flow
        coordinator.pages = flow
        coordinator.delivery = RoutedDelivery(visiblePages: { [weak flow] in flow?.focusedPages ?? [:] }, settings: settings)
        flow.start()
    }

    /// An edited prompt: the session's `claude` is relaunched at just before it, then the store
    /// drops it and everything after. False, with nothing dropped, when it can't: the session works
    /// (a turn the CLI started may run), there's no point to go back to, or the relaunch failed.
    static func rewind(_ id: SessionID, prompt: String, sessions: LiveSessions, pool: SessionPool) async -> Bool {
        guard await !pool.isWorking(id), let point = await sessions.rewindPoint(id, prompt: prompt) else { return false }
        if case .resume(let claude, let at) = point {
            guard let launch = await sessions.composerPlan(id)?.launch, launch.claudeSession == claude,
                  await pool.rewind(id, launch: launch, to: at) else { return false }
        }
        return await sessions.commitRewind(id, prompt: prompt, point)
    }
}
