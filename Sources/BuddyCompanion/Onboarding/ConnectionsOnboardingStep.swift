import BuddyOverlay
import SwiftUI

/// Onboarding's optional tools step: Lumi uses whatever tools the user's Claude has,
/// so this only points to where they're added. Nothing is managed here; that's Settings › Connections.
public enum ConnectionsOnboarding {
    /// Kept from the earlier Connections step, so a user who finished it isn't shown this again.
    public static let stepID = "connections"

    public static func step() -> ExternalOnboardingStep {
        ExternalOnboardingStep(id: stepID, title: "Your tools") {
            ToolsStepView()
        }
    }

    struct Suggestion: Identifiable, Equatable {
        let name: String
        let use: String
        /// An SF Symbol: no third-party marks are shipped.
        let symbol: String
        /// The connector's own page in the claude.ai directory, where it's added.
        let url: URL
        var id: String { name }
    }

    /// Each URL is the "Add to Claude" link on Anthropic's page for that connector
    /// (claude.com/marketplace/connectors/<name>, checked Oct 18 2026). GitHub has no claude.ai
    /// connector there (it's a Claude Code plugin), so it isn't suggested.
    static let suggestions: [Suggestion] = [
        Suggestion(name: "Notion", use: "pages and docs", symbol: "doc.text",
                   url: directoryPage("69f3a300-cc60-48c4-b237-dfac56530dbf")),
        Suggestion(name: "Linear", use: "issues and projects", symbol: "checklist",
                   url: directoryPage("fa50c30c-9f62-4f94-b851-217868185db6")),
        Suggestion(name: "Slack", use: "messages and channels", symbol: "bubble.left.and.bubble.right",
                   url: directoryPage("597f662f-36de-437e-836e-5a81013cbfbe")),
        Suggestion(name: "Gmail", use: "your email", symbol: "envelope",
                   url: directoryPage("2701e52f-b826-4aaf-8b25-11f2a97c98b0")),
        Suggestion(name: "Google Drive", use: "files and docs", symbol: "folder",
                   url: directoryPage("b89f7865-a755-4f86-8062-c3bd651740ce")),
        Suggestion(name: "Google Calendar", use: "your events", symbol: "calendar",
                   url: directoryPage("2a838eaa-f7b4-4bc2-bd47-c326f3c813c5")),
    ]

    static func directoryPage(_ id: String) -> URL { URL(string: "https://claude.ai/directory/\(id)")! }

    /// The suggestions two to a row, in order.
    static var rows: [[Suggestion]] {
        stride(from: 0, to: suggestions.count, by: 2).map { Array(suggestions[$0..<min($0 + 2, suggestions.count)]) }
    }

    /// Every connector: the Anthropic Directory, as Anthropic's announcement and Claude Code's MCP
    /// docs link it. Claude Code fetches the added ones at the start of a session.
    static let directory = URL(string: "https://claude.ai/directory")!
}

struct ToolsStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your tools").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Lumi uses the same tools as your Claude. Click one to add it there, and Lumi can use it from your next new session.")
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                ForEach(ConnectionsOnboarding.rows, id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { SuggestionLabel(suggestion: $0) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Link("Open Claude connectors ↗", destination: ConnectionsOnboarding.directory).buttonStyle(.lumiLink)
            // Plain text: Settings opens only once setup is finished.
            Text("Already added something? Once you're set up, Settings › Connections shows what Lumi sees.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

private struct SuggestionLabel: View {
    let suggestion: ConnectionsOnboarding.Suggestion

    var body: some View {
        Link(destination: suggestion.url) { label }
            .buttonStyle(.plain)
            .help("Add \(suggestion.name) in Claude")
            .accessibilityLabel("Add \(suggestion.name) in Claude, \(suggestion.use)")
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.name + " ↗").font(.headline).foregroundStyle(.tint)
                Text(suggestion.use).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
