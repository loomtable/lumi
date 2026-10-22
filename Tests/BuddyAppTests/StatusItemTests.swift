@testable import BuddyApp
import BuddyCompanion
import Foundation
import Testing

/// The menu bar item: a left click tucks or brings back the kept answer, or
/// opens the menu when nothing is kept; a right or ⌃-click always opens the menu.
struct StatusItemTests {
    @Test func aClickTucksBringsBackOrOpensTheMenu() {
        #expect(StatusItemClick.action(secondary: false, answerShowing: true, answerKept: true) == .tuckAnswer)
        #expect(StatusItemClick.action(secondary: false, answerShowing: false, answerKept: true) == .showLastAnswer)
        #expect(StatusItemClick.action(secondary: false, answerShowing: false, answerKept: false) == .openMenu)
        for showing in [false, true] {
            for kept in [false, true] {
                #expect(StatusItemClick.action(secondary: true, answerShowing: showing, answerKept: kept) == .openMenu)
            }
        }
    }

    @Test func theMenuLeadsWithShowLastAnswerOnlyEnabledWhenOneIsKept() {
        let none = StatusMenuItem.menu(answerKept: false, problems: [], needsSetUp: false, keyName: "Right ⌥", paused: false)
        #expect(none.first == StatusMenuItem(title: "Show Last Answer", action: .showLastAnswer, enabled: false))
        let kept = StatusMenuItem.menu(answerKept: true, problems: [], needsSetUp: false, keyName: "Right ⌥", paused: true)
        #expect(kept.first?.enabled == true)
        #expect(kept.contains(StatusMenuItem(title: "Pause", action: .togglePause, checked: true)))
        #expect(kept.last == StatusMenuItem(title: "Quit Lumi", action: .quit, keyEquivalent: "q"))
        #expect(!kept.contains { $0.action == .setUp })
    }

    @Test func checkForUpdatesAndSendFeedbackSitJustAboveQuit() {
        for needsSetUp in [false, true] {
            let items = StatusMenuItem.menu(answerKept: false, problems: [], needsSetUp: needsSetUp, keyName: "Right ⌥",
                                            paused: false)
            #expect(Array(items.suffix(4)) == [
                .separator,
                StatusMenuItem(title: "Check for Updates…", action: .checkForUpdates),
                StatusMenuItem(title: "Send Feedback…", action: .sendFeedback),
                StatusMenuItem(title: "Quit Lumi", action: .quit, keyEquivalent: "q"),
            ])
        }
        #expect(StatusMenuItem.releasesURL == URL(string: "https://github.com/loomtable/lumi/releases/latest"))
    }

    /// The email carries the version, build and macOS version, and nothing else.
    @Test func feedbackEmailNamesTheVersionAndMacOSOnly() throws {
        #expect(StatusMenuItem.feedbackAddress == "hello@loomtable.com")
        let url = StatusMenuItem.feedbackURL(version: "0.1.0", build: "1", macOS: "26.0.1")
        #expect(url.absoluteString
            == "mailto:hello@loomtable.com?subject=Lumi%20feedback%20%280.1.0%2C%20build%201%29&body=%0AmacOS%2026.0.1")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path == "hello@loomtable.com")
        #expect(parts.queryItems == [URLQueryItem(name: "subject", value: "Lumi feedback (0.1.0, build 1)"),
                                     URLQueryItem(name: "body", value: "\nmacOS 26.0.1")])
        // A stray "&" or "=" in a version can't add or split a field.
        let odd = StatusMenuItem.feedbackURL(version: "1&cc=x", build: "2+3", macOS: "26.0")
        #expect(URLComponents(url: odd, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == ["subject", "body"])
    }

    @Test func macOSVersionShowsThePatchOnlyWhenThereIsOne() {
        #expect(StatusMenuItem.macOSVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == "26.0")
        #expect(StatusMenuItem.macOSVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)) == "26.1.2")
    }

    @Test func eachProblemIsOneLineThatFixesOrReopensWhereItCan() {
        let problems = [
            AppProblem(text: "needs Input Monitoring", fix: .privacy),
            AppProblem(text: "Reopen to finish", fix: nil, relaunches: true),
            AppProblem(text: "The microphone stopped working.", fix: nil),
        ]
        let items = StatusMenuItem.menu(answerKept: false, problems: problems, needsSetUp: true, keyName: "Right ⌥", paused: false)
        #expect(Array(items[2...4]) == [
            StatusMenuItem(title: "needs Input Monitoring", action: .openPane(.privacy)),
            StatusMenuItem(title: "Reopen to finish", action: .relaunch),
            StatusMenuItem(title: "The microphone stopped working.", action: nil, enabled: false),
        ])
        #expect(items[5] == .separator)
        #expect(items[6] == StatusMenuItem(title: "Set Up Lumi…", action: .setUp, keyEquivalent: ","))
    }

    /// Until setup is finished the menu offers no Settings: setup takes Open Lumi's place and ⌘,,
    /// and the key row (a Settings pane) is gone. Afterwards the menu is as before.
    @Test func setupReplacesSettingsInTheMenuUntilItIsFinished() {
        let setUp = StatusMenuItem.menu(answerKept: false, problems: [], needsSetUp: true, keyName: "Right ⌥", paused: false)
        #expect(setUp.contains(StatusMenuItem(title: "Set Up Lumi…", action: .setUp, keyEquivalent: ",")))
        #expect(!setUp.contains { $0.action == .openSettings })
        #expect(!setUp.contains { $0.action == .openPane(.keys) })
        #expect(setUp.filter { $0.keyEquivalent == "," }.count == 1)

        let done = StatusMenuItem.menu(answerKept: false, problems: [], needsSetUp: false, keyName: "Right ⌥", paused: false)
        #expect(!done.contains { $0.action == .setUp })
        #expect(done.contains(StatusMenuItem(title: "Open Lumi", action: .openSettings, keyEquivalent: ",")))
        #expect(done.contains(StatusMenuItem(title: "Lumi Key: Right ⌥…", action: .openPane(.keys))))
    }

    /// Every request for Settings (menu, ⌘,, reopen, Fix chips, `buddy://settings/…` links) goes
    /// to onboarding while setup is unfinished, then to Settings at the pane asked for.
    @Test func settingsRequestsOpenOnboardingUntilSetupIsFinished() {
        for pane in [nil] + SettingsPane.allCases.map(Optional.some) {
            #expect(SettingsRoute.route(pane, needsSetUp: true) == .onboarding)
            #expect(SettingsRoute.route(pane, needsSetUp: false) == .settings(pane))
        }
    }
}
