import Testing
@testable import BuddyVoice

struct ListenSafeguardsTests {
    /// Owner, Oct 29: the talk key stopped after 5–10 s of silence. It waits 30 s now.
    @Test func stopsAfterThirtySecondsWithoutSpeech() {
        var g = ListenSafeguards(startedAt: 100)
        #expect(g.tick(at: 110).isEmpty, "10 s of silence no longer stops it")
        #expect(g.tick(at: 129.9).isEmpty)
        #expect(g.tick(at: 130) == [.stop(.silence)])
        #expect(g.tick(at: 131).isEmpty, "a stop is reported once")
    }

    @Test func silenceCountsFromTheLastSpeechAndNotDuringIt() {
        var g = ListenSafeguards(startedAt: 0)
        g.observe(.started, at: 2)
        #expect(g.tick(at: 60).isEmpty, "a long sentence isn't silence")
        g.observe(.ended, at: 61)
        #expect(g.tick(at: 90.9).isEmpty)
        #expect(g.tick(at: 91) == [.stop(.silence)])
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
