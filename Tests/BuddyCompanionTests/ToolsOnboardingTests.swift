import AppKit
@testable import BuddyCompanion
import Foundation
import Testing

@Suite("Onboarding › Your tools")
@MainActor
struct ToolsOnboardingTests {
    @Test func theStepKeepsItsIDAndNeverHoldsContinue() {
        let step = ConnectionsOnboarding.step()
        #expect(step.id == "connections", "a user who finished the old Connections step isn't shown this again")
        #expect(step.canContinue() && step.onStart == nil && step.headerAccessory == nil)
    }

    @Test func linksAreClaudePagesOverHTTPSAndEachToolHasItsOwn() {
        let urls = [ConnectionsOnboarding.directory] + ConnectionsOnboarding.suggestions.map(\.url)
        for url in urls {
            #expect(url.scheme == "https" && url.host == "claude.ai" && url.path.hasPrefix("/directory"))
        }
        #expect(Set(urls).count == urls.count, "no two links go to the same page")
    }

    @Test func suggestionsAreUniqueUseSystemSymbolsAndFillTwoColumns() {
        let names = ConnectionsOnboarding.suggestions.map(\.name)
        #expect(names == ["Notion", "Linear", "Slack", "Gmail", "Google Drive", "Google Calendar"])
        #expect(Set(names).count == names.count)
        for s in ConnectionsOnboarding.suggestions {
            #expect(NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil) != nil, "\(s.symbol) is an SF Symbol")
        }
        #expect(ConnectionsOnboarding.rows.map { $0.map(\.name) } == [["Notion", "Linear"], ["Slack", "Gmail"], ["Google Drive", "Google Calendar"]])
    }
}
