import Testing

/// Overlay tests drive real panels, and a process has one key window and one pointer, so two
/// overlays shown at once steal each other's focus. Every test in this target takes this lock,
/// so they run one at a time while the other targets still run in parallel. Controllers in
/// tests also ignore other apps (`observesSystem: false`).
nonisolated struct OverlayExclusive: TestTrait, TestScoping {
    @concurrent func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await OverlayLock.shared.acquire()
        do {
            try await function()
        } catch {
            await OverlayLock.shared.release()
            throw error
        }
        await OverlayLock.shared.release()
    }
}

extension Trait where Self == OverlayExclusive {
    static var overlayExclusive: Self { Self() }
}

/// A FIFO async lock.
actor OverlayLock {
    static let shared = OverlayLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
