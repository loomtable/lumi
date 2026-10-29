import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("TopicValidator")
struct TopicValidatorTests {
    let fallback = SessionTopic(title: "Q3 burn", symbol: "tablecells")

    @Test(arguments: [
        ("Q3 burn model", true), ("Fix login bug", true), ("Trip to Lisbon", true), ("Investor update draft", true),
        ("Lisbon", false), ("Plan the whole trip now", false), ("A very long title indeed here", false),
        ("Fix login bug.", false), ("\"Quoted title\"", false), ("Mail ana@example.com", false),
        ("Open https://x.com", false), ("Invoice 4412", false), ("Budget 2026 review", false),
    ])
    func titles(title: String, valid: Bool) {
        #expect(TopicValidator.isValidTitle(title) == valid)
    }

    /// U49: a title is shown as plain text (tiles, peek, notifications), so a model's
    /// Markdown loses its marks and keeps its words.
    @Test func markdownInATitleKeepsOnlyItsText() {
        #expect(TopicValidator.validate(SessionTopic(title: "**Munich** dining"), fallback: fallback).title == "Munich dining")
        #expect(TopicValidator.validate(SessionTopic(title: "Fix `login` bug"), fallback: fallback).title == "Fix login bug")
        #expect(TopicValidator.validate(SessionTopic(title: "# Trip planning"), fallback: fallback).title == "Trip planning")
        #expect(TopicValidator.validate(SessionTopic(title: "**Munich**"), fallback: fallback).title == "Q3 burn",
                "still checked after the marks go")
        #expect(LocalTopic.from(utterance: "fix the **login** crash", originBundleID: nil).title == "Fix login crash")
    }

    @Test func eachFieldFallsBackOnItsOwn() {
        #expect(TopicValidator.validate(SessionTopic(title: "Burn model", symbol: "chart.pie"), fallback: fallback)
                == SessionTopic(title: "Burn model", symbol: "chart.pie"))
        #expect(TopicValidator.validate(SessionTopic(title: "Burn", symbol: "chart.pie"), fallback: fallback)
                == SessionTopic(title: "Q3 burn", symbol: "chart.pie"))
        #expect(TopicValidator.validate(SessionTopic(title: "Burn model", symbol: "ant"), fallback: fallback)
                == SessionTopic(title: "Burn model", symbol: "tablecells"))
        #expect(TopicValidator.validate(SessionTopic(title: "Burn model", symbol: "chart.pie"), fallback: fallback,
                                        symbolExists: { _ in false }).symbol == "tablecells")
        #expect(TopicValidator.validate(nil, fallback: fallback) == fallback)
        #expect(TopicValidator.validate(SessionTopic(title: "  Burn   model "), fallback: fallback).title == "Burn model")
    }

    @Test func theAllowlistHasNoStatesAndNoAnimals() {
        for symbol in SymbolAllowlist.symbols {
            #expect(!symbol.hasPrefix("checkmark") && !symbol.hasPrefix("xmark") && !symbol.hasPrefix("exclamationmark")
                    && !symbol.hasPrefix("clock"))
        }
        for animal in ["ladybug", "ant", "tortoise", "hare", "bird", "fish", "pawprint", "lizard", "cat", "dog"] {
            #expect(!SymbolAllowlist.symbols.contains { $0.contains(animal) }, "\(animal)")
        }
    }
}

@Suite("LocalTopic")
struct LocalTopicTests {
    @Test(arguments: [
        ("hey lumi can you check the Q3 burn model in this sheet", "Check Q3 burn model"),
        ("What's wrong with the login flow?", "Wrong login flow"),
        ("why is this list empty", "List empty"),
        ("um", "New session"),
        ("summarise the investor update for alex@example.com please", "Summarise investor"),
    ])
    func titles(utterance: String, title: String) {
        let got = LocalTopic.from(utterance: utterance, originBundleID: nil).title
        #expect(got == title, "\(got)")
    }

    @Test func titlesStayWithinTheLimit() {
        let topic = LocalTopic.from(utterance: "internationalisation localisation documentation considerations", originBundleID: nil)
        #expect(topic.title.count <= TopicValidator.maxTitleLength)
        #expect(!topic.title.isEmpty)
    }

    @Test func symbolsComeFromAKeywordThenTheAppThenNothing() {
        #expect(LocalTopic.from(utterance: "book a flight to Lisbon", originBundleID: "com.apple.Safari").symbol == "airplane")
        #expect(LocalTopic.from(utterance: "why does this crash", originBundleID: nil).symbol == "hammer")
        #expect(LocalTopic.from(utterance: "what does this say", originBundleID: "com.apple.mail").symbol == "envelope")
        #expect(LocalTopic.from(utterance: "what does this say", originBundleID: "com.example.unknown").symbol == nil)
        for (_, symbol) in LocalTopic.apps { #expect(SymbolAllowlist.contains(symbol), "\(symbol)") }
        for entry in LocalTopic.keywords { #expect(SymbolAllowlist.contains(entry.symbol), "\(entry.symbol)") }
    }
}
