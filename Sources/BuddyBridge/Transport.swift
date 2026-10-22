import Foundation
import Synchronization

/// A running `claude` process seen as lines out and lines in. The real one wraps `Process`;
/// tests and the replay harness use `ReplayTransport`.
public protocol ClaudeTransport: Sendable {
    /// stdout, one JSON object per line. Finishes when the process exits or stdout closes.
    var lines: AsyncStream<Data> { get }
    /// Writes one stdin line (the caller adds the newline) off the caller's executor: a
    /// screenshot is megabytes against a 64 KB pipe. Throws once the process is gone.
    func send(_ line: Data) async throws
    /// Closes stdin after any write in progress (never under a running write).
    func closeInput()
    /// SIGTERM, then SIGKILL if it is still running after a grace period. No `result` is
    /// written for a turn in progress (S4 docs check).
    func terminate()
    /// The exit status, once the process has exited.
    func exitStatus() async -> Int32
    /// The last few hundred bytes of stderr, for error details.
    var stderrTail: String { get }
    /// Whether the other end is a real `claude` that answers an `initialize` control request once
    /// it has started up. Fakes don't.
    var answersStartupHandshake: Bool { get }
}

extension ClaudeTransport {
    public var answersStartupHandshake: Bool { false }
}

public enum TransportError: Error, Equatable {
    case launchFailed(String)
    case inputClosed
}

/// `claude` as a child process, in its own process group so stopping it also stops the hooks,
/// MCP servers, browsers and shell commands it started (not children that move themselves into
/// a new session or group with setsid/setpgid, such as some browsers' helpers).
public final class ProcessTransport: ClaudeTransport {
    public var answersStartupHandshake: Bool { true }

    public let lines: AsyncStream<Data>
    let pid: pid_t
    private let stdin: FileHandle
    /// The read ends must outlive `init`: if they deallocate, they close, and the child dies of
    /// SIGPIPE on its next write (Foundation's `Process` used to keep them alive).
    private let stdoutRead: FileHandle
    private let stderrRead: FileHandle
    private let state: Shared<State>
    /// True once the child has been reaped. After that its pid (= its group id) may be reused by
    /// an unrelated process, so nothing may signal the group any more.
    private let reaped: Shared<Bool>

    private struct State {
        var stderr = Data()
        var exit: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    }

    /// After the process exits, how long to keep reading stdout before giving up on EOF. A hook
    /// or MCP grandchild that inherited the pipe can hold it open indefinitely.
    static let drainAfterExit: Duration = .milliseconds(500)

    public convenience init(spec: LaunchSpec) throws {
        try self.init(executable: spec.executable, arguments: spec.arguments,
                      workingDirectory: spec.workingDirectory, environment: spec.environment)
    }

    /// Any line-oriented program; tests use `/bin/cat`.
    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) throws {
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        // EPIPE instead of SIGPIPE when writing to a child that already exited.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let pid = try Self.spawn(executable: executable.path, arguments: arguments, directory: workingDirectory.path,
                                 environment: environment,
                                 stdin: stdinPipe.fileHandleForReading.fileDescriptor,
                                 stdout: stdoutPipe.fileHandleForWriting.fileDescriptor,
                                 stderr: stderrPipe.fileHandleForWriting.fileDescriptor)
        // The child has its own copies; close ours so EOF arrives when it exits.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        self.lines = lines
        self.pid = pid
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdoutRead = stdoutPipe.fileHandleForReading
        self.stderrRead = stderrPipe.fileHandleForReading
        let state = Shared(State())
        self.state = state

        let splitter = Shared(LineSplitter())
        stdoutPipe.fileHandleForReading.readabilityHandler = Self.stdoutHandler(splitter: splitter, continuation: continuation)
        stderrPipe.fileHandleForReading.readabilityHandler = Self.stderrHandler(state: state)

        let reaped = Shared(false)
        self.reaped = reaped
        // The source keeps itself alive (through `holder`) until it has reaped the child, so a
        // transport dropped early never leaves a zombie; it cancels itself after the reap.
        let holder = Shared<SourceBox?>(nil)
        let reap = Self.reaper(pid: pid, reaped: reaped, holder: holder, state: state, stdout: stdoutPipe.fileHandleForReading,
                               splitter: splitter, continuation: continuation)
        // One serial queue for every reap attempt: the source's events and the first check.
        let exitQueue = DispatchQueue(label: "BuddyBridge.exit")
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: exitQueue)
        holder.withLock { $0 = SourceBox(source: source) }
        source.setEventHandler(handler: reap)
        source.resume()
        // If it exited before the source was armed, the event may never come: check once.
        exitQueue.async(execute: reap)
    }

    /// Holds the process source; `DispatchSourceProcess` is thread-safe to cancel from its handler.
    struct SourceBox: @unchecked Sendable {
        let source: any DispatchSourceProcess
    }

    /// posix_spawn into a new process group (pgid = pid), with only the three pipes inherited and
    /// default signal handling.
    private static func spawn(executable: String, arguments: [String], directory: String, environment: [String: String],
                              stdin: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TransportError.launchFailed("no such folder: \(directory)")
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else { throw TransportError.launchFailed("\(executable): \(String(cString: strerror(rc)))") }
        return pid
    }

    private let writeQueue = DispatchQueue(label: "BuddyBridge.stdin")

    public func send(_ line: Data) async throws {
        let stdin = stdin
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                do {
                    try stdin.write(contentsOf: line)
                    c.resume()
                } catch {
                    c.resume(throwing: TransportError.inputClosed)
                }
            }
        }
    }

    /// Runs on the write queue, after any write in progress, so the fd is never closed (and
    /// reused) under a running write. Call `terminate()` first to unblock a stuck write.
    public func closeInput() {
        let stdin = stdin
        writeQueue.async { try? stdin.close() }
    }

    static let killGrace: Duration = .seconds(2)

    /// SIGTERM to the whole process group, then SIGKILL if `claude` is still there after the
    /// grace period. Does nothing once the child has been reaped (its pid may belong to someone
    /// else by then); leftover group members are swept at the reap instead.
    public func terminate() {
        let pid = pid, grace = Self.killGrace, reaped = reaped
        // Check and signal under the reaper's lock: the pid can't be reaped (and reused) between.
        let sent = reaped.withLock { done -> Bool in
            if done { return false }
            killpg(pid, SIGTERM)
            return true
        }
        guard sent else { return }
        Task.detached {
            try? await Task.sleep(for: grace)
            reaped.withLock { done in if !done { killpg(pid, SIGKILL) } }
        }
    }

    public func exitStatus() async -> Int32 {
        await withCheckedContinuation { c in
            let done: Int32? = state.withLock { s in
                if let exit = s.exit { return exit }
                s.exitWaiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    public var stderrTail: String {
        state.withLock { String(decoding: $0.stderr.suffix(600), as: UTF8.self) }
    }

    // Callbacks run on Foundation's threads. They are built here, outside any actor, and
    // only touch Sendable state (Mutex, AsyncStream.Continuation).

    nonisolated static func stdoutHandler(splitter: Shared<LineSplitter>,
                                          continuation: AsyncStream<Data>.Continuation) -> @Sendable (FileHandle) -> Void {
        { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if let last = splitter.withLock({ $0.finish() }) { continuation.yield(last) }
                continuation.finish()
                return
            }
            for line in splitter.withLock({ $0.append(chunk) }) { continuation.yield(line) }
        }
    }

    private nonisolated static func stderrHandler(state: Shared<State>) -> @Sendable (FileHandle) -> Void {
        { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            state.withLock { s in
                s.stderr.append(chunk)
                if s.stderr.count > 4096 { s.stderr = s.stderr.suffix(2048) }
            }
        }
    }

    /// Exit status as a shell reports it: a signal kill is 128 + signal (SIGTERM → 143).
    static func shellStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Reaps the child once it has exited. Before reaping, while the exited leader still holds its
    /// pid, it SIGKILLs whatever is left in its group (MCP servers, hooks), which is safe then.
    private nonisolated static func reaper(pid: pid_t, reaped: Shared<Bool>, holder: Shared<SourceBox?>, state: Shared<State>,
                                           stdout: FileHandle, splitter: Shared<LineSplitter>,
                                           continuation: AsyncStream<Data>.Continuation) -> @Sendable () -> Void {
        {
            // Check, sweep, reap and mark under one lock (all non-blocking), so `terminate` can
            // never signal a pid that has been reaped in between.
            let status: Int32? = reaped.withLock { done in
                if done { return nil }
                var info = siginfo_t()
                guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid else { return nil }
                killpg(pid, SIGKILL)
                var raw: Int32 = 0
                guard waitpid(pid, &raw, WNOHANG) == pid else { return nil }
                done = true
                return raw
            }
            guard let status else { return }
            holder.withLock { box in
                box?.source.cancel()
                box = nil
            }
            recordExit(shellStatus(status), state: state, stdout: stdout, splitter: splitter, continuation: continuation)
        }
    }

    private nonisolated static func recordExit(_ status: Int32, state: Shared<State>, stdout: FileHandle,
                                               splitter: Shared<LineSplitter>, continuation: AsyncStream<Data>.Continuation) {
        let waiters = state.withLock { s in
            s.exit = status
            defer { s.exitWaiters = [] }
            return s.exitWaiters
        }
        for w in waiters { w.resume(returning: status) }
        Task.detached {
            try? await Task.sleep(for: drainAfterExit)
            // Lines a handler call yields after this point are dropped: the process is gone.
            stdout.readabilityHandler = nil
            if let last = splitter.withLock({ $0.finish() }) { continuation.yield(last) }
            continuation.finish()
        }
    }
}

/// Plays recorded stream-json back: the replay harness for UI work, and the fake for tests.
/// Each `send` releases the lines up to and including the next `result`, like a real turn.
public final class ReplayTransport: ClaudeTransport {
    public let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let state: Shared<Replay>
    private let pacing: Duration

    private struct Replay {
        var pending: [Data]
        var wholeStream = false
        var releasing: Task<Void, Never>?
        var sent: [Data] = []
        var closed = false
        var exit: Int32?
        var stderr = ""
    }

    /// `preamble` lines (hooks before the first input) are emitted at once; the rest wait for
    /// input. `pacing` delays each line, to watch the UI animate.
    /// `wholeStream`: the first send plays everything that follows, for recordings in which the
    /// session continued on its own (background subagents) after a turn's first result.
    public init(lines recorded: [Data], pacing: Duration = .zero, wholeStream: Bool = false) {
        (lines, continuation) = AsyncStream<Data>.makeStream()
        self.pacing = pacing
        var pending = recorded
        let firstInit = pending.firstIndex { line in
            if case .initialized = StreamEvent(line: line) { return true }
            return false
        } ?? 0
        let preamble = pending[..<firstInit]
        pending.removeFirst(firstInit)
        state = Shared(Replay(pending: pending, wholeStream: wholeStream))
        for line in preamble { continuation.yield(line) }
    }

    public convenience init(fixture url: URL, pacing: Duration = .zero, wholeStream: Bool = false) throws {
        var splitter = LineSplitter()
        let data = try Data(contentsOf: url)
        var lines = splitter.append(data)
        if let last = splitter.finish() { lines.append(last) }
        self.init(lines: lines, pacing: pacing, wholeStream: wholeStream)
    }

    /// Lines the bridge wrote to stdin, for assertions.
    public var sentLines: [Data] { state.withLock { $0.sent } }

    /// The exit status if it has "exited", without waiting.
    public var exited: Int32? { state.withLock { $0.exit } }

    public func send(_ line: Data) async throws {
        let continuation = continuation, pacing = pacing
        try state.withLock { s in
            guard !s.closed, s.exit == nil else { throw TransportError.inputClosed }
            s.sent.append(line)
            let end = s.wholeStream ? nil : s.pending.firstIndex { l in
                if case .result = StreamEvent(line: l) { return true }
                return false
            }
            let turn = end.map { Array(s.pending[...$0]) } ?? s.pending
            s.pending.removeFirst(turn.count)
            // Chain on the previous turn's release so back-to-back sends keep their order.
            let previous = s.releasing
            s.releasing = Task.detached {
                await previous?.value
                for line in turn {
                    if pacing > .zero { try? await Task.sleep(for: pacing) }
                    continuation.yield(line)
                }
            }
        }
    }

    public func closeInput() {
        state.withLock { s in
            s.closed = true
            if s.exit == nil { s.exit = 0 }
        }
        continuation.finish()
    }

    public func terminate() {
        state.withLock { if $0.exit == nil { $0.exit = 143 } }
        continuation.finish()
    }

    /// Simulates a crash: stdout ends with the given status, after writing `stderr`.
    public func crash(status: Int32 = 1, stderr: String = "") {
        state.withLock {
            if $0.exit == nil { $0.exit = status }
            $0.stderr += stderr
        }
        continuation.finish()
    }

    public func exitStatus() async -> Int32 {
        while true {
            if let exit = state.withLock({ $0.exit }) { return exit }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    public var stderrTail: String { state.withLock { $0.stderr } }
}

/// A `Mutex` that callbacks can share: `Mutex` is noncopyable and can't be captured by the
/// escaping handlers Foundation takes.
final class Shared<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<R>(_ body: (inout sending Value) throws -> sending R) rethrows -> R {
        try mutex.withLock(body)
    }
}
