import AVFAudio
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import BuddyVoice

/// Runs `body` on a background thread and waits for it. These callbacks are invoked by the audio thread,
/// NotificationCenter and the HAL; if any had inherited actor isolation, Swift 6 would trap here.
private func offMain(_ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            precondition(!Thread.isMainThread)
            body()
            done.resume()
        }
    }
}

/// A 9-channel non-interleaved buffer list, like voice processing delivers on the built-in mic.
private final class NineChannelInput: @unchecked Sendable {
    // Only touched by one thread at a time in these tests: filled on the test thread, read by the
    // callback inside `offMain`, which the test awaits.
    let list: UnsafeMutableAudioBufferListPointer
    let storage: [UnsafeMutablePointer<Float>]

    init(frames: Int, channel0: [Float]) {
        list = AudioBufferList.allocate(maximumBuffers: 9)
        storage = (0..<9).map { _ in .allocate(capacity: frames) }
        for c in 0..<9 {
            for i in 0..<frames { storage[c][i] = c == 0 ? channel0[i] : 0.9 }
            list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: storage[c])
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

private func timestamp(hostTime: UInt64) -> AudioTimeStamp {
    var stamp = AudioTimeStamp()
    stamp.mHostTime = hostTime
    stamp.mFlags = .hostTimeValid
    return stamp
}

@Test func sinkBlockCopiesChannelZeroOffTheMainThread() async {
    let ring = SampleRing()
    ring.beginCapture(at: 0)
    // The audio thread calls this block in production; the test hands it to one background thread and
    // waits, so it is never called concurrently.
    nonisolated(unsafe) let block = EngineMic.sinkBlock(ring: ring)
    let voice = MicFixtures.sine(440, rate: 48_000, frames: 512)
    let input = NineChannelInput(frames: 512, channel0: voice)
    await offMain {
        var stamp = timestamp(hostTime: HostTime.now())
        _ = block(&stamp, 512, input.list.unsafePointer)
    }
    var out: [Float] = []
    ring.read(into: &out)
    #expect(out == voice)
}

@Test func sinkBlockDropsBuffersFromBeforeTheCurrentStart() async {
    let ring = SampleRing()
    // The audio thread calls this block in production; the test hands it to one background thread and
    // waits, so it is never called concurrently.
    nonisolated(unsafe) let block = EngineMic.sinkBlock(ring: ring)
    let input = NineChannelInput(frames: 512, channel0: [Float](repeating: 0.5, count: 512))
    let staleTime = HostTime.now()
    ring.beginCapture(at: staleTime + 1_000)
    await offMain {
        var late = timestamp(hostTime: staleTime)        // queued before the new start
        _ = block(&late, 512, input.list.unsafePointer)
    }
    var out: [Float] = []
    ring.read(into: &out)
    #expect(out.isEmpty)
    #expect(ring.droppedFrames.load(ordering: .relaxed) == 512)
}

/// The full sink path: 9-channel 48 kHz callbacks → ring → 16 kHz mono of channel 0.
@Test func sinkPathConvertsNineChannelsTo16kHzChannelZero() async throws {
    let ring = SampleRing()
    ring.beginCapture(at: 0)
    // The audio thread calls this block in production; the test hands it to one background thread and
    // waits, so it is never called concurrently.
    nonisolated(unsafe) let block = EngineMic.sinkBlock(ring: ring)
    let resampler = try #require(Resampler(inputSampleRate: 48_000))
    var out: [Float] = []
    for n in 0..<94 {                                     // ~1 s of 512-frame IO cycles
        let input = NineChannelInput(frames: 512, channel0: MicFixtures.sine(440, rate: 48_000, frames: 512, offset: n * 512))
        await offMain {
            var stamp = timestamp(hostTime: HostTime.now())
            _ = block(&stamp, 512, input.list.unsafePointer)
        }
        var drained: [Float] = []
        ring.read(into: &drained)
        out += drained.withUnsafeBufferPointer { resampler.process($0) }
    }
    #expect(abs(out.count - 16_043) < 200)                // 94 × 512 / 3
    #expect(abs(MicFixtures.estimatedHz(out) - 440) < 15)
    #expect(MicFixtures.rms(Array(out.dropFirst(256))) < 0.4)        // the 0.9 DC on channels 1–8 didn't leak in
}

@Test func notificationAndHALCallbacksRunOffTheMainThread() async {
    let mic = EngineMic(voiceProcessing: false, permission: { true })
    let changes = ChangeFlags()
    let config = EngineMic.configurationChangeBlock(mic: mic, generation: -1, changes: changes)    // stale: ignored
    let notification = AVMicEngine.notificationBlock(config)
    await offMain { notification(Notification(name: .AVAudioEngineConfigurationChange)) }
    #expect(!changes.takeDirty(), "a stale generation doesn't mark the engine dirty")

    let calls = Atomic<Int>(0)
    // Called once, from the background thread below, which the test awaits.
    nonisolated(unsafe) let listener = AudioHAL.listenerBlock { calls.add(1, ordering: .relaxed) }
    let input = EngineMic.defaultInputChangeHandler(mic: mic, changes: changes)
    await offMain {
        var address = AudioObjectPropertyAddress()
        withUnsafePointer(to: &address) { listener(1, $0) }
        input()
    }
    #expect(calls.load(ordering: .relaxed) == 1)
    #expect(changes.takeDeviceChanged(), "the HAL callback marks the change before hopping to the actor")
}

@Test func startWithoutPermissionReportsDeniedWithoutTouchingTheMic() async throws {
    let mic = EngineMic(voiceProcessing: true, permission: { false }, requestPermission: { false },
                        engineFactory: { _, _ in throw MicError.notPrepared })
    var events: [MicEvent] = []
    for await event in try await mic.start() { events.append(event) }
    #expect(events == [.problem(.permissionDenied)])
}
