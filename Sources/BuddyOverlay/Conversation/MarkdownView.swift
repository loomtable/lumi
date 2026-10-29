import AppKit
import SwiftUI

/// Renders one Markdown block. Typed answers go through this, never through `proseBlock`
/// (D8 fix 1). The in-house renderer is the default; a Textual-backed one can be swapped in
/// with one conformance if the owner approves the dependency.
@MainActor public protocol MarkdownRendering {
    /// `live`: the streaming tail, which isn't selectable until it freezes.
    func view(for block: MarkdownBlock, live: Bool, density: PageDensity, tokens: Tokens) -> AnyView
}

/// A typed answer, frozen blocks first, then the live tail.
struct MarkdownView: View {
    let markdown: StreamingMarkdown
    let density: PageDensity
    let t: Tokens
    var renderer: any MarkdownRendering = InHouseMarkdown()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(markdown.frozen) { block in
                renderer.view(for: block, live: false, density: density, tokens: t)
            }
            ForEach(markdown.liveBlocks) { block in
                renderer.view(for: block, live: true, density: density, tokens: t)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The fallback renderer: `AttributedString(markdown:)` per block for inline styles, our own
/// views for headings, lists, quotes, tables and code (SF Mono 12/17 with a Copy button).
public struct InHouseMarkdown: MarkdownRendering {
    public init() {}

    public func view(for block: MarkdownBlock, live: Bool, density: PageDensity, tokens: Tokens) -> AnyView {
        let content = BlockView(block: block, density: density, t: tokens)
        return live ? AnyView(content.textSelection(.disabled)) : AnyView(content.textSelection(.enabled))
    }

    /// Inline Markdown (emphasis, code spans, links), whitespace kept; plain text if it won't parse.
    static func inline(_ s: String, t: Tokens, mono: Font) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var a = try? AttributedString(markdown: s, options: options) else { return AttributedString(s) }
        autolink(&a)
        for run in a.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                a[run.range].font = mono
                a[run.range].foregroundColor = t.emberText.color
            }
            if run.link != nil {
                a[run.range].foregroundColor = t.emberText.color
            }
        }
        return a
    }
}

extension InHouseMarkdown {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Bare web addresses become links, as in Claude Code's terminal (QA S-12): only text that
    /// starts with http(s):// or www., outside code spans and existing links, so a file name like
    /// `Package.swift` never turns into one.
    static func autolink(_ a: inout AttributedString) {
        guard let detector = linkDetector else { return }
        let plain = String(a.characters)
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let text = Range(match.range, in: plain).map({ plain[$0].lowercased() }),
                  text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www."),
                  let range = Range(match.range, in: a),
                  !a[range].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true })
            else { continue }
            a[range].link = url
        }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let density: PageDensity
    let t: Tokens

    var body: some View {
        switch block.kind {
        case .paragraph:
            text(block.text, density.body)
        case .heading(let level):
            Text(InHouseMarkdown.inline(block.text, t: t, mono: density.mono.mono))
                .font(.system(size: level <= 2 ? density.headline.size : density.body.size, weight: .semibold))
                .foregroundStyle(t.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .code(let language):
            CodeBlockView(code: block.text, language: language, density: density, t: t)
        case .list(let ordered):
            ListBlock(items: MarkdownList.items(block.text), ordered: ordered, density: density, t: t)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(t.hairline.color).frame(width: 2)
                text(Self.unquoted(block.text), density.body, secondary: true)
            }
        case .table:
            TableBlock(rows: Self.tableRows(block.text), density: density, t: t)
        case .rule:
            Rectangle().fill(t.hairline.color).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func text(_ s: String, _ m: PageDensity.Metric, secondary: Bool = false) -> some View {
        Text(InHouseMarkdown.inline(s, t: t, mono: density.mono.mono))
            .font(m.font)
            .lineSpacing(m.spacing)
            .foregroundStyle(secondary ? t.secondaryText.color : t.text.color)
            .tint(t.emberText.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func unquoted(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var l = line.drop { $0 == " " }
            if l.first == ">" { l = l.dropFirst() }
            if l.first == " " { l = l.dropFirst() }
            return String(l)
        }.joined(separator: "\n")
    }

    /// Table cells, without the `|---|` alignment row.
    static func tableRows(_ s: String) -> [[String]] {
        s.split(separator: "\n").compactMap { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("|") { l.removeFirst() }
            if l.hasSuffix("|") { l.removeLast() }
            let cells = l.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let isAlignment = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
            return isAlignment ? nil : cells
        }
    }
}

private struct ListBlock: View {
    let items: [MarkdownListItem]
    let ordered: Bool
    let density: PageDensity
    let t: Tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.marker)
                        .font(density.body.font.monospacedDigit())
                        .foregroundStyle(t.secondaryText.color)
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                    Text(InHouseMarkdown.inline(item.text, t: t, mono: density.mono.mono))
                        .font(density.body.font)
                        .lineSpacing(density.body.spacing)
                        .foregroundStyle(t.text.color)
                        .tint(t.emberText.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TableBlock: View {
    let rows: [[String]]
    let density: PageDensity
    let t: Tokens

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(InHouseMarkdown.inline(c < row.count ? row[c] : "", t: t, mono: density.mono.mono))
                            .font(.system(size: density.callout.size, weight: r == 0 ? .semibold : .regular))
                            .foregroundStyle(r == 0 ? t.secondaryText.color : t.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
                if r < rows.count - 1 {
                    Divider().overlay(t.hairline.color).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A fenced code block: SF Mono on the tile, scrolling sideways, with a Copy button.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let density: PageDensity
    let t: Tokens
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: density.caption.size))
                    .foregroundStyle(t.secondaryText.color)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .buttonStyle(.plain)
                .font(.system(size: density.caption.size, weight: .medium))
                .foregroundStyle(t.secondaryText.color)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
                .resettingCopied($copied)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal) {
                Text(code)
                    .font(density.mono.mono)
                    .lineSpacing(density.mono.spacing)
                    .foregroundStyle(t.text.color)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PageColors(t: t).tile.color, in: RoundedRectangle(cornerRadius: PageShape.codeRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PageShape.codeRadius, style: .continuous).strokeBorder(t.hairline.color.opacity(0.5)))
    }
}
