import Testing
@testable import BuddyCompanion
@testable import BuddyOverlay

/// The Settings list's icon tiles: a white glyph on each page's colour stays at least 3:1 (WCAG's
/// non-text contrast), and the pages that scan alike don't share a colour by accident.
struct SettingsIconTileTests {
    @Test(arguments: SettingsPage.allCases)
    func theWhiteGlyphReadsOnItsTile(_ page: SettingsPage) {
        let tile = SettingsIconTile.tile(page)
        #expect(SwitcherSurface.contrast(TokenColor(1, 1, 1), tile) >= 3, "\(page)")
    }

    @Test func pagesNextToEachOtherHaveDifferentColours() {
        let tiles = SettingsPage.allCases.map { SettingsIconTile.tile($0) }
        for (a, b) in zip(tiles, tiles.dropFirst()) { #expect(a != b) }
    }
}
