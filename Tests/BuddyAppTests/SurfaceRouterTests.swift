import BuddyCore
import BuddyOverlay
import Foundation
import Testing
@testable import BuddyApp

struct SurfaceRouterTests {
    let s = SessionID(rawValue: "s_1")
    let other = SessionID(rawValue: "s_2")
    let origin = SessionOrigin(key: ContextKey(bundleID: "com.apple.Numbers"), appName: "Numbers", windowNumber: 42)

    func input(_ kind: TurnKind, configure: (inout DeliveryInput) -> Void = { _ in }) -> DeliveryInput {
        var i = DeliveryInput(session: s, kind: kind, origin: origin)
        i.frontWindow = 42
        configure(&i)
        return i
    }

    func deliver(_ i: DeliveryInput, _ settings: DeliverySettings = DeliverySettings()) -> Delivery {
        SurfaceRouter.deliver(i, settings: settings)
    }

    @Test(arguments: [TurnKind.typed, .voiceInPage, .steer, .relay])
    func aVisiblePageTakesTheAnswerSilentlyByDefault(kind: TurnKind) {
        #expect(deliver(input(kind) { $0.visiblePages = [s: .panel] }) == .appendInPage(.panel, speak: false))
        #expect(deliver(input(kind) { $0.visiblePages = [s: .studio] }, DeliverySettings(speakTypedAnswers: true))
            == .appendInPage(.studio, speak: true))
    }

    @Test func aVoiceTurnInAVisiblePageStillSpeaks() {
        #expect(deliver(input(.voice) { $0.visiblePages = [s: .panel] }) == .appendInPage(.panel, speak: true))
    }

    @Test func aPageOnAnotherSessionDoesNotCount() {
        #expect(deliver(input(.voice) { $0.visiblePages = [other: .panel] }) == .glance(speak: true))
    }

    @Test func typedFromTheTextBoxOpensThePanel() {
        #expect(deliver(input(.typed)) == .openPanel)
    }

    @Test func typedNeverReopensAPageTheUserPutAway() {
        #expect(deliver(input(.typed) { $0.pageDismissed = true }) == .ambient(notify: nil))
        #expect(deliver(input(.typed) { $0.userIsComposingOrHolding = true }) == .ambient(notify: nil))
    }

    @Test func voiceOnTheOriginWindowGetsGlance() {
        #expect(deliver(input(.voice)) == .glance(speak: true))
        #expect(deliver(input(.action)) == .glance(speak: true))
        // No window numbers: the front app is taken as the origin, as today.
        #expect(deliver(input(.voice) { $0.frontWindow = nil }) == .glance(speak: true))
    }

    @Test func voiceElsewhereIsAmbient() {
        #expect(deliver(input(.voice) { $0.frontWindow = 7 }) == .ambient(notify: nil))
        #expect(deliver(input(.voice) { $0.userIsComposingOrHolding = true }) == .ambient(notify: nil))
    }

    @Test func awayAndRanLongGetsOneBanner() {
        #expect(deliver(input(.voice) { $0.present = false; $0.ranFor = 30 }) == .ambient(notify: .banner))
        #expect(deliver(input(.voice) { $0.present = false; $0.ranFor = 29 }) == .ambient(notify: nil))
        #expect(deliver(input(.voice) { $0.present = false; $0.ranFor = 60 }, DeliverySettings(notifyWhenAway: false))
            == .ambient(notify: nil))
        #expect(deliver(input(.typed) { $0.present = false; $0.ranFor = 60 }) == .ambient(notify: .banner))
    }

    @Test func failures() {
        #expect(deliver(input(.voice) { $0.failed = true }) == .failure(ambient: false))
        #expect(deliver(input(.voice) { $0.failed = true; $0.frontWindow = 7 }) == .failure(ambient: true))
        #expect(deliver(input(.typed) { $0.failed = true; $0.visiblePages = [s: .panel] }) == .appendInPage(.panel, speak: false))
        #expect(deliver(input(.voice) { $0.failed = true; $0.visiblePages = [s: .panel] }) == .appendInPage(.panel, speak: false))
    }

    @Test func settingsMapFromSessionSettings() {
        let d = DeliverySettings(SessionSettings(speakTypedAnswers: true, notifyWhenAway: false))
        #expect(d == DeliverySettings(speakTypedAnswers: true, notifyWhenAway: false))
    }
}

@MainActor
struct RoutedDeliveryTests {
    let s = SessionID(rawValue: "c_1")

    func answer() -> Answer {
        Answer(block: BuddyBlock(say: "Hi", shape: .chip), lane: Lane(mode: .quick, model: .haiku), conversation: .ember, turn: 1,
               replyHint: "", question: "Q", earlier: [], isLong: false, mainAction: nil)
    }

    @Test func aVisiblePageTakesTheAnswerElseTheGlance() {
        let pages = FakePageSurfaces(showing: s, kind: .panel)
        let d = RoutedDelivery(pages: pages)
        #expect(d.surface(for: answer(), conversationID: "c_1", kind: .typed) == .page(.panel))
        #expect(d.surface(for: answer(), conversationID: "c_2", kind: .typed) == .glance)
        #expect(d.surface(for: answer(), conversationID: "c_2", kind: .voice) == .glance)
        #expect(RoutedDelivery(pages: NoPageSurfaces()).surface(for: answer(), conversationID: "c_1", kind: .voice) == .glance)
    }

    @Test func mapping() {
        #expect(RoutedDelivery.surface(.ambient(notify: nil)) == .ambient)
        #expect(RoutedDelivery.surface(.failure(ambient: true)) == .ambient)
        #expect(RoutedDelivery.surface(.openPanel) == .glance)
        #expect(RoutedDelivery.surface(.appendInPage(.studio, speak: true)) == .page(.studio))
    }
}
