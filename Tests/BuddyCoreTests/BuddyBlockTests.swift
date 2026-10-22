import Foundation
import Testing
@testable import BuddyCore

struct BuddyBlockTests {
    private func decode(_ json: String) throws -> BuddyBlock {
        try JSONDecoder().decode(BuddyBlock.self, from: Data(json.utf8))
    }

    @Test func decodesFullBlock() throws {
        let block = try decode("""
        {
          "say": "Your new date filter drops last week's test data.",
          "shape": "card",
          "card_html": "<div>diff</div>",
          "points": [{ "quote": "Today's stories", "label": "1" }],
          "actions": [{ "label": "Loosen filter in dev", "prompt": "Loosen it" }],
          "insert": null,
          "handoff": null
        }
        """)
        #expect(block.shape == .card)
        #expect(block.cardHTML == "<div>diff</div>")
        #expect(block.points == [.init(quote: "Today's stories", label: "1")])
        #expect(block.actions.first?.label == "Loosen filter in dev")
        #expect(block.insert == nil)
        #expect(block.handoff == nil)
    }

    @Test func missingOptionalFieldsDefault() throws {
        let block = try decode(#"{ "say": "Let me check the repo.", "shape": "chip", "handoff": "deep" }"#)
        #expect(block.points.isEmpty)
        #expect(block.actions.isEmpty)
        #expect(block.cardHTML == nil)
        #expect(block.handoff == .deep)
    }

    @Test func dropsActionsBeyondThree() throws {
        let actions = (1...5).map { #"{ "label": "a\#($0)", "prompt": "p" }"# }.joined(separator: ",")
        let block = try decode(#"{ "say": "x", "shape": "rich", "actions": [\#(actions)] }"#)
        #expect(block.actions.map(\.label) == ["a1", "a2", "a3"])
    }

    @Test func unknownShapeFallsBackByContent() throws {
        #expect(try decode(#"{ "say": "x", "shape": "banner" }"#).shape == .chip)
        #expect(try decode(#"{ "say": "x", "shape": "banner", "card_html": "<p/>" }"#).shape == .card)
        #expect(try decode(#"{ "say": "x" }"#).shape == .chip)
        #expect(try decode(#"{ "say": "x", "shape": "Rich" }"#).shape == .rich)
    }

    @Test(arguments: [#""none""#, #""quick""#, #""""#, "null"])
    func unknownHandoffMeansNone(raw: String) throws {
        #expect(try decode(#"{ "say": "x", "shape": "chip", "handoff": \#(raw) }"#).handoff == nil)
    }

    @Test func skipsMalformedActionsAndPoints() throws {
        let block = try decode(#"""
        { "say": "x", "shape": "card",
          "actions": [{ "label": "no prompt" }, { "label": "ok", "prompt": "p" }],
          "points": [{ "quote": 3 }, { "quote": "q", "label": "1" }] }
        """#)
        #expect(block.actions == [.init(label: "ok", prompt: "p")])
        #expect(block.points == [.init(quote: "q", label: "1")])
    }

    @Test func bareStringPointsAreKeptAsQuotesLabelledByPosition() throws {
        let block = try decode(#"""
        { "say": "x", "shape": "card",
          "points": ["refreshTimer", { "quote": "trail.distanceKm!", "label": "2" }, "", 4, "self.reload()"] }
        """#)
        #expect(block.points == [
            .init(quote: "refreshTimer", label: "1"),
            .init(quote: "trail.distanceKm!", label: "2"),
            .init(quote: "self.reload()", label: "5"),
        ])
    }

    @Test func needsOkCountsOnlyOnARichCardWithAnAction() throws {
        let action = #"[{ "label": "Stop it", "prompt": "kill 51234" }]"#
        let approval = try decode(#"{ "say": "x", "shape": "rich", "needs_ok": true, "actions": \#(action) }"#)
        #expect(approval.needsApproval)
        #expect(try decode(#"{ "say": "x", "shape": "rich", "actions": \#(action) }"#).needsApproval == false)
        #expect(try decode(#"{ "say": "x", "shape": "card", "needs_ok": true, "actions": \#(action) }"#).needsApproval == false)
        #expect(try decode(#"{ "say": "x", "shape": "rich", "needs_ok": true }"#).needsApproval == false)
        #expect(try decode(#"{ "say": "x", "shape": "rich", "needs_ok": "yes", "actions": \#(action) }"#).needsApproval == false)
        let json = String(decoding: try JSONEncoder().encode(approval), as: UTF8.self)
        #expect(json.contains(#""needs_ok":true"#))
    }

    @Test func aLinkIsHttpsOnlyAndAnythingElseIsDropped() throws {
        let ok = try decode(#"{ "say": "x", "shape": "card", "link": { "label": "Open draft", "url": "https://mail.google.com/mail/u/0/#drafts/abc" } }"#)
        #expect(ok.link?.label == "Open draft")
        #expect(ok.link?.domain == "mail.google.com")
        for url in ["http://example.com/x", "file:///Users/me/.ssh/id_rsa", "buddy://settings/microphone",
                    "x-apple.systempreferences:com.apple.settings", "javascript:alert(1)", "https:///nohost", "not a url"] {
            let block = try decode(#"{ "say": "x", "shape": "card", "link": { "label": "Open", "url": "\#(url)" } }"#)
            #expect(block.link == nil, "\(url) must not decode")
            #expect(block.say == "x", "a bad link never loses the answer")
        }
        #expect(try decode(#"{ "say": "x", "shape": "card", "link": { "label": "  ", "url": "https://a.com" } }"#).link == nil)
        #expect(try decode(#"{ "say": "x", "shape": "card", "link": "https://a.com" }"#).link == nil)
        let json = String(decoding: try JSONEncoder().encode(ok), as: UTF8.self)
        #expect(json.contains(#""link":{"#))
    }

    @Test func nonArrayActionsDecodeAsEmpty() throws {
        #expect(try decode(#"{ "say": "x", "shape": "chip", "actions": "none" }"#).actions.isEmpty)
    }

    @Test func missingSayFails() {
        #expect(throws: DecodingError.self) {
            try decode(#"{ "shape": "chip" }"#)
        }
    }

    @Test func headlineWordCountUsesFirstSentence() {
        let block = BuddyBlock(say: "Your new date filter drops last week's test data. Want me to loosen it?", shape: .card)
        #expect(block.headlineWordCount == 9)
        #expect(BuddyBlock(say: "", shape: .chip).headlineWordCount == 0)
    }

    /// The same cases as Tools/scenarios/test_buddy_rules.py, so the app and the evals agree.
    @Test(arguments: [
        ("Use rg: it's the fastest, at 38 ms. It's 1.6 times faster than git grep.", 8),
        ("Revenue hit 3.5 million in Q3, up from 3.1 million.", 10),
        ("Open index.ts and rename the export. Then rebuild.", 6),
        ("Use a fixture, e.g. the one in tests. Then run it.", 8),
        ("Dr. Ortiz signed it. Nobody else did.", 4),
        ("The call is at 5 p.m. tomorrow. Bring notes.", 7),
        ("The call ends at 5 p.m. Then the review starts.", 6),
        ("Pack shirts, socks, etc. Then leave.", 4),
        ("Pack shirts, socks, etc. and go.", 6),
        ("The I.R.S. sent a letter about it. Pay soon.", 7),
        ("She has a Ph.D. in physics. It shows.", 6),
        ("Prices in the U.S. Then Europe.", 4),
        ("It was written by J. R. R. Tolkien in 1954. Read it.", 10),
        ("Ask J. Smith about the budget. Today.", 6),
        ("Go with Plan A. It is cheaper.", 4),
        ("Run npm i. Then start the server.", 3),
        ("It's \"done.\" Next sentence.", 2),
        ("Is it ready? Almost.", 3),
        ("No punctuation at all", 4),
        ("One. Two three.", 1),
    ])
    func headlineWordsMatchTheEvalRules(say: String, words: Int) {
        #expect(BuddyBlock(say: say, shape: .chip).headlineWordCount == words, "\(BuddyBlock.firstSentence(of: say))")
    }

    @Test func millisecondsEndASentenceButMsTitleDoesNot() {
        #expect(BuddyBlock.firstSentence(of: "Ask Ms. Lee about it. Then wait.") == "Ask Ms. Lee about it.")
        #expect(BuddyBlock.firstSentence(of: "It took 38 ms. and then stopped.") == "It took 38 ms. and then stopped.")
        #expect(BuddyBlock.firstSentence(of: "It took 38 ms. Then it stopped.") == "It took 38 ms.")
    }

    @Test func roundTripsWithSnakeCaseKeys() throws {
        let block = BuddyBlock(say: "Hi.", shape: .rich, cardHTML: "<p/>", handoff: .research)
        let json = String(decoding: try JSONEncoder().encode(block), as: UTF8.self)
        #expect(json.contains("\"card_html\""))
        #expect(try decode(json) == block)
    }
}
