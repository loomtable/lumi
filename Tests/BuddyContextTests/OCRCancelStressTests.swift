import CoreGraphics
import Foundation
import Synchronization
import Testing
import Vision
@testable import BuddyContext

/// Cancelling OCR mid-flight must never crash (Vision's TextRecognition segfaulted on a cancelled
/// in-flight `RecognizeTextRequest`). Summon, Esc and a new summon all cancel the summon OCR.
/// Opt-in for the long run: `BUDDYCONTEXT_OCR_STRESS=<rounds>`; a short run always goes.
@Suite("OCR cancel stress", .serialized)
struct OCRCancelStressTests {
    static let rounds = Int(ProcessInfo.processInfo.environment["BUDDYCONTEXT_OCR_STRESS"] ?? "") ?? 4

    static let shot: Screenshot = {
        var lines: [(String, CGPoint)] = []
        for row in 0..<22 {
            lines.append(("Row \(row): the quarterly totals and the regional growth figures for review", CGPoint(x: 20, y: 10 + Double(row) * 17)))
        }
        return OCRLocateTests.screenshot(lines: lines)
    }()

    @Test("recognize cancelled at random points, many at once")
    func cancelRecognize() async {
        for round in 0..<Self.rounds {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<4 {
                    group.addTask {
                        let task = Task { await OCRText.recognize(Self.shot, within: OCRLocateTests.display, level: .accurate) }
                        try? await Task.sleep(for: .milliseconds((round * 7 + i * 13) % 60))
                        task.cancel()
                        _ = await task.value
                    }
                }
            }
        }
    }

    @Test("prepare, locate and re-summon in quick succession")
    func summonCancelResummon() async {
        let locator = OCRLocateTests.locator(ocrWait: .milliseconds(30))
        for round in 0..<Self.rounds * 3 {
            await locator.prepare(Self.shot, pid: 1) // a summon starts OCR
            try? await Task.sleep(for: .milliseconds(round % 25))
            if round.isMultiple(of: 2) {
                await locator.prepare(Self.shot, pid: 1) // a new summon cancels it
            } else {
                _ = await locator.locate(["regional growth"], pid: 1, screenshot: Self.shot) // locate gives up at 30 ms
            }
        }
        // Still works afterwards. The wait is load-safe, not a speed check: OCR the rounds left
        // running goes first, and accurate OCR took over 5 s at load ~60.
        let slow = OCRLocateTests.locator(ocrWait: .seconds(30))
        await slow.prepare(Self.shot, pid: 1)
        #expect(await slow.locate(["quarterly totals"], pid: 1, screenshot: Self.shot).count == 1)
    }
}

/// The queue's own rules, with a fake perform (no Vision).
@Suite("OCR queue")
struct OCRQueueTests {
    /// Counts performs; each takes `delay` (forever when nil).
    final class Probe: Sendable {
        let started = Mutex(0)
        let delay: Duration?
        init(delay: Duration?) { self.delay = delay }

        var perform: OCRQueue.Perform {
            { [self] _, _ in
                started.withLock { $0 += 1 }
                if let delay { try? await Task.sleep(for: delay) } else { while true { try? await Task.sleep(for: .seconds(60)) } }
                return []
            }
        }
    }

    static let image: CGImage = OCRLocateTests.screenshot(lines: []).full

    @Test("a caller cancelled while waiting gets nil at once, and its perform never runs")
    func cancelledWhileQueued() async throws {
        let probe = Probe(delay: .milliseconds(400))
        let queue = OCRQueue(perform: probe.perform)
        let first = Task { await queue.recognize(Self.image, level: .accurate) }
        while probe.started.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(1)) }

        let second = Task { await queue.recognize(Self.image, level: .accurate) }
        try await Task.sleep(for: .milliseconds(20))
        let cancelledAt = ContinuousClock.now
        second.cancel()
        #expect(await second.value == nil)
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(150)) // didn't wait for the first

        #expect(await first.value?.isEmpty == true) // the first finishes normally
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.started.withLock { $0 } == 1) // the abandoned one never started
    }

    @Test("a hung perform stops holding the queue after the stuck limit")
    func hungPerform() async throws {
        let hung = Probe(delay: nil)
        let queue = OCRQueue(stuckLimit: .milliseconds(100), perform: hung.perform)
        _ = Task { await queue.recognize(Self.image, level: .accurate) } // never returns
        while hung.started.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(1)) }

        let next = Task { await queue.recognize(Self.image, level: .accurate) }
        // It can't return (the fake hangs too), but it starts once the limit passes.
        try await Task.sleep(for: .milliseconds(400))
        #expect(hung.started.withLock { $0 } == 2)
        next.cancel()
        #expect(await next.value == nil)
    }
}
