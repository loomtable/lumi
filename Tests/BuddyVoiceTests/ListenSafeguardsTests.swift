import Testing
@testable import BuddyVoice

struct ListenSafeguardsTests {
    @Test func stopsAfterTenSecondsWithoutSpeech() {
        var g = ListenSafeguards(startedAt: 100)
        #expect(g.tick(at: 109.9).isEmpty)
        #expect(g.tick(at: 110) == [.stop(.silence)])
        #expect(g.tick(at: 111).isEmpty, "a stop is reported once")
    }

    @Test func silenceCountsFromTheLastSpeechAndNotDuringIt() {
        var g = ListenSafeguards(startedAt: 0)
        g.observe(.started, at: 2)
        #expect(g.tick(at: 30).isEmpty, "a long sentence isn't silence")
        g.observe(.ended, at: 31)
        #expect(g.tick(at: 40.9).isEmpty)
        #expect(g.tick(at: 41) == [.stop(.silence)])
    }

    @Test func warnsOnceAtOneFortyFiveAndStopsAtTwoMinutes() {
        var g = ListenSafeguards(startedAt: 0)
        g.observe(.started, at: 0)
        #expect(g.tick(at: 104).isEmpty)
        #expect(g.tick(at: 105) == [.warnNearLimit])
        #expect(g.tick(at: 110).isEmpty)
        #expect(g.tick(at: 120) == [.stop(.maxLength)])
    }

    @Test func discardNeedsConfirmationOverThirtySecondsOfSpeech() {
        var g = ListenSafeguards(startedAt: 0)
        g.observe(.started, at: 0)
        g.observe(.ended, at: 20)
        g.observe(.started, at: 25)
        #expect(!g.discardNeedsConfirmation(at: 35))   // 20 + 10
        #expect(g.discardNeedsConfirmation(at: 35.5))  // 20 + 10.5
        #expect(abs(g.speechSeconds(at: 40) - 35) < 1e-9)
    }

    @Test func repeatedStartsDontRestartTheSpeechTimer() {
        var g = ListenSafeguards(startedAt: 0)
        g.observe(.started, at: 1)
        g.observe(.started, at: 5)
        g.observe(.ended, at: 6)
        #expect(g.speechSeconds(at: 10) == 5)
    }

    @Test func remembersWhetherAnySpeechWasHeard() {
        var g = ListenSafeguards(startedAt: 0)
        #expect(!g.heardSpeech)
        g.observe(.started, at: 1)
        #expect(g.heardSpeech && g.speechSeconds(at: 1) == 0)
        g.observe(.ended, at: 2)
        #expect(g.heardSpeech)
    }
}
