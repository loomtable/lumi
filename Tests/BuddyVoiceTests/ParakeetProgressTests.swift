import Dispatch
import FluidAudio
import Synchronization
import Testing
@testable import BuddyVoice

struct ParakeetProgressTests {
    /// FluidAudio calls the progress handler on its download queue (runtime isolation rule):
    /// call it off the main thread and check every phase maps across.
    @Test func progressHandlerRunsOffMainAndMapsEveryPhase() async {
        let received = Mutex<[ModelLoadProgress]>([])
        let handler = ParakeetTranscriber.progressHandler { p in received.withLock { $0.append(p) } }
        let inputs = [
            DownloadProgress(fractionCompleted: 0.0, phase: .listing),
            DownloadProgress(fractionCompleted: 0.5, phase: .downloading(completedFiles: 3, totalFiles: 6)),
            DownloadProgress(fractionCompleted: 0.95, phase: .compiling(modelName: "Encoder")),
        ]
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                for p in inputs { handler(p) }
                done.resume()
            }
        }
        #expect(received.withLock { $0 } == [
            ModelLoadProgress(fraction: 0.0, phase: .listing),
            ModelLoadProgress(fraction: 0.5, phase: .downloading(completedFiles: 3, totalFiles: 6)),
            ModelLoadProgress(fraction: 0.95, phase: .compiling),
        ])
    }
}
