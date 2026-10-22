import SwiftUI

/// Settings › Claude Code: whether it's installed, its version, sign-in, and plugin
/// status with Repair. Every value comes from the shell's last real check (`ClaudeCodeProbe`);
/// nothing is assumed. Internals (the CLI's path, the folders Deep ran in) stay out of sight;
/// the install command shows only when Claude Code is missing.
struct ClaudeCodePane: View {
    @Environment(\.claudeCodeStatus) private var status
    @Environment(\.claudeCodeActions) private var actions
    @State private var repairing = false
    @State private var repairError: String?

    var body: some View {
        Form {
            Section("Install") {
                LabeledContent("Claude Code") { Text(value(status.executablePath.map { _ in "Installed" }, missing: "Not found")) }
                LabeledContent("Version") { Text(value(status.version, missing: "Unknown")) }
                if status.checked, status.executablePath == nil {
                    Text("Install Claude Code, then check again: curl -fsSL https://claude.ai/install.sh | bash")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("Sign-in") {
                LabeledContent("Status") { Text(signInText) }
                if status.loggedIn == false {
                    Text("Open Terminal, run claude, and sign in. Lumi uses your Claude Code login.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Plugin") {
                LabeledContent("Lumi plugin") { Text(pluginText) }
                if let problem = status.pluginProblem {
                    Text(problem).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let repair = actions.repairPlugin {
                    Button(repairing ? "Repairing…" : "Repair plugin") {
                        repairing = true
                        repairError = nil
                        Task {
                            do { try await repair() } catch { repairError = error.localizedDescription }
                            await actions.refresh?()
                            repairing = false
                        }
                    }
                    .disabled(repairing)
                    if let repairError { Text(repairError).font(.callout).foregroundStyle(.red) }
                }
            }
            if let refresh = actions.refresh {
                Section { Button("Check again") { Task { await refresh() } } }
            }
        }
        .formStyle(.grouped)
    }

    private func value(_ text: String?, missing: String) -> String {
        text ?? (status.checked ? missing : "Checking…")
    }

    private var signInText: String {
        switch status.loggedIn {
        case true?: ["Signed in", status.loginDetail].compactMap { $0 }.joined(separator: " · ")
        case false?: "Not signed in"
        case nil: status.checked ? "Unknown" : "Checking…"
        }
    }

    private var pluginText: String {
        switch status.pluginLoaded {
        case true?: "Loaded"
        case false?: "Needs repair"
        case nil: status.checked ? "Unknown" : "Checking…"
        }
    }
}
