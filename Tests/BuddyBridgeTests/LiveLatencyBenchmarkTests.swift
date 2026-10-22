import BuddyCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BuddyBridge

/// Quick-lane latency on 10 sample questions (M1 gate: first spoken word within 2.5 s, tracked,
/// not pass/fail). Real Haiku turns through `QuickLane`, no app or UI, using scenario packets and
/// their rendered screens. Three paths, measured from `ask` as the user feels it:
/// - warm: a new conversation on the booted spare (the app prewarms one at launch and after ⌘N);
/// - resume: a follow-up after an app relaunch, a fresh lane resuming the session (`--resume`);
/// - new: a new conversation with no spare ready (first 5 questions only, to bound cost).
/// Spends your Claude plan: stops before $0.18. Run once, when asked:
///   Tools/scenarios/pw Tools/scenarios/render.cjs screens Scenarios/cases /tmp/sb-screens
///   BUDDYBRIDGE_LATENCY=1 BUDDYBRIDGE_LATENCY_SCREENS=/tmp/sb-screens Scripts/test.sh --filter LiveLatencyBenchmark
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYBRIDGE_LATENCY"] == "1"), .serialized)
struct LiveLatencyBenchmarkTests {
    /// Eight apps, ten answer types.
    static let ids = [
        "browser-define-allele", "browser-summarise-council-pilot", "chat-draft-reply-oncall-cover",
        "chat-compute-offsite-split", "editor-run-single-test", "terminal-git-merge-conflict",
        "pdf-minutes-catch-up", "spreadsheet-mark-odd-months", "video-gradient-descent-overshoot",
        "finder-translate-file-names",
    ]
    /// Ten more of what the target users ask day to day: developers across terminal,
    /// editor and chat first, then dense content (a lecture diagram, a contract, a dashboard).
    static let everydayIDs = [
        "terminal-undo-last-commit", "terminal-define-detached-head", "editor-define-satisfies",
        "editor-summarise-migration", "editor-annotate-swift-risks", "chat-annotate-asks-for-me",
        "chat-rewrite-expense-reminder", "video-tcp-handshake-diagram", "pdf-contract-anything-risky",
        "spreadsheet-summarise-regional-sales",
    ]
    static let followUp = "and in one line?"
    static let budgetUSD = 0.18
    static let coldNewCount = 5

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Sample: Codable {
        var id: String
        var path: String
        var firstEvent: Double?
        var firstSentence: Double?
        var answer: Double?
        var costUSD: Double
        var handoff: Bool
        var error: String?
    }

    /// The Quick lane as the app launches it, in one scratch folder per question so a relaunched
    /// lane can resume the session (sessions are stored per folder).
    static func spec(folder: URL) async throws -> LaunchSpec {
        let home = NSHomeDirectory()
        var base = ProcessInfo.processInfo.environment
        for key in base.keys where key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE" { base[key] = nil }
        let loginPath = await LaunchEnvironment.loginShellPath(shell: base["SHELL"] ?? "/bin/zsh", home: home)
        let env = LaunchEnvironment.make(base: base, loginShellPath: loginPath, home: home)
        let claude = try #require(LaunchEnvironment.locateClaude(preferred: nil, path: env["PATH"] ?? "", home: home),
                                  "claude not found")
        return LaunchSpec.quick(executable: claude, home: folder, plugin: repo.appendingPathComponent("buddy-plugin"),
                                environment: env)
    }

    static func packet(_ id: String) throws -> ContextPacket {
        let url = repo.appendingPathComponent("Scenarios/cases/\(id)/scenario.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let json = try JSONSerialization.data(withJSONObject: try #require(root["packet"]))
        return try ContextPacket.makeDecoder().decode(ContextPacket.self, from: json)
    }

    /// The rendered screen as the app sends it: JPEG at quality 0.7, long edge 1280 (render.cjs
    /// already draws 1280 × 800).
    static func screenshot(_ id: String, in dir: String) throws -> TurnInput.Image {
        let png = URL(fileURLWithPath: dir).appendingPathComponent("\(id).png")
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil), "render the screens first: \(png.path)")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return TurnInput.Image(data: out as Data, mediaType: "image/jpeg")
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// One question, timed from `ask`: the first event the turn produces (process start-up
    /// excluded only in the sense that `initialized` and `reconnecting` don't count), the first
    /// spoken sentence, and the finished answer.
    static func run(_ lane: QuickLane, id: String, path: String, conversation: String, resume: String?,
                    input: TurnInput) async -> (Sample, sessionID: String?) {
        let clock = ContinuousClock()
        let start = clock.now
        var sample = Sample(id: id, path: path, costUSD: 0, handoff: false)
        var session: String?
        for await event in await lane.ask(conversation: conversation, resumeSessionID: resume, input: input) {
            let t = seconds(clock.now - start)
            switch event {
            case .initialized, .reconnecting: break
            case .sayFirstSentence:
                sample.firstEvent = sample.firstEvent ?? t
                sample.firstSentence = sample.firstSentence ?? t
            case .finished(let outcome):
                sample.firstEvent = sample.firstEvent ?? t
                sample.answer = t
                sample.costUSD = outcome.result.costUSD ?? 0
                sample.handoff = outcome.extraction.block?.handoff != nil
                session = outcome.result.sessionID.isEmpty ? nil : outcome.result.sessionID
            case .failed(let error):
                sample.error = String(describing: error)
            default:
                sample.firstEvent = sample.firstEvent ?? t
            }
        }
        return (sample, session)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        // Nearest rank: with 10 samples, p95 is the slowest.
        return sorted[min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
    }

    @Test func quickLatencyOnTenSampleQuestions() async throws {
        let screens = try #require(ProcessInfo.processInfo.environment["BUDDYBRIDGE_LATENCY_SCREENS"],
                                   "set BUDDYBRIDGE_LATENCY_SCREENS to the rendered screens folder")
        var samples: [Sample] = []
        var spent = 0.0
        func record(_ s: Sample) {
            samples.append(s)
            spent += s.costUSD
            print(String(format: "%-36@ %-6@ first %5.2fs  say %5.2fs  answer %5.2fs  $%.4f%@%@", s.id as NSString,
                         s.path as NSString, s.firstEvent ?? -1, s.firstSentence ?? -1, s.answer ?? -1, s.costUSD,
                         (s.handoff ? "  handoff" : "") as NSString, (s.error.map { "  ERROR \($0)" } ?? "") as NSString))
        }

        for (index, id) in Self.ids.enumerated() {
            guard spent < Self.budgetUSD else { print("budget reached at $\(spent): stopping"); break }
            let folder = FileManager.default.temporaryDirectory.appending(path: "sb-latency-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let spec = try await Self.spec(folder: folder)
            let packet = try Self.packet(id)
            let image = try Self.screenshot(id, in: screens)
            let input = TurnInput(text: BuddyPrompt.quick(packet), images: [image])

            // Warm: the spare is booted before the question, as after app launch or ⌘N.
            let warmLane = QuickLane(spec: spec)
            await warmLane.prewarm()
            let (warm, session) = await Self.run(warmLane, id: id, path: "warm", conversation: "w\(index)",
                                                 resume: nil, input: input)
            record(warm)
            await warmLane.shutdown()

            // Resume: the app relaunched; the conversation's follow-up resumes its session cold.
            if let session, spent < Self.budgetUSD {
                var next = packet
                next.utterance = Self.followUp
                let lane = QuickLane(spec: spec)
                let (resumed, _) = await Self.run(lane, id: id, path: "resume", conversation: "w\(index)", resume: session,
                                                  input: TurnInput(text: BuddyPrompt.quick(next), images: [image]))
                record(resumed)
                await lane.shutdown()
            }

            // New, no spare: a question before the spare has booted.
            if index < Self.coldNewCount, spent < Self.budgetUSD {
                let lane = QuickLane(spec: spec)
                let (cold, _) = await Self.run(lane, id: id, path: "new", conversation: "n\(index)", resume: nil, input: input)
                record(cold)
                await lane.shutdown()
            }
        }

        print("\npath     n   first p50/p95     say p50/p95       answer p50/p95    (seconds from ask)")
        for path in ["warm", "resume", "new"] {
            let ok = samples.filter { $0.path == path && $0.error == nil }
            func pair(_ values: [Double]) -> String {
                String(format: "%5.2f / %5.2f", Self.percentile(values, 0.5) ?? -1, Self.percentile(values, 0.95) ?? -1)
            }
            print(String(format: "%-7@ %2d   %@   %@   %@", path as NSString, ok.count,
                         pair(ok.compactMap(\.firstEvent)) as NSString, pair(ok.compactMap(\.firstSentence)) as NSString,
                         pair(ok.compactMap(\.answer)) as NSString))
        }
        print(String(format: "total $%.4f over %d turns", spent, samples.count))
        if let out = ProcessInfo.processInfo.environment["BUDDYBRIDGE_LATENCY_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: URL(fileURLWithPath: out))
        }
        #expect(samples.allSatisfy { $0.error == nil }, "every turn answered")
        #expect(spent < 0.20, "stayed under the $0.20 run budget")
    }
}
