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
    // MARK: - Buddy key

    public func handle(_ event: BuddyKeyEvent) async {
        // The dictation key types at the cursor and never reaches Claude. Paused, only a dictation
        // already running may still end (pausing cancels it; a late gesture finds it gone).
        if case .dictation(let gesture) = event {
            if isPaused, gesture == .began { return }
            // A dictation takes the mic: a strip still up closes first, so none is ever left
            // open (its release is dropped by the guard below).
            if gesture == .began { switcherFlow?.closeForDictation() }
            await dictation?.handle(gesture)
            return
        }
        guard !isPaused else { return }
        // Dictation has the mic: the buddy key and the switcher wait until the words are typed
        // (QA R13: the strip never opens during a dictation).
        if dictation?.isActive == true { return }
        if await handleSwitcher(event) { return } // switcher stream (flag off: never)
        guard case .gesture(let gesture) = event else { return }
        if case .pressBegan(let fresh) = gesture { pressFresh = fresh }
        if releasePending {
            switch gesture {
            case .pressBegan:
                releasePending = false
            case .tap, .holdEnded, .holdDiscarded, .cancelled, .doubleTap:
                releasePending = false
                return // the release of the interrupted press
            default:
                return
            }
        }
        if keyboardInOverlay {
            await handleWhileTyping(gesture)
            return
        }
        // A press while an answer is in flight or on screen waits to become a real tap or hold:
        // a chord (AltGr+e types é, ⇧⌥- an em dash) ends in `.cancelled`, so it can't cancel a
        // minutes-long Deep turn or start the mic and a screenshot.
        if case .pressBegan = gesture, phase == .thinking || phase == .showing {
            freshPressWaiting = true
            return
        }
        if freshPressWaiting {
            freshPressWaiting = false
            switch gesture {
            case .tap, .holdBegan:
                await handleWhileTyping(gesture)
            case .doubleTap:
                await beginListening()
                await openTextBox()
            default:
                break
            }
            return
        }
        switch (gesture, phase) {
        case (.pressBegan, .listening(confirmedTap: true, _)):
            break // The release that follows sends.
        case (.pressBegan, .held):
            // A held recording always asks first, even if its chip was dismissed: the next tap
            // sends only once the user has seen what it will send.
            if heldChipVisible { break }
            showHeldChip()
            heldReminderShown = true
        case (.tap, .held), (.holdEnded, .held):
            if heldReminderShown {
                heldReminderShown = false // this tap only brought the chip back
            } else {
                await sendHeld()
            }
        case (.pressBegan, _):
            await beginListening()
        case (.tap, .listening(confirmedTap: false, _)):
            phase = .listening(confirmedTap: true, holding: false)
            await setKeyListening(true) // the next tap sends at once
        case (.tap, .listening(confirmedTap: true, _)),
             // The send press can race `setListening(true)` and still see double-tap enabled.
             (.doubleTap, .listening(confirmedTap: true, _)):
            await send()
        case (.holdBegan, .listening(let confirmed, _)):
            phase = .listening(confirmedTap: confirmed, holding: true)
            overlay.updateListeningHint(listenHint("release to send"))
        case (.holdEnded, .listening):
            await send()
        case (.holdDiscarded, .listening(confirmedTap: false, _)):
            await discardListening(confirmed: false) // a long hold may hold a lot of speech
        case (.cancelled, .listening(confirmedTap: false, _)):
            await discardListening()
        case (.cancelled(.otherKey), .listening(confirmedTap: true, _)):
            await interrupt(.typing) // typing elsewhere stops tap-to-talk and keeps the speech
        case (.doubleTap, .listening(confirmedTap: false, _)),
             // The double-tap the setup chip suggests, its first press having shown that chip.
             (.doubleTap, .showing) where setupChipVisible:
            await openTextBox()
        default:
            break
        }
    }

    /// A chord that types a character ends in `.cancelled`, never in `.tap` or `.holdBegan`, so
    /// the box and its draft survive it and the character reaches the field.
    func handleWhileTyping(_ gesture: GestureEvent) async {
        // Over an answer (not a chip or the report), the key replies: the hint's lesson.
        let replying = phase == .showing && keptOnScreen && !reportShowing
        switch gesture {
        case .tap:
            await beginListening()
            guard case .listening = phase else { return }
            if replying { noteReply(byKey: true) }
            phase = .listening(confirmedTap: true, holding: false)
            await setKeyListening(true) // the next tap sends at once
        case .holdBegan:
            await beginListening()
            guard case .listening = phase else { return }
            if replying { noteReply(byKey: true) }
            phase = .listening(confirmedTap: false, holding: true)
            overlay.updateListeningHint(listenHint("release to send"))
        default:
            break
        }
    }
}
