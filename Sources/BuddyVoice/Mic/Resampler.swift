import AVFAudio
import Foundation
import Synchronization

/// Converts capture audio to 16 kHz mono Float32, keeping only channel 0. Voice processing hands us 9
/// channels on the built-in mic; channel 0 is the processed voice (S5).
///
/// Streaming: converter state carries across calls, so chunk boundaries don't click. Not thread-safe;
/// the capture pipeline uses it from its serial queue only.
final class Resampler {
    let input: AVAudioFormat
    let output: AVAudioFormat
    private let converter: AVAudioConverter
    private var monoBuffer: AVAudioPCMBuffer?

    init?(inputSampleRate: Double, channels: AVAudioChannelCount = 1) {
        guard inputSampleRate > 0, channels > 0,
              let input = Resampler.format(sampleRate: inputSampleRate, channels: channels),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        if channels > 1 { converter.channelMap = [0] }
        self.input = input
        self.output = output
        self.converter = converter
    }

    /// More than two channels needs an explicit layout, or AVAudioFormat returns nil.
    private static func format(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        guard channels > 2 else {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
                                 interleaved: false)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else {
            return nil
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
                             channelLayout: layout)
    }

    /// Drops converter history, for a new capture.
    func reset() { converter.reset() }

    /// Mono samples at the input rate (the pipeline's path: the sink already took channel 0).
    func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        guard input.channelCount == 1, let base = samples.baseAddress, !samples.isEmpty else { return [] }
        let frames = AVAudioFrameCount(samples.count)
        if monoBuffer == nil || monoBuffer!.frameCapacity < frames {
            monoBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: max(frames, 4_096))
        }
        guard let buffer = monoBuffer, let channel = buffer.floatChannelData?[0] else { return [] }
        channel.update(from: base, count: samples.count)
        buffer.frameLength = frames
        return process(buffer)
    }

    /// A buffer in `input` format, any channel count.
    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = output.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        let feed = OneShot()
        // AVAudioConverter calls this block synchronously inside convert(to:), on this thread, so the
        // buffer never actually crosses an isolation boundary.
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if !feed.fire() {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}

/// True the first time `fire()` is called, false after. A class around the Atomic so converter input
/// blocks can capture it: Swift 6.4 miscompiles a closure that captures a noncopyable Atomic directly
/// ("copy of noncopyable typed value. This is a compiler bug").
final class OneShot: Sendable {
    private let fired = Atomic(false)
    func fire() -> Bool { !fired.exchange(true, ordering: .relaxed) }
}
