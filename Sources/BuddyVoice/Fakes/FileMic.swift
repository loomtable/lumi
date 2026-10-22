import AVFoundation
import Foundation
import Synchronization

/// A mic that plays a sound file instead of capturing, at real-time pace in 20 ms chunks, then sends
/// up to `trailingSilence` seconds of silence and waits to be stopped. For end-to-end tests: with voice processing on, the echo canceller
/// removes anything the Mac plays through its speakers, so tests can't ask questions out loud.
public final class FileMic: MicCapture {
    public struct UnreadableFile: Error {}

    private let samples: [Float]
    private let realTime: Bool
    private let trailingSilence: Double
    private let task = Mutex<Task<Void, Never>?>(nil)

    /// Loads any file AVAudioFile reads and converts it to 16 kHz mono.
    public init(file: URL, realTime: Bool = true, trailingSilence: Double = 15) throws {
        let source = try AVAudioFile(forReading: file)
        let format = source.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length)),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output)
        else { throw UnreadableFile() }
        try source.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * AudioChunk.sampleRate / format.sampleRate) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw UnreadableFile() }
        let feed = OneShot()
        var error: NSError?
        // The converter calls this synchronously inside convert(to:), so `input` never leaves this thread.
        nonisolated(unsafe) let pending = input
        converter.convert(to: converted, error: &error) { _, status in
            if !feed.fire() { status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return pending
        }
        if let error { throw error }
        samples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
        self.realTime = realTime
        self.trailingSilence = trailingSilence
    }

    public var duration: Double { Double(samples.count) / AudioChunk.sampleRate }

    public func prepare() async throws {}

    public func start() async throws -> AsyncStream<MicEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MicEvent.self)
        let samples = samples, realTime = realTime
        let end = samples.count + Int(trailingSilence * AudioChunk.sampleRate)
        let player = Task {
            let chunk = Int(AudioChunk.sampleRate * 0.02)
            var i = 0
            while !Task.isCancelled, i < end {
                let slice = i < samples.count ? Array(samples[i ..< min(samples.count, i + chunk)]) : [Float](repeating: 0, count: chunk)
                i += chunk
                continuation.yield(.audio(AudioChunk(samples: slice, capturedAt: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))))
                if realTime { try? await Task.sleep(for: .milliseconds(20)) } else { await Task.yield() }
            }
            // Bounded: wait for stop() rather than producing silence forever.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            continuation.finish()
        }
        task.withLock { $0?.cancel(); $0 = player }
        return stream
    }

    public func stop() async {
        let player = task.withLock { t -> Task<Void, Never>? in defer { t = nil }; return t }
        player?.cancel()
        await player?.value
    }

    public func setVoiceProcessing(_ enabled: Bool) async throws {}
}
