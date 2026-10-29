@testable import BuddyApp
@testable import BuddyBridge
import BuddyCompanion
import BuddyCore
import Testing

struct TurnFailureLineTests {
    private func failed(code: String? = nil, status: Int? = nil, reason: String? = "api_error",
                        text: String = "") -> BridgeError {
        var r = StreamEvent.TurnResult(subtype: "success", isError: true, sessionID: "s", text: text,
                                       terminalReason: reason, apiErrorStatus: status, durationMS: nil, ttftMS: nil,
                                       costUSD: nil, permissionDenials: 0)
        r.errorCode = code
        return .turnFailed(r)
    }

    private func line(_ e: BridgeError, model: ModelID? = nil) -> TurnFailureLine.Line? {
        TurnFailureLine.line(for: e, model: model)
    }

    // Recorded (fixtures error-signed-out.jsonl, error-unknown-model.jsonl): exact fields.
    @Test func notSignedInLeadsToSettingsClaudeCode() {
        let l = line(failed(code: "authentication_failed", text: "Not logged in · Please run /login"))
        #expect(l == .init("Claude Code isn't signed in.", fix: .openSettings(.claudeCode)))
        #expect(l?.fix?.label == "Fix")
    }

    @Test func anUnknownModelLeadsToSettingsModels() {
        let l = line(failed(code: "model_not_found", status: 404,
                            text: "There's an issue with the selected model (claude-nonexistent-9)."))
        #expect(l == .init("That model isn't available to your account.", fix: .openSettings(.models)))
    }

    @Test func offlineRetriesSayWhatsHappening() {
        let retry = StreamEvent.APIRetry(attempt: 3, maxRetries: nil, retryDelayMS: 2311, errorStatus: nil, error: "unknown")
        #expect(TurnFailureLine.retrying(retry) == "Can't reach the API. Trying again…")
    }

    // Documented (code.claude.com/docs/en/errors, SDK types); not reproducible safely here.
    @Test func aSessionLimitKeepsClaudeCodesOwnLineWithNoModelSwitch() {
        let l = line(failed(code: "rate_limit", status: 429, text: "You've hit your session limit · resets 3:45pm"), model: .opus)
        #expect(l == .init("You've hit your session limit · resets 3:45pm"), "a session limit covers every model")
    }

    @Test func aPerModelLimitOffersASmallerModel() {
        let l = line(failed(code: "rate_limit", text: "You've hit your Opus limit"), model: .opus)
        #expect(l == .init("You've hit your Opus limit", fix: .useModel(.sonnet)))
        #expect(l?.fix?.label == "Use \(ModelID.sonnet.displayName)")
    }

    @Test func anAPIRateLimitSaysSoAndOffersASmallerModel() {
        #expect(line(failed(code: "rate_limit", status: 429), model: .sonnet) == .init("Hit a rate limit.", fix: .useModel(.haiku)))
        #expect(line(failed(code: "rate_limit"), model: .haiku)?.fix == nil, "nothing smaller than Haiku")
    }

    @Test func overloadedSaysBusy() {
        #expect(line(failed(code: "overloaded", status: 529), model: .opus)
                == .init("The API is busy right now. Try again in a moment.", fix: .useModel(.sonnet)))
        #expect(line(failed(status: 529))?.text == "The API is busy right now. Try again in a moment.", "status alone")
    }

    @Test func accountAndServerProblems() {
        #expect(line(failed(code: "billing_error")) == .init("There's a problem with your Claude account."), "no button that can't help")
        #expect(line(failed(code: "account_on_hold"))?.fix == nil)
        #expect(line(failed(code: "oauth_org_not_allowed")) == .init("This account's organization can't use Claude Code."))
        #expect(line(failed(status: 403)) == TurnFailureLine.generic, "a bare 403 doesn't say why")
        #expect(line(failed(code: "server_error"))?.text == "The API had a problem. Try again in a moment.")
        #expect(line(failed(status: 503))?.text == "The API had a problem. Try again in a moment.")
        #expect(line(failed(code: "cloud_credential_error"))?.fix == .openSettings(.claudeCode))
    }

    @Test func withoutACodeTheWordingStillCounts() {
        #expect(line(failed(code: nil, text: "Login expired · Please run /login"))?.fix == .openSettings(.claudeCode))
        #expect(line(failed(code: nil, text: "Unable to connect to API (ECONNREFUSED)"))?.text == "No connection to the API.")
        #expect(line(failed(code: nil, reason: "prompt_too_long"))?.text == "This session got too long. Start a new one with ⌘N.")
    }

    @Test func anythingElseKeepsTheGenericLine() {
        #expect(line(failed(code: "unknown", text: "something new")) == TurnFailureLine.generic)
        #expect(line(.cancelled) == nil)
        #expect(line(.timedOut)?.text == "Claude Code didn't answer in time.")
    }

    @Test func retryLinesForCapacityAndLimits() {
        func retry(_ error: String?, _ status: Int?) -> StreamEvent.APIRetry {
            .init(attempt: 1, maxRetries: 10, retryDelayMS: 500, errorStatus: status, error: error)
        }
        #expect(TurnFailureLine.retrying(retry("overloaded", 529)) == "The API is busy. Trying again…")
        #expect(TurnFailureLine.retrying(retry("rate_limit", 429)) == "Hit a rate limit. Trying again…")
        #expect(TurnFailureLine.retrying(retry("rate_limit", nil)) == "Hit a rate limit. Trying again…")
        #expect(TurnFailureLine.retrying(retry("server_error", 500)) == "The API had a problem. Trying again…")
        #expect(TurnFailureLine.retrying(retry("invalid_request", 400)) == nil, "no line we can stand behind")
        #expect(TurnFailureLine.retrying(retry("authentication_failed", nil)) == nil, "not a connection problem")
    }

    @Test func aBuddyPluginErrorOffersRepair() {
        let errors = [StreamEvent.PluginError(plugin: "buddy", type: "manifest", message: "bad json", path: nil)]
        #expect(TurnFailureLine.pluginProblem(errors) == .init("The Lumi plugin didn't load.", fix: .repairPlugin))
        #expect(TurnFailureLine.pluginProblem([.init(plugin: "other", type: "x", message: "y", path: nil)]) == nil)
    }
}

/// An open session's failed voice turn (V-05): the cascade's lines, not always the generic one.
struct SessionFailureLineTests {
    private func line(_ reason: SessionFailure.Reason?, text: String = "") -> TurnFailureLine.Line? {
        let end = TurnEnd(kind: .voice, markdown: text, isError: true,
                          error: reason.map { SessionFailure(reason: $0, retryable: true) })
        return TurnFailureLine.line(for: SessionTurnEvents.error(for: end))
    }

    @Test func signedOutOffersTheFix() {
        #expect(line(.auth, text: "Not logged in · Please run /login") == .init("Claude Code isn't signed in.", fix: .openSettings(.claudeCode)))
    }

    @Test func aMissingClaudeCodeSaysItIsntAvailable() {
        #expect(line(.unavailable("claude: not found")) == .init("Claude Code isn't available right now.", fix: .openSettings(.claudeCode)))
    }

    @Test func offlineAndLimitsUseTheCLIsWording() {
        #expect(line(.api("Unable to connect to API (ConnectionRefused)"), text: "Unable to connect to API (ConnectionRefused)")
                == .init("No connection to the API."))
        #expect(line(.rateLimited(resetsAt: nil), text: "You've hit your session limit · resets 3:45pm")
                == .init("You've hit your session limit · resets 3:45pm"))
        #expect(line(.api("model_not_found")) == .init("That model isn't available to your account.", fix: .openSettings(.models)))
    }

    @Test func aDeadProcessAndAnUnknownFailureKeepTheirLines() {
        #expect(line(.crashed) == TurnFailureLine.stopped)
        #expect(line(.api("something new")) == TurnFailureLine.generic)
        #expect(line(nil) == TurnFailureLine.generic)
    }
}

struct ModelSwitchToastTests {
    @Test func theSwitchIsNeverSilentAndNamesTheExactModel() {
        #expect(TurnFailureLine.modelSwitched(mode: .quick, model: .haiku)
                == "Quick now uses \(ModelID.haiku.displayName) · change in Settings › Models")
        #expect(TurnFailureLine.modelSwitched(mode: .deep, model: .sonnet).hasPrefix("Deep now uses \(ModelID.sonnet.displayName)"))
        #expect(FixAction.useModel(.sonnet).label == "Use \(ModelID.sonnet.displayName)", "the button names the exact model")
    }
}
