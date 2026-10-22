import Foundation
import Testing
@testable import BuddyConversations

@Suite("ClaudeSessionFiles")
struct SessionFilesTests {
    let id = UUID().uuidString.lowercased()
    let other = UUID().uuidString.lowercased()

    /// root/.claude mimicking Claude Code's layout for `id` and `other`.
    func layout(_ dir: URL) throws -> URL {
        let root = dir.appending(path: "claude", directoryHint: .isDirectory)
        try makeFile(root.appending(path: "projects/-a-b/\(id).jsonl"))
        try makeFile(root.appending(path: "projects/-a-b/\(id)/subagents/x"))
        try makeFile(root.appending(path: "projects/-c/\(other).jsonl"))
        try makeFile(root.appending(path: "projects/-c/\(other)/subagents/y"))
        try makeFile(root.appending(path: "session-env/\(id)/env"))
        try makeFile(root.appending(path: "session-env/\(other)/env"))
        try makeFile(root.appending(path: "file-history/\(id)/f1"))
        try makeFile(root.appending(path: "file-history/\(other)/f1"))
        try makeFile(root.appending(path: "projects/stray.jsonl"))
        return root
    }

    @Test("removes every file for the session and nothing else")
    func deletesSession() async throws {
        try await withTempDir { dir in
            let root = try layout(dir)
            let result = ClaudeSessionFiles(root: root).deleteSessions([id])
            #expect(result.missing.isEmpty)
            #expect(result.skipped.isEmpty)
            #expect(result.deleted.count == 4)
            #expect(!exists(root.appending(path: "projects/-a-b/\(id).jsonl")))
            #expect(!exists(root.appending(path: "projects/-a-b/\(id)")))
            #expect(!exists(root.appending(path: "session-env/\(id)")))
            #expect(!exists(root.appending(path: "file-history/\(id)")))
            #expect(exists(root.appending(path: "projects/-a-b")))
            #expect(exists(root.appending(path: "projects/-c/\(other).jsonl")))
            #expect(exists(root.appending(path: "projects/-c/\(other)/subagents/y")))
            #expect(exists(root.appending(path: "session-env/\(other)/env")))
            #expect(exists(root.appending(path: "file-history/\(other)/f1")))
            #expect(exists(root.appending(path: "projects/stray.jsonl")))
        }
    }

    @Test("an id with no files is reported missing")
    func missing() async throws {
        try await withTempDir { dir in
            let root = try layout(dir)
            let before = tree(root)
            let absent = UUID().uuidString.lowercased()
            let result = ClaudeSessionFiles(root: root).deleteSessions([absent])
            #expect(result == SessionDeletion(missing: [absent]))
            #expect(tree(root) == before)
        }
    }

    @Test("a root without projects reports missing")
    func emptyRoot() async throws {
        try await withTempDir { dir in
            let result = ClaudeSessionFiles(root: dir.appending(path: "nothing")).deleteSessions([id])
            #expect(result == SessionDeletion(missing: [id]))
        }
    }

    @Test("ids that aren't plain UUIDs are skipped and nothing is deleted", arguments: [
        "../x", "*", "", "a/b", "..", "../../claude", "\(UUID().uuidString)/..", "stray",
    ])
    func refusesNonUUID(bad: String) async throws {
        try await withTempDir { dir in
            let root = try layout(dir)
            try makeFile(dir.appending(path: "x.jsonl"))
            try makeFile(root.appending(path: "projects/x.jsonl"))
            let beforeRoot = tree(root), beforeDir = tree(dir)
            let result = ClaudeSessionFiles(root: root).deleteSessions([bad])
            #expect(result == SessionDeletion(skipped: [bad]))
            #expect(tree(root) == beforeRoot)
            #expect(tree(dir) == beforeDir)
        }
    }

    @Test("a symlinked transcript pointing outside root is skipped and its target kept")
    func symlinkOutside() async throws {
        try await withTempDir { dir in
            let root = try layout(dir)
            let target = try makeFile(dir.appending(path: "outside/precious.jsonl"), "keep")
            let link = root.appending(path: "projects/-c/\(id).jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let result = ClaudeSessionFiles(root: root).deleteSessions([id])
            #expect(result.skipped.contains { $0.hasSuffix("projects/-c/\(id).jsonl") })
            #expect(!result.deleted.contains { $0.hasSuffix("projects/-c/\(id).jsonl") })
            #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
            // The real files for the session still go.
            #expect(!exists(root.appending(path: "projects/-a-b/\(id).jsonl")))
            #expect(result.deleted.count == 4)
        }
    }

    @Test("a symlinked session directory pointing inside root is still skipped")
    func symlinkInside() async throws {
        try await withTempDir { dir in
            let root = dir.appending(path: "claude", directoryHint: .isDirectory)
            let target = root.appending(path: "session-env/\(other)", directoryHint: .isDirectory)
            try makeFile(target.appending(path: "env"))
            try FileManager.default.createDirectory(at: root.appending(path: "file-history"), withIntermediateDirectories: true)
            let link = root.appending(path: "file-history/\(id)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let result = ClaudeSessionFiles(root: root).deleteSessions([id])
            #expect(result.deleted.isEmpty)
            #expect(result.skipped.count == 1)
            #expect(exists(target.appending(path: "env")))
        }
    }

    @Test("a file where a directory is expected, or a directory where a file is, is skipped")
    func wrongKind() async throws {
        try await withTempDir { dir in
            let root = dir.appending(path: "claude", directoryHint: .isDirectory)
            let envFile = try makeFile(root.appending(path: "session-env/\(id)"))
            let projectFile = try makeFile(root.appending(path: "projects/-a-b/\(id)"))
            let transcriptDir = root.appending(path: "projects/-c/\(id).jsonl", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
            let result = ClaudeSessionFiles(root: root).deleteSessions([id])
            #expect(result.deleted.isEmpty)
            #expect(result.missing.isEmpty)
            #expect(result.skipped.count == 3)
            #expect(exists(envFile))
            #expect(exists(projectFile))
            #expect(exists(transcriptDir))
        }
    }

    @Test("several ids in one call are each handled")
    func several() async throws {
        try await withTempDir { dir in
            let root = try layout(dir)
            let absent = UUID().uuidString.lowercased()
            let result = ClaudeSessionFiles(root: root).deleteSessions([id, "*", absent, other])
            #expect(result.missing == [absent])
            #expect(result.skipped == ["*"])
            #expect(result.deleted.count == 8)
            #expect(tree(root.appending(path: "session-env")).isEmpty)
            #expect(exists(root.appending(path: "projects/stray.jsonl")))
        }
    }
}
