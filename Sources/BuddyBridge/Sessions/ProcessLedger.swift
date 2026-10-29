import Darwin
import Foundation

/// Which process a pid named when it was recorded: its start time and executable. A pid that is
/// reused later belongs to a process with a different start time (and usually path).
public struct ProcessIdentity: Codable, Sendable, Equatable {
    /// Start time, in microseconds since 1970 (`kinfo_proc.kp_proc.p_starttime`).
    public var start: Int64
    public var path: String

    public init(start: Int64, path: String) {
        self.start = start
        self.path = path
    }
}

/// The process groups of live session processes, on disk, so a Lumi that crashed doesn't leave
/// `claude` processes (and their MCP servers) running. Each pid is kept with its identity at
/// launch; at the next launch a group is stopped only if its leader is still that same `claude`
/// process (same start time, same executable). A reused pid may belong to anything by then, even
/// the user's own `claude` in a terminal, so any mismatch is skipped (11-REUSE §7, QA gate 4.10).
public struct ProcessLedger: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var pid: pid_t
        public var identity: ProcessIdentity
    }

    public let file: URL
    /// The live process table: a pid's identity now, or nil when no such process.
    private let table: @Sendable (pid_t) -> ProcessIdentity?

    public init(file: URL, table: @escaping @Sendable (pid_t) -> ProcessIdentity? = ProcessLedger.identity) {
        self.file = file
        self.table = table
    }

    /// Records a child just spawned. One whose identity can't be read isn't recorded, so it can
    /// never be signalled later.
    public func record(_ pid: pid_t) {
        var entries = read()
        guard !entries.contains(where: { $0.pid == pid }), let identity = table(pid) else { return }
        entries.append(Entry(pid: pid, identity: identity))
        write(entries)
    }

    public func remove(_ pid: pid_t) {
        let entries = read()
        guard entries.contains(where: { $0.pid == pid }) else { return }
        write(entries.filter { $0.pid != pid })
    }

    /// Stops what a crashed Lumi left behind and clears the ledger. Returns the groups signalled:
    /// only those whose leader is the very process recorded, and a `claude`.
    @discardableResult
    public func reapOrphans(stop: (pid_t) -> Void = { _ = killpg($0, SIGTERM) }) -> [pid_t] {
        let orphans = read().filter { entry in
            guard let now = table(entry.pid) else { return false }
            return now == entry.identity && Self.isClaude(path: now.path)
        }.map(\.pid)
        orphans.forEach(stop)
        try? FileManager.default.removeItem(at: file)
        return orphans
    }

    /// The recorded entries. A file in any other shape (an earlier build's bare pids) reads as
    /// empty: nothing unverified is ever signalled.
    func read() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// A `claude` executable: the native installer's `…/claude/versions/<v>`, or a `claude`
    /// binary on PATH.
    static func isClaude(path: String) -> Bool {
        path.lowercased().contains("claude")
    }

    /// `pid`'s start time (sysctl `KERN_PROC_PID`) and executable (`proc_pidpath`); nil when it
    /// isn't running or either can't be read.
    public static func identity(_ pid: pid_t) -> ProcessIdentity? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return ProcessIdentity(start: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec), path: path)
    }
}
