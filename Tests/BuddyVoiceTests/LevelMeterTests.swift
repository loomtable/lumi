import Testing
@testable import BuddyVoice

struct LevelMeterTests {
    @Test func normalizesOnDecibelScale() {
        let m = LevelMeter.mic()
        #expect(m.normalized(rms: 0) == 0)
        #expect(m.normalized(rms: 0.001) == 0)          // -60 dBFS is the floor
        #expect(abs(m.normalized(rms: 0.0316) - 0.625) < 0.01) // -30 dBFS: (−30 + 60) / 48
        #expect(m.normalized(rms: 0.5) == 1)
    }

    @Test func risesWithin30ms() {
        var m = LevelMeter.mic()
        var level: Float = 0
        for _ in 0 ..< 3 { level = m.update(rms: 0.5, dt: 0.010) }
        #expect(level >= 0.94)
    }

    @Test(arguments: [(LevelMeter.mic(), 0.250), (LevelMeter.reply(), 0.120)])
    func fallsOverItsReleaseTime(meter: LevelMeter, fall: Double) {
        var m = meter
        for _ in 0 ..< 20 { m.update(rms: 0.5, dt: 0.020) }
        let halfway = m.update(rms: 0, dt: fall / 2)
        #expect(halfway > 0.1, "still falling half way through the release")
        let done = m.update(rms: 0, dt: fall / 2)
        #expect(done <= 0.05)
    }

    @Test func framerSplitsTwentyMillisecondFramesAndCarriesRemainder() {
        var f = MeterFramer()
        #expect(f.push([Float](repeating: 0.1, count: 300)).isEmpty)
        let frames = f.push([Float](repeating: 0.1, count: 400)) // 700 total → 2 frames, 60 left
        #expect(frames.count == 2)
        #expect(abs(frames[0] - 0.1) < 1e-6)
        #expect(f.push([Float](repeating: 0.1, count: 260)).count == 1)
    }
}
