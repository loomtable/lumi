import BuddyCore
import Foundation

/// Lumi's voice layer for one voice turn in an open session (02 §D8.1). The session's system
/// prompt is the user's own, so the answer rules travel in the user message: in full on the
/// session's first voice turn and on the first one after a compaction, as a short reminder
/// otherwise.
public enum VoiceEnvelope {
    public enum Rules: Sendable, Equatable {
        case full(String)
        case reminder
    }

    static let open = "<lumi-voice>"
    static let close = "</lumi-voice>"
    static let reminder = "Voice turn: reply with exactly one `buddy` block per the Lumi voice rules above, `say` first, its first sentence at most 15 words."
    static let topicLine = "Also add `topic` to the block: {\"title\": \"2 to 4 words naming this conversation\", \"symbol\": \"one SF Symbol name for its subject (no animals)\"}."

    /// `<lumi-voice>` + `<buddy-packet>` + `<question>` (the same escaping as Quick and Deep), any
    /// note or approval mark, then the rules. Images: the screenshot, then the close-up (only with it).
    /// `quickNote`: what Quick said when it handed off (model text, escaped).
    /// `approved`: the engine's own mark that the user pressed an action button.
    /// `askTopic`: on turn 1 and turn 3 only.
    public static func input(packet: ContextPacket, screenshot: TurnInput.Image?, detail: TurnInput.Image?, rules: Rules,
                             quickNote: String? = nil, approved: Bool = false, askTopic: Bool = false) -> TurnInput {
        var text = open + "\n" + BuddyPrompt.body(packet)
        if let quickNote, !quickNote.isEmpty { text += "\n<quick-note>\(BuddyPrompt.escape(quickNote))</quick-note>" }
        if approved { text += "\n<approved-action/>" }
        switch rules {
        case .full(let rules):
            text += "\n<lumi-voice-rules>\n" + rules.trimmingCharacters(in: .whitespacesAndNewlines) + "\n</lumi-voice-rules>"
        case .reminder:
            text += "\n" + reminder
        }
        if askTopic { text += "\n" + topicLine }
        text += "\n" + close
        let images = screenshot.map { [$0] + (detail.map { [$0] } ?? []) } ?? []
        return TurnInput(text: text, images: images)
    }

    /// The full voice rules: the buddy-answer core (`SKILL.md`, frontmatter dropped), `open.md`
    /// (which carries the scope line) and the teammates rule. Nil when the core can't be read.
    public static func rulesText(plugin: URL, teammates: TeammatesMode) -> String? {
        guard var text = AnswerRules.text(for: [], in: plugin) else { return nil }
        let notes = plugin.appendingPathComponent("skills/buddy-answer/open.md")
        if let open = try? String(contentsOf: notes, encoding: .utf8) {
            text += "\n" + open.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        if let line = teammatesLine(teammates) { text += "\n" + line + "\n" }
        return text
    }

    /// Voice turns only (lead): typed turns get no teammate instruction.
    static func teammatesLine(_ mode: TeammatesMode) -> String? {
        switch mode {
        case .askFirst: "Before starting background teammates (subagents), propose the split in one spoken line and wait for yes."
        case .automatic: nil
        case .off: "Don't start background teammates (subagents); do the work yourself."
        }
    }
}
