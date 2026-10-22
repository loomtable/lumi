import Darwin
import Foundation

/// Whether the Mac is short of memory or hot, so optional work (later warm-ups) should wait for
/// another time. Both are read when asked: the kernel's current memory-pressure level
/// (`kern.memorystatus_vm_pressure_level`: 1 normal, higher for warning and critical) and
/// `ProcessInfo.thermalState`.
public final class SystemPressure: Sendable {
    public static let shared = SystemPressure()

    private init() {}

    /// Memory pressure above normal, or thermal state serious or critical.
    public var isHigh: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return Self.memoryPressureLevel() > 1 || thermal == .serious || thermal == .critical
    }

    /// The kernel's level now; 1 (normal) if it can't be read.
    static func memoryPressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return level
    }
}

/// Runs optional warm-up steps one at a time at `.utility` priority, starting after `delay`. Before
/// each, it waits (checking every `poll`, for at most `giveUpAfter` in all) until `isQuiet()`, then runs
/// it unless `skip()` (memory pressure, heat). A step that's skipped or never gets a quiet moment is dropped: the first real use
/// pays it instead, as before warm-ups existed.
enum IdleWarmUp {
    @discardableResult
    static func schedule(
        _ steps: [@Sendable () async -> Void], after delay: Duration, poll: Duration = .seconds(1),
        giveUpAfter: Duration = .seconds(600),
        isQuiet: @escaping @Sendable () async -> Bool, skip: @escaping @Sendable () async -> Bool = { false }
    ) -> Task<Int, Never> {
        Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            try? await Task.sleep(for: delay)
            var ran = 0
            for step in steps {
                while await !isQuiet() {
                    guard !Task.isCancelled, ContinuousClock.now - start < giveUpAfter else { return ran }
                    try? await Task.sleep(for: poll)
                }
                guard !Task.isCancelled else { return ran }
                guard await !skip() else { return ran }
                await step()
                ran += 1
            }
            return ran
        }
    }
}
