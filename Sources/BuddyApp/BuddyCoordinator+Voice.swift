import BuddyBridge
import BuddyCompanion
import BuddyContext
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import CoreGraphics
import Foundation
import Synchronization

extension BuddyCoordinator {
    // MARK: - Voice

    func apply(_ level: VoiceLevel) {
        switch level {
        case .mic(let value): overlay.setMicLevel(value)
        case .reply(let value): overlay.setSpeechLevel(value)
        }
    }

    func handle(_ event: VoiceEvent) async {
        switch event {
        case .speakingFinished:
            overlay.setSpeaking(false)
            speaking = false
            playNextReady()
        case .autoStopped(let held, let message):
            if let dictation, dictation.isActive {
                await dictation.voiceStopped(message: held ? message : nil)
                return
            }
            guard case .listening = phase else { return }
            _ = nextEpoch()
            summonSound?.cancel()
            await setKeyListening(false)
            if held {
                showHeldChip(message) // speech that was captured is kept, even after a mic failure
            } else {
                capture?.cancel()
                if let message { showChip(message) } else { dismissQuietly() }
            }
        case .setup(let state):
            voiceSetup = state
            showSetupProgress(state)
        case .nearLimit:
            if let dictation, dictation.isActive { return dictation.voiceNearLimit() }
            guard case .listening(_, let holding) = phase else { return }
            // At 1:45; the voice stops recording at 2:00. No countdown: it would go stale.
            overlay.updateListeningHint(holding ? "Stopping soon · release to send" : "Stopping soon · tap \(settings.keySymbol) to send")
        case .micProblem:
            // The voice follows a mic failure with .autoStopped(held:message:), which decides
            // whether the speech is kept; discarding here would lose it.
            break
        case .permissionDenied:
            trace(.permissionMissing)
        case .transcribing(let long):
            // Only for the send still waiting for its transcript, and only while it's thinking.
            guard case .thinking = phase, let waiting = awaitingTranscript, isCurrent(waiting) else { return }
            transcribingShown = true
            overlay.updateStatus(long ? "Still transcribing… Esc to cancel" : "Transcribing…")
        }
    }
}
