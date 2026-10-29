@testable import BuddyApp
import BuddyCore

/// `PageSurfaces` whose visible page the test sets.
@MainActor final class FakePageSurfaces: PageSurfaces {
    var visiblePage: (id: SessionID, kind: PageKind)?

    init(showing id: SessionID? = nil, kind: PageKind = .panel) {
        visiblePage = id.map { ($0, kind) }
    }
}
