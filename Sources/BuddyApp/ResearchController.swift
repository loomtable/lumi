import AppKit
import BuddyBridge
import BuddyCore
import BuddyOverlay
import Foundation

/// What the controller needs from `ResearchManager`; tests use a fake.
public protocol ResearchRunning: Sendable {
    func subscribe() async -> AsyncStream<ResearchJob>
    func begin(_ request: ResearchRequest) async -> ResearchJob
    func cancel(_ id: UUID) async
    func cancelAll(conversation: String) async
}

extension ResearchManager: ResearchRunning {
    public func begin(_ request: ResearchRequest) -> ResearchJob { start(request) }
}

/// Research in the shell (Background task): starts jobs, keeps the capsule in step
/// with every job update, opens a finished report from the capsule, and stops jobs. Every value
/// the capsule shows is mapped 1:1 from the bridge's job.
@MainActor
public final class ResearchController {
    /// A job finished with its report: the shell plays the done chime and speaks `job.say`
    /// (or `ResearchController.readyLine`).
    public var onDone: ((ResearchJob) -> Void)?
    /// A job to keep against its conversation, so Forget, retention and leaving temporary mode
    /// delete its report: when first seen, when it learns its session id, and when it ends (its
    /// report may be written after its conversation was forgotten).
    public var onRecord: ((ResearchJob) -> Void)?
    private var recordedSessions: [UUID: String?] = [:]

    private let runner: any ResearchRunning
    private let overlay: any OverlayPresenting
    private let model: @MainActor () -> ModelID
    private let color: @MainActor (String) -> ConversationColor
    private let linger: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let openFile: @MainActor (URL) -> Void
    /// Every job the capsule may show, in start order.
    private(set) var jobs: [ResearchJob] = []
    private var listener: Task<Void, Never>?
    private var lingering: [UUID: Task<Void, Never>] = [:]
    /// The Research model each job started with, for its report card's header.
    private var models: [UUID: ModelID] = [:]

    /// `model`: the Research model now, for the report card's header. `color`: a conversation's
    /// colour. `linger`: how long a failed or cancelled job stays in the capsule. `openFile`: opens
    /// a report that has no `buddy` block in the user's Markdown app.
    public init(runner: any ResearchRunning, overlay: any OverlayPresenting,
                model: @escaping @MainActor () -> ModelID,
                color: @escaping @MainActor (String) -> ConversationColor = { _ in .ember },
                linger: Duration = .seconds(8),
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                openFile: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.runner = runner
        self.overlay = overlay
        self.model = model
        self.color = color
        self.linger = linger
        self.sleep = sleep
        self.openFile = openFile
    }

    /// Subscribes to job updates. Call once at launch.
    public func activate() {
        guard listener == nil else { return }
        let runner = runner
        listener = Task { [weak self] in
            for await job in await runner.subscribe() {
                guard let self else { return }
                self.apply(job)
            }
        }
    }

    deinit { listener?.cancel() }

    /// A `.research` start or a hand-off to Research.
    @discardableResult
    public func start(_ request: ResearchRequest) async -> ResearchJob {
        let startedWith = model()
        let job = await runner.begin(request)
        models[job.id] = startedWith
        // The listener may already hold a newer state of this job (the manager reports
        // "running" before `begin` returns): the returned copy only adds a job not seen yet.
        if !jobs.contains(where: { $0.id == job.id }) { apply(job) }
        return job
    }

    /// Esc on a conversation, or the conversation cleared: stops its jobs.
    public func cancelAll(conversation: String) async {
        await runner.cancelAll(conversation: conversation)
    }

    /// The capsule's own events. Returns true when it handled `event`.
    @discardableResult
    public func handle(_ event: OverlayEvent) async -> Bool {
        switch event {
        case .stopResearch(let id):
            await runner.cancel(id)
            return true
        case .openReport(let id):
            openReport(id)
            return true
        default:
            return false
        }
    }

    /// Shows a finished job's result, popping out of the capsule, then drops it from the capsule.
    /// A report without a `buddy` block has no card to show, so the Markdown report itself opens.
    func openReport(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .done else { return }
        if let block = job.block {
            overlay.showAnswer(Answer(block: block, lane: Lane(mode: .research, model: models[id] ?? model()),
                                      conversation: color(job.conversationID), turn: 0, replyHint: ""),
                               anchor: .capsule)
        } else {
            openFile(job.reportPath)
        }
        remove(id)
    }

    /// The spoken line when the job's block had none ("Your research on QT is ready").
    public static func readyLine(_ job: ResearchJob) -> String { "Your research on \(job.topic) is ready." }

    // MARK: Job updates

    func apply(_ job: ResearchJob) {
        let ended = job.state == .done || job.state == .cancelled || { if case .failed = job.state { true } else { false } }()
        if ended, recordedSessions[job.id] != nil {
            recordedSessions[job.id] = nil
            onRecord?(job)
        } else if !ended, recordedSessions[job.id] != .some(job.sessionID) {
            recordedSessions[job.id] = .some(job.sessionID)
            onRecord?(job)
        }
        let previous = jobs.first { $0.id == job.id }
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[i] = job
        } else {
            // A job that was already removed (opened or lingered out) isn't brought back by a
            // late update; a new one is added.
            guard !removed.contains(job.id) else { return }
            jobs.append(job)
        }
        switch job.state {
        case .done where previous?.state != .done:
            onDone?(job)
        case .failed, .cancelled:
            scheduleRemoval(job.id)
        default:
            break
        }
        publish()
    }

    private var removed: Set<UUID> = []

    private func scheduleRemoval(_ id: UUID) {
        guard lingering[id] == nil else { return }
        let sleep = sleep, linger = linger
        lingering[id] = Task { [weak self] in
            await sleep(linger)
            guard !Task.isCancelled else { return }
            self?.remove(id)
        }
    }

    private func remove(_ id: UUID) {
        lingering[id]?.cancel()
        lingering[id] = nil
        removed.insert(id)
        jobs.removeAll { $0.id == id }
        models[id] = nil
        publish()
    }

    private func publish() {
        overlay.updateCapsule(jobs.map(Self.capsule))
        onJobsChange?(jobs)
    }

    /// Told whenever the capsule's jobs change (the menu bar pulses while one is working).
    public var onJobsChange: (([ResearchJob]) -> Void)?

    /// BuddyBridge's job → the overlay's capsule state, field for field.
    nonisolated static func capsule(_ job: ResearchJob) -> CapsuleState {
        let status: CapsuleState.Status = switch job.state {
        case .queued: .queued
        case .running: .running(CapsuleState.Phase(rawValue: job.phase.rawValue) ?? .planning)
        case .done: .done
        case .failed(let why): .failed(why)
        case .cancelled: .cancelled
        }
        let duration = job.startedAt.flatMap { start in job.finishedAt.map { $0.timeIntervalSince(start) } }
        return CapsuleState(id: job.id, topic: job.topic, status: status, sourceCount: job.sourceCount,
                            steps: job.steps, reconnecting: job.reconnecting, duration: duration)
    }
}

extension ResearchController {
    /// The real manager: each job in its own folder under `reportsDir`, sandboxed
    /// (`LaunchSpec.research`). `config` is read per job, so a Settings › Models change applies
    /// to the next job. Reads under `~/.claude/` and the plugin folder aren't sources.
    public static func manager(executable: URL, plugin: URL, reportsDir: URL, home: URL,
                               environment: [String: String], maxConcurrent: Int = ResearchManager.maxConcurrent,
                               config: @escaping @Sendable () -> ModeConfig) -> ResearchManager {
        ResearchManager(
            reportsDir: reportsDir,
            spec: { jobDir, reportPath, resume in
                .research(executable: executable, jobDir: jobDir, reportPath: reportPath, plugin: plugin,
                          resume: resume, config: config(), environment: environment)
            },
            maxConcurrent: maxConcurrent,
            ignoredPrefixes: [home.appending(path: ".claude").path + "/", plugin.path + "/"])
    }

    /// `~/Library/Application Support/<bundle id>/reports`.
    public static var reportsDirectory: URL {
        BuddyCore.paths.reports
    }
}
