import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("ConversationManager fixes")
struct ManagerFixTests {
    func manager(_ shots: URL, clock: ManualConversationClock = ManualConversationClock(t0)) throws -> ConversationManager {
        let ids = Counter()
        return ConversationManager(
            index: try ConversationIndex(url: nil), sessionFiles: FakeSessionFiles(), screenshotDirectory: shots,
            clock: clock, makeID: { ids.next() })
    }

    @Test("a Quick-only conversation stores the project that was in front")
    func quickOnlyProject() async throws {
        try await withTempDir { dir in
            let m = try manager(dir)
            let p = try await m.prepare(projectFolder: "/work/web")
            let saved = try await m.finish(id: p.id, update: TurnUpdate(quickSessionID: "q", lastLane: .quick), utterance: "hi")
            #expect(saved?.projectFolder == "/work/web")
        }
    }

    @Test("a research job started before the first save is written when the row is created")
    func pendingResearchJob() async throws {
        try await withTempDir { dir in
            let m = try manager(dir)
            let p = try await m.prepare(projectFolder: nil)
            let job = ResearchJobRecord(sessionID: "11111111-1111-1111-1111-111111111111", reportPath: "/r/qt.md")
            try await m.recordResearchJob(job, conversation: p.id)
            let saved = try await m.finish(id: p.id, update: TurnUpdate(), utterance: "research QT")
            #expect(saved?.researchJobs == [job])
            #expect(saved?.sessionIDs.contains("11111111-1111-1111-1111-111111111111") == true)
        }
    }

    @Test("title comes from the first non-blank line")
    func titleFirstNonBlank() {
        #expect(ConversationManager.title(from: "   \n  Hello there\nmore") == "Hello there")
        #expect(ConversationManager.title(from: " \n \n") == "Untitled")
    }

    @Test("Forget reports screenshots that were already gone")
    func missingScreenshot() async throws {
        try await withTempDir { dir in
            let m = try manager(dir)
            let p = try await m.prepare(projectFolder: nil)
            _ = try await m.finish(id: p.id, update: TurnUpdate(), utterance: "q")
            let present = try makeFile(dir.appending(path: "a.jpg"))
            let gone = dir.appending(path: "b.jpg").path
            try await m.recordScreenshot(present.path, conversation: p.id)
            try await m.recordScreenshot(gone, conversation: p.id)
            let request = try #require(try await m.prepareForget(p.id))
            let report = try #require(try await m.forget(request))
            #expect(report.screenshotsDeleted == [present.path])
            #expect(report.screenshotsMissing == [gone])
            #expect(report.screenshotsSkipped.isEmpty)
            #expect(!exists(present))
        }
    }
}
