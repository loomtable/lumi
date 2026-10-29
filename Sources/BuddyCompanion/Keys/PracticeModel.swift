import BuddyKeys
import Foundation
import Observation

/// The Keys pane's practice area ("Setup" step 3): runs the real buddy key while the
/// pane is visible and shows each gesture as it happens.
@Observable
public final class PracticeModel {
    public enum Status: Equatable {
        case idle
        /// Input Monitoring is missing, so the key can't be heard.
        case needsInputMonitoring
        case listening
        case failed(String)
    }

    public private(set) var status: Status = .idle
    /// The last gesture, in words ("Tap", "Hold", "Double-tap"…).
    public private(set) var last: String?
    public private(set) var taps = 0
    public private(set) var holds = 0
    public private(set) var doubleTaps = 0

    @ObservationIgnored private var monitor: BuddyKeyMonitor?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let makeSource: () -> any KeyEventSource
    @ObservationIgnored private let inputMonitoringGranted: () -> Bool
    @ObservationIgnored private let clock: any GestureClock

    public init(
        makeSource: @escaping () -> any KeyEventSource = { EventTapSource() },
        inputMonitoringGranted: @escaping () -> Bool = { KeyPermissions.current().inputMonitoring },
        clock: any GestureClock = UptimeClock()
    ) {
        self.makeSource = makeSource
        self.inputMonitoringGranted = inputMonitoringGranted
        self.clock = clock
    }

    public var isRunning: Bool { status == .listening }

    /// Starts listening (only from the pane's Start practising button). Safe to call while a
    /// stop is in flight: each step checks for cancellation, so a stopped practice never leaves
    /// a tap running.
    public func start(with prefs: KeysPreferences) async {
        await stop()
        guard inputMonitoringGranted() else {
            status = .needsInputMonitoring
            return
        }
        generation += 1
        let mine = generation
        let monitor = BuddyKeyMonitor(options: Self.options(prefs), source: makeSource(), clock: clock)
        do {
            try await monitor.start()
        } catch {
            status = .failed(String(describing: error))
            return
        }
        // A stop (or a newer start) arrived while the tap was starting.
        guard mine == generation, !Task.isCancelled else {
            await monitor.stop()
            return
        }
        self.monitor = monitor
        status = .listening
        listener = Task { [weak self] in
            for await event in monitor.events {
                guard case .gesture(let g) = event else { continue }
                self?.record(g)
            }
        }
    }

    /// New timing or key while practising: retunes the running monitor, no new tap.
    public func update(_ prefs: KeysPreferences) async {
        await monitor?.update(Self.options(prefs))
    }

    public func stop() async {
        generation += 1
        listener?.cancel()
        listener = nil
        let running = monitor
        monitor = nil
        await running?.stop()
        if status == .listening { status = .idle }
    }

    isolated deinit {
        listener?.cancel()
    }

    /// Settings › Keys as the listener's options; the app's own buddy key uses the same mapping.
    public static func options(_ prefs: KeysPreferences) -> BuddyKeyMonitor.Options {
        let ms: (Int) -> Nanos = { Nanos($0) * 1_000_000 }
        return BuddyKeyMonitor.Options(
            key: prefs.key,
            gesture: GestureConfig(holdThreshold: ms(prefs.holdThresholdMs), doubleTapWindow: ms(prefs.doubleTapWindowMs)),
            ignoreDuringSecureInput: prefs.ignoreDuringSecureInput)
    }

    func record(_ gesture: GestureEvent) {
        switch gesture {
        case .tap: taps += 1; last = "Tap: this starts or sends a question"
        case .holdEnded: holds += 1; last = "Hold: talk while holding, release to send"
        case .doubleTap: doubleTaps += 1; last = "Double-tap: opens the text box"
        case .cancelled: last = "Cancelled: another key, click or scroll came in between"
        case .holdDiscarded: last = "Hold discarded: another key came in while holding"
        case .pressBegan, .holdBegan, .switcher, .switcherReleased: break
        }
    }
}
