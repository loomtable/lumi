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
    // MARK: - Research

    /// Quick or the router asked for Research: a background job starts and the capsule tracks it.
    /// The buddy stays free; the spoken "On it" line came with the request. `packet`: what the
    /// question was asked about (a turn in the background keeps its own).
    func startResearch(_ reply: ReplyTracker, packet: ContextPacket?, spoke: Bool, epoch mine: Int) async {
        guard let research, var packet else {
            if isCurrent(mine) { showChip("Research isn't available right now.", lane: .research) }
            return
        }
        packet.utterance = reply.question
        packet.screenshot = nil // outside the job's sandboxed folder; it couldn't read it
        packet.screenshotDetail = nil // no images go with a job
        // The user's own words are the job's instruction; nothing is paraphrased.
        let job = await research.start(
            ResearchRequest(conversationID: reply.conversationID, topic: Self.researchTopic(reply.question), packet: packet))
        researchSpoke[job.id] = spoke
        traceEnd(.researchStarted, ticket: ticket(epoch: mine), lane: .research, outcome: nil)
        guard isCurrent(mine) else { return }
        dismissQuietly()
        overlay.showToast("Running in the background", at: pointer.location())
    }

    /// A job finished: the done chime, then its line, unless voice replies are off or the user is
    /// talking (the voice skips speech over a live mic).
    /// The line is spoken only when nothing else is happening: never over a listen, the text
    /// box, a turn or another answer (the capsule already says "Report ready"), never paused.
    func researchFinished(_ job: ResearchJob) {
        let spokeIt = researchSpoke.removeValue(forKey: job.id) ?? true
        trace(.researchFinished, lane: .research, count: job.sourceCount)
        guard !isPaused else { return }
        let line = job.say ?? ResearchController.readyLine(job)
        let speak = phase == .idle && shouldSpeak(spoke: spokeIt)
        let (voice, sounds) = (voice, settings.sounds)
        let mine = epoch
        Task { [weak self] in
            if sounds { await voice.play(.researchDone) }
            guard speak, let self, self.isCurrent(mine) else { return }
            await self.say(line, epoch: mine)
        }
    }
}
