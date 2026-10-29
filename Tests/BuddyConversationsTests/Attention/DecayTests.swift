import BuddyCore
import Foundation
import Testing
@testable import BuddyConversations

@Suite("Attention · decay")
struct DecayTests {
    @Test("bands at the 15 min, 2 h, 6 h and 8 h boundaries", arguments: [
        (0.0, Decay.Band.fresh), (14.99, .fresh), (15, .recent), (119.99, .recent), (120, .idle),
        (359.99, .idle), (360, .stale), (479.99, .stale), (480, .expired), (10_000, .expired),
    ])
    func bands(minutes: Double, band: Decay.Band) {
        #expect(Decay.band(age: minutes * 60) == band)
    }

    @Test("the later of last use and finish counts")
    func lastTouched() {
        let s = session("a", seen(at: ago(5)), used: hoursAgo(3), finished: ago(5))
        #expect(Decay.state(of: s, now: t0) == .resting(.fresh))
    }

    @Test("states from status", arguments: [
        (running(since: ago(3)), AttentionState.running(since: ago(3), progress: nil)),
        (needs(since: ago(40)), .needsYou(since: ago(40))),
        (unread(at: ago(30)), .readyUnread(finishedAt: ago(30))),
        (unread(at: hoursAgo(4)), .resting(.idle)), // unseen for 4 h → plain finished
        (seen(at: ago(30)), .resting(.recent)),
        (failedStatus, .failed),
        (.interrupted(at: hoursAgo(7)), .resting(.stale)),
        (.idle, .resting(.expired)),
    ])
    func states(status: SessionStatus, state: AttentionState) {
        let finished: Date? = switch status {
        case .done(let at, _), .interrupted(let at): at
        default: nil
        }
        let s = session("a", status, used: hoursAgo(9), finished: finished)
        #expect(Decay.state(of: s, now: t0) == state)
    }

    @Test("live states never fade, even when last used long ago")
    func live() {
        for status in [running(since: hoursAgo(20)), needs(since: hoursAgo(20)), unread(at: ago(1))] {
            #expect(Decay.state(of: session("a", status, used: hoursAgo(20)), now: t0).isLive)
        }
        #expect(!Decay.state(of: session("a", failedStatus), now: t0).isLive)
    }
}
