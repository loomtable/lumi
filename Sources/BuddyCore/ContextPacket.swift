import Foundation

/// The JSON packet sent with every question. Built in under 200 ms with no AI;
/// any field that isn't ready is left out (encoded as absent, not null).
///
/// Keys beyond the basic packet, one per app kind, so the buddy plugin's
/// find-context skill can rely on them:
/// - `terminal {cwd, command}`: the front tab's process tree.
/// - `editor {workspace, file}`: workspace folder and open file.
/// - `chat {channel, thread}`: channel or thread.
/// - `finder {folder, selected}`: front folder and selected file paths.
/// - `window.document`: the AX document path (the document kind's file path).
/// - `selection {text?, length, truncated, bounds?, bounds_source?}`: an object, not a bare
///   string. A caret or the text-marker path can give bounds without text.
/// - Coordinates (`selection.bounds`, `cursor.x/y`) are global points, top-left origin.
/// `browser` is omitted when the URL is unknown (Firefox gives only the window title).
public struct ContextPacket: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public enum ScreenshotUnavailable: String, Codable, Sendable {
        /// Screen Recording isn't granted.
        case notGranted = "not_granted"
        /// The capture failed (after one retry); it may work next time.
        case captureFailed = "capture_failed"
    }

    public var v: Int = ContextPacket.currentVersion
    public var askedAt: Date
    public var utterance: String
    public var app: App?
    public var window: Window?
    public var browser: Browser?
    public var localServer: LocalServer?
    public var terminal: Terminal?
    public var editor: Editor?
    public var chat: Chat?
    public var finder: Finder?
    public var selection: Selection?
    public var editable: Editable?
    public var cursor: Cursor?
    public var screenshot: String?
    /// Why there's no `screenshot`; absent when there is one. The buddy-answer skill then says
    /// so truthfully instead of "I can't see your screen".
    public var screenshotUnavailable: ScreenshotUnavailable?
    /// Features the user switched off in Settings, so the answer leaves them out. Absent when all on.
    public var features: Features?
    public var display: Display?
    public var recent: [RecentApp]?
    public var conversation: Conversation?
    /// Fields left out because they're exactly what this session saw last time (`browser`,
    /// `recent`, …): they still hold. Set by the bridge per session, never by the builder.
    public var unchanged: [String]?
    /// The screen hasn't changed since the screenshot this session got on that turn, so no new
    /// image is attached. Unlike `screenshot_unavailable`, the earlier screenshot still shows it.
    public var screenshotUnchangedSinceTurn: Int?
    /// What the second image shows: a close-up at full resolution around the selected text
    /// (global points). Absent when no close-up was attached.
    public var screenshotDetail: Rect?

    public init(askedAt: Date, utterance: String) {
        self.askedAt = askedAt
        self.utterance = utterance
    }

    public enum AppKind: String, Codable, Sendable {
        case browser, editor, terminal, chat, document, finder, other
    }

    public struct App: Codable, Sendable, Equatable {
        public var name: String
        /// Nil for unbundled processes.
        public var bundle: String?
        public var kind: AppKind

        public init(name: String, bundle: String?, kind: AppKind) {
            self.name = name
            self.bundle = bundle
            self.kind = kind
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public var title: String?
        public var document: String?
        /// The focused window's frame in global points (top-left origin), so the model knows
        /// what a window-cropped screenshot shows.
        public var bounds: Rect?

        public init(title: String? = nil, document: String? = nil, bounds: Rect? = nil) {
            self.title = title
            self.document = document
            self.bounds = bounds
        }
    }

    public struct Browser: Codable, Sendable, Equatable {
        public var url: String
        public var host: String?
        public var tabTitle: String?

        public init(url: String, host: String? = nil, tabTitle: String? = nil) {
            self.url = url
            self.host = host
            self.tabTitle = tabTitle
        }

        enum CodingKeys: String, CodingKey {
            case url, host
            case tabTitle = "tab_title"
        }
    }

    public struct LocalServer: Codable, Sendable, Equatable {
        public var port: Int
        public var pid: Int32
        public var cwd: String?
        public var command: String?

        public init(port: Int, pid: Int32, cwd: String? = nil, command: String? = nil) {
            self.port = port
            self.pid = pid
            self.cwd = cwd
            self.command = command
        }
    }

    public struct Terminal: Codable, Sendable, Equatable {
        public var cwd: String?
        public var command: String?

        public init(cwd: String? = nil, command: String? = nil) {
            self.cwd = cwd
            self.command = command
        }
    }

    public struct Editor: Codable, Sendable, Equatable {
        public var workspace: String?
        public var file: String?

        public init(workspace: String? = nil, file: String? = nil) {
            self.workspace = workspace
            self.file = file
        }
    }

    public struct Chat: Codable, Sendable, Equatable {
        public var channel: String?
        public var thread: String?

        public init(channel: String? = nil, thread: String? = nil) {
            self.channel = channel
            self.thread = thread
        }
    }

    public struct Finder: Codable, Sendable, Equatable {
        public var folder: String?
        public var selected: [String]?

        public init(folder: String? = nil, selected: [String]? = nil) {
            self.folder = folder
            self.selected = selected
        }
    }

    /// The user's toggles: rings on screen, and the Insert / Replace button.
    public struct Features: Codable, Sendable, Equatable {
        /// False: write no `points` and no jump links.
        public var rings: Bool
        /// False: write no `insert`; the card's main button is only Copy.
        public var insert: Bool

        public init(rings: Bool, insert: Bool) {
            self.rings = rings
            self.insert = insert
        }

        /// Nil when everything is on, so the key is left out.
        public static func unlessAllOn(rings: Bool, insert: Bool) -> Features? {
            rings && insert ? nil : Features(rings: rings, insert: insert)
        }
    }

    /// Whether the focused element takes text, so an answer can be put there (Insert) or replace
    /// the selection (Replace). Read from AX "settable" flags only, never the field's content.
    /// Absent when there's no editable field in front.
    public struct Editable: Codable, Sendable, Equatable {
        /// The focused element is a text field or area the user can type in (never a secure one).
        public var field: Bool
        /// The selection is inside that field (so it can be replaced).
        public var selection: Bool

        public init(field: Bool, selection: Bool) {
            self.field = field
            self.selection = selection
        }
    }

    public struct Selection: Codable, Sendable, Equatable {
        /// Longer selections are cut to this many characters (⌘A in a big document).
        public static let maxTextLength = 8_000

        /// The selected text, capped at `maxTextLength`. Nil when only bounds are known.
        public var text: String?
        /// Length of the full selection in characters, before capping.
        public var length: Int
        public var truncated: Bool
        /// Screen rect in global points (top-left origin), when it can be found.
        public var bounds: Rect?
        public var boundsSource: BoundsSource?

        /// How the bounds were found, so rings know how far to trust them.
        public enum BoundsSource: String, Codable, Sendable {
            case axRange = "ax_range"
            case axTextMarker = "ax_text_marker"
            case ocr
        }

        public init(text: String?, bounds: Rect? = nil, boundsSource: BoundsSource? = nil) {
            let full = text ?? ""
            self.text = text.map { String($0.prefix(Self.maxTextLength)) }
            self.length = full.count
            self.truncated = full.count > Self.maxTextLength
            self.bounds = bounds
            self.boundsSource = boundsSource
        }

        enum CodingKeys: String, CodingKey {
            case text, length, truncated, bounds
            case boundsSource = "bounds_source"
        }
    }

    public struct Cursor: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var element: Element?

        public init(x: Double, y: Double, element: Element? = nil) {
            self.x = x
            self.y = y
            self.element = element
        }
    }

    public struct Element: Codable, Sendable, Equatable {
        public var role: String
        public var label: String?

        public init(role: String, label: String? = nil) {
            self.role = role
            self.label = label
        }
    }

    public struct Rect: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Display: Codable, Sendable, Equatable {
        public var id: UInt32
        public var scale: Double
        public var appearance: Appearance

        public enum Appearance: String, Codable, Sendable {
            case light, dark
        }

        public init(id: UInt32, scale: Double, appearance: Appearance) {
            self.id = id
            self.scale = scale
            self.appearance = appearance
        }
    }

    public struct RecentApp: Codable, Sendable, Equatable {
        public var app: String
        public var title: String?
        public var cwd: String?
        public var command: String?

        public init(app: String, title: String? = nil, cwd: String? = nil, command: String? = nil) {
            self.app = app
            self.title = title
            self.cwd = cwd
            self.command = command
        }
    }

    public struct Conversation: Codable, Sendable, Equatable {
        public var id: String
        public var turn: Int
        /// The last three turns as text, for Quick follow-ups.
        public var previous: [String]

        public static let maxPrevious = 3

        /// One entry of `previous`. The cascade matches entries by text, so build them here only.
        public static func recapEntry(question: String, answer: String) -> String {
            "Q: \(question)\nA: \(answer)"
        }

        public init(id: String, turn: Int, previous: [String] = []) {
            self.id = id
            self.turn = turn
            self.previous = Array(previous.suffix(Self.maxPrevious))
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try c.decode(String.self, forKey: .id),
                turn: try c.decode(Int.self, forKey: .turn),
                previous: try c.decodeIfPresent([String].self, forKey: .previous) ?? []
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case v, utterance, app, window, browser, terminal, editor, chat, finder, selection, editable, cursor
        case screenshot, display, recent, conversation
        case screenshotUnavailable = "screenshot_unavailable"
        case features
        case unchanged
        case screenshotUnchangedSinceTurn = "screenshot_unchanged_since_turn"
        case screenshotDetail = "screenshot_detail"
        case askedAt = "asked_at"
        case localServer = "local_server"
    }
}

extension ContextPacket {
    /// Encoder matching the wire format: ISO 8601 to the second with the given zone's offset
    /// (`+05:30`; UTC encodes as `Z`), sorted keys.
    public static func makeEncoder(timeZone: TimeZone = .current) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone).format(date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
