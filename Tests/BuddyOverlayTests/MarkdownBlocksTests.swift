import Foundation
import Testing
@testable import BuddyOverlay

/// Typed answers render as Markdown blocks, code fences included (D8 fix 1: `proseBlock`
/// returned nil on any ```), streaming with only the tail re-parsed.
struct MarkdownBlocksTests {
    func kinds(_ s: String) -> [MarkdownBlock.Kind] { MarkdownSplitter.split(s).blocks.map(\.kind) }

    @Test func splitsAtBlankLinesAndKeepsFencesWhole() {
        let md = """
        # Fix

        The token lived **60 s**.
        It was meant to be minutes.

        ```swift
        let ttl = 60

        let other = 1
        ```
        - one
        - two
          more
        1. first
        > quoted
        lazy

        | a | b |
        |---|---|
        | 1 | 2 |
        ---
        """
        let r = MarkdownSplitter.split(md)
        #expect(r.blocks.map(\.kind) == [
            .heading(level: 1), .paragraph, .code(language: "swift"), .list(ordered: false), .list(ordered: true),
            .quote, .table, .rule,
        ])
        #expect(r.blocks[0].text == "Fix")
        #expect(r.blocks[1].text == "The token lived **60 s**.\nIt was meant to be minutes.")
        #expect(r.blocks[2].text == "let ttl = 60\n\nlet other = 1")
        #expect(r.blocks[3].text == "- one\n- two\n  more")
        #expect(r.blocks.map(\.id) == Array(0..<8))
        #expect(r.complete == 8)
    }

    @Test func tildeFencesAndLongerClosers() {
        #expect(kinds("~~~\na\n~~~") == [.code(language: nil)])
        #expect(MarkdownSplitter.split("````md\n```\ninner\n```\n````").blocks.map(\.text) == ["```\ninner\n```"])
        #expect(kinds("#hashtag") == [.paragraph])
    }

    @Test func streamingFreezesFinishedBlocksOnly() {
        var md = StreamingMarkdown()
        md.append("First para")
        #expect(md.frozen.isEmpty)
        #expect(md.liveBlocks.map(\.text) == ["First para"])
        md.append("graph.\n\nSecond")
        #expect(md.frozen.map(\.text) == ["First paragraph."])
        #expect(md.tail == "Second")
        #expect(md.liveBlocks.first?.id == 1)
        md.append(" one.\n\n```py\nprint(1)\n\n")
        #expect(md.frozen.map(\.text) == ["First paragraph.", "Second one."])
        // An open fence streams as code and stays live.
        #expect(md.liveBlocks.map(\.kind) == [.code(language: "py")])
        md.append("```\n")
        #expect(md.frozen.map(\.kind).last == .code(language: "py"))
        #expect(md.frozen.last?.text == "print(1)\n")
        #expect(md.tail.isEmpty)
        md.finish()
        #expect(md.isFinished)
        #expect(md.frozen.count == 3)
    }

    @Test func aBlockKeepsItsIDWhenItFreezes() {
        var md = StreamingMarkdown()
        md.append("a\n\nb")
        let liveID = md.liveBlocks.first?.id
        md.append("\n\n")
        #expect(md.frozen.last?.id == liveID)
    }

    @Test func finishKeepsStreamedTextThatEndsWithTheResult() {
        var md = StreamingMarkdown()
        md.append("Let me look.\n\nThe answer is 4.")
        md.finish("The answer is 4.")
        #expect(md.frozen.map(\.text) == ["Let me look.", "The answer is 4."])
    }

    @Test func finishUsesTheResultWhenNothingStreamedOrItDiffers() {
        var empty = StreamingMarkdown()
        empty.finish("```\ncode\n```")
        #expect(empty.frozen.map(\.kind) == [.code(language: nil)])

        var odd = StreamingMarkdown()
        odd.append("partial")
        odd.finish("Something else entirely")
        #expect(odd.frozen.map(\.text) == ["Something else entirely"])
        #expect(odd.text == "Something else entirely")
    }

    @Test func theTailIsSpeculativelyClosed() {
        var md = StreamingMarkdown()
        md.append("Set **tokenTTL to `3600")
        #expect(md.liveBlocks.first?.text == "Set **tokenTTL to `3600`**")
        #expect(StreamingMarkdown.speculativelyClosed("a `**` b") == "a `**` b")
    }

    @Test func historyIsFinishedAtOnce() {
        let md = StreamingMarkdown(finished: "One\n\nTwo")
        #expect(md.isFinished)
        #expect(md.frozen.count == 2)
        #expect(md.liveBlocks.isEmpty)
    }

    @Test func multibyteTextSplitsCleanly() {
        var md = StreamingMarkdown()
        md.append("Café ☕️ first.\n\nNext")
        #expect(md.frozen.map(\.text) == ["Café ☕️ first."])
        #expect(md.tail == "Next")
    }
}

/// Round 3 S-11 to S-13: nested lists keep their levels, task items get boxes, bare URLs link.
@MainActor
struct MarkdownListAndLinkTests {
    @Test func aNestedListIsOneBlockWithLevels() {
        let md = """
        1. Install it
           - with brew
           - or the script
             - as root
        2. Run it
        - [ ] todo
        - [x] done
        """
        let blocks = MarkdownSplitter.split(md).blocks
        #expect(blocks.map(\.kind) == [.list(ordered: true), .list(ordered: false)])
        let items = MarkdownList.items(blocks[0].text)
        #expect(items.map(\.marker) == ["1.", "◦", "◦", "◦", "2."])
        #expect(items.map(\.depth) == [0, 1, 1, 2, 0])
        #expect(items.map(\.text) == ["Install it", "with brew", "or the script", "as root", "Run it"])
        let tasks = MarkdownList.items(blocks[1].text)
        #expect(tasks.map(\.marker) == ["☐", "☑"] && tasks.map(\.text) == ["todo", "done"])
        // A continuation line still joins its item; an unindented bullet after a numbered list starts a new one.
        #expect(MarkdownList.items("- one\n  more").map(\.text) == ["one more"])
    }

    @Test func bareWebAddressesBecomeLinksButNotFileNamesOrCode() throws {
        var a = try AttributedString(markdown: "See https://lumi.loomtable.com/docs and www.example.org, `https://in.code`, Package.swift",
                                     options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        InHouseMarkdown.autolink(&a)
        let links = a.runs.compactMap { run in run.link.map { ($0.absoluteString, String(a[run.range].characters)) } }
        #expect(links.map(\.1) == ["https://lumi.loomtable.com/docs", "www.example.org"])
        #expect(links.first?.0 == "https://lumi.loomtable.com/docs")
    }
}
