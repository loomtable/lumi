import BuddyCore
import SwiftUI

/// One finished turn of a conversation: the question, then the answer as it was, read-only.
/// Full screen shows a conversation's earlier turns with these; the Conversations window
/// can host the same view once it shows transcripts.
public struct TranscriptTurnView: View {
    let turn: TranscriptTurn

    public init(turn: TranscriptTurn) { self.turn = turn }

    public var body: some View {
        TokensReader { t in
            PastTurnRows(turn: turn, t: t)
        }
    }
}

/// A whole conversation, oldest turn first, for the Conversations window. It scrolls itself
/// and opens on the newest turn; text can be selected and copied. It reads the tokens of the
/// window's appearance and needs no overlay controller or panel.
public struct TranscriptView: View {
    let turns: [TranscriptTurn]

    public init(turns: [TranscriptTurn]) { self.turns = turns }

    public var body: some View {
        TokensReader { t in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(turns) { turn in
                            PastTurnRows(turn: turn, t: t).id(turn.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .textSelection(.enabled)
                }
                // Opens on the newest turn, but a short conversation sits at the top, not the bottom.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
                // Another conversation picked in the same pane: open on its newest turn too.
                .onChange(of: turns.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
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
                    .fill(t.variant.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
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
                        ActionButton(title: action.label, kind: .quiet, t: t) {}
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
