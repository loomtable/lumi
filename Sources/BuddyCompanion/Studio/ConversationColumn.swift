import BuddyCore
import BuddyOverlay
import SwiftUI

/// A session in Studio (04 §6.3): its title and actions in the window toolbar, the teammates'
/// lane, then the page at comfortable density, with the top-edge working light while it runs.
struct ConversationColumn: View {
    let session: SessionSnapshot
    let model: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TokensReader { t in
            VStack(spacing: 0) {
                // The team's lane while it works, as in the Panel: the page's roster (seeded from
                // the snapshot, QA U30), the snapshot's while the page loads. One view either way,
                // so the chips don't swap out under the pointer.
                if team.live {
                    TeamLane(team: team.members, selected: page?.openLane) { mate in
                        if let page { page.openLane = page.openLane == mate.id ? nil : mate.id }
                        else { model.openTeammate(mate.id, in: session.id) }
                    }
                    .readingColumn(.comfortable, inset: PageDensity.comfortable.inset - TeamLane.inset)
                    .padding(.vertical, 6)
                    .transition(Motion.transition(y: -6, reduceMotion: reduceMotion))
                }
                Divider()
                StudioPageSlot(session: session, model: model)
                    .id(session.id)
            }
            // The title and actions sit in the window's toolbar: no header band above the page.
            .modifier(ConversationHeader(session: session, model: model))
            .overlay(alignment: .top) {
                // The Panel's light: it sweeps, and holds still with Reduce Motion (QA U22).
                // Only while something runs: the lead's turn or a teammate (never an ask left after
                // the answer, or a team that handed back).
                if running { WorkingLight(color: t.emberMark, reduceMotion: reduceMotion).transition(.opacity) }
            }
            .animation(Motion.crossfade, value: running)
            // The lane tucks away once the lead has answered after the team (04 §5.3).
            .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: team.live)
        }
    }

    /// The column's page, once it's up.
    private var page: ConversationPageModel? {
        model.page.flatMap { $0.session == session.id ? $0 : nil }
    }

    private var running: Bool { session.isRunning || page?.page.team.isWorking == true }

    /// The team the lane shows: the page's while it's up (it follows the stream), else the store's.
    private var team: (members: [TeammateSnapshot], live: Bool) {
        if let page { return (page.page.team.members, page.page.team.isLive) }
        return (session.teammates, session.teamLive)
    }
}

/// The session's title and actions in the window's toolbar (owner, Oct 29: no header band; the
/// title sits in the title bar, as in ChatGPT and Claude): the agent mark and the title on the
/// leading side, Continue, Open as Panel, the Inspector and ⋯ on the trailing side.
struct ConversationHeader: ViewModifier {
    let session: SessionSnapshot
    let model: StudioModel
    @State private var editing = false
    @State private var draft = ""
    @State private var forgetting = false
    @State private var width = CGFloat.greatestFiniteMagnitude
    @FocusState private var titleFocused: Bool

    /// Narrower than this (a small window with the inspector open), Open as Panel and the
    /// Inspector fold into ⋯ so the title keeps its room (QA U54).
    static func foldsButtons(width: CGFloat) -> Bool { width < 460 }

    func body(content: Content) -> some View {
        let folded = Self.foldsButtons(width: width)
        content
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .toolbar {
                ToolbarItem(placement: .navigation) { title }
                    .sharedBackgroundVisibility(.hidden)
                // The actions stay on the trailing edge, however long the title.
                ToolbarSpacer(.flexible)
                if interrupted {
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            if !folded {
                                TokensReader { t in Text("Interrupted").font(.system(size: 12)).foregroundStyle(t.secondaryText.color) }
                            }
                            Button("Continue") { Task { await model.continueInterrupted(session.id) } }
                                .buttonStyle(.pillProminent)
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !folded {
                        // The inverse of the Panel's "Open in Lumi" arrows, so the pair reads as one move.
                        Button(action: openPanel) { Label("Open as Panel", systemImage: "arrow.down.right.and.arrow.up.left") }
                            .help("Open as Panel (⇧⌘P)")
                        Button(action: toggleInspector) { Label("Inspector", systemImage: "sidebar.right") }
                            .help("Inspector (⌥⌘I)")
                    }
                    Menu {
                        if folded {
                            Button("Open as Panel", action: openPanel)
                            Button(model.inspectorShown ? "Hide Inspector" : "Show Inspector", action: toggleInspector)
                            Divider()
                        }
                        Button(session.pinned ? "Unpin" : "Pin") { Task { await model.togglePin(session.id) } }
                        Button("Rename…") { beginRename() }
                        Button(session.archived ? "Unarchive" : "Archive") {
                            Task { await model.setArchived(!session.archived, for: session.id) }
                        }
                        Divider()
                        Button("Forget…", role: .destructive) { forgetting = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                }
            }
            // A rename in progress never carries over to the next session (QA S-03).
            .onChange(of: session.id) { editing = false; forgetting = false }
            // The Session menu's Rename… (QA S-17).
            .onChange(of: model.renameRequests) { beginRename() }
            // The shortcuts work whether the buttons show or sit in ⋯.
            .background {
                Group {
                    Button("Open as Panel", action: openPanel).keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Inspector", action: toggleInspector).keyboardShortcut("i", modifiers: [.command, .option])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .confirmationDialog("Forget “\(session.title)”?", isPresented: $forgetting, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { Task { await model.forget(session.id) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(StudioCopy.forgetMessage)
            }
    }

    private var interrupted: Bool {
        if case .interrupted = session.status { return true }
        return false
    }

    /// The agent mark, then the title (double-click to rename) over the origin line.
    private var title: some View {
        let disc = PageDensity.headerDisc
        return HStack(spacing: 8) {
            // The Panel's disc, beads on the lower arc: one implementation (QA U20).
            SessionDisc(id: session.id, symbol: session.symbol, color: session.color, teammates: session.liveTeam,
                        working: session.isRunning && !session.needsAttention,
                        needsYou: session.needsAttention, size: disc, title: session.title)
                .frame(width: SessionDisc.slotWidth(size: disc), height: disc)
            VStack(alignment: .leading, spacing: 0) {
                if editing {
                    TextField("Title", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: PageDensity.headerTitleSize, weight: .semibold))
                        .frame(minWidth: 160)
                        .focused($titleFocused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        // Clicking away saves the edit, as in Finder.
                        .onChange(of: titleFocused) { _, focused in if !focused, editing { commit() } }
                } else {
                    Text(session.title)
                        .font(.system(size: PageDensity.headerTitleSize, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginRename() }
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityAction(named: "Rename") { beginRename() }
                }
                if let origin = Self.originLine(session.origin) {
                    TokensReader { t in
                        Text(origin).font(.system(size: 11)).foregroundStyle(t.secondaryText.color).lineLimit(1)
                    }
                }
            }
        }
    }

    private func openPanel() { Task { await model.source.openPanel(session.id) } }
    private func toggleInspector() { model.inspectorShown.toggle() }

    private func beginRename() {
        draft = session.title
        editing = true
        titleFocused = true
    }

    private func commit() {
        editing = false
        Task { await model.rename(session.id, to: draft) }
    }

    /// "From Numbers · Q3 budget".
    static func originLine(_ origin: SessionOrigin?) -> String? {
        guard let origin, let app = origin.appName else { return nil }
        return ["From \(app)", origin.windowTitle].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The session's page (conversation's ConversationPageView) at comfortable density: the thread and
/// the composer. Fed from the data source; its events go back through it unchanged. The Studio model
/// holds it while it's up, for voice-in-page turns and its `isVisible`.
struct StudioPageSlot: View {
    let session: SessionSnapshot
    let model: StudioModel
    @State private var page: ConversationPageModel?

    var body: some View {
        Group {
            if let page {
                ConversationPageView(model: page, density: .comfortable,
                                     onComposerFocus: { model.pageComposerFocused = $0 })
            } else {
                Color.clear
            }
        }
        .task(id: session.id) {
            let source = model.source
            let page = await model.makePage(for: session)
            self.page = page
            model.register(page)
            for await event in source.events(for: session.id) { page.apply(event) }
        }
        .onChange(of: session) { _, new in
            guard let page else { return }
            Task { await model.update(page, with: new) }
        }
        .onDisappear {
            model.pageComposerFocused = false
            if model.page === page { model.register(nil) }
            page?.isVisible = false
        }
    }
}
