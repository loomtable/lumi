import Foundation
import Testing
@testable import BuddyCompanion

// QA U54: in an 880 pt window with the inspector open the session column is 332 pt wide, and
// the disc plus three round buttons left the title nothing ("…").
@Suite struct ConversationHeaderTests {
    @Test("Open as Panel and the Inspector fold into ⋯ when the column is narrow, not at usual widths",
          arguments: [(332.0, true), (420, true), (632, false), (1000, false)])
    func buttonsFold(width: Double, folds: Bool) {
        #expect(ConversationHeader.foldsButtons(width: width) == folds)
    }
}
