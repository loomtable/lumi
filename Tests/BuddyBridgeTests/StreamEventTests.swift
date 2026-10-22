import Foundation
import Testing
@testable import BuddyBridge

struct StreamEventTests {
    @Test func everyFixtureLineParses() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Fixture.dir.path).filter { $0.hasSuffix(".jsonl") }
        #expect(names.count == 12)
        for name in names {
            let lines = try Fixture.lines(name)
            #expect(lines.compactMap(StreamEvent.init(line:)).count == lines.count, "\(name)")
        }
    }

    @Test func initCarriesModeModelAndSession() throws {
        let info = try #require(try Fixture.events("quick-text-partials.jsonl").compactMap {
            if case .initialized(let i) = $0 { i } else { nil }
        }.first)
        #expect(info.permissionMode == "auto")
        #expect(info.model == "claude-haiku-5-5")
        #expect(!info.sessionID.isEmpty)
        #expect(info.pluginErrors.isEmpty)
    }

    @Test func pluginErrorsAreParsed() throws {
        let info = try #require(try Fixture.events("init-plugin-errors.jsonl").compactMap {
            if case .initialized(let i) = $0 { i } else { nil }
        }.first)
        #expect(info.pluginErrors.map(\.type) == ["path-not-found"])
        #expect(info.plugins.contains("buddy-probe"))
    }

    @Test func unknownModelIsAnErrorThoughSubtypeSaysSuccess() throws {
        let result = try #require(try Fixture.events("error-unknown-model.jsonl").compactMap {
            if case .result(let r) = $0 { r } else { nil }
        }.first)
        #expect(result.subtype == "success")
        #expect(result.isError)
        #expect(result.terminalReason == "api_error")
        #expect(result.apiErrorStatus == 404)
    }

    @Test func toolUseKeepsStringInputs() throws {
        let tools = try Fixture.events("deep-tooluse-thinking-3turns.jsonl").flatMap { e -> [StreamEvent.ToolUse] in
            guard case .assistant(let blocks, _, _, _) = e else { return [] }
            return blocks.compactMap { if case .toolUse(let t) = $0 { t } else { nil } }
        }
        let bash = try #require(tools.first { $0.name == "Bash" })
        #expect(bash.input["description"] != nil)
        #expect(bash.input["command"] != nil)
    }

    @Test func rateLimitWindows() throws {
        let rl = try #require(try Fixture.events("quick-text-partials.jsonl").compactMap {
            if case .rateLimit(let r) = $0 { r } else { nil }
        }.first)
        #expect(rl.status == "allowed")
        #expect(Set(rl.windows.keys) == ["five_hour", "seven_day"])
        #expect(rl.resetsAt != nil)
    }

    @Test func initRepeatsEveryTurn() throws {
        let events = try Fixture.events("quick-multiturn-3.jsonl")
        #expect(events.filter { if case .initialized = $0 { true } else { false } }.count == 3)
    }

    @Test func apiRetryFields() {
        let line = Line.json(["type": "system", "subtype": "api_retry", "attempt": 2, "max_retries": 10,
                              "retry_delay_ms": 1200, "error_status": 529, "error": "overloaded"])
        #expect(StreamEvent(line: line) == .apiRetry(.init(attempt: 2, maxRetries: 10, retryDelayMS: 1200,
                                                           errorStatus: 529, error: "overloaded")))
    }

    @Test func unknownTypesDoNotFail() {
        #expect(StreamEvent(line: Line.json(["type": "brand_new"])) == .other(type: "brand_new"))
        #expect(StreamEvent(line: Line.json(["type": "system", "subtype": "x"])) == .system(subtype: "x"))
        #expect(StreamEvent(line: Data("not json".utf8)) == nil)
    }

    @Test func splitterFlushesTheLastLine() {
        var s = LineSplitter()
        #expect(s.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        #expect(s.append(Data(":2}".utf8)).isEmpty)
        #expect(s.finish() == Data("{\"b\":2}".utf8))
        #expect(s.finish() == nil)
    }
}
