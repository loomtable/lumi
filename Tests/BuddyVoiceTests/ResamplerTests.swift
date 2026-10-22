import AVFAudio
import Foundation
import Testing
@testable import BuddyVoice

enum MicFixtures {
    static func sine(_ hz: Double, rate: Double, frames: Int, offset: Int = 0, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * hz * Double($0 + offset) / rate)) }
    }

    /// Frequency from rising zero crossings, skipping the converter's start-up.
    static func estimatedHz(_ samples: [Float], rate: Double = 16_000) -> Double {
        let body = Array(samples.dropFirst(256))
        var crossings = 0
        for i in 1..<body.count where body[i - 1] < 0 && body[i] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(body.count) / rate)
    }

    static func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }
}

@Test(arguments: [48_000.0, 44_100.0, 96_000.0])
func monoStreamResamplesTo16kHz(rate: Double) throws {
    let resampler = try #require(Resampler(inputSampleRate: rate))
    let chunk = Int(rate / 100)              // 10 ms chunks, as the pipeline drains them
    var out: [Float] = []
    for i in 0..<100 {                       // 1 s
        let input = MicFixtures.sine(1_000, rate: rate, frames: chunk, offset: i * chunk)
        out += input.withUnsafeBufferPointer { resampler.process($0) }
    }
    #expect(abs(out.count - 16_000) < 200)
    #expect(abs(MicFixtures.estimatedHz(out) - 1_000) < 15)
    #expect(abs(MicFixtures.rms(Array(out.dropFirst(256))) - Float(0.5 / 2.0.squareRoot())) < 0.03)
}

@Test func nineChannelVoiceProcessingBufferKeepsChannelZero() throws {
    let rate = 48_000.0
    let resampler = try #require(Resampler(inputSampleRate: rate, channels: 9))
    let frames = 4_800
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: resampler.input, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let voice = MicFixtures.sine(440, rate: rate, frames: frames)
    let channels = try #require(buffer.floatChannelData)
    for c in 0..<9 {
        for i in 0..<frames {
            // Channel 0 is the processed voice; the rest are loud, different signals that must not leak in.
            channels[c][i] = c == 0 ? voice[i] : 0.9 * Float(sin(2 * .pi * 3_000 * Double(i) / rate))
        }
    }
    // The converter holds back ~240 frames of filter priming on the first call and catches up later.
    let first = resampler.process(buffer)
    let out = resampler.process(buffer)
    #expect(abs(first.count + out.count - 3_200) < 300)
    #expect(abs(MicFixtures.estimatedHz(out) - 440) < 15)
    #expect(MicFixtures.rms(Array(out.dropFirst(256))) < 0.4)
}
