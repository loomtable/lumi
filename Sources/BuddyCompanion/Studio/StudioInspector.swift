import AppKit
import BuddyCore
import BuddyOverlay
import SwiftUI

/// The inspector (04 §6.3): Team and Details for the open session, plus Files and Context once
/// the session has any (no empty tabs, QA S-05).
struct StudioInspector: View {
    let session: SessionSnapshot
    @Bindable var model: StudioModel
    @State private var details = SessionDetails()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioTabs(tabs: Self.tabs(details), selection: shownTab, title: \.title)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch shownTab.wrappedValue {
                    case .team: team
                    case .files: files
                    case .context: context
                    case .details: detailRows
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Opaque well; in Liquid Glass the window's veil, so the column isn't a solid slab.
        .background { TokensReader { t in (t.onGlass ? t.windowBackground : t.well.opacity(1)).color.ignoresSafeArea() } }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        // Re-read when the session or its status changes (a finished turn adds files and context).
        .task(id: "\(session.id.rawValue)|\(session.turns)") { details = await model.source.details(for: session.id) }
    }

    /// Team and Details always; Files and Context only with something in them.
    static func tabs(_ details: SessionDetails) -> [StudioModel.InspectorTab] {
        StudioModel.InspectorTab.allCases.filter { tab in
            switch tab {
            case .team, .details: true
            case .files: !details.files.isEmpty
            case .context: !details.contexts.isEmpty
            }
        }
    }

    /// The chosen tab, or Team while the chosen one has nothing to show.
    private var shownTab: Binding<StudioModel.InspectorTab> {
        Binding(get: { Self.tabs(details).contains(model.inspectorTab) ? model.inspectorTab : .team },
                set: { model.inspectorTab = $0 })
    }

    @ViewBuilder
    private var team: some View {
        if session.teammates.isEmpty {
            Empty("No teammates in this session.")
        } else {
            ForEach(session.teammates) { mate in
                TokensReader { t in
                    StudioCard(rim: mate.state == .needsYou ? Tokens.amberBorder : nil, padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TeammateBead(state: mate.state, size: 8)
                            Text(mate.name).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(mate.state.label).font(.system(size: 11)).foregroundStyle(t.secondaryText.color)
                        }
                        if let line = mate.liveLine {
                            Text(line).font(.system(size: 12))
                                .foregroundStyle(mate.state == .needsYou ? t.amber.color : t.secondaryText.color)
                        }
                        Button("Open lane") { model.openTeammate(mate.id, in: session.id) }
                            .buttonStyle(.lumiLink)
                            .font(.system(size: 12))
                    }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            TokensReader { t in
                Text("Teammates fold into the session when it finishes. Their work stays here.")
                    .font(.system(size: 11)).foregroundStyle(t.secondaryText.color)
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        if details.files.isEmpty {
            Empty("No files yet.")
        } else {
            ForEach(details.files, id: \.self) { url in
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label(url.lastPathComponent, systemImage: "doc")
                }
                .buttonStyle(.plain)
                .help(url.path)
            }
        }
    }

    @ViewBuilder
    private var context: some View {
        if details.contexts.isEmpty {
            Empty("No screen context in this session.")
        } else {
            ForEach(details.contexts) { item in
                VStack(alignment: .leading, spacing: 6) {
                    if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Screenshot of \(item.appName)")
                    }
                    Text(["Read from \(item.appName)", item.title].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detailRows: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            row("Session", session.id.rawValue)
            row("Claude session", details.claudeSessionID)
            row("Folder", details.workingDirectory)
            row("Model", details.model)
            row("Permissions", details.permissionMode)
            row("Turns", "\(session.turns)")
            row("Cost", details.costUSD.map { $0.formatted(.currency(code: "USD")) })
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
        if let command = details.resumeCommand {
            Button(copied ? "Copied" : "Copy resume command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .padding(.top, 6)
            .help(command)
            .resettingCopied($copied)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

private struct Empty: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        TokensReader { t in
            Text(text).font(.system(size: 12)).foregroundStyle(t.secondaryText.color).padding(.top, 8)
        }
    }
}
