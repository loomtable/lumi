import Foundation
import SQLite3
import Synchronization
import Testing
@testable import BuddyConversations

let t0 = Date(timeIntervalSince1970: 1_760_000_000)

/// A fresh directory under the system temp folder, removed when `body` returns or throws.
func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "BuddyConversationsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

/// Deterministic conversation IDs: c1, c2, …
final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> String { value.withLock { $0 += 1; return "c\($0)" } }
}

/// Reads the first column of the first row of `sql` from the SQLite file at `url`, outside
/// the actor, to check what is actually on disk.
func rawScalar(_ url: URL, _ sql: String) -> String? {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
        sqlite3_close(handle)
        return nil
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let s = statement else { return nil }
    defer { sqlite3_finalize(s) }
    guard sqlite3_step(s) == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { return nil }
    return String(cString: text)
}

@discardableResult
func makeFile(_ url: URL, _ contents: String = "x") throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Every path under `dir` (relative, sorted), symlinks not followed.
func tree(_ dir: URL) -> [String] {
    (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).sorted()
}
