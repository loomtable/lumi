import AppKit

/// Quitting without a deadlock. `.terminateLater` waits for a reply from a main-actor task, but when
/// `terminate` itself was called from the main queue or a main-actor task (onboarding's relaunch),
/// that task can't run until `terminate` returns, so the app hangs. Instead the first request is
/// cancelled, the engine stops with the main queue free, and then the app quits for real. A
/// watchdog quits anyway if stopping hangs (a stuck child process).
@MainActor
public final class QuitSequence {
    private var stopped = false
    private var stopping = false
    private let stop: @MainActor () async -> Void
    /// Runs first, synchronously, before the engine stops or the watchdog starts: work that must
    /// happen on every quit, even one the watchdog ends (putting other apps' AX switches back).
    private let beforeStop: @MainActor () -> Void
    private let terminate: @MainActor () -> Void
    private let watchdog: Duration

    public init(stop: @escaping @MainActor () async -> Void,
                beforeStop: @escaping @MainActor () -> Void = {},
                terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
                watchdog: Duration = .seconds(3)) {
        self.stop = stop
        self.beforeStop = beforeStop
        self.terminate = terminate
        self.watchdog = watchdog
    }

    /// `applicationShouldTerminate`'s answer.
    public func shouldTerminate() -> NSApplication.TerminateReply {
        if stopped { return .terminateNow }
        guard !stopping else { return .terminateCancel }
        stopping = true
        beforeStop()
        Task { [stop] in
            await stop()
            self.finish()
        }
        Task { [watchdog] in
            try? await Task.sleep(for: watchdog)
            self.finish()
        }
        return .terminateCancel
    }

    /// Once, from whichever comes first: the engine stopped, or the watchdog.
    private func finish() {
        guard !stopped else { return }
        stopped = true
        terminate()
    }
}
