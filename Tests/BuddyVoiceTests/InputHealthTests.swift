import Testing
@testable import BuddyVoice

/// 20 ms of 16 kHz audio.
private let zeros = [Float](repeating: 0, count: 320)
private let signal = [Float](repeating: 0.01, count: 320)

private func feed(_ health: inout InputHealth, _ chunk: [Float], seconds: Double, granted: Bool = true) -> [MicProblem] {
    var problems: [MicProblem] = []
    for _ in 0..<Int((seconds / 0.02).rounded()) {
        if let p = health.observe(chunk, permissionGranted: { granted }) { problems.append(p) }
    }
    return problems
}

@Test func zerosDuringWarmUpAreIgnored() {
    var health = InputHealth(warmUpGrace: 0.3, zeroLimit: 1.0)
    // VP gives ~160 ms of zeros after a start; then real audio.
    #expect(feed(&health, zeros, seconds: 0.3).isEmpty)
    #expect(feed(&health, signal, seconds: 2).isEmpty)
}

@Test func oneSecondOfZerosWithPermissionIsSilentInput() {
    var health = InputHealth(warmUpGrace: 0.3, zeroLimit: 1.0)
    #expect(feed(&health, zeros, seconds: 1.2).isEmpty)       // 0.3 grace + 0.9 counted
    #expect(feed(&health, zeros, seconds: 0.2) == [.silentInput])
}

@Test func zerosWithoutPermissionArePermissionDenied() {
    var health = InputHealth()
    #expect(feed(&health, zeros, seconds: 1.5, granted: false) == [.permissionDenied])
}

@Test func revokedMidCaptureIsReportedOnce() {
    var health = InputHealth()
    #expect(feed(&health, signal, seconds: 1).isEmpty)
    #expect(feed(&health, zeros, seconds: 5, granted: false) == [.permissionDenied])
    #expect(feed(&health, signal, seconds: 0.5).isEmpty)
    #expect(feed(&health, zeros, seconds: 2, granted: false).isEmpty)   // once per start
}

@Test func signalResetsTheZeroRun() {
    var health = InputHealth()
    _ = feed(&health, signal, seconds: 0.5)
    for _ in 0..<5 {
        #expect(feed(&health, zeros, seconds: 0.8).isEmpty)
        #expect(feed(&health, signal, seconds: 0.02).isEmpty)
    }
}

@Test func resetAllowsANewReportAndRebuildRestartsGrace() {
    var health = InputHealth()
    #expect(feed(&health, zeros, seconds: 1.5) == [.silentInput])
    health.reset()
    #expect(feed(&health, zeros, seconds: 1.5) == [.silentInput])

    var rebuilt = InputHealth()
    _ = feed(&rebuilt, signal, seconds: 1)
    #expect(feed(&rebuilt, zeros, seconds: 0.9).isEmpty)
    rebuilt.restartGrace()
    // The new engine's warm-up zeros don't count toward the run from before the rebuild.
    #expect(feed(&rebuilt, zeros, seconds: 1.2).isEmpty)
}
