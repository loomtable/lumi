import BuddyConversations
import SwiftUI

/// Settings › Conversations: the most recent conversations and a way into the Conversations
/// window. It stays current while shown, and a row opens the window.
struct ConversationHistoryView: View {
    @Environment(\.conversationManager) private var manager
    @Environment(\.openWindow) private var openWindow
    @State private var recent: [ConversationRecord] = []

    /// Must match the app shell's `WindowID.conversations`.
    static let windowID = "conversations"
    static let recentCount = 5

    var body: some View {
        Section("History") {
            if manager == nil {
                Text("History isn't available yet.").foregroundStyle(.secondary)
            } else if recent.isEmpty {
                Text("No conversations yet.").foregroundStyle(.secondary)
            } else {
                ForEach(recent) { record in
                    Button { openWindow(id: Self.windowID) } label: { row(record) }
                        .buttonStyle(.plain)
                        .help("Open in Conversations")
                }
            }
            Button("Open Conversations…") { openWindow(id: Self.windowID) }
        }
        .task(id: manager == nil) {
            // Re-read while visible, so a new or forgotten conversation shows without reopening.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    static let refreshInterval: Duration = .seconds(5)

    private func load() async {
        guard let manager else { recent = []; return }
        let now = (try? await manager.list(limit: Self.recentCount, offset: 0)) ?? recent
        if now != recent { recent = now }
    }

    private func row(_ record: ConversationRecord) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ConversationDotColor.color(record.color)).frame(width: 8, height: 8)
                .accessibilityLabel(ConversationDotColor.name(record.color))
            Text(record.title).lineLimit(1)
            Spacer()
            Text(record.lastUsed.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
