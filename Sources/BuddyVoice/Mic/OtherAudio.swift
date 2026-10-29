import BuddyCore
import Foundation
import os

/// Whether a capture takes the Voice Isolation path (U57). Starting the voice-processing unit
/// cold costs about 1.2 s to a live mic, so it's worth it only when other audio can bleed into
/// the mic: another process is outputting and the output plays out loud (speakers, unmuted).
/// Through headphones or AirPods, or muted, a plain capture is clean and live at once. Core Audio
/// can't say how loud another process is without a tap (a new permission), so a paused browser
/// tab on speakers still counts.
enum OtherAudio {
    enum Route: Equatable, Sendable {
        /// Speakers, built-in or external: what plays can reach the mic.
        case speakers
        /// Headphones or a Bluetooth headset: it can't.
        case headphones
        /// Muted or at zero volume: nothing is heard.
        case silent
    }

    private static let log = Logger(subsystem: BuddyCore.bundleIdentifier, category: "voice")

    /// `players`: the other processes outputting, by bundle ID. Logs the IDs that turned Voice
    /// Isolation on (IDs only).
    static func usesVoiceIsolation(players: [String], route: Route) -> Bool {
        guard !players.isEmpty, route == .speakers else { return false }
        log.notice("Voice isolation for this capture; other audio from \(players.joined(separator: ","), privacy: .public)")
        return true
    }
}
