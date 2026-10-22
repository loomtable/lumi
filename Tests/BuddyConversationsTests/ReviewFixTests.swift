import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("Conversation review fixes")
struct ConversationReviewFixTests {
    struct Env {
        let manager: ConversationManager
        let sessions: FakeSessionFiles
        let clock: ManualConversationClock
    }

    func env(_ shots: URL) throws -> Env {
        let ids = Counter()
        let sessions = FakeSessionFiles()
        let clock = ManualConversationClock(t0)
        let m = ConversationManager(
            index: try ConversationIndex(url: nil), sessionFiles: sessions, screenshotDirectory: shots,
            clock: clock, makeID: { ids.next() })
        return Env(manager: m, sessions: sessions, clock: clock)
    }

    static let q1 = "11111111-1111-1111-1111-111111111111"
    static let q2 = "22222222-2222-2222-2222-222222222222"

    @Test("forgetting while a question runs: its finish doesn't recreate the row, and its sessions are deleted")
    func forgetMidTurn() async throws {
        try await withTempDir { dir in
            let e = try env(dir)
            let p = try await e.manager.prepare(projectFolder: nil)
            _ = try await e.manager.finish(id: p.id, update: TurnUpdate(quickSessionID: Self.q1), utterance: "one")
            _ = try await e.manager.prepare(projectFolder: nil)  // second question starts
            let request = try #require(try await e.manager.prepareForget(p.id))
            _ = try #require(try await e.manager.forget(request))
            let late = try await e.manager.finish(id: p.id, update: TurnUpdate(quickSessionID: Self.q2), utterance: "two")
            #expect(late == nil)
            #expect(try await e.manager.list().isEmpty)
            #expect(e.sessions.deletedSessions.last == [Self.q2])
        }
    }

    @Test("a screenshot from the first question is recorded once the row exists, and Forget deletes it")
    func firstTurnScreenshot() async throws {
        try await withTempDir { dir in
            let e = try env(dir)
            let p = try await e.manager.prepare(projectFolder: nil)
            let shot = try makeFile(dir.appending(path: "first.jpg"))
            try await e.manager.recordScreenshot(shot.path, conversation: p.id)
            _ = try await e.manager.finish(id: p.id, update: TurnUpdate(), utterance: "q")
            let request = try #require(try await e.manager.prepareForget(p.id))
            #expect(request.screenshotCount == 1)
            let report = try #require(try await e.manager.forget(request))
            #expect(report.screenshotsDeleted == [shot.path])
            #expect(!exists(shot))
        }
    }

    @Test("leaving temporary mode forgets temporary conversations' sessions and screenshots")
    func temporaryLeavesNothing() async throws {
        try await withTempDir { dir in
            let e = try env(dir)
            _ = try await e.manager.setTemporary(true)
            let p = try await e.manager.prepare(projectFolder: nil)
            let shot = try makeFile(dir.appending(path: "temp.jpg"))
            try await e.manager.recordScreenshot(shot.path, conversation: p.id)
            _ = try await e.manager.finish(id: p.id, update: TurnUpdate(quickSessionID: Self.q1), utterance: "secret")
            let reports = try await e.manager.setTemporary(false)
            #expect(reports.count == 1)
            #expect(!exists(shot))
            #expect(e.sessions.deletedSessions == [[Self.q1]])
            #expect(try await e.manager.list().isEmpty)
        }
    }

    @Test("Forget refuses a stale confirmation when something was added after it was shown")
    func staleConfirmation() async throws {
        try await withTempDir { dir in
            let e = try env(dir)
            let p = try await e.manager.prepare(projectFolder: nil)
            _ = try await e.manager.finish(id: p.id, update: TurnUpdate(), utterance: "q")
            let request = try #require(try await e.manager.prepareForget(p.id))
            try await e.manager.recordScreenshot(try makeFile(dir.appending(path: "late.jpg")).path, conversation: p.id)
            #expect(try await e.manager.forget(request) == nil)
            #expect(try await e.manager.list().count == 1)
        }
    }

    @Test("a still-empty conversation takes the project now in front")
    func pendingAdoptsProject() {
        var r = ConversationRules()
        _ = r.ask(projectFolder: "/a", at: t0, newID: "c1")
        let (d, _) = r.ask(projectFolder: "/b", at: t0.addingTimeInterval(5), newID: "c2")
        #expect(d == .continueCurrent("c1"))
        #expect(r.currentProject == "/b")
    }

    @Test("a clock jumping backwards closes the back window instead of stretching it")
    func clockBackwards() {
        var r = ConversationRules()
        _ = r.ask(projectFolder: nil, at: t0, newID: "c1")
        r.turnFinished(at: t0, projectFolder: nil)
        _ = r.newConversation(at: t0.addingTimeInterval(10), newID: "c2")
        #expect(r.goBack(at: t0.addingTimeInterval(-3600)) == nil)
    }
}
