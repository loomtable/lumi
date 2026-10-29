import AppKit
import BuddyCore
import Observation

/// What the switcher's views draw. Owned by `LiveSwitcher`, which keeps the geometry and the
/// panels in step with it.
@MainActor @Observable
final class SwitcherModel {
    /// Strip order, frozen while the strip is open: all of them show (`StripOrder` gives at most
    /// 8, which with New fill three rows of three). Index `tiles.count` is New.
    var tiles: [SessionSnapshot] = []
    var highlight = 0
    var isOpen = false
    /// Set by `close(commit:)` for the pick animation.
    var committed = false
    /// "Now" for the status lines, set at prepare and refresh.
    var now = Date()
    /// What the peek shows; nil hides it.
    var peek: SessionSnapshot?
    /// The key hint row in the peek (only while the strip is open and the keys work).
    var peekShowsKeys = false
    /// Origin app icons, by bundle ID (loaded at prepare, off the Tab path).
    var icons: [String: NSImage] = [:]
    /// The header row the pill sits in (0 without a pill), and whether it's under the tiles
    /// (the pill at the bottom of the screen).
    var headerHeight: CGFloat = 0
    var headerAtBottom = false
    /// The plate's width when it's wider than its chips (around a wide pill); 0: as wide as the chips.
    var plateWidth: CGFloat = 0
}

/// Sizes the panels use, kept beside the model so views and the controller agree.
enum SwitcherPanelLayout {
    /// Room around a surface for its shadow, inside its panel.
    static let shadowRoom: CGFloat = 24
}
