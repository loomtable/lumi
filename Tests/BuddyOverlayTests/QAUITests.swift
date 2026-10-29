import BuddyCore
import Foundation
import Testing
@testable import BuddyOverlay

// qa-ui (Oct 28): interaction logic and contrast checks found missing while verifying the v2
// screens. IDs are the findings in docs/v2-sessions/30-QA.md (## UI).

struct QAUIHistoryTests {
    let at = Date(timeIntervalSince1970: 1_000)
    let markdown = "March is high because of three one-off invoices:\n\n1. The deposit.\n2. An overlap.\n\n```swift\nlet a = 1\n```"

    /// TranscriptReader keeps a typed answer's Markdown in `markdown`; `block.say` is its first line.
    func typedTurn() -> TranscriptTurn {
        TranscriptTurn(id: "h1", question: "Why is March so high?",
                       block: BuddyBlock(say: "March is high because of three one-off invoices:", shape: .rich),
                       mode: .deep, model: .opus, kind: .typed, markdown: markdown)
    }

    @Test func aReopenedTypedTurnShowsTheWholeAnswer() {
        var page = ConversationPage(session: SessionID(rawValue: "s_1"), title: "Q3")
        page.load(history: [typedTurn()], at: at)
        // U1 (fixed in 461c02a).
        #expect(page.turns[0].answer.text == markdown)
        #expect(page.turns[0].answer.frozen.contains { $0.kind == .code(language: "swift") })
    }

    @Test func aReopenedVoiceTurnStillShowsWhatWasSaid() {
        var page = ConversationPage(session: SessionID(rawValue: "s_1"), title: "Q3")
        let voice = TranscriptTurn(id: "h2", question: "What's this?", block: BuddyBlock(say: "It's the March total.", shape: .chip),
                                   mode: .quick, model: .haiku, kind: .voice)
        page.load(history: [voice], at: at)
        #expect(page.turns[0].answer.text == "It's the March total.")
    }
}

/// WCAG 2.x contrast of every text token on the surfaces it sits on (04 §7.1), computed, not eyeballed.
struct QAUIContrastTests {
    static func luminance(_ c: TokenColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    /// `fg` composited over `bg` (both sRGB), then the ratio against `bg`.
    static func ratio(_ fg: TokenColor, on bg: TokenColor) -> Double {
        let a = fg.alpha
        let mixed = TokenColor(fg.red * a + bg.red * (1 - a), fg.green * a + bg.green * (1 - a), fg.blue * a + bg.blue * (1 - a))
        let (l1, l2) = (luminance(mixed), luminance(bg))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func opaque(_ c: TokenColor) -> TokenColor { c.opacity(1) }

    nonisolated static let variants: [Tokens.Variant] = Theme.allCases.flatMap { theme in
        [false, true].flatMap { dark in
            [Tokens.Variant(dark: dark, theme: theme), .init(dark: dark, theme: theme, reduceTransparency: true),
             .init(dark: dark, theme: theme, increaseContrast: true)]
        }
    }

    @Test(arguments: variants)
    func textTokensReadOnTheWellAndTheTile(_ v: Tokens.Variant) {
        let t = Tokens(v)
        let surfaces = [("well", Self.opaque(t.well)), ("tile", t.opaqueSurface)]
        let texts = [("text", t.text), ("secondary", t.secondaryText), ("emberText", t.emberText), ("sage", t.sage),
                     ("amber", t.amber), ("rose", t.rose), ("mist", t.mist)]
        for (sName, s) in surfaces {
            for (name, c) in texts {
                #expect(Self.ratio(c, on: s) >= 4.5, "\(name) on \(sName), \(v)")
            }
        }
        #expect(Self.ratio(t.onEmber, on: t.emberMark) >= 4.5, "onEmber on emberMark, \(v)")
    }

    /// The approval card's amber header over its wash, and text on a picked question chip.
    @Test(arguments: variants)
    func cardsKeepTheirTextReadable(_ v: Tokens.Variant) {
        let t = Tokens(v)
        let colors = PageColors(t: t)
        let wash = Self.composite(colors.amberWash, over: Self.opaque(t.well))
        #expect(Self.ratio(t.amber, on: wash) >= 4.5)
        let chosen = Self.composite(t.emberMark.opacity(0.14), over: Self.opaque(t.well))
        #expect(Self.ratio(t.text, on: chosen) >= 4.5)
        #expect(Self.ratio(t.text, on: Self.composite(colors.added, over: Self.opaque(t.well))) >= 4.5)
        #expect(Self.ratio(t.text, on: Self.composite(colors.removed, over: Self.opaque(t.well))) >= 4.5)
    }

    /// The switcher's text sits on its opaque reading well (U4, fixed in 6592292), over any backdrop;
    /// in Liquid Glass on the glass's veil over the material's worst case.
    @Test(arguments: variants)
    func switcherTextOnItsWell(_ v: Tokens.Variant) {
        let t = Tokens(v)
        for well in WindowSurfaceTokenTests.readingSurfaces(t) { switcherText(t, on: well, v) }
    }

    private func switcherText(_ t: Tokens, on well: TokenColor, _ v: Tokens.Variant) {
        for (name, c) in SwitcherSurface.textColors(t) {
            #expect(Self.ratio(c, on: well) >= 4.5, "\(name) on the switcher well, \(v)")
        }
        // The selected tile's fill sits between the well and the text.
        let selected = Self.composite(SwitcherSurface.selection(t), over: well)
        for (name, c) in SwitcherSurface.textColors(t) {
            #expect(Self.ratio(c, on: selected) >= 4.5, "\(name) on the selected tile, \(v)")
        }
    }

    static func composite(_ fg: TokenColor, over bg: TokenColor) -> TokenColor {
        let a = fg.alpha
        return TokenColor(fg.red * a + bg.red * (1 - a), fg.green * a + bg.green * (1 - a), fg.blue * a + bg.blue * (1 - a))
    }
}

extension Tokens.Variant: CustomTestStringConvertible {
    public var testDescription: String {
        (dark ? "dark" : "light") + (reduceTransparency ? "+RT" : "") + (increaseContrast ? "+IC" : "")
    }
}
