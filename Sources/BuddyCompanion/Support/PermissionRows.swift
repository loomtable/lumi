import AppKit
import SwiftUI

/// One permission as a row: status, why it's needed, and a button that always shows the user
/// something (the system prompt where macOS still shows one, else the exact System Settings pane).
/// Reads the shell's `PermissionCenter`. Used by onboarding and Settings › Privacy.
struct PermissionGrantRow: View {
    let kind: PermissionKind
    let state: PermissionCenter.State
    /// The button was pressed this run, so the user has been sent to System Settings.
    let asked: Bool
    /// Not required (the microphone): marked "Optional".
    var required = true
    let grant: () -> Void
    /// Quit & Reopen, for a grant macOS applies only to a new process.
    let relaunch: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(state))
                .foregroundStyle(state == .granted ? Color.green : state == .grantedNeedsRelaunch ? Color.orange : Color.secondary)
                .accessibilityLabel(Self.status(state))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.title)
                    if !required { Text("Optional").font(.caption).foregroundStyle(.secondary) }
                }
                Text(kind.purpose).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .grantedNeedsRelaunch {
                    Text(AppRelauncher.canRelaunch ? "Turned on. macOS applies it once Lumi reopens."
                                                   : "Turned on. Quit Lumi and open it again to apply it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if Self.mayNeedReopen(kind, state: state, asked: asked) {
                    // macOS may not report this grant to a running process at all until it reopens.
                    Text("Turned it on already? macOS applies it once Lumi reopens.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state == .missing, asked, kind != .microphone {
                    HStack(spacing: 6) {
                        Text("Turn on Lumi in the list. Not there? Click +, then choose Lumi.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if PermissionGrantRow.canReveal {
                            Button("Show in Finder") { PermissionGrantRow.revealApp() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .granted:
                Text("Allowed").foregroundStyle(.secondary)
            case .grantedNeedsRelaunch:
                if AppRelauncher.canRelaunch {
                    Button("Quit & Reopen", action: relaunch)
                        .accessibilityLabel("Quit and reopen to apply \(kind.title)")
                }
            case .missing:
                if Self.mayNeedReopen(kind, state: state, asked: asked), AppRelauncher.canRelaunch {
                    Button("Quit & Reopen", action: relaunch)
                        .accessibilityLabel("Quit and reopen to apply \(kind.title)")
                }
                Button(Self.buttonTitle(asked: asked), action: grant)
                    .accessibilityLabel("\(Self.buttonTitle(asked: asked)) \(kind.title)")
            }
        }
    }

    /// Sent to System Settings for a grant macOS only applies to a new process: it may already be
    /// on and still read as missing here, so a reopen is offered too.
    static func mayNeedReopen(_ kind: PermissionKind, state: PermissionCenter.State, asked: Bool) -> Bool {
        state == .missing && asked && kind.needsRelaunchAfterGrant
    }

    /// "Allow…" until pressed (the prompt, or the pane it opens), then "Open Settings".
    static func buttonTitle(asked: Bool) -> String { asked ? "Open Settings" : "Allow…" }

    static func symbol(_ state: PermissionCenter.State) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .grantedNeedsRelaunch: "arrow.clockwise.circle.fill"
        case .missing: "circle"
        }
    }

    static func status(_ state: PermissionCenter.State) -> String {
        switch state {
        case .granted: "Allowed"
        case .grantedNeedsRelaunch: "Allowed, needs a reopen"
        case .missing: "Not allowed"
        }
    }

    static var canReveal: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// So the user can add the app with + (or drag it into the list) when macOS didn't list it.
    static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// How this process was started, for permission checks (see `OnboardingModel.launchedByLaunchServices`).
public enum LaunchCheck {
    /// Apps opened through LaunchServices (Finder, Spotlight, the Dock, `open`) are children of
    /// launchd. Anything else was started by another process, typically a terminal, whose TCC
    /// grants macOS then checks instead. Measured on macOS 26.6: the same app reads every grant as
    /// allowed when run from iTerm, and none when opened with `open`.
    public static var isOwnResponsibleProcess: Bool { getppid() == 1 }
}

/// Shown instead of trusting the rows when the checks would be about the terminal's grants.
struct LaunchedFromTerminalNotice: View {
    var body: some View {
        Label {
            Text("Lumi was started from Terminal, so macOS is checking Terminal's permissions, not Lumi's. Quit it and open Lumi from Applications.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
