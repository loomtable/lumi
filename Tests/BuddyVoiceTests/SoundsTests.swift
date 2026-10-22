import Testing
@testable import BuddyVoice

struct SoundsTests {
    @Test(arguments: BuddySound.allCases)
    func lengthMatchesNotes(_ sound: BuddySound) {
        let rate = 48_000.0
        let expected = sound.notes.reduce(0) { $0 + Int(($1.seconds * rate).rounded()) }
        #expect(ToneSynth.render(sound, sampleRate: rate).count == expected)
    }

    @Test(arguments: BuddySound.allCases)
    func peakIsTheSpecGain(_ sound: BuddySound) {
        let peak = ToneSynth.render(sound).map(abs).max() ?? 0
        #expect(peak <= BuddySound.gain + 1e-6)
        #expect(peak > BuddySound.gain * 0.98)
    }

    @Test(arguments: BuddySound.allCases)
    func startsAndEndsAtZeroWithoutClicks(_ sound: BuddySound) {
        let rate = 48_000.0
        let samples = ToneSynth.render(sound, sampleRate: rate)
        var offset = 0
        for note in sound.notes {
            let count = Int((note.seconds * rate).rounded())
            #expect(abs(samples[offset]) < 1e-6)
            #expect(abs(samples[offset + count - 1]) < 1e-4)
            offset += count
        }
        // No step between neighbouring samples bigger than the steepest sine slope allows.
        let maxHz = sound.notes.map(\.hz).max() ?? 0
        let maxStep = Float(2 * Double.pi * maxHz / rate) * BuddySound.gain * 1.01
        for i in 1..<samples.count {
            #expect(abs(samples[i] - samples[i - 1]) <= maxStep)
        }
    }

    @Test(arguments: BuddySound.allCases)
    func eachNoteHasItsFrequency(_ sound: BuddySound) {
        let rate = 48_000.0
        let samples = ToneSynth.render(sound, sampleRate: rate)
        var offset = 0
        for note in sound.notes {
            let count = Int((note.seconds * rate).rounded())
            let slice = samples[offset..<(offset + count)]
            var crossings = 0
            var previous = slice.first ?? 0
            for s in slice.dropFirst() {
                if (previous < 0) != (s < 0), s != 0 { crossings += 1 }
                previous = s
            }
            let measured = Double(crossings) / 2 / note.seconds
            #expect(abs(measured - note.hz) / note.hz < 0.03, "\(sound) note \(note.hz) Hz measured \(measured)")
            offset += count
        }
    }

    @Test func levelWindowsAreTwentyMilliseconds() {
        let samples = [Float](repeating: 0.5, count: 24_000)   // 1 s at 24 kHz
        let levels = LevelWindows.rms(samples, sampleRate: 24_000)
        #expect(levels.count == 50)
        #expect(levels.allSatisfy { abs($0 - 0.5) < 1e-6 })
    }
}
