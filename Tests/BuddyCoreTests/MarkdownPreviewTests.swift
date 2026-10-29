import BuddyCore
import Testing

struct MarkdownPreviewTests {
    nonisolated static let cases: [(String, String)] = [
        // The owner's peek (U49): emphasis marks never show.
        (#"I took "Beautypass" to mean **Budapest**."#, #"I took "Beautypass" to mean Budapest."#),
        ("__Bold__, *em*, _em_ and ~~gone~~", "Bold, em, em and gone"),
        ("Run `npm test` then ``a ` tick``", "Run npm test then a ` tick"),
        ("See [the doc](https://example.com/a_b) or <https://example.com>", "See the doc or https://example.com"),
        ("![chart](data:image/png;base64,xyz) Revenue", "chart Revenue"),
        ("Marks in code stay: `**not bold**`", "Marks in code stay: **not bold**"),
        ("snake_case_name and 2*3*4 stay", "snake_case_name and 2*3*4 stay"),
        (#"A \*literal\* star"#, "A *literal* star"),
        ("## Fixed\n\n- one\n- two\n1. three\n> quoted\n- [x] done", "Fixed one two three quoted done"),
        ("| City | Temp |\n|---|:--:|\n| Budapest | 14° |", "City · Temp Budapest · 14°"),
        ("Above\n\n---\n\nBelow", "Above Below"),
        ("Fix:\n```swift\nlet x = **y**\n```\nDone", "Fix: let x = **y** Done"),
        ("Line one<br>line two", "Line one line two"),
        ("**Bold across\nlines**", "Bold across lines"),
    ]

    @Test(arguments: cases)
    func marksGoTheirTextStays(_ markdown: String, _ expected: String) {
        #expect(MarkdownPreview.line(markdown) == expected)
    }

    @Test func cutAtAWordWithinTheLimit() {
        let line = MarkdownPreview.line(String(repeating: "**word** ", count: 60), limit: 40)
        #expect(line.count <= 40)
        #expect(line.hasSuffix("…"))
        #expect(!line.contains("*"))
        #expect(MarkdownPreview.line("short", limit: 40) == "short")
    }

    @Test func aSayWithMarkdownIsPlainToo() {
        #expect(SessionSnapshot.lastSay(say: "It's **Budapest**.", markdown: "") == "It's Budapest.")
        #expect(SessionSnapshot.lastSay(say: "  ", markdown: "*Fallback*") == "Fallback")
    }
}
