import BuddyCore
import Foundation
import Testing
@testable import BuddyBridge

struct BuddyBlockExtractionTests {
    @Test func takesTheLastBuddyFence() {
        let text = """
        Here is the answer.

        ```buddy
        {"say": "First.", "shape": "chip"}
        ```

        ```swift
        let x = 1
        ```

        ```buddy
        {"say": "Your filter drops last week.", "shape": "card", "card_html": "<p>x</p>"}
        ```
        """
        let e = BuddyBlockExtractor.extract(from: text)
        #expect(e.block?.say == "Your filter drops last week.")
        #expect(e.block?.shape == .card)
        #expect(e.prose.hasPrefix("Here is the answer."))
        #expect(e.prose.contains("```swift"))
        #expect(!e.prose.contains("last week"))
    }

    @Test func fallsBackToAJSONFenceThatDecodes() {
        let text = "x\n```json\n{\"unrelated\": 1}\n```\n```json\n{\"say\": \"Hi.\"}\n```"
        #expect(BuddyBlockExtractor.extract(from: text).block?.say == "Hi.")
    }

    @Test func noBlockKeepsTheText() {
        let e = BuddyBlockExtractor.extract(from: "  Just words.\n")
        #expect(e.block == nil)
        #expect(e.prose == "Just words.")
    }

    @Test func badBuddyJSONIsNil() {
        #expect(BuddyBlockExtractor.extract(from: "```buddy\n{\"shape\": \"chip\"}\n```").block == nil)
        #expect(BuddyBlockExtractor.extract(from: "```buddy\n{not json\n```").block == nil)
    }

    @Test func inlineTripleBackticksAreNotFences() {
        let text = "Use ``` for code.\n```buddy\n{\"say\": \"Ok.\"}\n```"
        #expect(BuddyBlockExtractor.extract(from: text).block?.say == "Ok.")
    }

    @Test func sayStreamsOutBeforeTheBlockEnds() {
        var s = SayStreamExtractor()
        let chunks = ["```bud", "dy\n{\n  \"sa", "y\": \"The rate is \\\"5", "%\\\" today", ".\", \"shape\": \"card\", \"card_html\": \"<div>"]
        var said: [SayStreamExtractor.Speech] = []
        for c in chunks { said += s.append(c) }
        #expect(said == [.firstSentence("The rate is \"5%\" today."), .complete("The rate is \"5%\" today.")])
        #expect(s.append("more\"}\n```").isEmpty)
    }

    @Test func theFirstSentenceComesOutBeforeSayEnds() {
        var s = SayStreamExtractor()
        #expect(s.append("```buddy\n{\"say\": \"It shrinks the Fed's bond holdings.").isEmpty, "needs the following space")
        #expect(s.append(" It drains") == [.firstSentence("It shrinks the Fed's bond holdings.")])
        #expect(s.append(" cash from markets.\", \"shape\"") == [.complete("It shrinks the Fed's bond holdings. It drains cash from markets.")])
    }

    @Test func shortAbbreviationsDontEndTheSentence() {
        var s = SayStreamExtractor()
        #expect(s.append("```buddy\n{\"say\": \"U.S. yields rose 6 basis points. Then").first == .firstSentence("U.S. yields rose 6 basis points."))
    }

    /// Streamed a few characters at a time, the first sentence follows the headline rules.
    @Test(arguments: [
        ("Ask Dr. Ortiz about the dosage today. She wrote the guideline.", "Ask Dr. Ortiz about the dosage today."),
        ("Use a fixture, e.g. the one in tests. Then run it again.", "Use a fixture, e.g. the one in tests."),
        ("The call is at 5 p.m. tomorrow in room four. Bring notes.", "The call is at 5 p.m. tomorrow in room four."),
        ("It now loads in 38 ms. The cache fixed it.", "It now loads in 38 ms."),
        ("Ask Ms. Lee about the budget sheet. She owns it.", "Ask Ms. Lee about the budget sheet."),
        ("It was written by J. R. R. Tolkien in 1954. Read it.", "It was written by J. R. R. Tolkien in 1954."),
        ("Go with Plan A. It is cheaper and faster.", "Go with Plan A."),
        ("Revenue hit 3.5 million in Q3. Up from 3.1 million.", "Revenue hit 3.5 million in Q3."),
    ])
    func streamedFirstSentenceFollowsTheHeadlineRules(say: String, first: String) {
        let json = "```buddy\n{\"say\": \"" + say + "\", \"shape\": \"card\"}\n```"
        var s = SayStreamExtractor()
        var said: [SayStreamExtractor.Speech] = []
        var rest = Substring(json)
        while !rest.isEmpty {
            said += s.append(String(rest.prefix(3)))
            rest = rest.dropFirst(3)
        }
        #expect(said == [.firstSentence(first), .complete(say)])
        #expect(first == BuddyBlock.firstSentence(of: say), "same answer as the headline count")
    }

    @Test func theFirstSentenceComesOutAtTheNextWordsFirstLetter() {
        var s = SayStreamExtractor()
        #expect(s.append("```buddy\n{\"say\": \"Ask Dr.").isEmpty)
        #expect(s.append(" O").isEmpty, "Dr. never ends a sentence")
        #expect(s.append("rtiz now. T") == [.firstSentence("Ask Dr. Ortiz now.")])
    }

    @Test func sayWaitsForTheClosingQuote() {
        var s = SayStreamExtractor()
        #expect(s.append("```buddy\n{\"say\": \"Half a sent").isEmpty)
        #expect(s.append("ence\"") == [.firstSentence("Half a sentence"), .complete("Half a sentence")])
    }

    @Test func sayOutsideABuddyFenceIsIgnored() {
        var s = SayStreamExtractor()
        #expect(s.append("{\"say\": \"not a block\"}").isEmpty)
    }

    @Test func crlfTextStillHasABlock() {
        let text = "Answer.\r\n```buddy\r\n{\"say\": \"Ok.\"}\r\n```\r\n"
        #expect(BuddyBlockExtractor.extract(from: text).block?.say == "Ok.")
        var s = SayStreamExtractor()
        #expect(s.append("```buddy\r\n{\"say\":\r\n \"Ok.\"").last == .complete("Ok."))
    }

    @Test func anOpenerIsNotAClose() {
        let text = "```buddy\n{\"say\": \"First.\"\n```swift\nlet x = 1\n```\n```buddy\n{\"say\": \"Second.\"}\n```"
        // The first fence never closes properly before the swift opener; the last block still wins.
        #expect(BuddyBlockExtractor.extract(from: text).block?.say == "Second.")
    }

    @Test func aMentionOfTheFenceMidLineIsNotAFence() {
        var s = SayStreamExtractor()
        #expect(s.append("Reply with a ```buddy block like {\"say\": \"x\"}").isEmpty)
    }
}
