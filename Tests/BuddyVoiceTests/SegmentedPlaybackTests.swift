import Synchronization
import Testing
@testable import BuddyVoice

/// Records when a level stream ends. A class, so closures capture a reference, not the Mutex itself.
private final class StreamWatch: Sendable {
    private let endedAt = Mutex<ContinuousClock.Instant?>(nil)
    private let count = Mutex(0)

    init(_ levels: AsyncStream<Float>) {
        Task {
            for await _ in levels { self.count.withLock { $0 += 1 } }
            self.endedAt.withLock { $0 = .now }
        }
    }

    var ended: Bool { endedAt.withLock { $0 != nil } }
    var levels: Int { count.withLock { $0 } }

    func waitUntilEnded(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if ended { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ended
    }
}

/// Polls `condition` until it holds, for at most `limit`: an event wait with a generous bound, not a
/// timing window.
func until(_ limit: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Silence of `seconds` at 24 kHz (Kokoro's rate).
private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(24_000 * seconds)) }

@Suite(.serialized)
struct SegmentedPlaybackTests {
    @Test func theStreamEndsAfterTheLastSegmentNotTheFirst() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let reply = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(reply.levels)
        #expect(try await reply.append(silence(0.15)))
        // Waits for the first segment's own played-back callback rather than a guessed duration.
        #expect(await until { await playback.timeline.first?.playedBackAt != nil }, "the first segment played back")
        #expect(!watch.ended, "the reply is still open")
        #expect(try await reply.append(silence(0.15)))
        await reply.finish()
        #expect(await watch.waitUntilEnded())
        let timeline = await playback.timeline
        #expect(timeline.count == 2)
        #expect(timeline.allSatisfy { $0.playedBackAt != nil }, "ended only after both played back")
        // The meter runs on the playhead's real-time schedule and stops when the reply ends, so how many
        // levels arrive depends on load; only that they flow is guaranteed.
        #expect(watch.levels > 0, "levels flowed while it played")
    }

    @Test func aSegmentAppendedAfterPlaybackRanDryStartsNowNotInThePast() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let reply = try await playback.beginReply(sampleRate: 24_000)
        try await reply.append(silence(0.1))
        try await Task.sleep(for: .milliseconds(250))
        try await reply.append(silence(0.1))
        await reply.finish()
        let t = await playback.timeline
        #expect(t[1].startsAt >= t[0].endsAt)
        #expect(t[1].startsAt >= t[1].appendedAt)
        // Back to back when the next segment is ready in time.
        let back = try await playback.beginReply(sampleRate: 24_000)
        try await back.append(silence(0.3))
        try await back.append(silence(0.3))
        await back.finish()
        let b = await playback.timeline
        #expect(b[1].startsAt == b[0].endsAt)
    }

    @Test func stopMidReplyEndsTheStreamAndRefusesLaterAppends() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let reply = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(reply.levels)
        try await reply.append(silence(1.0))
        try await Task.sleep(for: .milliseconds(100))
        let t = ContinuousClock.now
        await playback.stopVoice()
        #expect(await watch.waitUntilEnded(timeout: .milliseconds(150)))
        #expect(ContinuousClock.now - t < .milliseconds(150))
        #expect(try await reply.append(silence(0.2)) == false)
        #expect(await playback.isPlayingVoice == false)
    }

    @Test func idleStopWaitsWhileTheReplyIsOpenBetweenSegments() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(50), output: FakePlaybackOutput())
        let reply = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(reply.levels)
        try await reply.append(silence(0.05))
        try await Task.sleep(for: .milliseconds(300))   // played back, longer than the idle delay
        #expect(await playback.isOutputRunning, "output stays up while more sentences may come")
        try await reply.append(silence(0.05))
        await reply.finish()
        #expect(await watch.waitUntilEnded())
        try await Task.sleep(for: .milliseconds(200))
        #expect(await playback.isOutputRunning == false, "idle stop runs once the reply has finished")
    }

    @Test func anOutputChangeBeforeTheFirstSentenceKeepsTheReply() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let reply = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(reply.levels)
        await playback.configurationChanged()   // e.g. the mic turned voice processing off after a send
        #expect(!watch.ended)
        #expect(try await reply.append(silence(0.1)), "the first sentence still plays")
        await reply.finish()
        #expect(await watch.waitUntilEnded())
        #expect(await playback.timeline.count == 1)
    }

    @Test func aDeviceChangeReachesPlaybackThroughTheOutput() async throws {
        let output = FakePlaybackOutput()
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: output)
        let reply = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(reply.levels)
        try await reply.append(silence(1.0))
        output.simulateConfigurationChange()   // e.g. headphones unplugged mid-sentence
        #expect(await watch.waitUntilEnded(), "the reply playing at the change is dropped")
        #expect(try await reply.append(silence(0.1)) == false)
    }

    @Test func anOutputChangeWhilePlayingDropsTheReply() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let reply = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(reply.levels)
        try await reply.append(silence(1.0))
        await playback.configurationChanged()   // e.g. headphones unplugged mid-sentence
        #expect(await watch.waitUntilEnded(timeout: .milliseconds(150)))
        #expect(try await reply.append(silence(0.1)) == false)
    }

    @Test func aHoldKeepsAFinishedReplyOpenForMoreSegments() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let reply = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(reply.levels)
        try await reply.append(silence(0.15))
        #expect(await reply.hold())
        await reply.finish()                     // the first line's sentences are all queued
        try await Task.sleep(for: .milliseconds(300))
        #expect(!watch.ended, "the continuation still holds it")
        #expect(try await reply.append(silence(0.1)))
        await reply.finish()
        #expect(await watch.waitUntilEnded())
        #expect(await playback.timeline.count == 2)
        #expect(await reply.hold() == false, "a reply that has ended can't be continued")
    }

    @Test func aStaleTicketRefusesTheWholeReply() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let ticket = await playback.reserveReply()
        await playback.stopVoice()
        let reply = try await playback.beginReply(sampleRate: 24_000, ticket: ticket)
        var levels = 0
        for await _ in reply.levels { levels += 1 }
        #expect(levels == 0)
        #expect(try await reply.append(silence(0.1)) == false)
        #expect(await playback.isOutputRunning == false)
    }

    @Test func aNewReplyCutsTheOpenOne() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let first = try await playback.beginReply(sampleRate: 24_000)
        let watch = StreamWatch(first.levels)
        try await first.append(silence(1.0))
        let second = try await playback.beginReply(sampleRate: 24_000)
        #expect(await watch.waitUntilEnded(timeout: .milliseconds(150)))
        #expect(try await first.append(silence(0.1)) == false)
        #expect(try await second.append(silence(0.1)))
        await second.finish()
    }
}

struct LeadingQuietTests {
    @Test func laterSegmentsKeepAtMost120msOfLeadIn() {
        let rate = 24_000.0
        let samples = [Float](repeating: 0, count: Int(rate * 0.3)) + [Float](repeating: 0.1, count: 2_400)
        let capped = LevelWindows.capLeadingQuiet(samples, sampleRate: rate)
        #expect(capped.count == Int(rate * 0.12) + 2_400)
        let short = [Float](repeating: 0, count: Int(rate * 0.06)) + [Float](repeating: 0.1, count: 2_400)
        #expect(LevelWindows.capLeadingQuiet(short, sampleRate: rate) == short, "a short pause is kept as is")
    }
}
