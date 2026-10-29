import Foundation

/// How to start or resume the `claude` process that holds one open Claude session. Lumi mints the
/// Claude session id: `--session-id` on the first launch, `--resume` after.
public struct SessionLaunch: Sendable, Equatable {
    public var claudeSession: UUID
    /// False: `--session-id`; true: `--resume`.
    public var exists: Bool
    /// Home or a trusted folder only.
    public var cwd: URL
    /// Every stored directory, passed again on every launch as `--add-dir`.
    public var addDirs: [URL]
    /// `CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1` (Continue only).
    public var continueInterrupted: Bool
    /// Settings › Teammates, default 3.
    public var maxSubagents: Int
    /// `--resume-session-at` (an edited prompt): set by the pool for the launches until the CLI
    /// takes the edited prompt (`SessionPool.rewind`), never by callers.
    public var resumeAt: String?

    public init(claudeSession: UUID, exists: Bool, cwd: URL, addDirs: [URL] = [], continueInterrupted: Bool = false, maxSubagents: Int = 3) {
        self.claudeSession = claudeSession
        self.exists = exists
        self.cwd = cwd
        self.addDirs = addDirs
        self.continueInterrupted = continueInterrupted
        self.maxSubagents = maxSubagents
    }
}
