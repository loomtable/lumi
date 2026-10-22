@testable import BuddyApp
import BuddyCompanion
import Foundation
import Testing

@MainActor
struct SettingsLinkTests {
    @Test(arguments: PermissionKind.allCases)
    func everyPrivacyPaneRoundTrips(kind: PermissionKind) {
        #expect(SettingsLink.url(for: SettingsLink.link(for: kind)) == kind.settingsURL)
    }

    @Test func onlyExactSettingsLinksAreHonoured() {
        for prompt in ["Open Screen Recording settings", "buddy://settings", "buddy://settings/",
                       "buddy://settings/screen-recording/extra", "buddy://settings/unknown",
                       "buddy://other/screen-recording", "https://settings/screen-recording",
                       "buddy://settings/screen-recording?x=1", "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                       "buddy://settings//microphone", "buddy://settings/microphone/", "buddy://user@settings/microphone",
                       "buddy://settings:80/microphone", "buddy://settings/screen%2Drecording", "BUDDY://settings/microphone"] {
            #expect(SettingsLink.url(for: prompt) == nil, "\(prompt)")
        }
        #expect(SettingsLink.url(for: "  buddy://settings/microphone\n") == PermissionKind.microphone.settingsURL)
    }
}
