import AppKit

/// Quitting without a deadlock. `.terminateLater` waits for a reply from a main-actor task, but when
/// `terminate` itself was called from the main queue or a main-actor task (onboarding's relaunch),
/// that task can't run until `terminate` returns, so the app hangs. Instead the first request is
/// cancelled, the engine stops with the main queue free, and then the app quits for real. A
/// watchdog quits anyway if stopping hangs (a stuck child process). With sessions still working,
/// the user is asked first (QA S-08): quitting interrupts their turns.
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
    /// How many sessions are working now; asked once per quit request.
    private let working: @MainActor () -> Int
    /// Shows the question and returns true for Quit.
    private let confirm: @MainActor (_ question: String) -> Bool

    public init(stop: @escaping @MainActor () async -> Void,
                beforeStop: @escaping @MainActor () -> Void = {},
                terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
                watchdog: Duration = .seconds(3),
                working: @escaping @MainActor () -> Int = { 0 },
                confirm: @escaping @MainActor (_ question: String) -> Bool = QuitSequence.ask) {
        self.stop = stop
        self.beforeStop = beforeStop
        self.terminate = terminate
        self.watchdog = watchdog
        self.working = working
        self.confirm = confirm
    }

    /// "2 sessions are still working. Quit anyway?"; nil when nothing is working.
    public static func question(working: Int) -> String? {
        switch working {
        case ...0: nil
        case 1: "1 session is still working. Quit anyway?"
        default: "\(working) sessions are still working. Quit anyway?"
        }
    }

    /// The question as an alert: Quit or Cancel.
    public static func ask(_ question: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "Their turns stop. You can continue them when Lumi opens again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `applicationShouldTerminate`'s answer.
    public func shouldTerminate() -> NSApplication.TerminateReply {
        if stopped { return .terminateNow }
        guard !stopping else { return .terminateCancel }
        if let question = Self.question(working: working()), !confirm(question) { return .terminateCancel }
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
