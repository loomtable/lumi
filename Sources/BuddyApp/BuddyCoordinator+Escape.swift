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
    // MARK: - Esc

    func setEscape(_ wants: Bool) {
        guard let escape else { return }
        if wants, escapeTask == nil {
            do {
                let presses = try escape.activate()
                escapeTask = Task { [weak self] in
                    for await _ in presses { await self?.escapePressed() }
                }
            } catch {
                // Missing Accessibility is the runtime's permission line and the permission chip;
                // the next summon tries again.
            }
        } else if !wants {
            escapeTask?.cancel()
            escapeTask = nil
            escape.deactivate()
        }
    }

    /// Esc: discard while listening, cancel while thinking, otherwise the overlay handles it.
    public func escapePressed() async {
        // A dictation's pill is up: Esc cancels it (its words are kept in history).
        if let dictation, dictation.isActive {
            await dictation.cancel()
            return
        }
        nextRouteSource = nil
        switch phase {
        case .listening, .held:
            await discardListening(confirmed: false)
        case .typing:
            closeTextBox()
        case .thinking:
            let front = foregroundTicket
            // Still being sent: the send cancels it once it returns (a turn in the background
            // must not be cancelled in its place).
            if front == nil, turnsKeepRunning { cancelledEpochs.insert(epoch) }
            // Only a turn this ask sent: while it's still transcribing nothing is out, and the
            // current session may be running a page turn of its own.
            let id = front?.conversationID ?? inFlightConversation
            if let id { progress.end(session: SessionID(rawValue: id)) } // cancelled: no capsule takes over
            _ = nextEpoch()
            phase = .idle
            overlay.dismiss(.escape)
            if let front {
                await cancel(front)
            } else {
                // With sessions on nothing is cancelled here (a sent turn keeps running behind).
                traceEnd(.cancelled, ticket: turnsKeepRunning ? nil : ticket(conversation: id), outcome: .cancelled)
                if !turnsKeepRunning, let id { await turns.cancel(conversation: id) }
            }
        case .showing where shownApproval != nil:
            // Esc on the approval card cancels its turn, as Esc does while it thinks.
            guard let shown = shownApproval else { return }
            shownApproval = nil
            progress.end(session: shown.ticket.session)
            _ = nextEpoch()
            overlay.setSpeaking(false)
            dismissQuietly(.escape)
            await voice.stopSpeaking()
            await cancel(shown.ticket)
        case .showing, .idle:
            _ = nextEpoch() // a reply still synthesising must not start afterwards
            speechGeneration += 1 // nor the rest of an in-page answer (V-16)
            answerHeard = false // a ready answer waits for the card to close, not just for the voice
            overlay.setSpeaking(false)
            overlay.handleEscape()
            await voice.stopSpeaking()
        }
    }
}
