import BuddyAct
import BuddyCompanion
import BuddyContext
import BuddyCore
import BuddyKeys

extension AppRuntime {
    /// The dictation key's controller (keys stream), behind `LumiFeatures.dictation`. The key itself
    /// reaches the monitor through `EnginePreferences.keys.dictationKey`, set only with the flag.
    func makeDictation(_ coordinator: BuddyCoordinator, features: LumiFeatures) {
        guard features.dictation else { return }
        let preferences = preferences
        let inserter = LiveDictationInserter(inserter: TextInserter(
            isBlocked: { preferences.current.blocklist.isBlocked(bundleID: $0) }))
        coordinator.dictation = DictationController(
            voice: coordinator.voice, overlay: coordinator.overlay, inserter: inserter,
            // With the Panel's composer focused, dictation types there (makePanel runs first).
            panel: coordinator.pageFlow?.panel,
            pointer: coordinator.pointer, tracer: coordinator.tracer, history: dictationHistory,
            coordinatorPhase: { [weak coordinator] in coordinator?.phase ?? .idle })
        dictationHistory.available = true
        coordinator.dictation?.dictationKey = { preferences.current.dictationKey }
        // Words kept but not typed: a chip whose button opens the Dictation page.
        coordinator.dictation?.showSaved = { [weak coordinator] line in
            coordinator?.showChip(line, fix: .openDictationHistory)
        }
        coordinator.dictation?.onIdle = { [weak coordinator] in coordinator?.playNextReady() }
        coordinator.dictation?.moveTurnBehind = { [weak coordinator] in coordinator?.moveTurnBehind() ?? false }
        coordinator.dictation?.endGesture = { [weak self] in await self?.monitor?.endDictation() }
        // With a Studio composer focused, dictation types there (QA R8). studioSource lives as long
        // as the runtime; it says no composer is key unless Studio is on and focused.
        coordinator.dictation?.studio = studioSource
        // Any other Lumi field with the keyboard (Glance reply, search, rename, Settings): typed in
        // process, since Lumi can't paste into itself (U64).
        coordinator.dictation?.ownField = OwnFieldInserter()
    }
}
