import Foundation

/// Renders the interface sounds: sine notes at gain 0.05, back to back.
public enum ToneSynth {
    public static let sampleRate: Double = 48_000
    /// Raised-cosine fade at each note's edges so notes start and end at zero (no click).
    static let fadeSeconds = 0.005

    public static func render(_ sound: BuddySound, sampleRate: Double = sampleRate) -> [Float] {
        var samples: [Float] = []
        for note in sound.notes {
            let count = Int((note.seconds * sampleRate).rounded())
            let fade = min(count / 2, Int(fadeSeconds * sampleRate))
            let step = 2 * Double.pi * note.hz / sampleRate
            for i in 0..<count {
                var gain = Double(BuddySound.gain)
                if i < fade {
                    gain *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade))
                } else if i >= count - fade {
                    gain *= 0.5 - 0.5 * cos(Double.pi * Double(count - 1 - i) / Double(fade))
                }
                samples.append(Float(gain * sin(step * Double(i))))
            }
        }
        return samples
    }
}

/// Plays the interface sounds through the shared output engine. Renders each sound once.
public actor TonePlayer: SoundPlayer {
    private let playback: AudioPlayback
    private var cache: [BuddySound: [Float]] = [:]

    public init(playback: AudioPlayback) {
        self.playback = playback
    }

    public func play(_ sound: BuddySound) async {
        let samples = cache[sound] ?? ToneSynth.render(sound)
        cache[sound] = samples
        try? await playback.playEffect(samples, sampleRate: ToneSynth.sampleRate)
    }
}
