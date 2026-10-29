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
    // MARK: - Helpers

    /// Kinds, timings and counts only: nothing the user said or saw can reach the trace.
    func trace(_ event: TraceEvent, since start: ContinuousClock.Instant? = nil, lane: Mode? = nil,
                       outcome: TraceOutcome? = nil, count: Int? = nil) {
        tracer?.record(event, duration: start.map { .now - $0 }, lane: lane, outcome: outcome, count: count)
    }

    /// A piece of this turn's reply started or queued; the first one is the spoken-word latency.
    func markSpoken(_ reply: inout ReplyTracker) {
        if !reply.speaking { trace(.firstSpokenWord, since: reply.startedAt) }
        reply.startedSpeaking(speechGeneration)
    }

    func lane(for mode: Mode) -> Lane {
        switch mode {
        case .quick: Lane(mode: .quick, model: settings.quick.model)
        case .deep: Lane(mode: mode, model: settings.deep.model)
        case .research: Lane(mode: mode, model: settings.research.model)
        }
    }

    func anchor(for packet: ContextPacket) -> Anchor {
        if let b = packet.selection?.bounds {
            return .rect(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        }
        if let c = packet.cursor { return .point(CGPoint(x: c.x, y: c.y)) }
        return lastAnchor
    }

    /// The capture's screen fingerprint and whether it matches `previous`, made off the main actor
    /// while the user speaks (a few milliseconds at the model's image size).
    /// `caret`: the text caret's rectangle, the one place a change (its blink) doesn't count.
    nonisolated static func summon(_ context: SummonContext, _ outcome: ShotOutcome,
                                   comparedWith previous: (fingerprint: ScreenFingerprint, token: String)?,
                                   caret: CGRect? = nil) async -> Summon {
        let screenshot = outcome.shot?.screenshot
        let (fingerprint, same) = await Task.detached(priority: .userInitiated) { () -> (ScreenFingerprint?, Bool) in
            let fingerprint = screenshot?.fingerprint()
            return (fingerprint, fingerprint.map { previous?.fingerprint.isSameScreen(as: $0, caret: caret) ?? false } ?? false)
        }.value
        return Summon(context: context, shot: outcome.shot, unavailable: outcome.unavailable,
                      fingerprint: fingerprint, sameAs: same ? previous?.token : nil)
    }

    /// The caret's rectangle in global points: selection bounds with nothing selected, and only
    /// when it's caret-sized. A larger rect from some app would hide real changes, so it exempts
    /// nothing.
    nonisolated static func caret(in packet: ContextPacket) -> CGRect? {
        guard let selection = packet.selection, (selection.text ?? "").isEmpty, let b = selection.bounds,
              b.width <= caretMax.width, b.height <= caretMax.height else { return nil }
        return CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
    }

    /// At most 4 pt wide and 1.5 lines of large text tall.
    nonisolated static let caretMax = (width: 4.0, height: 32.0)

    /// Names the screen this question shows: the last token while the screen is unchanged in the
    /// same conversation, so the bridge doesn't send a session the same image twice.
    func screenToken(_ captured: Summon, conversation: String) -> String? {
        guard let fingerprint = captured.fingerprint else { return nil }
        if let same = captured.sameAs, let last = lastScreen, last.token == same, last.conversation == conversation {
            return same
        }
        let token = UUID().uuidString
        lastScreen = (conversation, fingerprint, token)
        return token
    }

    /// `reason`: `.requested` folds toward the source; a user's close tucks it into the menu-bar dot.
    func dismissQuietly(_ reason: DismissReason = .requested) {
        lastMainAction = nil
        shownFix = nil
        overlay.dismiss(reason)
        phase = .idle
    }

    /// How many of the model's actions the card shows, mirroring the overlay's `shownActions`: at
    /// most 3 buttons in all, counting the main button or an approval card's Cancel, and a card's
    /// link button; a chip has one.
    static func visibleActions(_ block: BuddyBlock, mainAction: MainAction? = nil) -> Int {
        let isChip = block.shape == .chip
        let reserved = (mainAction != nil || block.needsApproval ? 1 : 0) + (block.link != nil && !isChip ? 1 : 0)
        return min(block.actions.count, max(0, (isChip ? 1 : BuddyBlock.maxActions) - reserved))
    }

    /// The answer's main button, from the turn's packet: Replace when the selection is
    /// in an editable field, Insert into a focused field, otherwise Copy. Only with paste content:
    /// `insert` for Insert and Replace (never the spoken headline), `insert` or card HTML for Copy.
    /// Never in a terminal (inserting into a shell could run something), on an approval card, or
    /// when the user switched Insert & Replace off.
    static func mainAction(for block: BuddyBlock, packet: ContextPacket?) -> MainAction? {
        guard !block.needsApproval else { return nil }
        let insertAllowed = packet?.features?.insert != false
        let insert = !(block.insert ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if insert, insertAllowed, packet?.app?.kind != .terminal, let editable = packet?.editable, editable.field {
            return editable.selection ? .replace : .insert
        }
        return insert || !(block.cardHTML ?? "").isEmpty ? .copy : nil
    }

    /// The user pressed the card's link button (a draft the turn made elsewhere). Only the shown
    /// answer's own link, so a stale or forged event can't open anything else.
    func openLink(_ url: URL) {
        guard phase == .showing, !reportShowing, let link = lastAnswer?.link, link.url == url else { return }
        openURL?.open(url)
    }

    /// A failure chip with its fix, read out when the question was spoken. `reply`:
    /// the failed turn's, so a reply the user stopped stays silent.
    func showFailure(_ line: TurnFailureLine.Line, lane mode: Mode, spoke: Bool, reply: ReplyTracker? = nil,
                             epoch mine: Int) async {
        showChip(line.text, lane: mode, fix: line.fix)
        shownFixSpoke = spoke
        guard shouldSpeak(spoke: spoke) else { return }
        _ = await say(line.text, since: reply?.speaking == true ? reply?.speechGeneration : nil, epoch: mine)
    }

    /// The job's topic, as the capsule shows it and the ready line says it ("Your research on QT is
    /// ready"): the question without the "research" command the router heard. A Quick hand-off's
    /// question has no command and stays whole.
    static func researchTopic(_ question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(trimmed)
        guard rest.lowercased().hasPrefix("research"),
              rest.dropFirst(8).first.map({ $0.isWhitespace || $0.isPunctuation }) ?? false
        else { return trimmed }
        rest = rest.dropFirst(8).drop { $0.isWhitespace || $0.isPunctuation }
        for word in ["on", "about", "into", "for"] where rest.lowercased().hasPrefix(word + " ") {
            rest = rest.dropFirst(word.count + 1)
            break
        }
        let topic = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
        return topic.isEmpty ? trimmed : topic
    }

    /// The tools Claude Code didn't allow this turn, each once.
    static func deniedLine(_ tools: [String]) -> String? {
        var seen = Set<String>()
        let unique = tools.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : "Claude Code wasn't allowed to use \(unique.joined(separator: ", "))."
    }

    /// What the user switched off, told to the model on every ask (settings can change mid-conversation).
    var features: ContextPacket.Features? {
        .unlessAllOn(rings: settings.rings, insert: settings.insert)
    }

    /// One true line per bridge failure. Cancelling shows nothing.
    /// What is left of `say` after its first sentence was spoken. Whitespace differences are
    /// ignored; if the spoken text isn't a prefix at all, the whole `say` is spoken rather than
    /// leaving the answer silent.
    static func remainder(of say: String, after spoken: String?) -> String {
        guard let spoken, !spoken.isEmpty else { return say }
        let fullWords = say.split(whereSeparator: \.isWhitespace)
        let spokenWords = spoken.split(whereSeparator: \.isWhitespace)
        guard fullWords.starts(with: spokenWords) else { return say }
        return fullWords.dropFirst(spokenWords.count).joined(separator: " ")
    }
}
