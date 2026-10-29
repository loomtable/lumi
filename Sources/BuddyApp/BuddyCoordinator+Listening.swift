import BuddyBridge
import BuddyCompanion
import BuddyContext
import BuddyConversations
import BuddyCore
import BuddyKeys
import BuddyOverlay
import BuddyTrace
import BuddyVoice
import CoreGraphics
import Foundation
import Synchronization

extension BuddyCoordinator {
    // MARK: - Listening

    /// Reads the front app and takes the screenshot, off the listening path.
    func startCapture() -> Task<Summon, Never> {
        let (context, tracer, shotDeadline) = (context, tracer, screenshotDeadline)
        let previousScreen = lastScreen.map { (fingerprint: $0.fingerprint, token: $0.token) }
        return Task {
            let summon = await context.capture()
            // A capture superseded by a new summon isn't traced; its numbers mean nothing.
            switch summon.result {
            case .blocked:
                if !Task.isCancelled {
                    tracer?.record(.contextPacket, duration: nil, lane: nil, outcome: .skipped, count: nil)
                }
                return Summon(context: summon, shot: nil) // Never capture a blocked app.
            case .packet(let p, let timings):
                if !Task.isCancelled {
                    // The builder's own measure, the "context packet" figure.
                    tracer?.record(.contextPacket, duration: .nanoseconds(Int64(timings.totalMs * 1_000_000)), lane: nil,
                                   outcome: timings.late.isEmpty ? .ok : .late, count: timings.late.count)
                }
                let shotStart = ContinuousClock.now
                let outcome = await Self.screenshot(
                    context, displayID: p.display?.id, focus: ModelRegion.focus(in: p), within: shotDeadline)
                let shot = outcome.shot
                if !Task.isCancelled {
                    tracer?.record(.screenshot, duration: .now - shotStart, lane: nil,
                                   outcome: shot == nil ? .failed : .ok, count: nil)
                    if outcome.unavailable == .notGranted {
                        tracer?.record(.permissionMissing, duration: nil, lane: nil, outcome: nil, count: nil)
                    }
                }
                return await Self.summon(summon, outcome, comparedWith: previousScreen, caret: Self.caret(in: p))
            case .noFrontApp:
                let outcome = await Self.screenshot(context, displayID: nil, within: shotDeadline)
                if outcome.unavailable == .notGranted, !Task.isCancelled {
                    tracer?.record(.permissionMissing, duration: nil, lane: nil, outcome: nil, count: nil)
                }
                return await Self.summon(summon, outcome, comparedWith: previousScreen)
            }
        }
    }

    func beginListening() async {
        let summonAt = ContinuousClock.now // "key press → mic live" starts here
        nextRouteSource = nil // a pick belongs to the listen it was made in…
        if let pick = switchedTo.take(), clock().timeIntervalSince(pick.at) <= Self.routeSourceLifetime {
            nextRouteSource = .switcherPick(pick.id) // …or, made without speech, to the next one
        }
        let previous = inFlightConversation
        let wasThinking = phase == .thinking
        // Asked again before the answer came: with sessions off that question is cancelled below,
        // so no capsule; with sessions on it keeps running behind, in its capsule (V-02).
        if wasThinking, !turnsKeepRunning, let previous { progress.end(session: SessionID(rawValue: previous)) }
        // Pressed over an approval card: a spoken yes or no answers it (V-03).
        answeringApproval = shownApproval
        shownApproval = nil
        let mine = nextEpoch()
        discardNeedsConfirmation = false
        releasePending = false
        phase = .listening(confirmedTap: false, holding: false)
        micLive = false
        interruptSent = false
        let point = pointer.location()
        lastAnchor = .point(point)
        summonPoint = point
        typedCardShowing = false
        reportShowing = false
        setupChipVisible = false
        overlay.setSpeaking(false)
        // Idle long enough that this question starts a fresh conversation: the pill and the
        // answer go back to their own spots, not where the user dragged the last one.
        if let last = lastAnswerAt, clock().timeIntervalSince(last) >= ConversationBook.idleLimit {
            overlay.resetPositions()
            lastAnswerAt = nil
        }
        listenFresh = pressFresh
        overlay.showListening(at: point, hint: listenHint("tap \(settings.keySymbol) to send"))
        overlay.setMicReady(false) // "Listening" only once the mic is live (micLive)
        trace(.summon)

        capture?.cancel()
        capture = startCapture()
        await voice.stopSpeaking() // first: the 150 ms stop target
        // Asked again before the answer came. With sessions on, the turn keeps running in the
        // background (V-02); the epoch moved on, so it no longer speaks or shows.
        if wasThinking, !turnsKeepRunning, let previous {
            traceEnd(.cancelled, ticket: ticket(conversation: previous), outcome: .cancelled)
            await turns.cancel(conversation: previous)
        }
        guard isCurrent(mine) else { return }
        do {
            try await voice.startListening()
            // Esc, Pause or a voice event may have ended this listen while the mic started.
            if !isCurrent(mine) {
                _ = await voice.discard(confirmed: true, playSound: false)
                return
            }
            micLive = true
            overlay.setMicReady(true)
            trace(.micLive, since: summonAt)
            playSummonSound(pressedAt: summonAt)
            watchScreenSharing(epoch: mine)
        } catch {
            guard isCurrent(mine) else { return }
            // Only the voice's own "still setting up" shows progress: a mic failure during setup's
            // later steps must say what it is.
            if let problem = error as? VoicePortError, problem.stillSettingUp {
                // Still loading the speech models (or retrying a failed load): show the real
                // progress and keep it live; before any, the voice's own line.
                let line = Self.setupLine(voiceSetup, key: typeKey) ?? Self.withTypeHint(problem.message, key: typeKey)
                await stopListeningWithProblem(line, followSetup: true)
            } else if let problem = error as? VoicePortError, problem.notSetUp {
                // No voice chosen yet: typing still works, and Settings › Voice sets it up.
                await stopListeningWithProblem(Self.withTypeHint(problem.message, key: typeKey),
                                               fix: .openSettings(.voice))
            } else {
                await stopListeningWithProblem(Self.voiceMessage(error, fallback: "The microphone didn't start."))
            }
        }
    }

    /// The summon sound says "I'm listening", so it waits for the mic to be live (the voice
    /// returns from `startListening` on its first real audio), and at least 300 ms after the
    /// press so a double-tap reads as one motion. A cancelled or failed listen is silent.
    func playSummonSound(pressedAt: ContinuousClock.Instant) {
        guard settings.sounds else { return }
        let voice = voice, sleep = sleep
        let wait = max(.zero, Self.summonSoundDelay - (.now - pressedAt))
        summonSound?.cancel()
        summonSound = Task {
            try? await sleep(wait)
            guard !Task.isCancelled else { return }
            await voice.play(.summon)
        }
    }

    static let summonSoundDelay: Duration = .milliseconds(300)

    /// Discards the recording. `confirmed: false` lets the voice ask first when there's more
    /// than 30 s of speech; then the recording is kept and the next Esc confirms.
    func discardListening(sound: Bool = true, confirmed: Bool = true) async {
        let mine = nextEpoch()
        nextRouteSource = nil
        summonSound?.cancel()
        let result = await voice.discard(confirmed: confirmed || discardNeedsConfirmation, playSound: sound)
        guard isCurrent(mine) else { return }
        if case .needsConfirmation(let seconds) = result {
            // Stop the mic first and keep the recording while asking (never ask over a live mic).
            if case .listening = phase {
                // Held from now on, so a lock or sharing event during the stop can't take over.
                phase = .held
                await setKeyListening(false)
                await voice.interrupt(.confirmingDiscard)
                guard isCurrent(mine) else { return }
            }
            discardNeedsConfirmation = true
            showChip("Press Esc again to discard \(Int(seconds.rounded())) s of speech, or tap \(settings.keySymbol) to send it.")
            phase = .held
            heldChipVisible = true
            return
        }
        discardNeedsConfirmation = false
        capture?.cancel()
        phase = .idle
        overlay.dismiss(.requested)
        await setKeyListening(false)
        restoreApproval() // a listen begun over an approval card: the card comes back
    }

    func showHeldChip(_ reason: String? = nil) {
        let lead = reason.map { "\($0) " } ?? "I stopped listening. "
        showChip("\(lead)Tap \(settings.keySymbol) to send it, or press Esc to discard.")
        phase = .held // after showChip, which sets .showing
        heldChipVisible = true
    }

    /// Stops listening from outside (lock, sleep, screen sharing, typing) and keeps the speech.
    public func interrupt(_ reason: ListenInterruption) async {
        guard case .listening(let confirmed, let holding) = phase, !interruptSent else { return }
        // The mic isn't up yet: there's no speech to keep, so end the listen here (the voice
        // would have nothing to stop and never report back).
        guard micLive else {
            await discardListening(sound: false)
            return
        }
        interruptSent = true
        releasePending = !confirmed || holding
        _ = nextEpoch()
        summonSound?.cancel()
        await setKeyListening(false)
        await voice.interrupt(reason)
        // The voice reports what it kept with .autoStopped(held:), which shows the held chip.
    }

    // MARK: - System interruptions

    /// Screen lock and sleep stop listening and keep the speech (safeguards), and stop
    /// a reply reading out to an empty room. Display sleep alone doesn't: the user may still be
    /// talking, and a lock on display sleep sends its own notification.
    func handle(_ event: SystemInterruption) async {
        switch event {
        case .screenLocked:
            await stopSpeakingForLock()
            await interrupt(.screenLocked)
        case .systemWillSleep:
            await stopSpeakingForLock()
            await interrupt(.systemSleep)
        case .remoteScreenSharingStarted: await interrupt(.screenSharing)
        case .screenUnlocked, .systemDidWake, .displaysDidSleep, .displaysDidWake, .remoteScreenSharingEnded: break
        }
    }

    func stopSpeakingForLock() async {
        guard phase == .showing else { return }
        speechGeneration += 1 // a reply still synthesising must not start afterwards
        overlay.setSpeaking(false)
        await voice.stopSpeaking()
    }

    /// Inbound macOS Screen Sharing only (there's no API for Zoom, Meet or FaceTime sharing).
    /// Yields at once when a session is already running.
    func watchScreenSharing(epoch mine: Int) {
        endSharingWatch()
        guard let stream = interruptions?.watchRemoteScreenSharing() else { return }
        sharingWatch = Task { [weak self] in
            for await event in stream {
                // An event the poll buffered before the watch ended must not stop a later listen.
                guard !Task.isCancelled, let self, self.isCurrent(mine) else { return }
                await self.handle(event)
            }
        }
    }

    func endSharingWatch() {
        sharingWatch?.cancel() // ends the stream, which stops its poll
        sharingWatch = nil
    }

    /// Sends a recording the voice kept after stopping by itself.
    func sendHeld() async {
        let mine = epoch
        let gesture = ContinuousClock.now
        discardNeedsConfirmation = false
        heldChipVisible = false
        phase = .thinking
        inFlightConversation = nil // nothing of this ask is sent yet
        overlay.showThinking(lane(for: .quick), status: nil)
        do {
            guard let transcript = try await voice.sendHeld() else {
                if isCurrent(mine) { dismissQuietly() }
                return
            }
            guard isCurrent(mine) else { return }
            await ask(transcript: transcript, epoch: mine, startedAt: gesture)
        } catch {
            if isCurrent(mine) { showChip(Self.voiceMessage(error, fallback: "I couldn't hear that.")) }
        }
    }

    /// Listening ended on an error: stop the mic and side tasks, then show the line.
    /// `followSetup`: the chip then follows the voice's setup progress until it's ready.
    func stopListeningWithProblem(_ message: String, fix: FixAction? = nil, followSetup: Bool = false) async {
        let (mine, shown) = (epoch, voiceSetup)
        summonSound?.cancel()
        capture?.cancel()
        showChip(message, fix: fix)
        setupChipVisible = followSetup // before the awaits, so no progress event is missed
        _ = await voice.discard(confirmed: true, playSound: false)
        await setKeyListening(false)
        // Catch up if setup moved on meanwhile.
        if followSetup, isCurrent(mine), voiceSetup != shown { showSetupProgress(voiceSetup) }
    }
}
