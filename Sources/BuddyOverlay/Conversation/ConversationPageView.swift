import BuddyCore
import SwiftUI

/// One session's conversation page: the thread on a reading well, then the composer. The
/// Panel renders it at `.compact` density, the Studio column at `.comfortable`. Headers are
/// the host's (the Panel's 44 pt header, the Studio's session header).
public struct ConversationPageView: View {
    let model: ConversationPageModel
    let density: PageDensity
    /// The composer gained or lost keyboard focus.
    var onComposerFocus: (Bool) -> Void
    /// The height the page would like: the thread's content plus the composer (the Panel
    /// grows with it).
    var onContentHeight: (CGFloat) -> Void
    @State private var threadHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    /// How many of the latest turns the thread lays out; "Show earlier" adds a page more.
    @State private var shown = Self.turnsPerPage
    /// Every turn shown is measured on open (about 4 ms each in a debug build), so a long
    /// session opens on its latest turns.
    static let turnsPerPage = 50

    public init(model: ConversationPageModel, density: PageDensity, onComposerFocus: @escaping (Bool) -> Void = { _ in },
                onContentHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.density = density
        self.onComposerFocus = onComposerFocus
        self.onContentHeight = onContentHeight
    }

    /// For hosts that pass page actions on as `PanelEvent`s (the Studio column): it sets the
    /// model's `onAction`.
    public init(model: ConversationPageModel, density: PageDensity, onEvent: @escaping @MainActor (PanelEvent) -> Void) {
        let id = model.session
        model.onAction = { onEvent(PanelEvent($0, session: id)) }
        self.init(model: model, density: density)
    }

    /// While the `/` or `@` menu is open, room for it above the composer, so a short Panel grows
    /// rather than cutting the menu at its top. A fixed amount, so the Panel doesn't jump as rows
    /// narrow.
    private var menuRoom: CGFloat { model.composer.menu == nil ? 0 : CompletionMenuView.maxHeight + 6 }

    public var body: some View {
        TokensReader { t in
            VStack(spacing: 0) {
                thread(t)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 8) {
                    // A pending approval is pinned above the composer while it waits, so it never
                    // scrolls away; the turn keeps the answered card.
                    if let pending = model.page.pendingApprovals.first {
                        ApprovalCard(approval: pending, density: density, t: t) { allow, always, message in
                            model.approve(pending.id, allow: allow, always: always, message: message)
                        }
                    }
                    if let notice = model.notice {
                        Text(notice)
                            .font(density.caption.font)
                            .foregroundStyle(t.secondaryText.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ComposerView(model: model, density: density, t: t, onFocus: onComposerFocus)
                }
                .padding(.bottom, 12)
                .padding(.top, 8)
                .readingColumn(density, inset: density.composerInset)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { h in
                    bottomHeight = h
                    onContentHeight(threadHeight + h + menuRoom)
                }
                .onChange(of: model.composer.menu == nil) { onContentHeight(threadHeight + bottomHeight + menuRoom) }
            }
        }
    }

    @ViewBuilder private func thread(_ t: Tokens) -> some View {
        ScrollView(.vertical) {
            // Not lazy: a LazyVStack guesses the height of turns it hasn't measured, so scrolling
            // up a long page grew it by 1,000+ pt near the top and the view jumped (owner, Oct 29).
            // Every turn shown is measured once, which keeps the height exact.
            VStack(alignment: .leading, spacing: density.turnGap) {
                if let lane = model.openLane, let mate = model.page.teammates.first(where: { $0.id == lane }) {
                    TeammateLane(mate: mate, model: model, density: density, t: t)
                } else {
                    let turns = model.page.turns
                    let first = max(0, turns.count - shown)
                    if first > 0 {
                        Button("Show earlier") { shown += Self.turnsPerPage }
                            .buttonStyle(.plain)
                            .font(density.callout.font)
                            .foregroundStyle(t.secondaryText.color)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(turns[first...]) { turn in
                        TurnView(turn: turn, model: model, density: density, t: t, isLatest: turn.id == turns.last?.id)
                            .id(turn.id)
                    }
                }
            }
            .padding(.vertical, density.threadPadding)
            .readingColumn(density)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { h in
                threadHeight = h
                onContentHeight(h + bottomHeight + menuRoom)
            }
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}

