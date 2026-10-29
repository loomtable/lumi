/// What a switcher key means, after the buddy key's adaptations (03 §3.4).
public enum SwitcherKey: Sendable, Equatable, Hashable {
    /// Tab (` with a ⌘ buddy key), →, ⇥ again.
    case next
    /// ⇧Tab or `, ←.
    case prev
    /// 1–9: highlight that tile.
    case index(Int)
    /// Return.
    case commit
    /// Esc or `.`: restore the original session and close the strip.
    case cancel
    /// Space or ↓: show the highlighted session's last answer.
    case peek
    /// ↑: close the peek.
    case unpeek
    /// N or =: a new session.
    case new
    /// T: the highlighted session's teammates.
    case teammates
    /// P: pin or unpin.
    case pin
    /// ⌫: archive.
    case archive
}
