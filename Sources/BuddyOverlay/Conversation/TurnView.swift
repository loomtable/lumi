import AppKit
import BuddyCore
import SwiftUI

/// One turn (04 §4.1): the context strip, the user's bubble, the Trail, the answer on the well
/// (no bubble, no avatar), approvals and questions inline, then the answer's actions.
struct TurnView: View {
    let turn: PageTurn
    let model: ConversationPageModel
    let density: PageDensity
    let t: Tokens
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: density.blockGap) {
            if let context = turn.context, let headline = context.headline {
                ContextStripView(strip: context, headline: headline, density: density, t: t)
            }
            if !turn.question.isEmpty { PromptBubble(turn: turn, model: model, density: density, t: t) }
            if turn.fromHistory {
                // A past turn has no live timing: no "Worked for 0:00", only who helped.
                if !turn.historyTeammates.isEmpty {
                    Text("With " + turn.historyTeammates.joined(separator: ", "))
                        .font(density.callout.font)
                        .foregroundStyle(t.secondaryText.color)
                }
            } else if turn.started || !turn.trail.rows.isEmpty || turn.finished {
                TrailView(trail: turn.trail, density: density, t: t, showThinking: model.showThinking)
            }
            if let plan = turn.plan, !plan.isEmpty { PlanTile(todos: plan, density: density, t: t) }
            if !turn.answer.isEmpty {
                MarkdownView(markdown: turn.answer, density: density, t: t)
                    .padding(.top, -4)
            }
            ForEach(turn.questions) { q in
                QuestionCard(question: q, density: density, t: t,
                             onAnswer: { model.answer(q.id, answers: $0) },
                             onSomethingElse: { model.answerInComposer(q.id, questions: q.ask.items.map(\.question)) })
            }
            ForEach(turn.approvals.filter { $0.state != .pending }) { a in
                ApprovalCard(approval: a, density: density, t: t) { allow, always, message in
                    model.approve(a.id, allow: allow, always: always, message: message)
                }
            }
            if turn.interrupted, isLatest {
                // The Trail line already says "Interrupted" (QA U33): only the action here.
                HStack(spacing: 8) {
                    Button("Continue", action: model.continueInterrupted)
                        .buttonStyle(.pillProminent)
                }
            }
            // On every answer, never only on hover: a row that came and went grew the turn
            // and the page jumped under the pointer (owner, Oct 29).
            if turn.finished, !turn.answer.isEmpty {
                AnswerActions(turn: turn, density: density, t: t)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What Lumi read: a 56 × 36 crop, then "Read from <app>" and the document · selection.
struct ContextStripView: View {
    let strip: ContextStrip
    let headline: String
    let density: PageDensity
    let t: Tokens
    @State private var zoomed = false

    var body: some View {
        HStack(spacing: 10) {
            if let image = thumbnail {
                Button { zoomed.toggle() } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: PageShape.thumbRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What Lumi read")
                .popover(isPresented: $zoomed) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480, maxHeight: 480)
                        .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(density.caption.font)
                    .foregroundStyle(t.secondaryText.color)
                if let sub = strip.subline {
                    Text(sub)
                        .font(density.caption.font)
                        .foregroundStyle(t.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: NSImage? {
        guard strip.readScreen, let path = strip.screenshotPath else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

/// The user's words: the quiet trailing bubble, at most 78% of the column. With `onEdit`, a
/// pencil shows beside it on hover.
struct UserBubble: View {
    let text: String
    let density: PageDensity
    let t: Tokens
    var onEdit: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        TrailingShare(fraction: 0.78) {
            HStack(alignment: .bottom, spacing: 2) {
                if let onEdit {
                    // Always laid out, shown on hover: the row never changes height.
                    HeaderIcon(symbol: "pencil", label: "Edit", action: onEdit)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
                bubble
            }
        }
        .onHover { hovering = $0 }
    }

    private var bubble: some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(density.body.font)
            .lineSpacing(density.body.spacing)
            .foregroundStyle(t.text.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PageColors(t: t).tile.color,
                        in: RoundedRectangle(cornerRadius: PageShape.bubbleRadius, style: .continuous))
            .textSelection(.enabled)
            .accessibilityLabel("You: \(text)")
    }
}

/// Takes the width it's offered and sets its one child against the trailing edge, at most
/// `fraction` of that width. Not `containerRelativeFrame`: its container is the scroll view,
/// which in Studio is the whole window, so the bubble pushed the turn past the reading column
/// and the answer ran off the right edge (owner, Oct 29).
private struct TrailingShare: Layout {
    let fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(share(of: proposal))
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return CGSize(width: offered ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                              proposal: share(of: ProposedViewSize(width: bounds.width, height: proposal.height)))
    }

    private func share(of proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 * fraction }, height: proposal.height)
    }
}

extension View {
    /// A Copy button's "Copied" goes back to Copy after a moment, so a second copy reads as one
    /// (QA S-14).
    public func resettingCopied(_ copied: Binding<Bool>, after delay: Duration = .seconds(1.5)) -> some View {
        task(id: copied.wrappedValue) {
            guard copied.wrappedValue else { return }
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { copied.wrappedValue = false }
        }
    }
}

/// Copy, and "↳ N files" for what the turn edited. Copy stays quiet until the pointer is on
/// it; hover changes only its opacity, never the layout.
private struct AnswerActions: View {
    let turn: PageTurn
    let density: PageDensity
    let t: Tokens
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HeaderIcon(symbol: copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy answer") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.answer.text, forType: .string)
                copied = true
            }
            .resettingCopied($copied)
            .opacity(hovering || copied ? 1 : 0.55)
            .onHover { hovering = $0 }
            Spacer()
            let files = Self.files(turn.trail)
            if !files.isEmpty {
                Text("↳ \(files.count) \(files.count == 1 ? "file" : "files")")
                    .font(density.caption.font)
                    .foregroundStyle(t.secondaryText.color)
                    .help(files.joined(separator: "\n"))
            }
        }
    }

    static func files(_ trail: Trail) -> [String] {
        var out: [String] = []
        for case let s? in trail.rows.map(\.step) where s.kind == .edit || s.kind == .write {
            if let o = s.object, !out.contains(o) { out.append(o) }
        }
        return out
    }
}
