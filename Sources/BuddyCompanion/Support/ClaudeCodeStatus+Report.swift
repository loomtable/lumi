import BuddyBridge
import Foundation

extension ClaudeCodeStatus {
    /// What the pane shows, from the bridge's real check plus the latest `plugin_errors` seen in a
    /// session's `system/init` (a plugin can validate yet fail to load).
    public init(report: ClaudeCodeReport, pluginErrors: [String] = []) {
        let (loaded, problem): (Bool?, String?) = switch report.plugin {
        case .valid where pluginErrors.isEmpty: (true, nil)
        case .valid: (false, pluginErrors.first)
        case .invalid(let why): (false, why)
        case .unknown(let why): (nil, why)
        case .notInstalled where report.executable == nil: (nil, nil)
        case .notInstalled: (false, "The plugin isn't installed.")
        }
        self.init(executablePath: report.executable?.path, version: report.version, loggedIn: report.auth?.loggedIn,
                  loginDetail: report.auth.flatMap(Self.loginDetail), pluginLoaded: loaded, pluginProblem: problem,
                  checked: true)
    }

    /// "Claude Max", "Claude Pro", "API key", "Bedrock"…; never the account itself.
    static func loginDetail(_ auth: ClaudeCodeReport.Auth) -> String? {
        if let provider = auth.provider, provider != "firstParty" { return provider.prefix(1).uppercased() + provider.dropFirst() }
        if let plan = auth.subscription { return "Claude " + plan.prefix(1).uppercased() + plan.dropFirst() }
        if auth.method?.lowercased().contains("api") == true { return "API key" }
        return nil
    }
}
