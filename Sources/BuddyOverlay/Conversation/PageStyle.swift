import SwiftUI

/// How tightly the conversation page is set: the Panel is compact, the Studio column
/// comfortable (04 §7.3). Only type sizes and gaps differ.
nonisolated public enum PageDensity: String, Sendable, Equatable, CaseIterable {
    case compact, comfortable

    /// Size and line height in points.
    public struct Metric: Sendable, Equatable {
        public var size: CGFloat
        public var line: CGFloat
        /// Extra space between lines: line height minus the font's own.
        public var spacing: CGFloat { max(0, line - size * 1.2) }
    }

    public var headline: Metric { self == .compact ? Metric(size: 15, line: 20) : Metric(size: 16, line: 21) }
    public var body: Metric { self == .compact ? Metric(size: 13, line: 18) : Metric(size: 14, line: 21) }
    public var callout: Metric { Metric(size: 12, line: self == .compact ? 16 : 17) }
    public var caption: Metric { Metric(size: 11, line: 14) }
    public var mono: Metric { Metric(size: 12, line: self == .compact ? 17 : 18) }
    /// The composer's text.
    public var composer: Metric { self == .compact ? Metric(size: 13, line: 18) : Metric(size: 14, line: 20) }

    /// Between turns: 20 (Panel) / 24 (Studio).
    public var turnGap: CGFloat { self == .compact ? 20 : 24 }
    /// Between blocks inside a turn.
    public var blockGap: CGFloat { 12 }
    /// The page's side inset: Panel 16, Studio column 24.
    public var inset: CGFloat { self == .compact ? 16 : 24 }
    /// Above the first turn and below the last: Panel 16, Studio 12 (its header sits right above).
    public var threadPadding: CGFloat { self == .compact ? 16 : 12 }
    /// The composer's side margin: Panel 12; in Studio the page inset, so the composer is
    /// exactly as wide as the text above it (as in ChatGPT and Claude).
    public var composerInset: CGFloat { self == .compact ? 12 : inset }
    /// The session header: the Panel's 44 pt row, and in Studio the window toolbar's title.
    /// Both show a 24 pt agent mark and a 15 pt semibold title.
    public static let headerHeight: CGFloat = 44
    public static let headerDisc: CGFloat = 24
    public static let headerTitleSize: CGFloat = 15

    /// The Studio column's reading width, from 720 to 820 pt: 65% of a page `width` wide, so a
    /// wide window reads a little wider while the text stays centred. The text is this less two
    /// insets (672–772 pt, about ChatGPT's and Claude's 768). The Panel has no column (nil).
    public func readingWidth(in width: CGFloat) -> CGFloat? {
        guard self == .comfortable else { return nil }
        return min(Self.widestColumn, max(Self.narrowestColumn, (width * 0.65).rounded()))
    }

    public static let narrowestColumn: CGFloat = 720
    public static let widestColumn: CGFloat = 820
}

/// Centres its one child in the reading column for a page as wide as it's offered
/// (`PageDensity.readingWidth(in:)`), or across the whole width when that's narrower. A layout,
/// not `containerRelativeFrame`, so it reads the width its parent offers (LESSONS, Oct 29).
public struct ReadingColumn: Layout {
    let density: PageDensity
    public init(_ density: PageDensity) { self.density = density }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let size = child.sizeThatFits(column(proposal))
        return CGSize(width: offered ?? size.width, height: size.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                              proposal: column(ProposedViewSize(width: bounds.width, height: proposal.height)))
    }

    private func column(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let w = proposal.width else { return proposal }
        let limit = density.readingWidth(in: w.isFinite ? w : .greatestFiniteMagnitude)
        return ProposedViewSize(width: limit.map { min(w, $0) } ?? w, height: proposal.height)
    }
}

extension View {
    /// The page's reading column with its content inset (the page's by default): the thread,
    /// the composer, and Studio's header and team lane all line up on it.
    public func readingColumn(_ density: PageDensity, inset: CGFloat? = nil) -> some View {
        ReadingColumn(density) { self.padding(.horizontal, inset ?? density.inset) }
    }
}

extension PageDensity.Metric {
    var font: Font { .system(size: size) }
    var mono: Font { .system(size: size, design: .monospaced) }
}

/// Conversation colours derived from the Lantern Ink tokens (04 §7.1): diff tints, the user
/// bubble's tile, the chip well.
nonisolated struct PageColors {
    let t: Tokens

    /// The user bubble, chips and file tiles: #F3F1ED / #1E2025 (the opaque surface).
    var tile: TokenColor { t.opaqueSurface }
    /// Diff additions: sage @10% light, @12% dark.
    var added: TokenColor { t.sage.opacity(t.variant.dark ? 0.12 : 0.10) }
    /// Diff deletions: rose @8% light, @12% dark.
    var removed: TokenColor { t.rose.opacity(t.variant.dark ? 0.12 : 0.08) }
    /// The approval card's wash under the amber border.
    var amberWash: TokenColor { Tokens.amberBorder.opacity(0.05) }
}

/// Radii from 04 §7.4, concentric with the card rule.
enum PageShape {
    static let panelRadius: CGFloat = 22
    static let panelWellInset: CGFloat = 5
    static let panelWellRadius: CGFloat = panelRadius - panelWellInset
    static let bubbleRadius: CGFloat = 14
    static let fileChipRadius: CGFloat = 7
    static let thumbRadius: CGFloat = 6
    static let composerRadius: CGFloat = 22
    static let hitTarget: CGFloat = 28
    static let codeRadius: CGFloat = 9
    static let cardRadius: CGFloat = 16
}
