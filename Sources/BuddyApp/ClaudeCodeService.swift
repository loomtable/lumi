import BuddyBridge
import BuddyCompanion
import Foundation
import Observation

/// Settings › Claude Code's data: the last real check of the user's install,
/// and the plugin's load errors from sessions. Probing runs off the
/// launch path and takes up to ~20 s.
@MainActor
@Observable
public final class ClaudeCodeService {
    /// What the pane shows. `checked` stays false ("Checking…") until the first probe lands.
    public private(set) var status = ClaudeCodeStatus()

    private let probe: @Sendable () async -> ClaudeCodeReport
    private let install: @Sendable () throws -> URL
    private let restartLanes: @MainActor () async -> Void
    @ObservationIgnored private var report: ClaudeCodeReport?
    @ObservationIgnored private var pluginErrors: [String] = []
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Called after each finished check with the new status (the runtime starts the engine when
    /// Claude Code turns up after a launch that couldn't find it).
    @ObservationIgnored public var onChecked: (@MainActor (_ previous: ClaudeCodeStatus, _ new: ClaudeCodeStatus) -> Void)?

    /// `probe`: one full check (`ClaudeCodeProbe().check(…)` with the launch environment).
    /// `install`: BuddyBridge's `PluginInstaller.install()`. `restartLanes`: restart the warm Quick processes
    /// and any idle Deep session, which loaded the old plugin.
    public init(probe: @escaping @Sendable () async -> ClaudeCodeReport,
                install: @escaping @Sendable () throws -> URL,
                restartLanes: @escaping @MainActor () async -> Void) {
        self.probe = probe
        self.install = install
        self.restartLanes = restartLanes
    }

    /// The pane's buttons.
    public var actions: ClaudeCodeActions {
        ClaudeCodeActions(refresh: { [weak self] in await self?.refresh() },
                          repairPlugin: { [weak self] in try await self?.repairPlugin() })
    }

    /// Runs the check; a second call while one runs waits for it rather than starting another.
    public func refresh() async {
        if let inFlight { return await inFlight.value }
        let probe = probe
        let task = Task { [weak self] in
            let report = await probe()
            guard let self else { return }
            self.report = report
            // Cleared before the task finishes, so a caller awaiting it sees no check running.
            self.inFlight = nil
            let previous = self.status
            self.publish()
            self.onChecked?(previous, self.status)
        }
        inFlight = task
        await task.value
    }

    /// "Repair plugin": a fresh copy of the bundled plugin, every process restarted onto it,
    /// then a new check. A check that started before the copy is waited out, not reused, so
    /// the pane never shows the old plugin's result. A failed copy keeps the old plugin and
    /// throws to the pane.
    public func repairPlugin() async throws {
        _ = try install()
        pluginErrors = []
        if let stale = inFlight { await stale.value }
        await restartLanes()
        await refresh()
    }

    /// A check that starts now: one already running (from before an install, say) is waited
    /// out rather than reused. Onboarding's "Check again", its re-check and its first look use this.
    public func checkAfresh() async {
        if let stale = inFlight { await stale.value }
        await refresh()
    }

    /// From each session's `system/init`: the buddy plugin's load errors (empty clears them).
    public func pluginLoaded(errors: [StreamEvent.PluginError]) {
        let mine = errors.filter { $0.plugin == "buddy" }.map { "\($0.type): \($0.message)" }
        guard mine != pluginErrors else { return }
        pluginErrors = mine
        publish()
    }

    private func publish() {
        if let report { status = ClaudeCodeStatus(report: report, pluginErrors: pluginErrors) }
    }
}
