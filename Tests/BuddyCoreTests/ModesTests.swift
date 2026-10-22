import Testing
@testable import BuddyCore

struct ModesTests {
    @Test func defaultsPerMode() {
        #expect(ModeConfig.default(for: .quick) == ModeConfig(model: .haiku, effort: .low))
        #expect(ModeConfig.default(for: .deep) == ModeConfig(model: .opus, effort: .high))
        #expect(ModeConfig.default(for: .research) == ModeConfig(model: .opus, effort: .max))
    }

    @Test(arguments: Mode.allCases)
    func defaultEffortIsOffered(mode: Mode) {
        #expect(mode.allowedEfforts.contains(ModeConfig.default(for: mode).effort))
    }

    @Test func customModelShowsRawID() {
        #expect(ModelID(rawValue: "claude-sonnet-5-5-preview").displayName == "claude-sonnet-5-5-preview")
        #expect(ModelID.opus.displayName == "Opus 5.5")
    }

    @Test func conversationColoursRotate() {
        #expect((0..<6).map(ConversationColor.forIndex) == [.ember, .mist, .sage, .amber, .ember, .mist])
        #expect(ConversationColor.forIndex(-1) == .amber)
    }
}
