import AppKit
import CoreGraphics
import Darwin
import Foundation
import Synchronization

/// Things that must stop listening at once ("Tap-to-talk safeguards": screen lock,
/// sleep, the start of screen sharing). The coordinator maps them to `voice.interrupt`.
public enum SystemInterruption: Sendable, Equatable {
    case screenLocked
    case screenUnlocked
    case systemWillSleep
    case systemDidWake
    case displaysDidSleep
    case displaysDidWake
    /// Heuristic, inbound only: macOS Screen Sharing or Remote Management has a session (its
    /// `screensharingd` process is running). macOS has no public API for "this screen is being
    /// shared or recorded", so screen sharing in Zoom, Meet or FaceTime, or a QuickTime
    /// recording, is NOT detected.
    case remoteScreenSharingStarted
    case remoteScreenSharingEnded
}

/// Real: `SystemInterruptions`. Fake: `FakeSystemInterruptions`.
public protocol SystemInterruptionSource: Sendable {
    /// Lock, unlock, sleep and wake, for as long as the stream is iterated. Call it on the main
    /// thread of an app whose main run loop runs: distributed notifications are delivered there.
    func events() -> AsyncStream<SystemInterruption>
    /// Remote screen sharing while listening: open it when the mic starts, end it when the
    /// listen ends. Yields `.remoteScreenSharingStarted` at once if a session is already
    /// running, then each change.
    func watchRemoteScreenSharing() -> AsyncStream<SystemInterruption>
    /// The state right now (at launch, after wake).
    func isScreenLocked() -> Bool
    /// Nil when it couldn't be checked.
    func isRemoteScreenSharingActive() -> Bool?
}

public final class SystemInterruptions: SystemInterruptionSource {
    /// How often to look for a sharing session while listening.
    public let sharingPollInterval: TimeInterval
    let sharingProbe: @Sendable () -> Bool?
    let lockProbe: @Sendable () -> Bool

    /// The probes are injectable for tests; nil from `sharingProbe` means "couldn't tell" and is
    /// skipped.
    public init(
        sharingPollInterval: TimeInterval = 1,
        sharingProbe: @escaping @Sendable () -> Bool? = { SystemInterruptions.processRunning(named: "screensharingd") },
        lockProbe: @escaping @Sendable () -> Bool = { SystemInterruptions.sessionIsLocked() }
    ) {
        self.sharingPollInterval = sharingPollInterval
        self.sharingProbe = sharingProbe
        self.lockProbe = lockProbe
    }

    /// Undocumented but long-stable distributed notifications (used since 10.x, still on 26).
    static let lockedName = Notification.Name("com.apple.screenIsLocked")
    static let unlockedName = Notification.Name("com.apple.screenIsUnlocked")

    /// Observer registrations currently live, across all streams (for tests).
    static let liveRegistrations = Atomic(0)

    public func events() -> AsyncStream<SystemInterruption> {
        let (stream, continuation) = AsyncStream.makeStream(of: SystemInterruption.self)
        let observers = Observers(continuation: continuation)
        continuation.onTermination = { _ in observers.stop() }
        return stream
    }

    public func watchRemoteScreenSharing() -> AsyncStream<SystemInterruption> {
        let (stream, continuation) = AsyncStream.makeStream(of: SystemInterruption.self)
        let initial = sharingProbe()
        if initial == true { continuation.yield(.remoteScreenSharingStarted) }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = DispatchTimeInterval.milliseconds(Int(sharingPollInterval * 1_000))
        timer.schedule(
            deadline: .now() + interval, repeating: interval,
            leeway: .milliseconds(Int(sharingPollInterval * 250)))
        timer.setEventHandler(handler: Self.poll(SharingState(initial ?? false), sharingProbe, continuation))
        timer.resume()
        let box = TimerBox(timer)
        continuation.onTermination = { _ in box.timer.cancel() }
        return stream
    }

    public func isScreenLocked() -> Bool { lockProbe() }

    /// The real lock state: the session dictionary's lock key.
    public static func sessionIsLocked() -> Bool {
        // CGSessionCopyCurrentDictionary is documented; this key is not, and is present only
        // while the screen is locked.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    public func isRemoteScreenSharingActive() -> Bool? {
        sharingProbe()
    }

    /// Whether any process (any user) has this name, from the kernel process table. Nil if the
    /// table couldn't be read, e.g. it grew past the buffer twice during a burst of forks.
    public static func processRunning(named name: String) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<2 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = procs.count * stride
            let result = procs.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return procs.prefix(size / stride).contains { p in
                withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == name
            }
        }
        return nil
    }

    final class SharingState: Sendable {
        let running: Mutex<Bool>
        init(_ value: Bool) { running = Mutex(value) }
    }

    final class TimerBox: @unchecked Sendable {
        // DispatchSource is thread-safe; the box only carries it into onTermination.
        let timer: any DispatchSourceTimer
        init(_ timer: any DispatchSourceTimer) { self.timer = timer }
    }

    /// Built outside any actor: the timer fires on a global queue.
    private nonisolated static func poll(
        _ state: SharingState, _ probe: @escaping @Sendable () -> Bool?,
        _ continuation: AsyncStream<SystemInterruption>.Continuation
    ) -> @Sendable () -> Void {
        {
            guard let now = probe() else { return }
            let changed = state.running.withLock { was in
                defer { was = now }
                return was != now
            }
            if changed { continuation.yield(now ? .remoteScreenSharingStarted : .remoteScreenSharingEnded) }
        }
    }

    /// The registrations behind one `events()` stream, removed once when it ends.
    final class Observers: Sendable {
        // Immutable after init; NotificationCenter.removeObserver is thread-safe, and stop() runs
        // the removal at most once (guarded by `stopped`).
        nonisolated(unsafe) private let tokens: [(center: NotificationCenter, token: any NSObjectProtocol)]
        private let stopped = Atomic(false)

        init(continuation: AsyncStream<SystemInterruption>.Continuation) {
            let distributed = DistributedNotificationCenter.default()
            let workspace = NSWorkspace.shared.notificationCenter
            let map: [(NotificationCenter, Notification.Name, SystemInterruption)] = [
                (distributed, SystemInterruptions.lockedName, .screenLocked),
                (distributed, SystemInterruptions.unlockedName, .screenUnlocked),
                (workspace, NSWorkspace.willSleepNotification, .systemWillSleep),
                (workspace, NSWorkspace.didWakeNotification, .systemDidWake),
                (workspace, NSWorkspace.screensDidSleepNotification, .displaysDidSleep),
                (workspace, NSWorkspace.screensDidWakeNotification, .displaysDidWake),
            ]
            tokens = map.map { center, name, event in
                (center, center.addObserver(forName: name, object: nil, queue: nil, using: Self.handler(event, continuation)))
            }
            SystemInterruptions.liveRegistrations.add(tokens.count, ordering: .relaxed)
        }

        func stop() {
            guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
            for (center, token) in tokens { center.removeObserver(token) }
            SystemInterruptions.liveRegistrations.subtract(tokens.count, ordering: .relaxed)
        }

        /// Built outside any actor: notifications arrive on the posting thread.
        private nonisolated static func handler(
            _ event: SystemInterruption, _ continuation: AsyncStream<SystemInterruption>.Continuation
        ) -> @Sendable (Notification) -> Void {
            { _ in continuation.yield(event) }
        }
    }
}

/// For tests and previews: `send` delivers to every open stream and updates the state. Ended
/// streams are dropped.
public final class FakeSystemInterruptions: SystemInterruptionSource {
    private struct State {
        var next = 0
        var system: [Int: AsyncStream<SystemInterruption>.Continuation] = [:]
        var sharingWatches: [Int: AsyncStream<SystemInterruption>.Continuation] = [:]
        var locked: Bool
        var sharing: Bool?
    }

    private let state: Mutex<State>

    public init(locked: Bool = false, sharing: Bool? = false) {
        state = Mutex(State(locked: locked, sharing: sharing))
    }

    /// Open streams, for tests.
    public var openStreams: Int { state.withLock { $0.system.count + $0.sharingWatches.count } }

    public func events() -> AsyncStream<SystemInterruption> {
        open(sharing: false)
    }

    public func watchRemoteScreenSharing() -> AsyncStream<SystemInterruption> {
        open(sharing: true)
    }

    private func open(sharing: Bool) -> AsyncStream<SystemInterruption> {
        let (stream, c) = AsyncStream.makeStream(of: SystemInterruption.self)
        let id = state.withLock { s in
            s.next += 1
            if sharing {
                s.sharingWatches[s.next] = c
                if s.sharing == true { c.yield(.remoteScreenSharingStarted) }
            } else {
                s.system[s.next] = c
            }
            return s.next
        }
        c.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.system.removeValue(forKey: id); _ = $0.sharingWatches.removeValue(forKey: id) }
        }
        return stream
    }

    public func send(_ event: SystemInterruption) {
        let cs = state.withLock { s -> [AsyncStream<SystemInterruption>.Continuation] in
            switch event {
            case .screenLocked: s.locked = true
            case .screenUnlocked: s.locked = false
            case .remoteScreenSharingStarted: s.sharing = true
            case .remoteScreenSharingEnded: s.sharing = false
            default: break
            }
            switch event {
            case .remoteScreenSharingStarted, .remoteScreenSharingEnded: return Array(s.sharingWatches.values)
            default: return Array(s.system.values)
            }
        }
        for c in cs { c.yield(event) }
    }

    public func isScreenLocked() -> Bool { state.withLock { $0.locked } }
    public func isRemoteScreenSharingActive() -> Bool? { state.withLock { $0.sharing } }
}
