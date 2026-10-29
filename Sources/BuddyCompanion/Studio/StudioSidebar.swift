import BuddyCore
import BuddyOverlay
import SwiftUI

/// The sidebar: sessions (New session, Search, Now, Pinned, date groups, Settings at the bottom),
/// or, while a Settings page is open, the settings list with "‹ Sessions" (04 §6.1).
struct StudioSidebar: View {
    @Bindable var model: StudioModel
    var searchFocused: FocusState<Bool>.Binding
    @Environment(\.permissionCenter) private var permissions

    var body: some View {
        // The system draws the selected row in the tint with white text: the deep ember keeps it readable.
        TokensReader { t in
            Group { if model.showsSettingsList { settingsList } else { sessionsList } }
                .tint(t.emberDeep.color)
        }
    }

    private var selection: Binding<StudioModel.Selection?> {
        Binding(get: { model.selection }, set: { if let new = $0 { model.selection = new } })
    }

    // MARK: Sessions

    private var sessionsList: some View {
        // The working clocks tick each second only while something runs.
        TimelineView(.periodic(from: .now, by: model.running.isEmpty ? 60 : 1)) { context in
            let grouping = model.sidebar(now: context.date)
            List(selection: selection) {
                Section {
                    // The canvas's two quiet rows: an ember ＋ and a plain search field with its key.
                    Button { model.newSession() } label: {
                        Label {
                            Text("New session")
                        } icon: {
                            TokensReader { t in Image(systemName: "plus").foregroundStyle(t.emberMark.color) }
                        }
                        .badgeShortcut("⌘N")
                    }
                    .buttonStyle(.plain)
                    Label {
                        TextField("Search", text: $model.search, prompt: Text("Search"))
                            .textFieldStyle(.plain)
                            .focused(searchFocused)
                            .badgeShortcut(model.search.isEmpty ? "⌘K" : "")
                    } icon: {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                }
                ForEach(grouping.sections.filter { $0.group != .archived }) { section in
                    Section(section.group.title) {
                        ForEach(section.rows) { row in
                            SessionRow(row: row, now: context.date, model: model)
                                .tag(StudioModel.Selection.session(row.id))
                            ForEach(row.teammates) { mate in
                                Button { model.openTeammate(mate.id, in: row.id) } label: { TeammateRow(teammate: mate) }
                                    .buttonStyle(.plain)
                                    .help("Open \(mate.name)'s lane")
                            }
                        }
                    }
                }
                // Folded at the bottom; a search opens it when only archived sessions match.
                let archived = grouping.rows(.archived)
                if !archived.isEmpty {
                    Section(isExpanded: archivedShown(onlyMatches: grouping.sections.count == 1)) {
                        ForEach(archived) { row in
                            SessionRow(row: row, now: context.date, model: model)
                                .tag(StudioModel.Selection.session(row.id))
                        }
                    } header: {
                        Text("\(SidebarGrouping.Group.archived.title) (\(archived.count))")
                    }
                }
                if grouping.sections.isEmpty, !model.search.isEmpty {
                    Text("No sessions match “\(model.search)”.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if model.showsDictation {
                    footerButton(DictationHistoryView.title, systemImage: "mic", selected: model.selection == .dictation) {
                        model.selection = .dictation
                    }
                }
                footerButton("Settings", systemImage: "gearshape", shortcut: "⌘,") { model.showSettings() }
            }
            .padding(.vertical, 4)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// A row under the sessions list: Dictation, Settings.
    private func footerButton(_ title: String, systemImage: String, shortcut: String? = nil, selected: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let shortcut {
                    Label(title, systemImage: systemImage).badgeShortcut(shortcut)
                } else {
                    Label(title, systemImage: systemImage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(selected ? .semibold : nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func archivedShown(onlyMatches: Bool) -> Binding<Bool> {
        Binding(get: { model.archivedExpanded || (onlyMatches && !model.search.isEmpty) },
                set: { model.archivedExpanded = $0 })
    }

    // MARK: Settings

    private var settingsList: some View {
        List(selection: selection) {
            Button { model.leaveSettings() } label: {
                Label("Sessions", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("[", modifiers: .command)
            Section {
                ForEach(SettingsPage.allCases) { page in
                    HStack(spacing: 10) {
                        SettingsIconTile(page: page)
                        Text(page.title)
                        Spacer()
                        if page == .permissions, permissions?.needsAttention == true {
                            TokensReader { t in Circle().fill(t.rose.color).frame(width: 7, height: 7) }
                                .accessibilityLabel("Needs attention")
                        }
                    }
                    .tag(StudioModel.Selection.settings(page))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A Settings row's icon: a white glyph on a 22 pt rounded tile in the page's colour (the canvas
/// Settings board; System Settings' pattern), so the list scans by colour as well as by word.
struct SettingsIconTile: View {
    let page: SettingsPage

    var body: some View {
        Image(systemName: page.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Tokens.onTile.color)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Self.tile(page).color))
            .accessibilityHidden(true)
    }

    /// The canvas's tile colours: the brand's ember, mist, sage, amber and rose, and neutral greys.
    static func tile(_ page: SettingsPage) -> TokenColor {
        switch page {
        case .general, .privacy, .about: TokenColor(hex: 0x5A606B)
        case .voice: TokenColor(hex: 0xD9622F)
        case .model: TokenColor(hex: 0x6E56CF)
        case .claudeCode: TokenColor(hex: 0x2F3237)
        case .connections: TokenColor(hex: 0x2F6488)
        case .teammates: TokenColor(hex: 0x1F7A4F)
        case .permissions: TokenColor(hex: 0x8A5A00)
        case .appearance: TokenColor(hex: 0x3A3F48)
        case .notifications: TokenColor(hex: 0xB42318)
        }
    }
}

/// A session row: glyph, title and what it's doing. Context menu: Pin, Rename, Forget.
struct SessionRow: View {
    let row: SidebarGrouping.Row
    let now: Date
    let model: StudioModel
    @State private var renaming = false
    @State private var draft = ""
    @State private var forgetting = false
    @State private var hovering = false

    var body: some View {
        let live = row.session.status.isLive
        HStack(spacing: 9) {
            SessionGlyph(session: row.session, size: live ? 20 : 16, originBadge: !live)
            Text(row.session.title).lineLimit(1)
            if row.session.pinned, !live {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Pinned")
            }
            Spacer(minLength: 4)
            if hovering {
                hoverActions
            } else if case .interrupted = row.session.status {
                Button("Continue") { Task { await model.continueInterrupted(row.id) } }
                    .buttonStyle(.lumiLink)
                    .font(.system(size: 11))
                    .help("Interrupted when Lumi quit. Continue the turn.")
            } else {
                SidebarTrailing(trailing: row.trailing, now: now)
            }
        }
        .frame(minHeight: live ? 32 : 28)
        .onHover { hovering = $0 }
        .contextMenu {
            if case .interrupted = row.session.status {
                Button("Continue") { Task { await model.continueInterrupted(row.id) } }
            }
            Button(row.session.pinned ? "Unpin" : "Pin") { Task { await model.togglePin(row.id) } }
            Button("Rename…", action: beginRename)
            Button(row.session.archived ? "Unarchive" : "Archive") {
                Task { await model.setArchived(!row.session.archived, for: row.id) }
            }
            Divider()
            Button("Forget…", role: .destructive) { forgetting = true }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Title", text: $draft)
            Button("Rename") { Task { await model.rename(row.id, to: draft) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Forget “\(row.session.title)”?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { Task { await model.forget(row.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(StudioCopy.forgetMessage)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: row.session.pinned ? "Unpin" : "Pin") { Task { await model.togglePin(row.id) } }
        .accessibilityAction(named: "Rename") { beginRename() }
        .accessibilityAction(named: row.session.archived ? "Unarchive" : "Archive") {
            Task { await model.setArchived(!row.session.archived, for: row.id) }
        }
        .accessibilityAction(named: "Forget") { forgetting = true }
    }

    /// Pin, Rename and Forget while the pointer is over the row (04 §6.1).
    private var hoverActions: some View {
        HStack(spacing: 2) {
            Button { Task { await model.togglePin(row.id) } } label: {
                Image(systemName: row.session.pinned ? "pin.slash" : "pin")
            }
            .help(row.session.pinned ? "Unpin" : "Pin")
            Button(action: beginRename) { Image(systemName: "pencil") }.help("Rename")
            Button { forgetting = true } label: { Image(systemName: "trash") }.help("Forget")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func beginRename() {
        draft = row.session.title
        renaming = true
    }
}

/// The row's end: "needs you", progress, the working clock, an unread dot, or the time.
struct SidebarTrailing: View {
    let trailing: SidebarGrouping.Trailing
    let now: Date

    var body: some View {
        TokensReader { t in
            Group {
                switch trailing {
                case .needsYou:
                    Label("needs you", systemImage: "flag.fill").labelStyle(.titleAndIcon).foregroundStyle(t.amber.color)
                case .progress(let done, let total):
                    Text("\(done)/\(total)").foregroundStyle(.secondary)
                case .elapsed(let seconds):
                    Text(SidebarGrouping.clock(seconds)).foregroundStyle(.secondary)
                case .unread:
                    Circle().fill(t.emberMark.color).frame(width: 7, height: 7).accessibilityLabel("Unread")
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(t.rose.color).accessibilityLabel("Failed")
                case .interrupted:
                    Image(systemName: "pause.circle").foregroundStyle(t.mist.color).accessibilityLabel("Interrupted")
                case .time(let date):
                    Text(StudioCopy.shortTime(date, now: now)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11).monospacedDigit())
        }
    }
}

/// A teammate nested under its running session: indented, with its bead.
struct TeammateRow: View {
    let teammate: TeammateSnapshot

    var body: some View {
        HStack(spacing: 8) {
            TeammateBead(state: teammate.state, size: 7)
            Text(teammate.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            // The bead's colour has a word beside it (QA U16).
            TokensReader { t in
                Text(teammate.state.label).font(.system(size: 11)).foregroundStyle(t.secondaryText.color).lineLimit(1)
            }
        }
        .padding(.leading, 30)
        .frame(minHeight: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([teammate.name, teammate.state.label, teammate.liveLine].compactMap { $0 }.joined(separator: ", "))
    }
}

extension View {
    /// A shortcut hint at the end of a sidebar label ("⌘N").
    func badgeShortcut(_ keys: String) -> some View {
        HStack {
            self
            Spacer()
            Text(keys).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Studio's fixed strings and formats.
enum StudioCopy {
    static let forgetMessage = "This deletes the session, its saved conversation and its screenshots. It can't be undone."

    /// "11:20" today, "Tue" this week, "12 Oct" before that.
    static func shortTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
