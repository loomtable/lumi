import Foundation
import Synchronization
import Testing
@testable import BuddyVoice

private func eventually(_ timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

struct DiskProgressTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DiskProgress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func reportsFilesAsTheyLandAndNeverOne() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let progress = DiskProgress(folders: [root, root.appending(path: "missing")], expectedBytes: 1000, interval: .milliseconds(10))
        let seen = Mutex<[ModelLoadProgress]>([])
        let watch = progress.watch { p in seen.withLock { $0.append(p) } }
        try Data(count: 400).write(to: root.appending(path: "a.bin"))
        #expect(await eventually { seen.withLock { $0.last?.fraction } == 0.4 })
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try Data(count: 700).write(to: root.appending(path: "sub/b.bin"))
        #expect(await eventually { seen.withLock { $0.last } == ModelLoadProgress(fraction: 0.99, phase: .downloading(completedFiles: 2, totalFiles: 0)) })
        watch.cancel()
        #expect(seen.withLock { $0.map(\.fraction) } == seen.withLock { $0.map(\.fraction) }.sorted())
    }

    @Test func aCompleteInstallReportsNothing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 1000).write(to: root.appending(path: "a.bin"))
        let seen = Mutex(0)
        let watch = DiskProgress(folders: [root], expectedBytes: 1000, interval: .milliseconds(10)).watch { _ in seen.withLock { $0 += 1 } }
        await watch.value
        #expect(seen.withLock { $0 } == 0)
    }
}
