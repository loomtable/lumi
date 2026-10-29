import BuddyCore
import Foundation

/// One running query's capsule at the top centre: its session's glyph and short title, and a
/// live line of what it's doing ("Searching the web for “QT”"). The line comes from a real
/// event (StatusMapper, the Trail's verb); it names files, hosts and searches, never contents.
nonisolated public struct ProgressItem: Sendable, Equatable, Identifiable {
    /// The query: one per question sent, never reused.
    public var id: Int
    public var title: String
    /// An SF Symbol name; the title's first letter when nil or unknown.
    public var symbol: String?
    public var color: ConversationColor
    public var line: String
    /// The session the query runs in: a click on a needs-you capsule opens it.
    public var session: SessionID?
    /// Waiting on an approval or an answer: amber, and the only capsule that takes a click.
    public var needsYou: Bool
    /// The session's teammates still working: "· +2" after the title.
    public var teammates: Int
    /// The session's latest event: 90 s without one, the line shows its age (inspire #4).
    public var lastEventAt: Date?

    public init(id: Int, title: String, symbol: String? = nil, color: ConversationColor = .ember, line: String,
                session: SessionID? = nil, needsYou: Bool = false, teammates: Int = 0) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
        self.line = line
        self.session = session
        self.needsYou = needsYou
        self.teammates = teammates
    }

    /// "+2" while two teammates work; nil with none.
    public var teammatesNote: String? { teammates > 0 ? "+\(teammates)" : nil }

    /// "B" for "Budget notes"; "L" when the title is empty.
    public var monogram: String { title.first.map { String($0).uppercased() } ?? "L" }
}

/// The running queries, in the order they were asked. Pure, so the stack's rules are tested
/// without windows: one capsule per query, oldest at the top, at most `cap` rows, then "+N".
nonisolated public struct ProgressStack: Sendable, Equatable {
    /// Rows on screen at most, counting the "+N" row.
    public static let cap = 3
    /// The longest title and line a capsule shows, in characters.
    public static let titleLimit = 24
    public static let lineLimit = 48

    public private(set) var items: [ProgressItem] = []

    public init(_ items: [ProgressItem] = []) {
        for item in items { begin(item) }
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Adds a query at the bottom; a query already running keeps its place and takes the new values.
    public mutating func begin(_ item: ProgressItem) {
        let item = Self.clipped(item)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }

    /// A new live line. Returns whether anything changed (an unknown query or the same line: no).
    @discardableResult
    public mutating func update(_ id: Int, line: String) -> Bool {
        let line = Self.clip(line, Self.lineLimit)
        guard !line.isEmpty, let i = items.firstIndex(where: { $0.id == id }), items[i].line != line else { return false }
        items[i].line = line
        return true
    }

    /// The query waits on the user ("Needs your OK"), or stopped waiting. Returns whether anything changed.
    @discardableResult
    public mutating func setNeedsYou(_ id: Int, _ needsYou: Bool, line: String? = nil) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        var item = items[i]
        item.needsYou = needsYou
        if let line { item.line = Self.clip(line, Self.lineLimit) }
        guard item != items[i] else { return false }
        items[i] = item
        return true
    }

    /// The session's latest event time. Returns whether anything changed.
    @discardableResult
    public mutating func setLastEvent(_ id: Int, _ at: Date?) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].lastEventAt != at else { return false }
        items[i].lastEventAt = at
        return true
    }

    /// The session got a title, glyph or working teammates meanwhile. Returns whether anything changed.
    @discardableResult
    public mutating func rename(_ id: Int, title: String, symbol: String?, color: ConversationColor, teammates: Int = 0) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        var renamed = items[i]
        (renamed.title, renamed.symbol, renamed.color, renamed.teammates) = (title, symbol, color, teammates)
        renamed = Self.clipped(renamed)
        guard renamed != items[i] else { return false }
        items[i] = renamed
        return true
    }

    /// The query's answer appeared, or it ended without one.
    public mutating func end(_ id: Int) {
        items.removeAll { $0.id == id }
    }

    /// What's on screen once `hidden` queries are left out (the pill or a visible page already
    /// shows them): up to `cap` rows; past that, `cap - 1` rows and "+N" for the rest.
    public func shown(hiding hidden: Set<Int> = []) -> Shown {
        let visible = items.filter { !hidden.contains($0.id) }
        guard visible.count > Self.cap else { return Shown(rows: visible, more: 0) }
        let rows = Array(visible.prefix(Self.cap - 1))
        return Shown(rows: rows, more: visible.count - rows.count)
    }

    /// The capsules on screen, top to bottom, and how many more run ("+2").
    public struct Shown: Sendable, Equatable {
        public var rows: [ProgressItem]
        public var more: Int

        public static let empty = Shown(rows: [], more: 0)

        public init(rows: [ProgressItem], more: Int) {
            self.rows = rows
            self.more = more
        }

        public var isEmpty: Bool { rows.isEmpty && more == 0 }
        /// "+2 more"; nil with nothing hidden.
        public var moreLabel: String? { more > 0 ? "+\(more) more" : nil }
    }

    static func clipped(_ item: ProgressItem) -> ProgressItem {
        var item = item
        let title = clip(item.title, titleLimit)
        item.title = title.isEmpty ? "New session" : title
        item.line = clip(item.line, lineLimit)
        return item
    }

    /// One line, at most `limit` characters, with "…" when cut.
    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
