import Foundation
import Testing
@testable import BuddyApp
@testable import BuddyBridge
import BuddyCompanion
import BuddyCore
import BuddyOverlay

/// A missing required permission offers Fix once, after an answer closes, never in its place.
extension BuddyCoordinatorTests {
    private func answered(missing kind: PermissionKind?) async -> BuddyCoordinator {
        bridge.setScript([Self.done(BuddyBlock(say: "Yes.", shape: .chip))])
        let coordinator = makeCoordinator()
        coordinator.setMissingPermission(kind)
        await tapToTalk(coordinator)
        return coordinator
    }

    @Test func theAnswerShowsFirstThenClosingItOffersFix() async {
        let coordinator = await answered(missing: .accessibility)
        #expect(chips.last?.say == "Yes.", "the answer is never replaced")
        var granted: [PermissionKind] = []
        coordinator.onGrantPermission = { granted.append($0) }

        overlay.send(.dismissed(.clickAway))
        await settle(until: { chips.last?.say != "Yes." })
        #expect(chips.last?.say == BuddyCoordinator.permissionLine(.accessibility))
        #expect(chips.last?.actions.map(\.label) == ["Fix"])
        #expect(overlay.calls.compactMap { if case .answer(let a, _, _) = $0 { a.keepsPlacement } else { nil } } == [true, false],
                "the answer keeps its spot; the chip doesn't take one")

        overlay.send(.action(index: 0))
        await settle(until: { !granted.isEmpty })
        #expect(granted == [.accessibility])
        #expect(coordinator.phase == .idle)
    }

    @Test func itShowsOnceUntilAnotherPermissionIsMissing() async {
        let coordinator = await answered(missing: .accessibility)
        overlay.send(.dismissed(.escape))
        await settle(until: { chips.count == 2 })
        overlay.send(.dismissed(.clickAway)) // the Fix chip itself
        await settle()

        bridge.setScript([Self.done(BuddyBlock(say: "Again.", shape: .chip))])
        await tapToTalk(coordinator)
        overlay.send(.dismissed(.clickAway))
        await settle()
        #expect(chips.map(\.say) == ["Yes.", BuddyCoordinator.permissionLine(.accessibility), "Again."])

        coordinator.setMissingPermission(.screenRecording)
        bridge.setScript([Self.done(BuddyBlock(say: "Third.", shape: .chip))])
        await tapToTalk(coordinator)
        overlay.send(.dismissed(.closeButton))
        await settle(until: { chips.count == 5 })
        #expect(chips.last?.say == BuddyCoordinator.permissionLine(.screenRecording))
    }

    @Test func notAfterTheShellClosedItOrTheUserSwitchedApps() async {
        let coordinator = await answered(missing: .screenRecording)
        overlay.send(.dismissed(.appSwitched))
        await settle()
        #expect(chips.map(\.say) == ["Yes."])
        _ = coordinator
    }

    @Test func itGoesByItselfAndWhenThePermissionIsGranted() async {
        let coordinator = await answered(missing: .accessibility)
        coordinator.permissionChipLifetime = .milliseconds(10)
        overlay.send(.dismissed(.clickAway))
        await settle(until: { chips.count == 2 })
        await settle(until: { overlay.calls.last == .dismiss(.requested) })
        #expect(overlay.calls.last == .dismiss(.requested))
        #expect(coordinator.phase == .idle)

        coordinator.setMissingPermission(.screenRecording)
        coordinator.permissionChipLifetime = .seconds(60)
        bridge.setScript([Self.done(BuddyBlock(say: "Again.", shape: .chip))])
        await tapToTalk(coordinator)
        overlay.send(.dismissed(.clickAway))
        await settle(until: { chips.count == 4 })
        coordinator.setMissingPermission(nil)
        #expect(overlay.calls.last == .dismiss(.requested))
        #expect(coordinator.phase == .idle)
    }

    @Test func aReportOpenedByTheSameClickKeepsTheChipForLaterAndIsntClosedByAGrant() async {
        let coordinator = await answered(missing: .accessibility)
        overlay.send(.dismissed(.clickAway)) // the capsule click closes the answer…
        overlay.send(.openReport(UUID()))     // …and opens the report
        await settle(until: { chips.count == 2 })
        await settle()
        coordinator.setMissingPermission(nil)
        #expect(!overlay.calls.contains(.dismiss(.requested)), "the report card stays")
        #expect(coordinator.phase == .showing)

        coordinator.setMissingPermission(.screenRecording)
        overlay.send(.dismissed(.closeButton))
        await settle(until: { chips.count == 3 })
        #expect(chips.last?.say == BuddyCoordinator.permissionLine(.screenRecording))
    }
}
