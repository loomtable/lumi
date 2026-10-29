import BuddyBridge
import BuddyCompanion
import BuddyCore
import Foundation

/// What fixes a failed turn, shown as the chip's button.
public enum FixAction: Sendable, Equatable {
    /// Open Settings at this pane (Claude Code for sign-in, Models for a missing model).
    case openSettings(SettingsPane)
    /// Copy a fresh plugin and restart Claude Code onto it (ClaudeCodeService.repairPlugin).
    case repairPlugin
    /// Ask again with a smaller model: the limit or capacity problem was the bigger one's.
    case useModel(ModelID)
    /// Ask the same question again: the failure may not happen twice (a timeout, a crash, a 5xx).
    case retry
    /// Grant a missing permission: the runtime's grant flow (the system prompt, then its pane).
    case grantPermission(PermissionKind)
    /// Open the Lumi window's Dictation page: dictated words that weren't typed are there.
    case openDictationHistory

    /// The button's label.
    public var label: String {
        switch self {
        case .openSettings(.claudeCode), .grantPermission: "Fix"
        case .openSettings(.voice): "Set Up Voice"
        case .openSettings: "Open Settings"
        case .repairPlugin: "Repair plugin"
        case .useModel(let model): "Use \(model.displayName)"
        case .retry: "Try again"
        case .openDictationHistory: "Open"
        }
    }
}

/// One true line per bridge failure, with the action that fixes it, instead of the
/// generic "Claude Code couldn't finish that." Everything comes from what Claude Code reported:
/// its error code first (the synthetic reply's `error`), then the HTTP status and terminal reason,
/// then its own documented wording. Nothing is guessed: an unknown failure keeps the generic line.
public enum TurnFailureLine {
    public struct Line: Sendable, Equatable {
        public var text: String
        public var fix: FixAction?

        public init(_ text: String, fix: FixAction? = nil) {
            self.text = text
            self.fix = fix
        }
    }

    public static let generic = Line("Claude Code couldn't finish that.", fix: .retry)
    /// The turn ended without a block to show.
    public static let noAnswer = Line("Claude Code finished without an answer I can show.", fix: .retry)
    /// The lane's process went away, or the cascade's stream ended without its `.done`.
    public static let stopped = Line("Claude Code stopped unexpectedly.", fix: .retry)
    /// The question's screen capture was gone (superseded or cleared); trying again captures afresh.
    public static let screenUnreadable = Line("I couldn't read the screen.", fix: .retry)
    static let apiProblem = Line("The API had a problem. Try again in a moment.", fix: .retry)

    /// The line for a failed turn. `model`: the model the turn ran on, so a limit can offer a
    /// smaller one.
    public static func line(for error: BridgeError, model: ModelID? = nil) -> Line? {
        switch error {
        case .cancelled: nil
        case .busy: Line("Still working on the last question.")
        case .timedOut: Line("Claude Code didn't answer in time.", fix: .retry)
        case .processExited, .launchFailed, .sessionNotFound: stopped
        case .unavailable: Line("Claude Code isn't available right now.", fix: .openSettings(.claudeCode))
        case .turnFailed(let result): line(for: result, model: model)
        }
    }

    static func line(for r: StreamEvent.TurnResult, model: ModelID?) -> Line {
        let text = r.text ?? ""
        switch r.errorCode {
        case "authentication_failed":
            return Line("Claude Code isn't signed in.", fix: .openSettings(.claudeCode))
        case "oauth_org_not_allowed":
            // Signed in, but the account's organization isn't allowed: nothing in Settings fixes that.
            return Line("This account's organization can't use Claude Code.")
        case "cloud_credential_error":
            return Line("Claude Code's cloud credentials need attention.", fix: .openSettings(.claudeCode))
        case "billing_error", "account_on_hold":
            // Settled on the account's own page, not in Lumi: no button that can't help.
            return Line("There's a problem with your Claude account.")
        case "rate_limit":
            return limit(text, model: model)
        case "overloaded":
            return busy(model: model)
        case "model_not_found":
            return Line("That model isn't available to your account.", fix: .openSettings(.models))
        case "server_error":
            return apiProblem
        case "max_output_tokens":
            return Line("The answer was too long to finish.")
        default:
            break
        }
        // No code (older Claude Code, or a failure without a synthetic reply): status, reason, wording.
        switch r.apiErrorStatus {
        // 403 and 404 alone don't say why (a scope, a region, a proxy, a base URL): left to the wording.
        case 401: return Line("Claude Code isn't signed in.", fix: .openSettings(.claudeCode))
        case 429: return limit(text, model: model)
        case 529: return busy(model: model)
        case let status? where (500...599).contains(status): return apiProblem
        default: break
        }
        if r.terminalReason == "prompt_too_long" {
            return Line("This session got too long. Start a new one with ⌘N.")
        }
        if signedOutWording.contains(where: text.contains) {
            return Line("Claude Code isn't signed in.", fix: .openSettings(.claudeCode))
        }
        if text.hasPrefix("You've hit your") { return limit(text, model: model) }
        if offlineWording.contains(where: text.contains) { return Line("No connection to the API.") }
        return generic
    }

    /// While Claude Code retries (`system/api_retry`): what's happening, nothing estimated.
    public static func retrying(_ retry: StreamEvent.APIRetry) -> String? {
        switch (retry.error, retry.errorStatus) {
        case ("overloaded", _), (_, 529?): "The API is busy. Trying again…"
        case ("rate_limit", _), (_, 429?): "Hit a rate limit. Trying again…"
        case ("server_error", _), (_, (500...599)?): "The API had a problem. Trying again…"
        // No response at all (offline, a dead proxy, a timeout): never for a known non-network error.
        case (nil, nil), ("unknown", nil): "Can't reach the API. Trying again…"
        default: nil
        }
    }

    /// A plan or rate limit: Claude Code's own line when it gives one ("You've hit your session
    /// limit · resets 3:45pm"), else "Hit a rate limit." A smaller model is offered only where it
    /// helps: a limit on one model ("…Opus limit") or an API rate limit, never a session, weekly or
    /// spend limit, which covers every model.
    private static func limit(_ text: String, model: ModelID?) -> Line {
        guard text.hasPrefix("You've hit your") else {
            return Line("Hit a rate limit.", fix: smaller(than: model).map(FixAction.useModel))
        }
        let perModel = text.contains("Opus limit") || text.contains("Sonnet limit")
        return Line(text, fix: perModel ? smaller(than: model).map(FixAction.useModel) : nil)
    }

    private static func busy(model: ModelID?) -> Line {
        Line("The API is busy right now. Try again in a moment.", fix: smaller(than: model).map(FixAction.useModel))
    }

    /// Opus → Sonnet → Haiku; nothing below Haiku (or for a model we don't know).
    static func smaller(than model: ModelID?) -> ModelID? {
        if model == .opus { return .sonnet }
        if model == .sonnet { return .haiku }
        return nil
    }

    /// Claude Code's documented sign-in failures (code.claude.com/docs/en/errors).
    static let signedOutWording = ["Not logged in", "Login expired", "Authentication required", "Invalid API key"]
    /// Its documented connection failures.
    static let offlineWording = ["Unable to connect to API", "Connection refused", "Can't reach the API server",
                                 "No internet route", "Couldn't connect through your proxy", "Connection dropped"]
}

/// Plugin load errors from a session's `system/init` ("Repair plugin").
extension TurnFailureLine {
    public static func pluginProblem(_ errors: [StreamEvent.PluginError]) -> Line? {
        guard errors.contains(where: { $0.plugin == "buddy" }) else { return nil }
        return Line("The Lumi plugin didn't load.", fix: .repairPlugin)
    }
}

/// Claude Code's permission mode, from each session's `system/init`. Lumi
/// launches with `--permission-mode auto`; the CLI or the user's settings can override it, and
/// in `-p` nobody can be asked, so actions that need permission are blocked rather than prompted.
extension TurnFailureLine {
    /// The menu line for `mode`, or nil when nothing is blocked (auto, or bypassPermissions).
    public static func permissionModeLine(_ mode: String) -> String? {
        switch mode {
        case "auto", "bypassPermissions", "": nil
        case "plan": "Claude Code is in plan mode, so it plans but doesn't act."
        default: "Claude Code is in \(mode) mode, not auto, so actions that need permission are blocked."
        }
    }
}

extension TurnFailureLine {
    /// The MCP servers a session's `system/init` reports as `needs-auth` or `failed`, as one menu
    /// line ("Linear needs sign-in in Claude Code."). Nil while every server is connected, pending
    /// or disabled. Sign-in happens in Claude Code (`/mcp`), so there's no Settings pane to open.
    public static func mcpProblemLine(_ servers: [StreamEvent.MCPServer]) -> String? {
        mcpProblemLine(statuses: servers.map { ($0.name, $0.status) })
    }

    static func mcpProblemLine(statuses servers: [(name: String, status: String)]) -> String? {
        func names(_ status: String) -> [String] {
            var seen = Set<String>()
            return servers.filter { $0.status == status && !$0.name.isEmpty }.map(\.name).filter { seen.insert($0).inserted }
        }
        let signIn = names("needs-auth"), failed = names("failed")
        var parts: [String] = []
        if !signIn.isEmpty { parts.append("\(list(signIn)) \(signIn.count == 1 ? "needs" : "need") sign-in") }
        if !failed.isEmpty { parts.append("\(list(failed)) couldn't connect") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ") + " in Claude Code."
    }

    /// "A", "A and B", "A, B and C", "A, B and 2 more".
    private static func list(_ names: [String]) -> String {
        let shown = names.count > 3 ? Array(names.prefix(2)) + ["\(names.count - 2) more"] : names
        guard shown.count > 1 else { return shown.joined() }
        return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
    }
}

extension TurnFailureLine {
    /// The toast after "Use <model>" switched a lane for good (never silent).
    public static func modelSwitched(mode: Mode, model: ModelID) -> String {
        "\(mode.displayName) now uses \(model.displayName) · change in Settings › Models"
    }
}
