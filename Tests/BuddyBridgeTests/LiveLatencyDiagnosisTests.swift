import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

/// Where a Quick turn's time goes, from the raw stream-json: start-up, the first API response
/// and its first block (thinking, text or tool use), tool calls before the answer, thinking,
/// the first text to the first complete `say` sentence, and input tokens with cache use. Each
/// variant drops one piece of the app's Quick launch, down to a bare baseline, so the piece that
/// costs the time shows. Every turn runs in a process that has idled first, like the app's spare.
/// Spends your Claude plan (Haiku, stops before $0.18). Run once, when asked:
///   BUDDYBRIDGE_LATENCY_DIAG=1 BUDDYBRIDGE_LATENCY_SCREENS=/tmp/sb-screens \
///     [BUDDYBRIDGE_LATENCY_DIAG_VARIANTS=full,noMCP] [BUDDYBRIDGE_LATENCY_DIAG_SET=core|everyday|all] \
///     [BUDDYBRIDGE_LATENCY_DIAG_COUNT=10] \
///     [BUDDYBRIDGE_LATENCY_OUT=diag.json] Scripts/test.sh --filter LiveLatencyDiagnosis
/// The JSON keeps each answer's text, so answers can be graded against the scenario's expectations.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUDDYBRIDGE_LATENCY_DIAG"] == "1"), .serialized)
struct LiveLatencyDiagnosisTests {
    static let environment = ProcessInfo.processInfo.environment
    /// The benchmark's 10 questions (`core`), the 10 everyday ones, or `all` 20; the first 5 of
    /// the set by default, `BUDDYBRIDGE_LATENCY_DIAG_COUNT` for more.
    static let ids: [String] = {
        let set = switch environment["BUDDYBRIDGE_LATENCY_DIAG_SET"] {
        case "everyday": LiveLatencyBenchmarkTests.everydayIDs
        case "all": LiveLatencyBenchmarkTests.ids + LiveLatencyBenchmarkTests.everydayIDs
        default: LiveLatencyBenchmarkTests.ids
        }
        return Array(set.prefix(environment["BUDDYBRIDGE_LATENCY_DIAG_COUNT"].flatMap(Int.init) ?? 5))
    }()
    /// Every variant except `noThinking` by default; `BUDDYBRIDGE_LATENCY_DIAG_VARIANTS` picks.
    static let variants: [Variant] = environment["BUDDYBRIDGE_LATENCY_DIAG_VARIANTS"].map {
        $0.split(separator: ",").compactMap { Variant(rawValue: String($0)) }
    } ?? Variant.allCases.filter { ![.noThinking, .noThinkingSettings].contains($0) }
    static let budgetUSD = 0.18
    /// Long enough for start-up (plugins, MCP servers, hooks) to finish before the question.
    static let idle: Duration = .seconds(6)

    enum Variant: String, CaseIterable, Codable {
        /// Exactly the app's Quick launch, with the screenshot.
        case full
        /// The app's launch asking for no thinking (`MAX_THINKING_TOKENS=0`). Haiku 5.5 ignores it:
        /// the 5.5 models always use adaptive reasoning (verified Oct 15, Claude Code 2.1.300).
        /// Kept to check a future Quick model; opt-in only.
        case noThinking
        /// The same request through settings (`alwaysThinkingEnabled: false`); also ignored by
        /// Haiku 5.5.
        case noThinkingSettings
        /// No MCP servers (`--strict-mcp-config` with none).
        case noMCP
        /// No MCP, and no user settings: no user hooks, no user-enabled plugins.
        case isolated
        /// The app's launch without the screenshot.
        case noImage
        /// Bare `claude`: no buddy plugin, agent or rules, isolated, no screenshot. Same model and effort.
        case baseline
    }

    struct Turn: Codable {
        var id: String
        var variant: Variant
        /// Seconds from sending the question.
        var initAt: Double?
        var firstAPIResponse: Double?   // message_start
        var firstBlock: Double?
        var firstBlockKind: String?
        var thinkingStart: Double?
        var thinkingEnd: Double?
        var thinkingChars = 0
        var firstText: Double?
        var sayFirstSentence: Double?
        var result: Double?
        var apiCalls = 0
        var tools: [String] = []
        var inputTokens = 0
        var cacheRead = 0
        var cacheCreation = 0
        var outputTokens = 0
        var costUSD = 0.0
        var apiMS: Double?
        var mcpServers: [String] = []
        var toolCount = 0
        /// The model `system/init` reports, to confirm which one ran.
        var model: String?
        var error: String?
        /// Everything the model wrote, for grading.
        var answer = ""
    }

    static func spec(_ variant: Variant, folder: URL) async throws -> LaunchSpec {
        var spec = try await LiveLatencyBenchmarkTests.spec(folder: folder)
        switch variant {
        case .full, .noImage: break
        case .noThinking: spec.environment["MAX_THINKING_TOKENS"] = "0"
        case .noThinkingSettings: spec.settings = #"{"alwaysThinkingEnabled": false}"#
        case .noMCP: spec.strictMCPConfig = true
        case .isolated:
            spec.strictMCPConfig = true
            spec.settingSources = "project,local"
        case .baseline:
            spec.strictMCPConfig = true
            spec.settingSources = "project,local"
            spec.pluginDirectory = nil
            spec.agent = nil
            spec.appendSystemPromptFile = nil
        }
        return spec
    }

    /// Lines from the child's stdout, each stamped when it arrived.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var lines: [(Duration, Data)] = []
        let clock = ContinuousClock()
        let start: ContinuousClock.Instant

        init() { start = clock.now }

        func append(_ data: Data) {
            let t = clock.now - start
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append((t, buffer[buffer.startIndex..<nl]))
                buffer = buffer[buffer.index(after: nl)...]
            }
        }

        var snapshot: [(Duration, Data)] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    static func run(_ variant: Variant, id: String, packet: ContextPacket, image: TurnInput.Image,
                    folder: URL) async throws -> Turn {
        let spec = try await spec(variant, folder: folder)
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.workingDirectory
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let lines = Lines()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { lines.append(data) }
        }
        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        try await Task.sleep(for: idle)

        let images = variant == .noImage || variant == .baseline ? [] : [image]
        let sentAt = lines.clock.now - lines.start
        try stdin.fileHandleForWriting.write(contentsOf: TurnInput(text: BuddyPrompt.quick(packet), images: images).streamJSONLine)

        var turn = Turn(id: id, variant: variant)
        let deadline = lines.clock.now + .seconds(60)
        var seen = 0
        var text = ""
        func at(_ d: Duration) -> Double { LiveLatencyBenchmarkTests.seconds(d - sentAt) }
        while lines.clock.now < deadline, turn.result == nil {
            let all = lines.snapshot
            for (time, data) in all[seen...] {
                guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let t = at(time)
                switch o["type"] as? String {
                case "system" where o["subtype"] as? String == "init":
                    turn.initAt = turn.initAt ?? t
                    turn.mcpServers = (o["mcp_servers"] as? [[String: Any]] ?? []).map {
                        "\($0["name"] as? String ?? "?"):\($0["status"] as? String ?? "?")"
                    }
                    turn.toolCount = (o["tools"] as? [Any])?.count ?? 0
                    turn.model = o["model"] as? String
                case "stream_event":
                    let e = o["event"] as? [String: Any] ?? [:]
                    switch e["type"] as? String {
                    case "message_start":
                        turn.apiCalls += 1
                        turn.firstAPIResponse = turn.firstAPIResponse ?? t
                    case "content_block_start":
                        let block = e["content_block"] as? [String: Any] ?? [:]
                        let kind = block["type"] as? String ?? "?"
                        if turn.firstBlock == nil { turn.firstBlock = t; turn.firstBlockKind = kind }
                        if kind == "thinking" || kind == "redacted_thinking" { turn.thinkingStart = turn.thinkingStart ?? t }
                    case "content_block_delta":
                        let delta = e["delta"] as? [String: Any] ?? [:]
                        switch delta["type"] as? String {
                        case "thinking_delta":
                            turn.thinkingChars += (delta["thinking"] as? String)?.count ?? 0
                            turn.thinkingEnd = t
                        case "text_delta":
                            turn.firstText = turn.firstText ?? t
                            text += delta["text"] as? String ?? ""
                            if turn.sayFirstSentence == nil, Self.hasFirstSaySentence(text) { turn.sayFirstSentence = t }
                        default: break
                        }
                    default: break
                    }
                case "assistant":
                    let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    turn.tools += content.filter { $0["type"] as? String == "tool_use" }.map { $0["name"] as? String ?? "?" }
                case "result":
                    turn.result = t
                    let usage = o["usage"] as? [String: Any] ?? [:]
                    turn.inputTokens = usage["input_tokens"] as? Int ?? 0
                    turn.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    turn.cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
                    turn.outputTokens = usage["output_tokens"] as? Int ?? 0
                    turn.costUSD = o["total_cost_usd"] as? Double ?? 0
                    turn.apiMS = o["duration_api_ms"] as? Double
                    if o["is_error"] as? Bool == true { turn.error = o["subtype"] as? String ?? "error" }
                default: break
                }
            }
            seen = all.count
            if turn.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        if turn.result == nil { turn.error = turn.error ?? "no result in 60 s" }
        turn.answer = text
        try? stdin.fileHandleForWriting.close()
        return turn
    }

    /// The `say` value has a complete first sentence (or has closed).
    static func hasFirstSaySentence(_ text: String) -> Bool {
        guard let key = text.range(of: #""say"\s*:\s*""#, options: .regularExpression) else { return false }
        let value = text[key.upperBound...]
        return value.range(of: #"[.!?](\s|")|(?<!\\)""#, options: .regularExpression) != nil
    }

    @Test func whereQuickTurnsSpendTheirTime() async throws {
        let screens = try #require(ProcessInfo.processInfo.environment["BUDDYBRIDGE_LATENCY_SCREENS"],
                                   "set BUDDYBRIDGE_LATENCY_SCREENS to the rendered screens folder")
        var turns: [Turn] = []
        var spent = 0.0
        outer: for id in Self.ids {
            let packet = try LiveLatencyBenchmarkTests.packet(id)
            let image = try LiveLatencyBenchmarkTests.screenshot(id, in: screens)
            for variant in Self.variants {
                guard spent < Self.budgetUSD else { print("budget reached at $\(spent): stopping"); break outer }
                let folder = FileManager.default.temporaryDirectory.appending(path: "sb-diag-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let turn = try await Self.run(variant, id: id, packet: packet, image: image, folder: folder)
                turns.append(turn)
                spent += turn.costUSD
                func f(_ v: Double?) -> String { v.map { String(format: "%5.2f", $0) } ?? "  -  " }
                print("\(id.padding(toLength: 34, withPad: " ", startingAt: 0)) \(variant.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))"
                      + " init \(f(turn.initAt)) api \(f(turn.firstAPIResponse)) block \(f(turn.firstBlock)) \(turn.firstBlockKind ?? "-")"
                      + " think \(f(turn.thinkingStart))→\(f(turn.thinkingEnd)) (\(turn.thinkingChars) ch)"
                      + " text \(f(turn.firstText)) say \(f(turn.sayFirstSentence)) done \(f(turn.result))"
                      + " calls \(turn.apiCalls) tools \(turn.tools) in \(turn.inputTokens)+r\(turn.cacheRead)+w\(turn.cacheCreation)"
                      + " out \(turn.outputTokens) $\(String(format: "%.4f", turn.costUSD)) \(turn.model ?? "?")"
                      + (turn.error.map { " ERROR \($0)" } ?? ""))
            }
        }
        if let first = turns.first(where: { $0.variant == .full }) {
            print("full launch: \(first.toolCount) tools; MCP servers \(first.mcpServers)")
        }
        if let first = turns.first(where: { $0.variant == .isolated }) {
            print("isolated launch: \(first.toolCount) tools; MCP servers \(first.mcpServers)")
        }
        print("\nvariant   n  init  api   block  say   done   (medians, seconds from send)  in+read+write tokens")
        for variant in Self.variants {
            let ok = turns.filter { $0.variant == variant && $0.error == nil }
            func m(_ k: KeyPath<Turn, Double?>) -> String {
                LiveLatencyBenchmarkTests.percentile(ok.compactMap { $0[keyPath: k] }, 0.5).map { String(format: "%5.2f", $0) } ?? "  -  "
            }
            let tokens = LiveLatencyBenchmarkTests.percentile(ok.map { Double($0.inputTokens + $0.cacheRead + $0.cacheCreation) }, 0.5) ?? 0
            print("\(variant.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) \(ok.count)  \(m(\.initAt)) \(m(\.firstAPIResponse)) \(m(\.firstBlock)) \(m(\.sayFirstSentence)) \(m(\.result))  \(Int(tokens))")
        }
        print(String(format: "total $%.4f over %d turns", spent, turns.count))
        if let out = ProcessInfo.processInfo.environment["BUDDYBRIDGE_LATENCY_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(turns).write(to: URL(fileURLWithPath: out))
        }
        #expect(spent < 0.20, "stayed under the $0.20 run budget")
    }
}
