import Testing
@testable import BuddyVoice

struct SentenceSplitterTests {
    @Test(arguments: [
        ("Your date filter drops last week's data. Want me to loosen it for you?",
         ["Your date filter drops last week's data.", "Want me to loosen it for you?"]),
        ("That run failed badly! The signing identity expired yesterday. Should I renew it now?",
         ["That run failed badly!", "The signing identity expired yesterday.", "Should I renew it now?"]),
        ("Wait… the cache was cleared before the deploy finished. That explains the empty page.",
         ["Wait… the cache was cleared before the deploy finished.", "That explains the empty page."]),
        ("No terminal punctuation here so it stays one piece",
         ["No terminal punctuation here so it stays one piece"]),
        ("Use a stricter type, e.g. a non-optional string. That avoids the crash entirely.",
         ["Use a stricter type, e.g. a non-optional string.", "That avoids the crash entirely."]),
        ("Ask Dr. Patel about the dosage before Friday. She wrote the guideline last year.",
         ["Ask Dr. Patel about the dosage before Friday.", "She wrote the guideline last year."]),
        ("The ratio went from 3.5 to 4.2 after v2.1 shipped. It's the new parser.",
         ["The ratio went from 3.5 to 4.2 after v2.1 shipped.", "It's the new parser."]),
        ("He said \"ship it.\" Then the build broke on the release branch.",
         ["He said \"ship it.\"", "Then the build broke on the release branch."]),
        ("React vs. Vue matters less here than the bundle size, i.e. the 2 MB vendor chunk.",
         ["React vs. Vue matters less here than the bundle size, i.e. the 2 MB vendor chunk."]),
        ("Latency dropped to 40 ms. The cache fixed it after the warm-up.",
         ["Latency dropped to 40 ms.", "The cache fixed it after the warm-up."]),
        ("Ask Ms. Lee about the budget today. She owns the sheet.",
         ["Ask Ms. Lee about the budget today.", "She owns the sheet."]),
        ("It took 38 ms. and then the request stopped. Retry the request now.",
         ["It took 38 ms. and then the request stopped.", "Retry the request now."]),
        ("Pack the cables, chargers, etc. Then ship the box today.",
         ["Pack the cables, chargers, etc.", "Then ship the box today."]),
        ("The meeting ends at 5 p.m. tomorrow in the big room.",
         ["The meeting ends at 5 p.m. tomorrow in the big room."]),
    ])
    func splits(text: String, expected: [String]) {
        #expect(SentenceSplitter.split(text) == expected)
    }

    @Test func shortPiecesMergeIntoTheNextSentence() {
        #expect(SentenceSplitter.split("Okay. The list is empty because the filter is too strict.")
            == ["Okay. The list is empty because the filter is too strict."])
        #expect(SentenceSplitter.split("Yes. No. The build passes on main now.")
            == ["Yes. No. The build passes on main now."])
    }

    @Test func aShortLastPieceJoinsThePreviousSentence() {
        #expect(SentenceSplitter.split("The filter drops last week's test data. Fix it?")
            == ["The filter drops last week's test data. Fix it?"])
    }

    @Test func runsOfPunctuationEndTogether() {
        #expect(SentenceSplitter.split("Did that really pass the review?! I doubt the tests ran at all.")
            == ["Did that really pass the review?!", "I doubt the tests ran at all."])
    }

    @Test func emptyAndWhitespaceGiveNothing() {
        #expect(SentenceSplitter.split("").isEmpty)
        #expect(SentenceSplitter.split("  \n ").isEmpty)
    }
}
