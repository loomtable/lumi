import BuddyCore
import Foundation

/// Sends a session only what changed on screen since it last looked (packet). The
/// front app, window, selection, cursor, question and conversation always go; the slower fields
/// below are left out when they're byte-for-byte what the session last got, and named in
/// `unchanged`. The screenshot is left out when the engine's screen token says the session
/// already has that very image (`screenshot_unchanged_since_turn`). A session with no record
/// gets everything: a repeat beats a gap.
enum ScreenDelta {
    /// Fields that may be left out, with how to read and clear each one.
    static let fields: [(key: String, encode: @Sendable (ContextPacket) -> Data?, clear: @Sendable (inout ContextPacket) -> Void)] = [
        ("browser", { enc($0.browser) }, { $0.browser = nil }),
        ("local_server", { enc($0.localServer) }, { $0.localServer = nil }),
        ("terminal", { enc($0.terminal) }, { $0.terminal = nil }),
        ("editor", { enc($0.editor) }, { $0.editor = nil }),
        ("chat", { enc($0.chat) }, { $0.chat = nil }),
        ("finder", { enc($0.finder) }, { $0.finder = nil }),
        ("display", { enc($0.display) }, { $0.display = nil }),
        ("recent", { enc($0.recent) }, { $0.recent = nil }),
    ]

    private static func enc<T: Encodable>(_ value: T?) -> Data? {
        value.flatMap { try? ContextPacket.makeEncoder().encode($0) }
    }

    static func encoded(_ packet: ContextPacket) -> [String: Data] {
        var out: [String: Data] = [:]
        for field in fields { out[field.key] = field.encode(packet) }
        return out
    }

    /// `detail` goes only with `image`: without it, `screenshot_detail` is cleared too.
    static func apply(_ packet: ContextPacket, image: TurnInput.Image?, detail: TurnInput.Image? = nil, token: String?,
                      seen: SeenScreen?) -> (ContextPacket, [TurnInput.Image]) {
        var packet = packet
        if image == nil || detail == nil { packet.screenshotDetail = nil }
        let images = image.map { [$0] + (detail.map { [$0] } ?? []) } ?? []
        guard let seen else { return (packet, images) }
        var out = packet
        var unchanged: [String] = []
        for field in fields {
            guard let now = field.encode(packet), seen.fields[field.key] == now else { continue }
            field.clear(&out)
            unchanged.append(field.key)
        }
        out.unchanged = unchanged.isEmpty ? nil : unchanged
        guard image != nil else { return (out, []) }
        if let token, token == seen.token {
            // The path stays: a session with tools can still open this capture to look closer.
            out.screenshotUnchangedSinceTurn = seen.turn
            out.screenshotDetail = nil
            return (out, [])
        }
        return (out, images)
    }

    /// The record after `packet` was sent. The screenshot part moves on only when an image went.
    static func seen(_ packet: ContextPacket, token: String?, sentImage: Bool, before: SeenScreen?) -> SeenScreen {
        let turn = packet.conversation?.turn ?? 0
        return SeenScreen(token: sentImage ? token : before?.token, turn: sentImage ? turn : before?.turn ?? turn,
                          fields: encoded(packet))
    }
}
