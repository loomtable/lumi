import BuddyBridge
import BuddyConversations
import BuddyCore
import Foundation

extension AppRuntime {
    /// The session store and the session engine (foundation and engine-core). With
    /// `LumiFeatures.sessions` on, turns are routed by SummonRouter over the session store; the
    /// engine half (the pool) is still a stub.
    func makeSessionEngine(_ coordinator: BuddyCoordinator, features: LumiFeatures) {
        guard features.sessions, let manager = conversationManager, let conversations, let savedIndex else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let trust: @Sendable () -> FolderTrust = { FolderTrust.load(home: home) }
        let sessions = LiveSessions(store: SessionStore(index: savedIndex), manager: manager, trust: trust)
        // Typed asks open sessions only with the Panel to show their Markdown (QA R4).
        sessions.typedOpensSessions = features.panel
        self.sessions = sessions
        studioSource.attach(sessions)
        connectSessionEngine(to: sessions)
        coordinator.routing = SessionRouting(sessions: sessions, conversations: conversations, trust: trust)
        // V-02: a new press or the switcher moves a running turn to the background, never cancels it.
        // The session the Glance shows counts as on screen, so a turn moved behind lands unread.
        coordinator.turnsKeepRunning = true
        coordinator.onFrontChanged = { [weak sessions, weak coordinator] in sessions?.glanceSession = coordinator?.glanceSession }
        sessions.onGone = { [weak coordinator] id in coordinator?.dropReady(for: id) }
        Task {
            await sessions.setStore(SessionStore(index: await manager.activeIndex))
            sessions.policy.idleLimit = preferences.current.idleTimeout
            sessions.maxSubagents = preferences.current.sessions.maxSubagents
        }
    }

    /// The pool half of the session engine, built before the cascade (Quick's hand-off goes to it):
    /// caps from the Mac's memory, the memory-pressure source, the orphan sweep and open-session
    /// launches with the user's own settings. Nil, and nothing changes, with `LumiFeatures.sessions` off.
    func makeSessionPool(claude: URL, environment: [String: String], plugin: URL, home: URL,
                         features: LumiFeatures) -> SessionEngine? {
        guard features.sessions else { return nil }
        let preferences = preferences
        let store = conversationManager.map(StoreVoiceRules.init(manager:))
        let engine = SessionEngine.make(
            claude: claude, environment: environment, plugin: plugin, home: home,
            settings: { preferences.current.sessions },
            // Read once at launch (QA R21), like every other flag.
            hostsPermissions: features.permissionHost,
            rules: store ?? MemoryVoiceRules(),
            turnCount: { id in await store?.turnCount(id) ?? 1 },
            onSent: { [weak self] uuid, kind, shown, claudeSession, id in
                await self?.recordSessionTurn(uuid: uuid, kind: kind, shown: shown, claudeSession: claudeSession, in: id)
            },
            recover: { [weak self] id, _ in await self?.recoverLostSession(id) },
            trace: traceLog)
        sessionEngine = engine
        return engine
    }

    /// A session's live events for a page: the pool's stream (it replays the current state first).
    nonisolated static func relay(_ pool: SessionPool, _ id: SessionID) -> AsyncStream<SessionEvent> {
        AsyncStream { out in
            let task = Task {
                for await event in await pool.events(for: id) { out.yield(event) }
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    /// QA E1: the session's Claude session is gone. The store forgets it and mints a new one,
    /// seeded with the recap; the turn is sent again there.
    private func recoverLostSession(_ id: SessionID) async -> (SessionLaunch, String?)? {
        guard let sessions else { return nil }
        sessions.claudeSessionLost(id)
        guard let plan = await sessions.composerPlan(id), let launch = plan.launch else { return nil }
        return (launch, plan.seed)
    }

    /// "Interrupted · Continue" (U11): the interrupted turn resumes with its own kind and uuid. Nil
    /// without the engine or the store, or when the session has no open Claude session to resume.
    func continueInterrupted(_ id: SessionID) async -> AsyncStream<TurnStreamEvent>? {
        guard let engine = sessionEngine, let sessions, let launch = await sessions.launch(for: id), launch.exists,
              let manager = conversationManager else { return nil }
        let last = await StoreVoiceRules(manager: manager).lastTurn(id)
        let events = await engine.turns.resume(id, launch: launch, kind: last?.kind ?? .typed, uuid: last?.uuid)
        return AsyncStream { out in
            let relay = Task { [weak sessions] in
                for await event in events {
                    // Nothing was left to resume (QA R22): the turn shows Interrupted again, and the
                    // session stays Interrupted, instead of spinning.
                    if case .turnEnded(let end) = event, case .unavailable(SessionPool.nothingToResume)? = end.error?.reason {
                        await sessions?.markInterrupted([id])
                        out.yield(.session(.processEnded(status: 0, midTurn: true)))
                        continue
                    }
                    out.yield(.session(event))
                }
                out.finish()
            }
            out.onTermination = { _ in relay.cancel() }
        }
    }

    private func recordSessionTurn(uuid: String, kind: TurnKind, shown: String, claudeSession: UUID, in id: SessionID) async {
        await sessions?.recordSent(userUUID: uuid, kind: kind, shown: shown, claudeSession: claudeSession, in: id)
    }

    /// The read model follows every session's events (background ones too), and the pool keeps the
    /// pinned and on-screen sessions warm.
    func connectSessionEngine(to sessions: LiveSessions) {
        studioSource.hooks.transcript = { [weak sessions] id in await sessions?.transcript(id) ?? [] }
        guard let engine = sessionEngine else { return }
        let pool = engine.pool
        studioSource.hooks.events = { id in Self.relay(pool, id) }
        engine.keep(Task { [weak sessions] in
            for await e in await pool.allEvents() { sessions?.apply(e.event, to: e.id) }
        })
        let changes = sessions.changes()
        engine.keep(Task { [weak sessions] in
            for await snapshots in changes {
                await pool.setPinned(Set(snapshots.filter(\.pinned).map(\.id)))
                await pool.setOnScreen(sessions?.onScreen ?? [])
            }
        })
    }

    /// Quick's hand-off into an open session: LiveSessions resolves the conversation's session (built
    /// after the cascade, so it's read at hand-off time). Nil keeps the Deep lane: a legacy
    /// conversation, or sessions not up yet.
    func sessionHandoff(_ engine: SessionEngine?) -> OpenHandoffRunner? {
        engine?.turns.handoff(resolve: { [weak self] state in await self?.sessions?.handoffLaunch(conversation: state.id) })
    }

    /// Quit: interrupts running turns and stops every session process; the sessions that were
    /// mid-turn show "Interrupted · Continue" next launch.
    func shutdownSessions() async {
        guard let engine = sessionEngine else { return }
        sessionEngine = nil
        await sessions?.markInterrupted(await engine.shutdown())
    }
}
