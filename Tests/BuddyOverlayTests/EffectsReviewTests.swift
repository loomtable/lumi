import Observation
import Synchronization
import Testing
@testable import BuddyOverlay

// Lead re-verification of #51: toggles that are off do no work, and ink waits for its row.

nonisolated private final class Fired: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    var value: Bool { flag.withLock { $0 } }
}

@Test(.overlayExclusive) func glowOffDoesNotObserveTheSpeechLevel() {
    let model = OverlayModel()
    model.speaking = true
    model.settings.glow = false
    let fired = Fired()
    withObservationTracking {
        // Exactly what the root view evaluates for the card's glow.
        _ = OverlayRootView.glowLevel(speaking: model.speaking, glow: model.settings.glow, speech: model.speech)
    } onChange: { fired.set() }
    model.speech = 0.7
    #expect(!fired.value)           // the reply level changing doesn't re-render anything
    model.settings.glow = true
    #expect(fired.value)            // the toggle itself is observed
}

@Test(.overlayExclusive) func glowOnObservesTheSpeechLevel() {
    let model = OverlayModel()
    model.speaking = true
    let fired = Fired()
    withObservationTracking {
        _ = OverlayRootView.glowLevel(speaking: model.speaking, glow: model.settings.glow, speech: model.speech)
    } onChange: { fired.set() }
    model.speech = 0.7
    #expect(fired.value)
}

@Test(.overlayExclusive) func inkWaitsForTheHeadlineRow() {
    #expect(AnswerContent.headlineRow == 1)
    #expect(AnswerContent.headlineInkDelay == Motion.rowDelay(1))
    #expect(abs(AnswerContent.headlineInkDelay - 0.195) < 1e-9)   // 140 ms + 55 ms × 1
}

@Test(.overlayExclusive) func inkOffDrawsPlainText() {
    #expect(InkText.animates(enabled: true, done: false))
    #expect(!InkText.animates(enabled: false, done: false))   // ink-in turned off
    #expect(!InkText.animates(enabled: true, done: true))     // finished: no timeline left running
}
