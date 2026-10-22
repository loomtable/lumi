@testable import BuddyApp
@testable import BuddyBridge
import BuddyCompanion
import BuddyCore
import BuddyKeys
import Foundation
import Testing

@MainActor
struct MenuBarStateTests {
    @Test func activityFollowsThePhaseAndResearch() {
        typealias P = BuddyCoordinator.Phase
        let cases: [(P, Bool, MenuBarActivity)] = [
            (.idle, false, .idle), (.listening(confirmedTap: false, holding: true), false, .listening),
            (.held, false, .idle), (.held, true, .busy), (.thinking, false, .busy), (.typing, false, .idle),
            (.showing, false, .idle), (.idle, true, .busy), (.showing, true, .busy),
            (.listening(confirmedTap: true, holding: false), true, .listening),
        ]
        for (phase, research, expected) in cases {
            #expect(MenuBarActivity.from(phase: phase, researchRunning: research) == expected, "\(phase) research=\(research)")
        }
    }

    @Test func aCheckStartsTheEngineWhenClaudeCodeTurnsUpOrIsUpdated() {
        func status(_ path: String?, _ version: String?) -> ClaudeCodeStatus {
            ClaudeCodeStatus(executablePath: path, version: version, checked: true)
        }
        let claude = "/Users/me/.local/bin/claude"
        #expect(AppRuntime.startsAfterCheck(previous: ClaudeCodeStatus(), new: status(claude, "2.1.301")))
        #expect(AppRuntime.startsAfterCheck(previous: status(claude, "2.1.200"), new: status(claude, "2.1.301")))
        #expect(!AppRuntime.startsAfterCheck(previous: status(claude, "2.1.200"), new: status(claude, "2.1.250")))
        #expect(!AppRuntime.startsAfterCheck(previous: status(claude, "2.1.301"), new: status(claude, "2.1.302")))
        #expect(!AppRuntime.startsAfterCheck(previous: ClaudeCodeStatus(), new: status(nil, nil)))
    }

    @Test func eachProblemLeadsToThePaneThatFixesIt() {
        #expect(AppRuntime.fix(for: AppRuntime.claudeMissing) == .claudeCode)
        #expect(AppRuntime.fix(for: AppRuntime.claudeTooOld) == .claudeCode)
        #expect(AppRuntime.fix(for: AppRuntime.pluginFailedPrefix + "disk full") == .claudeCode)
        #expect(AppRuntime.fix(for: AppRuntime.message(for: .inputMonitoringNotGranted)) == .privacy)
        #expect(AppRuntime.fix(for: AppRuntime.message(for: .accessibilityNotGranted)) == .privacy)
        #expect(AppRuntime.fix(for: AppRuntime.message(for: .tapCreationFailed)) == .privacy)
        #expect(AppRuntime.fix(for: AppRuntime.voiceFailedPrefix + "no network") == .voice)
        #expect(AppRuntime.fix(for: LiveConversations.saveFailed) == .conversations)
        #expect(AppRuntime.fix(for: AppRuntime.temporaryFailed) == .conversations)
        #expect(AppRuntime.fix(for: AppRuntime.indexFailed) == .conversations)
        #expect(AppRuntime.fix(for: "The microphone stopped working.") == nil, "no pane fixes it, so no link")
    }

    @Test func activeResearchJobsAreTheOnesStillWorking() {
        func job(_ state: ResearchState) -> ResearchJob {
            var j = ResearchJob(id: UUID(), conversationID: "c", topic: "t", reportPath: URL(fileURLWithPath: "/r.md"))
            j.state = state
            return j
        }
        #expect(job(.queued).isActive && job(.running).isActive)
        #expect(!job(.done).isActive && !job(.cancelled).isActive && !job(.failed("x")).isActive)
    }
}

extension BuddyCoordinatorTests {
    @Test func everyPhaseChangeIsReportedOnce() async {
        bridge.setScript([Self.done(BuddyBlock(say: "It's QT.", shape: .chip))])
        let coordinator = makeCoordinator()
        var phases: [BuddyCoordinator.Phase] = []
        coordinator.onPhaseChange = { phases.append($0) }
        await tapToTalk(coordinator)
        await settle(until: { coordinator.phase == .showing })
        #expect(phases.first.map { if case .listening = $0 { true } else { false } } == true)
        #expect(phases.contains(.thinking) && phases.last == .showing)
        #expect(zip(phases, phases.dropFirst()).allSatisfy { $0 != $1 }, "no repeats")
    }
}
