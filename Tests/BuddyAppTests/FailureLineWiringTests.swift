import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCompanion
import BuddyCore
import BuddyKeys
import BuddyOverlay

/// Failures say what went wrong, with a button that fixes it.
extension BuddyCoordinatorTests {
    static func failed(code: String) -> CascadeEvent {
        var r = StreamEvent.TurnResult(subtype: "success", isError: true, sessionID: "s", text: "",
                                       terminalReason: "api_error", apiErrorStatus: nil, durationMS: nil,
                                       ttftMS: nil, costUSD: nil, permissionDenials: 0)
        r.errorCode = code
        return .turn(lane: .quick, .failed(.turnFailed(r)))
    }

    var chips: [BuddyBlock] {
        overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.block } else { nil } }
    }

    @Test func signedOutSaysSoAndItsFixOpensClaudeCodeSettings() async {
        bridge.setScript([Self.failed(code: "authentication_failed"), Self.done(nil)])
        let coordinator = makeCoordinator()
        var opened: [SettingsPane] = []
        coordinator.onOpenSettingsPane = { opened.append($0) }
        await tapToTalk(coordinator)
        let chip = chips.last
        #expect(chip?.say == "Claude Code isn't signed in.")
        #expect(chip?.actions.map(\.label) == ["Fix"])

        overlay.send(.action(index: 0))
        await settle(until: { !opened.isEmpty })
        #expect(opened == [.claudeCode])
        #expect(bridge.asked.count == 1, "no model turn")
        #expect(coordinator.phase == .idle)
    }

    @Test func aPluginThatDidntLoadExplainsTheFailureAndRepairs() async {
        let info = StreamEvent.InitInfo(
            sessionID: "s", model: "m", cwd: "/", permissionMode: "auto", version: nil,
            pluginErrors: [.init(plugin: "buddy", type: "load", message: "x", path: nil)], plugins: [], mcpServers: [])
        bridge.setScript([.turn(lane: .quick, .initialized(info)), Self.failed(code: "something_new"), Self.done(nil)])
        let coordinator = makeCoordinator()
        var repairs = 0
        coordinator.onRepairPlugin = { repairs += 1 }
        await tapToTalk(coordinator)
        #expect(chips.last?.say == "The Lumi plugin didn't load.")
        overlay.send(.action(index: 0))
        await settle(until: { repairs == 1 })
        #expect(repairs == 1)
    }

    @Test func withoutTheRuntimeHookNoSmallerModelIsOffered() async {
        bridge.setScript([.turn(lane: .quick, .failed(.turnFailed(.init(
            subtype: "success", isError: true, sessionID: "s", text: "", terminalReason: "api_error",
            apiErrorStatus: 529, durationMS: nil, ttftMS: nil, costUSD: nil, permissionDenials: 0)))), Self.done(nil)])
        var settings = BuddyCoordinator.Settings()
        settings.quick.model = .opus
        let coordinator = makeCoordinator(settings: settings)
        await tapToTalk(coordinator)
        #expect(chips.last?.say == "The API is busy right now. Try again in a moment.")
        #expect(chips.last?.actions.isEmpty == true) // "Use Sonnet" needs onUseModel
        _ = coordinator
    }

    @Test func aRetrySaysWhyInThePill() async {
        let retry = StreamEvent.APIRetry(attempt: 1, maxRetries: 10, retryDelayMS: 500, errorStatus: 529, error: "overloaded")
        bridge.setScript([.turn(lane: .quick, .retrying(retry)), Self.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        #expect(overlay.calls.contains { call in
            switch call {
            case .status("The API is busy. Trying again…"), .thinking(_, status: "The API is busy. Trying again…"): true
            default: false
            }
        })
        _ = coordinator
    }

    @Test func everyTurnReportsItsPermissionMode() async {
        let info = StreamEvent.InitInfo(sessionID: "s", model: "m", cwd: "/", permissionMode: "default", version: nil,
                                        pluginErrors: [], plugins: [], mcpServers: [])
        bridge.setScript([.turn(lane: .quick, .initialized(info)), Self.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let coordinator = makeCoordinator()
        var modes: [String] = []
        coordinator.onPermissionMode = { modes.append($0) }
        await tapToTalk(coordinator)
        #expect(modes == ["default"])
    }

    @Test func everyTurnReportsItsMCPServers() async {
        let servers = [StreamEvent.MCPServer(name: "Linear", status: "needs-auth")]
        let info = StreamEvent.InitInfo(sessionID: "s", model: "m", cwd: "/", permissionMode: "auto", version: nil,
                                        pluginErrors: [], plugins: [], mcpServers: servers)
        bridge.setScript([.turn(lane: .quick, .initialized(info)), Self.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let coordinator = makeCoordinator()
        var reports: [(Mode, [StreamEvent.MCPServer])] = []
        coordinator.onMCPServers = { reports.append(($0, $1)) }
        await tapToTalk(coordinator)
        #expect(reports.count == 1 && reports.first?.0 == .quick && reports.first?.1 == servers)
    }

    @Test func useASmallerModelSwitchesSaysSoAndAsksAgain() async {
        let busy = CascadeEvent.turn(lane: .quick, .failed(.turnFailed(.init(
            subtype: "success", isError: true, sessionID: "s", text: "", terminalReason: "api_error",
            apiErrorStatus: 529, durationMS: nil, ttftMS: nil, costUSD: nil, permissionDenials: 0))))
        bridge.setScript([busy, Self.done(nil)])
        var settings = BuddyCoordinator.Settings()
        settings.quick.model = .opus
        let coordinator = makeCoordinator(settings: settings)
        var switched: [(ModelID, Mode)] = []
        coordinator.onUseModel = { model, mode in switched.append((model, mode)) }
        await tapToTalk(coordinator)
        #expect(chips.last?.actions.map(\.label) == [FixAction.useModel(.sonnet).label])

        bridge.setScript([Self.done(BuddyBlock(say: "Now it works.", shape: .chip))])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 && coordinator.phase == .showing })
        #expect(switched.map(\.0) == [.sonnet] && switched.map(\.1) == [.quick])
        #expect(overlay.calls.contains(.toast(TurnFailureLine.modelSwitched(mode: .quick, model: .sonnet))))
        #expect(bridge.asked.last?.packet.utterance == bridge.asked.first?.packet.utterance) // the same question
        #expect(chips.last?.say == "Now it works.")
    }

    @Test func aTimeoutOffersTryAgainWhichAsksTheSameQuestionAgain() async {
        bridge.setScript([.turn(lane: .quick, .failed(.timedOut)), Self.done(nil)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        #expect(chips.last?.say == "Claude Code didn't answer in time.")
        #expect(chips.last?.actions.map(\.label) == ["Try again"])
        await settle(until: { voice.calls.contains(.speak("Claude Code didn't answer in time.")) })
        #expect(voice.calls.contains(.speak("Claude Code didn't answer in time.")), "a spoken question's failure is said")

        bridge.setScript([Self.done(BuddyBlock(say: "Here it is.", shape: .chip))])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 && coordinator.phase == .showing })
        guard bridge.asked.count >= 2 else { Issue.record("asked: \(bridge.asked.count) of 2"); return }
        #expect(bridge.asked[1].packet.utterance == bridge.asked[0].packet.utterance)
        #expect(bridge.asked[1].packet.conversation?.turn == bridge.asked[0].packet.conversation?.turn)
        #expect(chips.last?.say == "Here it is.")
        await settle(until: { voice.calls.contains(.speak("Here it is.")) }) // speech follows the card
        #expect(voice.calls.contains(.speak("Here it is.")), "asked again as it was: spoken, so read out")
    }

    @Test func aFailedActionIsTriedAgainNotTheQuestionBeforeIt() async {
        let block = BuddyBlock(say: "I can convert these cells.", shape: .rich,
                               actions: [.init(label: "Convert", prompt: "Convert column C to numbers")])
        bridge.setScript([Self.done(block)])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        bridge.setScript([CascadeEvent.turn(lane: .deep, .failed(.processExited(status: 1, stderr: ""))), Self.done(nil, lane: .deep)])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 && coordinator.phase == .showing })
        #expect(chips.last?.say == "Claude Code stopped unexpectedly.")
        #expect(!voice.calls.contains(.speak("Claude Code stopped unexpectedly.")), "an action's turn isn't read out")

        bridge.setScript([Self.done(BuddyBlock(say: "Converted.", shape: .chip), lane: .deep)])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 3 && coordinator.phase == .showing })
        guard bridge.asked.count >= 3 else { Issue.record("asked: \(bridge.asked.count) of 3"); return }
        #expect(bridge.asked[2].packet.utterance == "Convert column C to numbers")
        #expect(bridge.asked[1].isApprovedAction, "the press approved the first run")
        #expect(bridge.asked[2].routing == .alwaysDeep && !bridge.asked[2].isApprovedAction,
                "it may have partly run: asked again as a proposal that needs the user's OK")
        #expect(chips.last?.say == "Converted.")
    }

    @Test func aFailedGoDeeperGoesDeeperAgain() async {
        bridge.setScript([Self.done(BuddyBlock(say: "Short answer.", shape: .rich))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        bridge.setScript([.turn(lane: .deep, .failed(.timedOut)), Self.done(nil, lane: .deep)])
        overlay.send(.goDeeper)
        await settle(until: { bridge.deeperCount == 1 && coordinator.phase == .showing })
        #expect(chips.last?.actions.map(\.label) == ["Try again"])

        bridge.setScript([Self.done(BuddyBlock(say: "The long answer.", shape: .rich), lane: .deep)])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.deeperCount == 2 && coordinator.phase == .showing })
        #expect(bridge.asked.count == 1, "through Go deeper, not a new question")
        guard bridge.deeper.count >= 2 else { Issue.record("deeper: \(bridge.deeper.count) of 2"); return }
        #expect(bridge.deeper[1].packet.utterance == "what does this mean?")
    }

    @Test func aTypedQuestionsFailureIsShownNotSaid() async {
        bridge.setScript([.turn(lane: .quick, .failed(.timedOut)), Self.done(nil)])
        let coordinator = makeCoordinator()
        await coordinator.handle(.gesture(.pressBegan(fresh: false)))
        await coordinator.handle(.gesture(.doubleTap))
        overlay.send(.submitted(text: "is this valid json", source: .textBox))
        await settle(until: { coordinator.phase == .showing })
        #expect(chips.last?.say == "Claude Code didn't answer in time.")
        #expect(!voice.calls.contains { if case .speak = $0 { true } else { false } })
    }

    @Test func useASmallerModelAfterAFailedActionAsksTheActionAgain() async {
        let block = BuddyBlock(say: "I can convert these cells.", shape: .rich,
                               actions: [.init(label: "Convert", prompt: "Convert column C to numbers")])
        bridge.setScript([Self.done(block)])
        var settings = BuddyCoordinator.Settings()
        settings.quick.model = .opus
        settings.deep.model = .opus
        let coordinator = makeCoordinator(settings: settings)
        coordinator.onUseModel = { _, _ in }
        await tapToTalk(coordinator)
        bridge.setScript([CascadeEvent.turn(lane: .deep, .failed(.turnFailed(.init(
            subtype: "success", isError: true, sessionID: "s", text: "", terminalReason: "api_error",
            apiErrorStatus: 529, durationMS: nil, ttftMS: nil, costUSD: nil, permissionDenials: 0)))),
                          Self.done(nil, lane: .deep)])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 2 && coordinator.phase == .showing })
        #expect(chips.last?.actions.map(\.label) == [FixAction.useModel(.sonnet).label])

        bridge.setScript([Self.done(BuddyBlock(say: "Converted.", shape: .chip), lane: .deep)])
        overlay.send(.action(index: 0))
        await settle(until: { bridge.asked.count == 3 && coordinator.phase == .showing })
        guard bridge.asked.count >= 3 else { Issue.record("asked: \(bridge.asked.count) of 3"); return }
        #expect(bridge.asked[2].packet.utterance == "Convert column C to numbers")
        #expect(!bridge.asked[2].isApprovedAction, "a smaller model doesn't carry the approval either")
    }

    @Test func tryAgainWithTheConversationGoneClosesTheChip() async {
        let conversations = ForgettingConversations()
        var settings = BuddyCoordinator.Settings()
        settings.sounds = false
        let coordinator = BuddyCoordinator(
            settings: settings, voice: voice, context: FakeContext.packet(), turns: bridge,
            overlay: overlay, pointer: FixedPointer(), conversations: conversations)
        coordinator.start()
        bridge.setScript([.turn(lane: .quick, .failed(.timedOut)), Self.done(nil)])
        await tapToTalk(coordinator)
        #expect(chips.last?.actions.map(\.label) == ["Try again"])
        conversations.forgotten = true // Forget, or temporary mode switched
        overlay.send(.action(index: 0))
        await settle(until: { coordinator.phase == .idle })
        #expect(coordinator.phase == .idle && bridge.asked.count == 1, "nothing sent, nothing left spinning")
    }

    @Test func failuresThatAskingAgainWontFixOfferNoTryAgain() {
        #expect(TurnFailureLine.line(for: .busy)?.fix == nil)
        #expect(TurnFailureLine.line(for: .unavailable("x"))?.fix == .openSettings(.claudeCode))
        for retryable: BridgeError in [.timedOut, .processExited(status: 1, stderr: ""), .launchFailed("x")] {
            #expect(TurnFailureLine.line(for: retryable)?.fix == .retry)
        }
        #expect(TurnFailureLine.noAnswer.fix == .retry && TurnFailureLine.screenUnreadable.fix == .retry)
    }

    @Test func deniedToolsAreANoteAfterTheAnswerEachOnce() async {
        bridge.setScript([.turn(lane: .quick, .permissionNotice(.denied(tools: ["Bash", "Write", "Bash"]))),
                          Self.done(BuddyBlock(say: "Done what I could.", shape: .chip))])
        let coordinator = makeCoordinator()
        await tapToTalk(coordinator)
        await settle(until: { overlay.calls.contains { if case .toast = $0 { true } else { false } } })
        let answer = overlay.calls.firstIndex { if case .answer = $0 { true } else { false } }
        let toast = overlay.calls.firstIndex(of: .toast("Claude Code wasn't allowed to use Bash, Write."))
        #expect(answer != nil && toast != nil && answer! < toast!)
        _ = coordinator
    }
}

/// Memory conversations whose current one can be forgotten mid-test.
@MainActor final class ForgettingConversations: ConversationPort {
    private let inner = MemoryConversations()
    var forgotten = false

    var current: ConversationTurn? { forgotten ? nil : inner.current }
    func prepare(project: String?) async -> ConversationTurn { await inner.prepare(project: project) }
    func update(_ state: ConversationState) async { await inner.update(state) }
    func recordTurn(conversationID: String, question: String, answer: String) async -> ConversationTurn? {
        await inner.recordTurn(conversationID: conversationID, question: question, answer: answer)
    }
    func record(_ turn: TranscriptTurn, conversationID: String) async -> ConversationTurn? {
        await inner.record(turn, conversationID: conversationID)
    }
    func startNew() async -> ConversationTurn { await inner.startNew() }
    func switchTo(_ id: String) async -> ConversationTurn? { nil }
    func recordScreenshot(_ path: String, conversationID: String) async {}
}
