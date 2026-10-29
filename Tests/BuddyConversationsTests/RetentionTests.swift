import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("Retention")
struct RetentionTests {
    @Test("conversations unused past retention leave the index with their screenshots, not their sessions")
    func prunesOldOnly() async throws {
        try await withTempDir { dir in
            let clock = ManualConversationClock(t0)
            let files = FakeSessionFiles()
            let ids = Counter()
            let m = ConversationManager(index: try ConversationIndex(url: nil), sessionFiles: files,
                                        screenshotDirectory: dir, clock: clock, makeID: { ids.next() })
            let old = try await m.prepare(projectFolder: nil)
            let shot = dir.appending(path: "old.png")
            try Data([1]).write(to: shot)
            try await m.recordScreenshot(shot.path, conversation: old.id)
            _ = try await m.finish(id: old.id, update: TurnUpdate(quickSessionID: "q-old", lastLane: .quick), utterance: "old one")

            clock.advance(40 * 86_400)
            let recent = try await m.newConversation()
            _ = try await m.finish(id: recent.id, update: TurnUpdate(quickSessionID: "q-new", lastLane: .quick), utterance: "recent")

            clock.advance(60 * 86_400)
            let removed = try await m.prune(unusedSince: clock.now().addingTimeInterval(-90 * 86_400))
            #expect(removed == [old.id])
            #expect(try await m.list().map(\.id) == [recent.id])
            #expect(!FileManager.default.fileExists(atPath: shot.path), "its screenshot goes too")
            #expect(files.deletedSessions.isEmpty, "Claude Code's own session files are left alone")
        }
    }

    @Test("the current conversation is never pruned, however old")
    func keepsCurrent() async throws {
        try await withTempDir { dir in
            let clock = ManualConversationClock(t0)
            let m = ConversationManager(index: try ConversationIndex(url: nil), sessionFiles: FakeSessionFiles(),
                                        screenshotDirectory: dir, clock: clock)
            let p = try await m.prepare(projectFolder: nil)
            _ = try await m.finish(id: p.id, update: TurnUpdate(quickSessionID: "q", lastLane: .quick), utterance: "still open")
            clock.advance(200 * 86_400)
            #expect(try await m.prune(unusedSince: clock.now().addingTimeInterval(-90 * 86_400)).isEmpty)
            #expect(try await m.list().count == 1)
        }
    }

    @Test("a question that finishes after its conversation was pruned doesn't bring it back")
    func lateFinishAfterPrune() async throws {
        try await withTempDir { dir in
            let clock = ManualConversationClock(t0)
            let files = FakeSessionFiles()
            let ids = Counter()
            let m = ConversationManager(index: try ConversationIndex(url: nil), sessionFiles: files,
                                        screenshotDirectory: dir, clock: clock, makeID: { ids.next() })
            let a = try await m.prepare(projectFolder: nil)
            _ = try await m.finish(id: a.id, update: TurnUpdate(quickSessionID: "q-a", lastLane: .quick), utterance: "about A")
            clock.advance(100 * 86_400)
            let b = try await m.newConversation()      // A is no longer current
            _ = try await m.finish(id: b.id, update: TurnUpdate(quickSessionID: "q-b", lastLane: .quick), utterance: "about B")
            clock.advance(10)
            #expect(try await m.prune(unusedSince: clock.now().addingTimeInterval(-90 * 86_400)) == [a.id])
            let late = try await m.finish(id: a.id, update: TurnUpdate(quickSessionID: "q-a", lastLane: .quick), utterance: "late")
            let remaining = try await m.list()
            #expect(late == nil && remaining.map(\.id) == [b.id], "A is not recreated")
            #expect(files.deletedSessions.isEmpty, "and its sessions are kept")
        }
    }
}
