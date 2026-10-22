import BuddyCore
import Foundation
import Synchronization
import Testing
@testable import BuddyTrace

/// A clock tests move by hand, read by the log's `now`.
final class TestNow: Sendable {
    let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    func advance(days: Int) { value.withLock { $0 = $0.addingTimeInterval(Double(days) * 86_400) } }
}

@Suite("TraceLog")
struct TraceLogTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-10-14 12:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_791_979_200)

    func withLog(enabled: Bool = true, _ body: (TraceLog, URL, TestNow) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = TestNow(Self.start)
        let log = TraceLog(directory: dir, enabled: enabled, now: { now.value.withLock { $0 } }, calendar: Self.utc)
        try await body(log, dir, now)
    }

    func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func lines(_ dir: URL, _ name: String) throws -> [String] {
        try String(contentsOf: dir.appending(path: name), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test("events go to the day's file as tab-separated kinds and numbers only")
    func writes() async throws {
        try await withLog { log, dir, _ in
            log.record(.summon)
            log.record(.contextPacket, duration: .milliseconds(12), lane: .quick, outcome: .ok, count: 3)
            await log.flush()
            #expect(files(dir) == ["trace-2026-10-14.log"])
            let l = try lines(dir, "trace-2026-10-14.log")
            #expect(l.count == 2)
            #expect(l[0].hasSuffix("\tsummon"))
            #expect(l[1].hasSuffix("\tcontextPacket\tms=12.0\tlane=quick\toutcome=ok\tcount=3"))
            #expect(l[1].hasPrefix("2026-10-14T12:00:00"))
        }
    }

    @Test("a span records its event with the elapsed time")
    func span() async throws {
        try await withLog { log, dir, _ in
            let span = log.begin(.firstSpokenWord)
            try await Task.sleep(for: .milliseconds(20))
            log.end(span, lane: .quick)
            await log.flush()
            let line = try #require(try lines(dir, "trace-2026-10-14.log").first)
            let ms = Double(line.split(separator: "\t")[2].dropFirst(3)) ?? 0
            #expect(ms >= 15 && ms < 2_000)
        }
    }

    @Test("disabled records nothing and creates no files; enabling starts logging")
    func disabled() async throws {
        try await withLog(enabled: false) { log, dir, _ in
            log.record(.summon)
            await log.flush()
            #expect(files(dir).isEmpty)
            log.setEnabled(true)
            log.record(.summon)
            await log.flush()
            #expect(files(dir) == ["trace-2026-10-14.log"])
        }
    }

    @Test("a new day starts a new file; files older than 7 days are deleted")
    func rotation() async throws {
        try await withLog { log, dir, now in
            for _ in 0..<9 {
                log.record(.summon)
                await log.flush()
                now.advance(days: 1)
            }
            log.record(.summon)
            await log.flush()
            // Day 10 (Oct 23) is written: keeps Oct 17…23.
            #expect(files(dir) == (17...23).map { "trace-2026-10-\($0).log" })
        }
    }

    @Test("files are readable by the user only; deleteAll removes them")
    func permissionsAndDelete() async throws {
        try await withLog { log, dir, _ in
            log.record(.summon)
            await log.flush()
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "trace-2026-10-14.log").path)
            #expect((attrs[.posixPermissions] as? Int) == 0o600)
            #expect((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700)
            try FileManager.default.createDirectory(at: dir.appending(path: "keep"), withIntermediateDirectories: true)
            await log.deleteAll()
            #expect(files(dir) == ["keep"])
        }
    }

    @Test("a folder and file that already exist with loose permissions are made user-only")
    func tightensPermissions() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = dir.appending(path: "trace-2026-10-14.log")
        FileManager.default.createFile(atPath: file.path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644])
        let log = TraceLog(directory: dir, enabled: true, now: { Self.start }, calendar: Self.utc)
        log.record(.summon)
        await log.flush()
        #expect((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try lines(dir, "trace-2026-10-14.log").count == 2)  // appended, not truncated
    }

    @Test("days follow the local calendar across a DST change")
    func dst() async throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let dir = FileManager.default.temporaryDirectory.appending(path: "trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 23:30 EDT on Oct 31, then 23:30 EST on Nov 1: 25 hours apart, one day each.
        let now = TestNow(Date(timeIntervalSince1970: 1_793_503_800))
        let log = TraceLog(directory: dir, enabled: true, now: { now.value.withLock { $0 } }, calendar: newYork)
        log.record(.summon)
        now.value.withLock { $0 = Date(timeIntervalSince1970: 1_793_593_800) }
        log.record(.summon)
        await log.flush()
        #expect(files(dir) == ["trace-2026-10-31.log", "trace-2026-11-01.log"])
    }

    @Test("old files are pruned at creation and when switched off, even while disabled")
    func retentionWhileDisabled() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for day in ["2026-10-01", "2026-10-08", "2026-10-09"] {
            FileManager.default.createFile(atPath: dir.appending(path: "trace-\(day).log").path, contents: nil)
        }
        let now = TestNow(Self.start)  // Oct 14: keeps Oct 8…14
        let log = TraceLog(directory: dir, enabled: false, now: { now.value.withLock { $0 } }, calendar: Self.utc)
        await log.flush()
        #expect(files(dir) == ["trace-2026-10-08.log", "trace-2026-10-09.log"])
        log.setEnabled(true)
        now.advance(days: 1)
        log.setEnabled(false)
        await log.flush()
        #expect(files(dir) == ["trace-2026-10-09.log"])
    }

    @Test("flush and deleteAll return even behind a full backlog of entries")
    func backlog() async throws {
        try await withLog { log, dir, _ in
            for _ in 0..<(TraceLog.maxPending * 2) { log.record(.summon) }
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await log.deleteAll(); return true }
                group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
                #expect(await group.next() == true)
                group.cancelAll()
            }
            await log.flush()
            #expect(files(dir).isEmpty)
            log.record(.summon)
            await log.flush()
            let after = try lines(dir, "trace-2026-10-14.log")
            #expect(after.count == 1)
        }
    }

    @Test("every event kind has a stable name")
    func names() {
        #expect(Set(TraceEvent.allCases.map(\.rawValue)).count == TraceEvent.allCases.count)
    }
}
