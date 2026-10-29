import CoreGraphics
import Foundation
import Testing
@testable import BuddyOverlay

/// Live (Oct 29): a cold voice-processing start took 1.3 s to make the mic live, while the pill
/// already said "Listening", so the first words were lost. The pill now waits for the mic.
@MainActor
struct MicReadyTests {
    @Test func thePillNeverSaysListeningBeforeTheMicIsLive() {
        let waiting = OverlayModel.listeningLabel(hint: "tap ⌥ to send", micReady: false, gettingReady: false, showsHint: false)
        #expect(!waiting.visible, "a normal start (under 250 ms) shows no word at all")
        let slow = OverlayModel.listeningLabel(hint: "tap ⌥ to send", micReady: false, gettingReady: true, showsHint: false)
        #expect(slow.text == "Getting ready…" && slow.visible)
        #expect(OverlayModel.listeningLabel(hint: "tap ⌥ to send", micReady: true, gettingReady: false, showsHint: false).text
                == "Listening")
        #expect(OverlayModel.listeningLabel(hint: "tap ⌥ to send", micReady: true, gettingReady: false, showsHint: true).text
                == "tap ⌥ to send")
    }

    @Test(.overlayExclusive) func gettingReadyShowsOnlyWhenTheMicIsSlowAndListeningStartsAtLive() async {
        let overlay = BuddyOverlayController(observesSystem: false)
        overlay.gettingReadyDelay = .milliseconds(20)
        overlay.listeningHintDelay = .seconds(60)   // the hint never interferes here
        overlay.showListening(at: CGPoint(x: 200, y: 200), hint: "tap ⌥ to send")
        #expect(overlay.model.micReady, "a pill shown without setMicReady (dictation) is ready")
        overlay.setMicReady(false)
        #expect(!overlay.model.micReady && !overlay.model.showsGettingReady)
        let deadline = ContinuousClock.now + .seconds(30)
        while !overlay.model.showsGettingReady, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(overlay.model.showsGettingReady, "still not live after the delay: Getting ready…")
        overlay.setMicReady(true)
        #expect(overlay.model.micReady && !overlay.model.showsGettingReady && !overlay.model.showsListeningHint)
        overlay.showListening(at: CGPoint(x: 200, y: 200), hint: "tap ⌥ to send")
        #expect(overlay.model.micReady, "each pill starts ready")
        overlay.dismiss(.requested)
    }
}
