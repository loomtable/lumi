import BuddyBridge
import BuddyCore
import BuddyTrace
import Foundation
import Synchronization

/// The session pool and its turns, built once at start when `LumiFeatures.sessions` is on.
public final class SessionEngine: Sendable {
    public let pool: SessionPool
    public let turns: LiveSessionTurns
    /// Tasks that follow the pool for the app (the read model's feed); cancelled on shutdown.
    private let feeds = Mutex<[Task<Void, Never>]>([])

    func keep(_ task: Task<Void, Never>) {
        feeds.withLock { $0.append(task) }
    }

    public init(pool: SessionPool, turns: LiveSessionTurns) {
        self.pool = pool
        self.turns = turns
    }

    /// Where live session processes are recorded, for the orphan sweep at the next launch.
    public static var ledgerFile: URL {
        BuddyCore.paths.sessionProcesses
    }

    /// Caps from the Mac's memory, the memory-pressure source, the orphan sweep (groups a crashed
    /// Lumi left), and open-session launches with the user's own settings.
    public static func make(claude: URL, environment: [String: String], plugin: URL, home: URL,
                            physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                            settings: @escaping @Sendable () -> SessionSettings,
                            hostsPermissions: Bool = false,
                            rules: any VoiceRulesLedger = MemoryVoiceRules(),
                            turnCount: @escaping @Sendable (SessionID) async -> Int = { _ in 1 },
                            onSent: @escaping LiveSessionTurns.Sent = { _, _, _, _, _ in },
                            recover: LiveSessionTurns.Recover? = nil,
                            ledger: ProcessLedger = ProcessLedger(file: SessionEngine.ledgerFile),
                            trace: TraceLog? = nil) -> SessionEngine {
        ledger.reapOrphans()
        var lifecycle: (@Sendable (PoolLifecycle) -> Void)?
        if let trace {
            lifecycle = { (event: PoolLifecycle) in
                if let reason = traceReason(event) {
                    trace.record(traceEvent(event), duration: traceDuration(event), outcome: nil, reason: reason)
                } else {
                    trace.record(traceEvent(event), duration: traceDuration(event))
                }
            }
        }
        let pool = SessionPool(caps: .forMemory(physicalMemory), spec: { launch in
            let mode = LaunchSpec.openPermissionMode(settingsFiles: LaunchSpec.openSettingsFiles(home: home, cwd: launch.cwd))
            return .open(executable: claude, launch: launch, permissionMode: mode, environment: environment)
        }, memoryPressure: MemoryPressure.events(), hostsPermissions: { hostsPermissions }, ledger: ledger,
           lifecycle: lifecycle)
        return SessionEngine(pool: pool, turns: LiveSessionTurns(pool: pool, plugin: plugin, settings: settings, rules: rules,
                                                                  turnCount: turnCount, onSent: onSent,
                                                                  recover: recover))
    }

    /// `sessionLaunched`/`sessionResumed` carry the start-up time (budgets 1.0 s / 1.2 s);
    /// `sessionSuspended` how long the session had been idle.
    static func traceEvent(_ e: PoolLifecycle) -> TraceEvent {
        switch e {
        case .launched(_, let resumed, _): resumed ? .sessionResumed : .sessionLaunched
        case .suspended: .sessionSuspended
        }
    }

    /// Why a session was suspended (idle, over the cap, memory pressure, …): the trace says, so a
    /// suspend can be told from one that shouldn't have happened.
    static func traceReason(_ e: PoolLifecycle) -> TraceReason? {
        guard case .suspended(_, _, let reason) = e else { return nil }
        return switch reason {
        case .idle: .suspendIdle
        case .cap: .suspendCap
        case .memoryPressure: .memoryPressure
        case .absorb: .absorb
        case .released: .released
        }
    }

    static func traceDuration(_ e: PoolLifecycle) -> Duration {
        switch e {
        case .launched(_, _, let startup): startup
        case .suspended(_, let idle, _): idle
        }
    }

    /// Quit: running turns are interrupted; returns the sessions that were mid-turn.
    public func shutdown() async -> Set<SessionID> {
        let midTurn = await pool.shutdownAll()
        feeds.withLock { $0.forEach { $0.cancel() }; $0 = [] }
        return midTurn
    }
}
