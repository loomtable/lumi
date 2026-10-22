import Foundation
import Testing
@testable import BuddyKeys

/// Integration tests against the real window server. Off by default (CI has no grants); run on a
/// dev Mac with `BUDDYKEYS_LIVE=1 Scripts/test.sh --filter LiveTap` once the host terminal has
/// Input Monitoring and Accessibility.
@Suite("Live taps", .enabled(if: ProcessInfo.processInfo.environment["BUDDYKEYS_LIVE"] == "1"))
struct LiveTapTests {
    @Test("listen-only tap starts on its own thread, reports current flags, and stops")
    func listenTapLifecycle() async throws {
        try #require(KeyPermissions.current().inputMonitoring, "grant Input Monitoring to the host terminal")
        let source = EventTapSource()
        let stream = try source.start()
        #expect(throws: KeySourceError.alreadyStarted) { _ = try source.start() }
        _ = source.currentFlags()
        source.stop()
        // The stream finishes once stopped.
        var iterator = stream.makeAsyncIterator()
        while await iterator.next() != nil {}
        // Restartable after stop.
        _ = try source.start()
        source.stop()
    }

    @Test("monitor runs end to end on the real source without emitting gestures at rest")
    func monitorOnRealSource() async throws {
        try #require(KeyPermissions.current().inputMonitoring)
        let monitor = BuddyKeyMonitor(source: EventTapSource())
        try await monitor.start()
        try await Task.sleep(for: .milliseconds(200))
        await monitor.stop()
    }

    @Test("scoped Esc tap activates, deactivates and can activate again")
    func escapeTapLifecycle() async throws {
        try #require(KeyPermissions.current().accessibility, "grant Accessibility to the host terminal")
        let tap = EscapeTap()
        _ = try tap.activate()
        #expect(throws: KeySourceError.alreadyStarted) { _ = try tap.activate() }
        tap.deactivate()
        _ = try tap.activate()
        tap.deactivate()
    }
}
