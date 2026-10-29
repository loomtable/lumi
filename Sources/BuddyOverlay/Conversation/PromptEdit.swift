import BuddyCore
import SwiftUI

/// The user's bubble, or its inline editor while that prompt is being edited. The pencil shows
/// on hover only when the prompt can be edited (nothing running).
struct PromptBubble: View {
    let turn: PageTurn
    let model: ConversationPageModel
    let density: PageDensity
    let t: Tokens

    var body: some View {
        if model.editing?.turnID == turn.id {
            PromptEditor(model: model, density: density, t: t)
        } else {
            UserBubble(text: turn.question, density: density, t: t,
                       onEdit: model.canEdit(turn) ? { model.beginEdit(turn.id) } : nil)
        }
    }
}

/// Edit an earlier prompt in place: the words in the bubble's shape, then Cancel and Send.
/// Return sends, Esc cancels. Sending replaces this prompt and everything after it.
struct PromptEditor: View {
    let model: ConversationPageModel
    let density: PageDensity
    let t: Tokens
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(get: { model.editing?.text ?? "" }, set: { model.editing?.text = $0 })
    }

    private var sending: Bool { model.editing?.sending == true }

    private var canSend: Bool {
        !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.page.isRunning && !sending
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(density.body.font)
                .lineSpacing(density.body.spacing)
                .foregroundStyle(t.text.color)
                .lineLimit(1...12)
                .focused($focused)
                .disabled(sending)
                .onSubmit { if canSend { model.sendEdit() } }
                .onExitCommand { model.cancelEdit() }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(PageColors(t: t).tile.color,
                            in: RoundedRectangle(cornerRadius: PageShape.bubbleRadius, style: .continuous))
                .accessibilityLabel("Edit your message")
            if model.editing?.confirming == true {
                Text("Later replies changed files. Those changes stay.")
                    .font(density.caption.font)
                    .foregroundStyle(t.secondaryText.color)
            }
            HStack(spacing: 8) {
                Button("Cancel", action: model.cancelEdit)
                    .buttonStyle(.pill)
                    .disabled(sending)
                Button("Send", action: model.sendEdit)
                    .buttonStyle(.pillProminent)
                    .disabled(!canSend)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear { focused = true }
    }
}
