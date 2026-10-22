import AppKit
import Foundation
import Synchronization
import Testing
@testable import BuddyContext

/// Answers from a script, then repeats the last one.
final class ScriptedProbe: Sendable {
    private let answers: Mutex<[Bool?]>
    init(_ answers: [Bool?]) { self.answers = Mutex(answers) }
    func next() -> Bool? {
        answers.withLock { a in a.count > 1 ? a.removeFirst() : a.first ?? nil }
    }
}

/// The first `count` events, or fewer if they don't arrive in time: a regression fails, not hangs.
func firstEvents(
    _ stream: AsyncStream<SystemInterruption>, _ count: Int, within timeout: Duration = .seconds(3)
) async -> [SystemInterruption] {
    let collected = Mutex<[SystemInterruption]>([])
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await e in stream {
                let n = collected.withLock { $0.append(e); return $0.count }
                if n == count { return }
            }
        }
        group.addTask { try? await Task.sleep(for: timeout) }
        await group.next()
        group.cancelAll()
    }
    return collected.withLock { $0 }
}

@Suite("System interruptions", .serialized)
struct SystemInterruptionsTests {
    @Test("sleep and wake from NSWorkspace arrive as interruptions (process-local posts only)")
    func workspace() async {
        let stream = SystemInterruptions().events()
        // NSWorkspace's notification centre is local to this process: nothing reaches other apps.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(await firstEvents(stream, 2) == [.systemWillSleep, .displaysDidWake])
    }

    @Test("the observers are removed when the stream ends")
    func teardown() async throws {
        let before = SystemInterruptions.liveRegistrations.load(ordering: .relaxed)
        let stream = SystemInterruptions().events()
        #expect(SystemInterruptions.liveRegistrations.load(ordering: .relaxed) == before + 6)
        let consumer = Task { for await _ in stream {} }
        consumer.cancel()
        await consumer.value
        for _ in 0..<100 where SystemInterruptions.liveRegistrations.load(ordering: .relaxed) != before {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(SystemInterruptions.liveRegistrations.load(ordering: .relaxed) == before)
    }

    @Test("sharing: a session already running is reported at once, then changes; failed probes are skipped")
    func sharingWatch() async {
        let probe = ScriptedProbe([true, nil, true, false, nil, false, true])
        let source = SystemInterruptions(sharingPollInterval: 0.02, sharingProbe: { probe.next() })
        #expect(await firstEvents(source.watchRemoteScreenSharing(), 3) ==
            [.remoteScreenSharingStarted, .remoteScreenSharingEnded, .remoteScreenSharingStarted])
    }

    @Test("sharing: no session means no event; a probe that can't tell reports nil")
    func sharingQuiet() async {
        let source = SystemInterruptions(sharingPollInterval: 0.02, sharingProbe: { false })
        #expect(await firstEvents(source.watchRemoteScreenSharing(), 1, within: .milliseconds(200)).isEmpty)
        #expect(SystemInterruptions(sharingProbe: { nil }).isRemoteScreenSharingActive() == nil)
    }

    @Test("process lookup reads the real table: launchd is found, a made-up name isn't")
    func processes() {
        #expect(SystemInterruptions.processRunning(named: "launchd") == true)
        #expect(SystemInterruptions.processRunning(named: "no-such-process-\(UUID().uuidString.prefix(6))") == false)
        #expect(SystemInterruptions().isRemoteScreenSharingActive() != nil)
    }

    @Test("lock state comes from the lock probe")
    func lockState() {
        #expect(!SystemInterruptions(lockProbe: { false }).isScreenLocked())
        #expect(SystemInterruptions(lockProbe: { true }).isScreenLocked())
        _ = SystemInterruptions.sessionIsLocked() // the real read doesn't crash, locked or not
    }

    @Test("the fake delivers to open streams, tracks state, and drops ended streams")
    func fake() async {
        let fake = FakeSystemInterruptions(sharing: true)
        let a = fake.events()
        let b = fake.events()
        fake.send(.screenLocked)
        #expect(await firstEvents(a, 1) == [.screenLocked])
        #expect(await firstEvents(b, 1) == [.screenLocked])
        #expect(fake.isScreenLocked())
        #expect(await firstEvents(fake.watchRemoteScreenSharing(), 1) == [.remoteScreenSharingStarted])
        fake.send(.remoteScreenSharingEnded)
        #expect(fake.isRemoteScreenSharingActive() == false)
        fake.send(.screenUnlocked)
        #expect(!fake.isScreenLocked())
    }

    @Test("the fake drops a stream once its consumer is cancelled")
    func fakeDropsEnded() async throws {
        let fake = FakeSystemInterruptions()
        let stream = fake.events()
        let consumer = Task { for await _ in stream {} }
        #expect(fake.openStreams == 1)
        consumer.cancel()
        await consumer.value
        #expect(fake.openStreams == 0)
    }
}
