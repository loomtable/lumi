import BuddyCore
import SwiftUI

/// One finished turn of a conversation: the question, then the answer as it was, read-only.
/// Full screen shows a conversation's earlier turns with these.
public struct TranscriptTurnView: View {
    let turn: TranscriptTurn

    public init(turn: TranscriptTurn) { self.turn = turn }

    public var body: some View {
        TokensReader { t in
            PastTurnRows(turn: turn, t: t)
        }
    }
}

/// The question and the past answer, inside a card's reading well.
struct PastTurnRows: View {
    let turn: TranscriptTurn
    let t: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuestionBubble(text: turn.question, t: t)
            PastAnswer(turn: turn, t: t)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the user asked, on the trailing side in a quiet bubble.
struct QuestionBubble: View {
    let text: String
    let t: Tokens

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(trimmed)
                .font(Typeface.detail)
                .foregroundStyle(t.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(t.text.opacity(t.variant.dark ? 0.08 : 0.05).color))
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("You asked: \(trimmed)")
        }
    }
}

/// A past answer: its lane, the headline, the card as text and its actions, dimmed and
/// disabled (only the latest answer's actions run).
struct PastAnswer: View {
    let turn: TranscriptTurn
    let t: Tokens

    static func cardText(_ block: BuddyBlock) -> String? {
        guard let html = block.cardHTML else { return nil }
        let text = CardText.plainText(fromHTML: html)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        let lane = Lane(mode: turn.mode, model: turn.model)
        VStack(alignment: .leading, spacing: 8) {
            Text(lane.label)
                .font(Typeface.label)
                .foregroundStyle(lane.isEmphasized ? t.emberText.color : t.secondaryText.color)
            Text(turn.block.say)
                .font(Typeface.headline)
                .foregroundStyle(t.text.color)
                .fixedSize(horizontal: false, vertical: true)
            if let text = Self.cardText(turn.block) {
                Text(text)
                    .font(Typeface.detail)
                    .foregroundStyle(t.text.color)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !turn.block.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(turn.block.actions.prefix(BuddyBlock.maxActions).enumerated()), id: \.offset) { _, action in
                        ActionButton(title: action.label, kind: .quiet) {}
                    }
                }
                .disabled(true)
                .opacity(0.5)
                .accessibilityHint("Earlier answer; its actions no longer run.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
