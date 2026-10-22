import Foundation

/// Progress for a download that reports none (FluidAudio's Kokoro v3 fetches each file whole), read
/// from the bytes on disk in its folders against the size of a full install. It moves as each file
/// lands. The total file count isn't known ahead, so the phase carries the files so far and 0.
struct DiskProgress: Sendable {
    let folders: [URL]
    let expectedBytes: Int64
    var interval: Duration = .milliseconds(500)

    /// Regular files and their bytes under `folders` now.
    func onDisk() -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for folder in folders {
            guard let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }

    /// Reports until cancelled, only while something is missing: an install that's already complete
    /// loads without a download bar. Never reports 1, which is the load finishing.
    func watch(_ report: @escaping @Sendable (ModelLoadProgress) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var last: Int64 = -1
            while !Task.isCancelled {
                let now = onDisk()
                if last < 0, now.bytes >= expectedBytes * 95 / 100 { return }
                if now.bytes != last {
                    last = now.bytes
                    let fraction = min(Double(now.bytes) / Double(max(expectedBytes, 1)), 0.99)
                    report(ModelLoadProgress(fraction: fraction, phase: .downloading(completedFiles: now.files, totalFiles: 0)))
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
