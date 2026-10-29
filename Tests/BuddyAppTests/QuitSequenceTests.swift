@testable import BuddyApp
import AppKit
import Testing

@MainActor
struct QuitSequenceTests {
    @Test func theFirstRequestStopsThenQuitsForReal() async {
        var stops = 0, terminations = 0
        let quit = QuitSequence(stop: { stops += 1 }, terminate: { terminations += 1 }, watchdog: .seconds(60))
        #expect(quit.shouldTerminate() == .terminateCancel, "never terminateLater: no reply can deadlock")
        #expect(quit.shouldTerminate() == .terminateCancel, "a second request while stopping changes nothing")
        for _ in 0..<100 where terminations == 0 { await Task.yield() }
        #expect(stops == 1 && terminations == 1)
        #expect(quit.shouldTerminate() == .terminateNow, "once stopped, the real quit goes through")
    }

    @Test func withSessionsWorkingItAsksFirst() async {
        // QA S-08: ⌘Q in the Dock app interrupts running turns, so it asks; Cancel keeps Lumi open.
        final class State { var asked: [String] = [], answer = false, stops = 0, working = 2 }
        let s = State()
        let quit = QuitSequence(stop: { s.stops += 1 }, terminate: {}, watchdog: .seconds(60),
                                working: { s.working }, confirm: { s.asked.append($0); return s.answer })
        #expect(quit.shouldTerminate() == .terminateCancel)
        for _ in 0..<20 { await Task.yield() }
        #expect(s.asked == ["2 sessions are still working. Quit anyway?"] && s.stops == 0)
        s.answer = true
        #expect(quit.shouldTerminate() == .terminateCancel)
        for _ in 0..<100 where s.stops == 0 { await Task.yield() }
        #expect(s.stops == 1)
        // Nothing working: no question.
        s.working = 0
        s.asked = []
        _ = QuitSequence(stop: {}, terminate: {}, watchdog: .seconds(60), working: { s.working },
                         confirm: { s.asked.append($0); return false }).shouldTerminate()
        #expect(s.asked.isEmpty)
        #expect(QuitSequence.question(working: 1) == "1 session is still working. Quit anyway?")
    }

    @Test func aStuckStopStillQuitsAfterTheWatchdog() async throws {
        var terminations = 0
        let quit = QuitSequence(stop: { try? await Task.sleep(for: .seconds(60)) }, terminate: { terminations += 1 },
                                watchdog: .milliseconds(50))
        #expect(quit.shouldTerminate() == .terminateCancel)
        // The stop never returns, so only the watchdog can quit. Waits for it rather than a fixed
        // 300 ms: a loaded machine can keep the main actor busy past that.
        let deadline = ContinuousClock.now + waitCeiling
        while terminations == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(terminations == 1)
        #expect(quit.shouldTerminate() == .terminateNow)
    }

    @Test func otherAppsAccessibilityIsPutBackBeforeTheEngineStops() async {
        var order: [String] = []
        let quit = QuitSequence(stop: { order.append("stop") }, beforeStop: { order.append("restore") },
                                terminate: { order.append("terminate") }, watchdog: .seconds(60))
        _ = quit.shouldTerminate()
        #expect(order.first == "restore", "synchronously, before anything else")
        for _ in 0..<100 where !order.contains("terminate") { await Task.yield() }
        #expect(order == ["restore", "stop", "terminate"])
        _ = quit.shouldTerminate()
        #expect(order.filter { $0 == "restore" }.count == 1, "once per quit")
    }

    @Test func aStuckStopStillPutsTheSwitchesBack() async throws {
        var restored = 0, terminations = 0
        let quit = QuitSequence(stop: { try? await Task.sleep(for: .seconds(60)) }, beforeStop: { restored += 1 },
                                terminate: { terminations += 1 }, watchdog: .milliseconds(50))
        _ = quit.shouldTerminate()
        let deadline = ContinuousClock.now + waitCeiling // the watchdog, however busy the machine
        while terminations == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restored == 1 && terminations == 1, "the watchdog quit still had them put back")
    }
}
