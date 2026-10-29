import Foundation
import Testing
@testable import BuddyVoice

/// U57: five 1.2 s mic starts with \`com.brave.Browser.helper\` outputting (a browser keeps output
/// running for paused tabs). Voice Isolation, and its cold start, only when other audio can
/// actually reach the mic.
struct OtherAudioTests {
    @Test func voiceIsolationOnlyWhenOtherAudioPlaysOutLoud() {
        let brave = ["com.brave.Browser.helper"]
        #expect(OtherAudio.usesVoiceIsolation(players: brave, route: .speakers), "on speakers it can bleed")
        #expect(!OtherAudio.usesVoiceIsolation(players: brave, route: .headphones), "in headphones it can't: the fast path")
        #expect(!OtherAudio.usesVoiceIsolation(players: brave, route: .silent), "muted: nothing to isolate from")
        #expect(!OtherAudio.usesVoiceIsolation(players: [], route: .speakers), "nothing else playing")
    }
}
