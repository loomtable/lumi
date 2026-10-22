import BuddyConversations
import BuddyCore
import BuddyOverlay
import SwiftUI

/// The Conversations window (⌘Y): searchable history with colour dots, resume,
/// Forget with confirmation, temporary mode and retention. The app shell
/// puts it in its `Window("Conversations")` scene.
public struct ConversationsWindow: View {
    @Binding var preferences: ConversationsPreferences
    private let makeModel: (() -> ConversationHistoryModel)?
    /// Which manager `model` was built for: a manager that arrives (or changes) after the
    /// window was created gets a fresh model.
    private let sourceID: ObjectIdentifier?
    @State private var model: ConversationHistoryModel?
    @State private var modelSourceID: ObjectIdentifier?

    public init(manager: ConversationManager?, preferences: Binding<ConversationsPreferences>,
                onResume: @escaping (ConversationRecord) -> Void = { _ in }) {
        _preferences = preferences
        sourceID = manager.map(ObjectIdentifier.init)
        makeModel = manager.map { manager in
            { ConversationHistoryModel(source: ManagerHistorySource(manager: manager), onResume: onResume) }
        }
    }

    /// The shell's own source (one that routes Resume and temporary mode through the engine).
    /// `identity` names the source, so a new one gets a fresh model.
    public init(source: (any ConversationHistorySource)?, identity: AnyObject?,
                preferences: Binding<ConversationsPreferences>) {
        _preferences = preferences
        sourceID = identity.map(ObjectIdentifier.init)
        makeModel = source.map { source in { ConversationHistoryModel(source: source) } }
    }

    /// For tests and previews: any source.
    init(model: ConversationHistoryModel, preferences: Binding<ConversationsPreferences>) {
        _preferences = preferences
        sourceID = ObjectIdentifier(model)
        makeModel = { model }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model?.isTemporary == true {
                Label("Temporary: nothing is saved", systemImage: "eye.slash")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.yellow.opacity(0.15))
                    .background(.background)  // a tint over the window colour, light or dark
            }
            if let model {
                // A click shows the conversation's turns beside the list.
                HSplitView {
                    ConversationList(model: model).frame(minWidth: 280, idealWidth: 320)
                    ConversationDetail(model: model).frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("History isn't available yet", systemImage: "clock.arrow.circlepath")
            }
            Divider()
            HistoryFooter(preferences: $preferences)
        }
        .frame(minWidth: 680, minHeight: 420)  // the list and the turns side by side
        .task(id: sourceID) { syncModel() }
        .onChange(of: preferences.retentionDays) { _, days in
            // A shorter retention prunes at once: prune here too (idempotent), then show the result.
            model?.requestRetention(days)
        }
        // Back to the window: the current conversation may have changed (⌘N, a new topic).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model?.reload() }
        }
        // A conversation gained a turn (asked in the overlay while this window stays open).
        .onReceive(NotificationCenter.default.publisher(for: ConversationHistoryModel.turnsChanged)) { _ in
            Task { await model?.reload() }
        }
        .onChange(of: preferences.temporaryMode) { _, on in
            // The manager is changed here too (idempotent with the shell applying the same
            // preference), so the banner and list follow the switch straight away.
            model?.requestTemporary(on)
        }
    }

    private func syncModel() {
        guard modelSourceID != sourceID || (model == nil) != (makeModel == nil) else { return }
        model = makeModel?()
        modelSourceID = sourceID
    }
}

/// Temporary mode and retention, bound to Settings › Conversations (the same store).
private struct HistoryFooter: View {
    @Binding var preferences: ConversationsPreferences

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Toggle("Temporary mode", isOn: $preferences.temporaryMode)
                .help("Save nothing: conversations live in memory and are deleted when this is turned off.")
            Spacer()
            Stepper(value: $preferences.retentionDays, in: ConversationsPreferences.retentionRange) {
                Text("Conversations unused for \(preferences.retentionDays) days are removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The searchable list with its actions, shared by the window.
/// The selected conversation's questions and answers, read-only. Resume (or Return) makes the next
/// question continue it.
struct ConversationDetail: View {
    let model: ConversationHistoryModel

    var body: some View {
        // One view, not a Group: in the split view a Group's branches are separate panes, so each
        // swap made a new pane whose task reloaded, showing Loading again, forever.
        ZStack {
            if model.selection == nil {
                ContentUnavailableView("Choose a conversation", systemImage: "text.bubble",
                                       description: Text("Its questions and answers show here."))
            } else if let turns = model.shownTurns {
                if turns.isEmpty {
                    ContentUnavailableView("No saved turns", systemImage: "text.bubble",
                                           description: Text("This conversation's answers weren't kept."))
                } else {
                    TranscriptView(turns: turns)
                }
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.selection) { await model.loadTurns() }
    }
}

struct ConversationList: View {
    @Bindable var model: ConversationHistoryModel

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                StatusLine(text: problem, systemImage: "exclamationmark.triangle", tint: .orange)
            } else if let done = model.notice {
                StatusLine(text: done, systemImage: "checkmark", tint: .secondary)
            }
            list
        }
        .searchable(text: $model.query, prompt: "Search conversations")
        .task { await model.reload() }
        .confirmationDialog(forgetTitle, isPresented: forgetShown, titleVisibility: .visible, presenting: model.pendingForget) { request in
            Button("Forget", role: .destructive) { Task { await model.confirmForget(request) } }
            Button("Cancel", role: .cancel) { model.cancelForget() }
        } message: { request in
            Text(ConversationHistoryModel.forgetMessage(request))
        }
    }

    @ViewBuilder private var list: some View {
        if model.showsEmptyState {
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Ask Lumi something and it appears here."))
            } else {
                ContentUnavailableView.search(text: model.query)
            }
        } else {
            List(selection: $model.selection) {
                ForEach(model.records) { record in
                    ConversationRow(record: record, model: model)
                        .tag(record.id)
                        .contextMenu { actions(record) }
                        .onAppear {
                            if record.id == model.records.last?.id { Task { await model.loadMore() } }
                        }
                }
            }
            .onKeyPress(.return) {
                guard let record = model.selected else { return .ignored }
                Task { await model.resume(record) }
                return .handled
            }
            .onDeleteCommand {
                if let record = model.selected { Task { await model.askToForget(record) } }
            }
        }
    }

    @ViewBuilder private func actions(_ record: ConversationRecord) -> some View {
        Button("Resume") { Task { await model.resume(record) } }
        Divider()
        Button("Forget…", role: .destructive) { Task { await model.askToForget(record) } }
    }

    private var forgetTitle: String { model.pendingForget.map { "Forget “\($0.title)”?" } ?? "Forget?" }

    private var forgetShown: Binding<Bool> {
        Binding(get: { model.pendingForget != nil }, set: { if !$0 { model.cancelForget() } })
    }
}

private struct StatusLine: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}

/// One conversation: colour dot, title, when, turns, folder, lane, and its actions.
struct ConversationRow: View {
    let record: ConversationRecord
    let model: ConversationHistoryModel

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(ConversationDotColor.color(record.color)).frame(width: 10, height: 10)
                .accessibilityLabel(ConversationDotColor.name(record.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(Self.detail(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.currentID == record.id {
                Label("Current", systemImage: "arrow.uturn.forward.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                    .help("Your next question continues this conversation.")
            }
            // Always available: the mark can be a moment stale, and resuming again is harmless.
            Button("Resume") { Task { await model.resume(record) } }
                .modifier(ResumeStyle(prominent: model.selection == record.id))
                .controlSize(.small)
            Button(role: .destructive) { Task { await model.askToForget(record) } } label: { Image(systemName: "trash") }
                .controlSize(.small)
                .help("Forget")
                .accessibilityLabel("Forget")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    /// "2 h ago · 3 turns · web · Deep".
    static func detail(_ r: ConversationRecord) -> String {
        var parts = [r.lastUsed.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))]
        parts.append(r.turns == 1 ? "1 turn" : "\(r.turns) turns")
        if let folder = r.projectFolder, !folder.isEmpty { parts.append((folder as NSString).lastPathComponent) }
        if let lane = r.lastLane { parts.append(lane.displayName) }
        return parts.joined(separator: " · ")
    }
}

/// Conversation colours (tokens), matching the overlay's dots.
enum ConversationDotColor {
    static func color(_ c: ConversationColor) -> Color {
        switch c {
        case .ember: Color(light: 0xD9622F, dark: 0xFF8A5B)
        case .mist: Color(light: 0x2F6488, dark: 0x8FB8D8)
        case .sage: Color(light: 0x1F7A4F, dark: 0x7FD1A8)
        case .amber: Color(light: 0x8A5A00, dark: 0xF5C060)
        }
    }

    /// Spoken with the row, so VoiceOver users can match it to the overlay's dot.
    static func name(_ c: ConversationColor) -> String {
        switch c {
        case .ember: "Ember"
        case .mist: "Mist"
        case .sage: "Sage"
        case .amber: "Amber"
        }
    }

    /// Resolved sRGB components in one appearance (tests).
    static func components(_ c: ConversationColor, dark: Bool) -> [CGFloat] {
        var out: [CGFloat] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color(c)).usingColorSpace(.sRGB)!
            out = [ns.redComponent, ns.greenComponent, ns.blueComponent]
        }
        return out
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A row's Resume: a plain button, prominent only on the selected row (where Return resumes).
private struct ResumeStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
