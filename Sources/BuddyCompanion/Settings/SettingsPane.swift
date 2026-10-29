import BuddyOverlay
import SwiftUI

/// The old Settings window's sections. The window is gone (Studio's `SettingsPage`s replace it);
/// the names stay as the deep-link vocabulary: a failure chip's Fix, the menu bar's problem rows,
/// a stored relaunch resume. Each maps onto its page with `SettingsPage.init(_:)`.
public nonisolated enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case keys, models, voice, appearance, conversations, connections, privacy, claudeCode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keys: "Keys"
        case .models: "Models"
        case .voice: "Voice"
        case .appearance: "Appearance"
        case .conversations: "Conversations"
        case .connections: "Connections"
        case .privacy: "Privacy"
        case .claudeCode: "Claude Code"
        }
    }

    public var systemImage: String {
        switch self {
        case .keys: "keyboard"
        case .models: "cpu"
        case .voice: "waveform"
        case .appearance: "paintpalette"
        case .conversations: "bubble.left.and.bubble.right"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .privacy: "hand.raised"
        case .claudeCode: "terminal"
        }
    }
}

/// The top of every Settings page while a required grant is missing: what's missing, one button
/// that fixes the first of them (or reopens, when macOS needs that), and a link to the rows.
struct PermissionsNeededCard: View {
    let center: PermissionCenter
    /// The pane showing it is the one with the grant rows: no Details link.
    let onPermissions: Bool
    /// Where "Quit & Reopen" comes back to.
    let resume: PermissionCenter.Resume
    let showPermissions: () -> Void

    var body: some View {
        let line = Self.line(center)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.lumiAmber)
                .accessibilityHidden(true)
            Text(line.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !onPermissions {
                Button("Details", action: showPermissions).buttonStyle(.lumiLink)
            }
            if line.offersReopen, AppRelauncher.canRelaunch {
                Button("Quit & Reopen") { center.relaunch(resume: resume) }
                    .buttonStyle(line.fix == nil ? .pillProminent : .pill)
            }
            if let kind = line.fix {
                Button("Allow \(kind.title)…") { Task { await center.fix(kind) } }
                    .buttonStyle(.pillProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: Tokens.windowCardRadius, style: .continuous).fill(Tokens.amberBorder.opacity(0.06).color)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.windowCardRadius, style: .continuous)
                .strokeBorder(Tokens.amberBorder.color, lineWidth: Tokens.hairlineWidth)
        }
    }

    struct Line: Equatable {
        var text: String
        /// The first missing grant, fixed by the card's button.
        var fix: PermissionKind?
        /// A grant waits for a reopen, or may already be on but unreadable until one.
        var offersReopen: Bool
    }

    /// Missing grants first (in the rows' order), then any waiting for a reopen.
    static func line(_ center: PermissionCenter) -> Line {
        let required = PermissionKind.allCases.filter { center.policy.required.contains($0) }
        let missing = required.filter { center.state($0) == .missing }
        let reopen = center.needsRelaunch
            || missing.contains { PermissionGrantRow.mayNeedReopen($0, state: .missing, asked: center.asked.contains($0)) }
        if let first = missing.first {
            let names = ListFormatter.localizedString(byJoining: missing.map(\.title))
            return Line(text: "Lumi needs \(names) to work.", fix: first, offersReopen: reopen)
        }
        let text = AppRelauncher.canRelaunch ? "Reopen Lumi to finish turning on its permissions."
                                             : "Quit Lumi and open it again to finish turning on its permissions."
        return Line(text: text, fix: nil, offersReopen: true)
    }
}
