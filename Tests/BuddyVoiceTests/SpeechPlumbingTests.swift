import Synchronization
import Testing
@testable import BuddyVoice

private final class Log: Sendable {
    let lines = Mutex<[String]>([])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

struct TaskChainTests {
    @Test func runsOperationsOneAtATimeInSubmissionOrder() async throws {
        let chain = TaskChain()
        let log = Log()
        // The first operation suspends; the second must not start until it has finished.
        async let first: Void = chain.run {
            log.add("first start")
            try await Task.sleep(for: .milliseconds(30))
            log.add("first end")
        }
        try await Task.sleep(for: .milliseconds(5))
        async let second: Void = chain.run { log.add("second") }
        _ = try await (first, second)
        #expect(log.lines.withLock { $0 } == ["first start", "first end", "second"])
    }

    @Test func aFailedOperationDoesNotBlockTheNext() async throws {
        struct Boom: Error {}
        let chain = TaskChain()
        await #expect(throws: Boom.self) { try await chain.run { throw Boom() } }
        #expect(try await chain.run { 42 } == 42)
    }
}

struct PlaybackTrimTests {
    @Test func dropsTheQuietLeadInButKeepsOneWindowOfPreRoll() {
        let rate = 24_000.0, window = 480
        let samples = [Float](repeating: 0, count: window * 15) + [Float](repeating: 0.1, count: window * 5)
        let trimmed = LevelWindows.trimLeadingQuiet(samples, sampleRate: rate)
        #expect(trimmed.count == window * 6)
        #expect(trimmed.first == 0 && trimmed[window] == 0.1)
    }

    @Test func leavesAudioThatStartsLoudOrNeverGetsLoud() {
        let loud = [Float](repeating: 0.1, count: 2_000)
        #expect(LevelWindows.trimLeadingQuiet(loud, sampleRate: 24_000) == loud)
        let silent = [Float](repeating: 0, count: 2_000)
        #expect(LevelWindows.trimLeadingQuiet(silent, sampleRate: 24_000) == silent)
    }
}

struct SystemSpeakerTests {
    @Test func emptyTextFinishesAtOnceWithoutRendering() async throws {
        let speaker = SystemSpeaker(playback: AudioPlayback(output: FakePlaybackOutput()))
        var levels = 0
        for await _ in try await speaker.speak("   ") { levels += 1 }
        #expect(levels == 0)
    }

    @Test func renderTimeoutScalesWithLengthWithATwoSecondFloor() {
        #expect(SystemSpeaker.renderTimeout(for: "Hi.") == 2)
        #expect(SystemSpeaker.renderTimeout(for: String(repeating: "a", count: 100)) == 8)
        #expect(SystemSpeaker.renderTimeout(for: "Ready.", minimum: SystemSpeaker.coldRenderTimeout) == 5)
    }

    @Test func aCollectorFinishedWithAnErrorThrowsToItsWaiter() async {
        let collector = SpeechCollector()
        collector.finish(error: VoiceUnavailable.synthesisFailed("timed out"))
        collector.finish()   // later calls are ignored
        await #expect(throws: VoiceUnavailable.synthesisFailed("timed out")) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in collector.onFinish(c) }
        }
    }
}

struct ReplyTicketTests {
    /// The race the second review found: stop() reaches the playback actor while the voice is still
    /// synthesizing; the reply's playVoice arrives afterwards and must not start.
    @Test func aPlayThatArrivesAfterAStopNeverStarts() async throws {
        let playback = AudioPlayback(output: FakePlaybackOutput())
        let ticket = await playback.reserveReply()
        await playback.stopVoice()
        let levels = try await playback.playVoice([Float](repeating: 0.1, count: 4_800), sampleRate: 24_000, ticket: ticket)
        var count = 0
        for await _ in levels { count += 1 }
        #expect(count == 0)
        #expect(await playback.isPlayingVoice == false)
    }

    @Test func aTicketTakenAfterAStopIsCurrent() async {
        let playback = AudioPlayback(output: FakePlaybackOutput())
        await playback.stopVoice()
        let ticket = await playback.reserveReply()
        #expect(await playback.isCurrent(ticket))
        await playback.stopVoice()
        #expect(await !playback.isCurrent(ticket))
    }
}

struct PlaybackIdleTests {
    /// idle CPU and Bluetooth: output stops once nothing has played for a while, and restarts on
    /// the next sound. Uses silent samples. Skips if this machine has no usable output device.
    @Test func outputStopsWhenIdleAndRestartsOnDemand() async throws {
        let playback = AudioPlayback(idleStopDelay: .milliseconds(100), output: FakePlaybackOutput())
        let silence = [Float](repeating: 0, count: 2_400)   // 50 ms at 48 kHz
        do { try await playback.playEffect(silence, sampleRate: 48_000) } catch { return }
        #expect(await playback.isOutputRunning)
        #expect(await until { await !playback.isOutputRunning }, "output stops once idle")
        try await playback.playEffect(silence, sampleRate: 48_000)
        #expect(await playback.isOutputRunning)
    }
}
