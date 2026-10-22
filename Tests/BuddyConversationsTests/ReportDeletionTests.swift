import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

/// Research reports (one folder per job inside the reports folder) leave with their
/// conversation: Forget, retention and leaving temporary mode.
@Suite("Report deletion")
struct ReportDeletionTests {
    struct Setup {
        let clock = ManualConversationClock(t0)
        let files = FakeSessionFiles()
        let reports: URL
        let manager: ConversationManager

        init(dir: URL) throws {
            reports = dir.appending(path: "reports", directoryHint: .isDirectory)
            let shots = dir.appending(path: "shots", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            let ids = Counter()
            manager = ConversationManager(index: try ConversationIndex(url: nil), sessionFiles: files,
                                          screenshotDirectory: shots, reportsDirectory: reports, clock: clock,
                                          makeID: { ids.next() })
        }

        /// A job folder with its report, as ResearchManager lays it out.
        func report(_ job: String) throws -> URL {
            try makeFile(reports.appending(path: "\(job)/report.md"), "# Report")
        }

        func saved(_ utterance: String) async throws -> String {
            let p = try await manager.prepare(projectFolder: nil)
            _ = try await manager.finish(id: p.id, update: TurnUpdate(quickSessionID: "q-\(p.id)", lastLane: .quick),
                                         utterance: utterance)
            return p.id
        }
    }

    @Test("Forget deletes each job's folder, counts them first, and nothing outside the reports folder")
    func forget() async throws {
        try await withTempDir { dir in
            let s = try Setup(dir: dir)
            let id = try await s.saved("qt research")
            let one = try s.report("job-1"), two = try s.report("job-2")
            let stray = try makeFile(dir.appending(path: "elsewhere/report.md"))
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: one.path), conversation: id)
            // Learns its session: the same report replaces its row.
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: "r1", reportPath: one.path), conversation: id)
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: two.path), conversation: id)
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: stray.path), conversation: id)

            let request = try #require(try await s.manager.prepareForget(id))
            #expect(request.reportCount == 3)
            let report = try #require(try await s.manager.forget(request))
            #expect(!exists(one.deletingLastPathComponent()) && !exists(two.deletingLastPathComponent()))
            #expect(report.reportsDeleted.count == 2)
            #expect(exists(stray), "outside the reports folder: left alone")
            #expect(s.files.deletedSessions.flatMap { $0 }.contains("r1"))
        }
    }

    @Test("a job that finishes after Forget has its report deleted then")
    func lateJob() async throws {
        try await withTempDir { dir in
            let s = try Setup(dir: dir)
            let id = try await s.saved("qt research")
            _ = try await s.manager.forget(try #require(try await s.manager.prepareForget(id)))
            let late = try s.report("job-late")
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: "r-late", reportPath: late.path), conversation: id)
            #expect(!exists(late.deletingLastPathComponent()))
            #expect(s.files.deletedSessions.contains(["r-late"]))
        }
    }

    @Test("retention removes reports with the row, but keeps sessions")
    func prune() async throws {
        try await withTempDir { dir in
            let s = try Setup(dir: dir)
            let old = try await s.saved("old")
            let report = try s.report("job-old")
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: "r-old", reportPath: report.path), conversation: old)
            s.clock.advance(40 * 86_400)
            _ = try await s.manager.newConversation()
            _ = try await s.saved("recent")
            s.clock.advance(60 * 86_400)   // past the ↩ Back window too
            #expect(try await s.manager.prune(unusedSince: s.clock.now().addingTimeInterval(-90 * 86_400)) == [old])
            #expect(!exists(report.deletingLastPathComponent()))
            #expect(!s.files.deletedSessions.flatMap { $0 }.contains("r-old"))
        }
    }

    @Test("leaving temporary mode deletes its reports, saved or still pending")
    func temporary() async throws {
        try await withTempDir { dir in
            let s = try Setup(dir: dir)
            try await s.manager.setTemporary(true)
            let saved = try await s.saved("temp one")
            let savedReport = try s.report("job-saved")
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: savedReport.path), conversation: saved)
            _ = try await s.manager.newConversation()
            let pending = try await s.manager.prepare(projectFolder: nil)   // no turn saved yet
            let pendingReport = try s.report("job-pending")
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: pendingReport.path), conversation: pending.id)
            try await s.manager.setTemporary(false)
            #expect(!exists(savedReport.deletingLastPathComponent()) && !exists(pendingReport.deletingLastPathComponent()))
        }
    }

    @Test("a job ending after retention removed its conversation loses its report, not its session")
    func latePrune() async throws {
        try await withTempDir { dir in
            let s = try Setup(dir: dir)
            let old = try await s.saved("old")
            s.clock.advance(40 * 86_400)
            _ = try await s.manager.newConversation()
            _ = try await s.saved("recent")
            s.clock.advance(60 * 86_400)
            _ = try await s.manager.prune(unusedSince: s.clock.now().addingTimeInterval(-90 * 86_400))
            let late = try s.report("job-late")
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: "r-late", reportPath: late.path), conversation: old)
            #expect(!exists(late.deletingLastPathComponent()))
            #expect(!s.files.deletedSessions.flatMap { $0 }.contains("r-late"))
        }
    }

    @Test("a job still running when temporary mode ends deletes its report when it records")
    func lateTemporary() async throws {
        try await withTempDir { dir in
            let s = try Setup(dir: dir)
            try await s.manager.setTemporary(true)
            let saved = try await s.saved("temp one")
            _ = try await s.manager.newConversation()
            let pending = try await s.manager.prepare(projectFolder: nil)
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: "/nowhere/x.md"), conversation: pending.id)
            try await s.manager.setTemporary(false)
            for id in [saved, pending.id] {
                let late = try s.report("job-\(id)")
                try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: "r-\(id)", reportPath: late.path), conversation: id)
                #expect(!exists(late.deletingLastPathComponent()), "\(id)")
            }
            #expect(try await s.manager.list().isEmpty, "nothing reaches the saved index")
        }
    }

    @Test("a saved conversation's job that ends during temporary mode is kept with its saved row")
    func savedJobDuringTemporary() async throws {
        try await withTempDir { dir in
            let s = try Setup(dir: dir)
            let id = try await s.saved("saved one")
            try await s.manager.setTemporary(true)
            let report = try s.report("job-saved")
            try await s.manager.recordResearchJob(ResearchJobRecord(sessionID: "r1", reportPath: report.path), conversation: id)
            try await s.manager.setTemporary(false)
            #expect(try await s.manager.prepareForget(id)?.reportCount == 1)
            _ = try await s.manager.forget(try #require(try await s.manager.prepareForget(id)))
            #expect(!exists(report.deletingLastPathComponent()))
        }
    }

    @Test("without a reports folder, reports are left alone")
    func noFolder() async throws {
        try await withTempDir { dir in
            let h = try Harness(dir: dir)
            let (_, a) = try await h.ask("x")
            let report = try makeFile(dir.appending(path: "reports/job/report.md"))
            try await h.manager.recordResearchJob(ResearchJobRecord(sessionID: nil, reportPath: report.path), conversation: a.id)
            _ = try await h.manager.forget(try #require(try await h.manager.prepareForget(a.id)))
            #expect(exists(report))
        }
    }
}
