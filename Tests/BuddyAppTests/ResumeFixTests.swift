@testable import BuddyApp
import BuddyConversations
import BuddyCore
import Foundation
import Testing

/// The resume bug (01 §2): a resumed conversation went back to a new session one or two turns
/// later. These replay it through LiveConversations over a file index and a relaunch.
@MainActor
struct ResumeFixTests {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let deepID = "22222222-2222-4222-8222-222222222222"

    private func live(_ index: ConversationIndex, clock: ManualConversationClock) -> LiveConversations {
        let manager = ConversationManager(index: index, sessionFiles: FakeSessionFiles(),
                                          screenshotDirectory: FileManager.default.temporaryDirectory, clock: clock)
        return LiveConversations(manager: manager, reader: nil)
    }

    /// One turn answered by Deep in `folder`.
    private func deepTurn(_ c: LiveConversations, project: String?, folder: String, question: String) async -> ConversationTurn {
        let turn = await c.prepare(project: project)
        var state = turn.state
        state.deepSessionID = Self.deepID
        state.deepFolder = URL(fileURLWithPath: folder, isDirectory: true)
        state.lastLane = .deep
        await c.update(state)
        _ = await c.recordTurn(conversationID: turn.state.id, question: question, answer: "Answer to \(question).")
        return turn
    }

    @Test func deepInHomeThenARepoInFrontContinuesTheSameConversation() async throws {
        let clock = ManualConversationClock()
        let c = live(try ConversationIndex(url: nil), clock: clock)
        let first = await deepTurn(c, project: nil, folder: Self.home, question: "what's on this page")
        clock.advance(120)
        let next = await c.prepare(project: Self.home + "/Developer/lumi")
        #expect(next.state.id == first.state.id, "no split: Deep in home is not another project")
        clock.advance(60)
        #expect(await c.prepare(project: Self.home + "/Developer/other").state.id == first.state.id)
    }

    @Test func afterARelaunchAResumedDeepConversationKeepsItsRecapDeepTimeAndFolder() async throws {
        try await withTemporaryIndex { url in
            let clock = ManualConversationClock()
            let id: String
            do {
                let c = live(try ConversationIndex(url: url), clock: clock)
                id = await deepTurn(c, project: nil, folder: "/work/web", question: "why is it empty").state.id
                clock.advance(10)
                _ = await deepTurn(c, project: nil, folder: "/work/web", question: "and the filter")
            }
            // Relaunch: a new index over the same file, nothing in memory.
            clock.advance(30)
            let again = live(try ConversationIndex(url: url), clock: clock)
            let resumed = try #require(await again.switchTo(id))
            #expect(resumed.previous == [
                "Q: why is it empty\nA: Answer to why is it empty.",
                "Q: and the filter\nA: Answer to and the filter.",
            ])
            #expect(resumed.state.lastDeepAnswerAt == ManualConversationClock().now().addingTimeInterval(10))
            #expect(resumed.state.deepFolder?.path == "/work/web")
            #expect(resumed.state.deepSessions == ["/work/web": Self.deepID])
            // The next question continues it, with the recap.
            let next = await again.prepare(project: nil)
            #expect(next.state.id == id && next.previous.count == 2)
        }
    }

    @Test func aQuickOnlyProjectIsNeverTakenForDeepsFolder() async throws {
        let clock = ManualConversationClock()
        let c = live(try ConversationIndex(url: nil), clock: clock)
        let turn = await c.prepare(project: "/work/app")
        var state = turn.state
        state.quickSessionID = "11111111-1111-4111-8111-111111111111"
        state.lastLane = .quick
        await c.update(state)
        _ = await c.recordTurn(conversationID: turn.state.id, question: "q", answer: "a")
        let resumed = try #require(await c.switchTo(turn.state.id))
        #expect(resumed.state.deepFolder == nil)
    }

    private func withTemporaryIndex(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "resume-fix-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir.appending(path: "conversations.sqlite"))
    }
}
