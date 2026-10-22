import Foundation

/// The `buddy` answer block: the last fenced block of every final message.
public struct BuddyBlock: Codable, Sendable, Equatable {
    /// One or two sentences written to be heard. The first has at most 15 words.
    public var say: String
    public var shape: Shape
    /// Self-contained HTML (inline CSS and SVG) that works in light and dark.
    public var cardHTML: String?
    public var points: [Point]
    /// At most three. Pressing one sends its prompt to Deep.
    public var actions: [Action]
    public var insert: String?
    public var handoff: Handoff?
    /// A "Needs your OK" card: display only, it never grants anything. Approval stays
    /// engine-written (`Question.isApprovedAction`). Only ever true on a `rich` card with actions.
    public var needsApproval: Bool
    /// A page the turn itself created, such as a connector draft: shown as a button with its domain,
    /// opened only when the user presses it. Always https; anything else decodes as nil.
    public var link: Link?

    public enum Shape: String, Codable, Sendable {
        /// Next to the anchor, no header, no tail.
        case chip
        /// Next to the anchor, with a tail.
        case card
        /// Centred on the display.
        case rich
    }

    public enum Handoff: String, Codable, Sendable {
        case deep
        case research
    }

    /// An exact on-screen quote to ring for 6 s.
    public struct Point: Codable, Sendable, Equatable {
        public var quote: String
        public var label: String

        public init(quote: String, label: String) {
            self.quote = quote
            self.label = label
        }
    }

    public struct Link: Codable, Sendable, Equatable {
        public var label: String
        public var url: URL

        /// Only `https` URLs with a host: never `http`, `file`, `buddy` or an app's own scheme.
        public init?(label: String, url: URL) {
            guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return nil }
            self.label = label
            self.url = url
        }

        /// What the button shows next to the label, so it's clear where it goes.
        public var domain: String { url.host() ?? "" }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let label = try c.decode(String.self, forKey: .label).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = try c.decode(String.self, forKey: .url).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, let url = URL(string: raw), let link = Link(label: label, url: url) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not an https link")
            }
            self = link
        }

        private enum CodingKeys: String, CodingKey { case label, url }
    }

    public struct Action: Codable, Sendable, Equatable {
        public var label: String
        public var prompt: String

        public init(label: String, prompt: String) {
            self.label = label
            self.prompt = prompt
        }
    }

    public static let maxActions = 3

    public init(
        say: String,
        shape: Shape,
        cardHTML: String? = nil,
        points: [Point] = [],
        actions: [Action] = [],
        insert: String? = nil,
        handoff: Handoff? = nil,
        needsApproval: Bool = false,
        link: Link? = nil
    ) {
        self.say = say
        self.shape = shape
        self.cardHTML = cardHTML
        self.points = points
        self.actions = actions
        self.insert = insert
        self.handoff = handoff
        self.needsApproval = needsApproval
        self.link = link
    }

    enum CodingKeys: String, CodingKey {
        case say, shape, points, actions, insert, handoff
        case cardHTML = "card_html"
        case needsApproval = "needs_ok"
        case link
    }

    /// The block comes from model output, so decoding is lenient: only `say` is required.
    /// Missing optional fields default, malformed points or actions are skipped one by one (a bare
    /// string point is read as its quote, labelled by position), extra actions are dropped,
    /// `needs_ok` counts only on a `rich` card with actions, an unknown `handoff`
    /// means no handoff, and an unknown or missing `shape` falls back to `card` when there
    /// is HTML to show and `chip` otherwise. Losing a whole answer over one bad enum value
    /// would be worse than a slightly wrong placement.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = try c.decode(String.self, forKey: .say)
        cardHTML = try c.decodeIfPresent(String.self, forKey: .cardHTML)
        let rawShape = try c.decodeIfPresent(String.self, forKey: .shape)?.lowercased()
        shape = rawShape.flatMap(Shape.init(rawValue:)) ?? (cardHTML == nil ? .chip : .card)
        let rawPoints = (try? c.decodeIfPresent([Lossy<RawPoint>].self, forKey: .points)) ?? nil
        points = (rawPoints ?? []).enumerated().compactMap { index, raw in
            switch raw.value {
            case .point(let point): point
            case .quote(let quote): quote.isEmpty ? nil : Point(quote: quote, label: String(index + 1))
            case nil: nil
            }
        }
        let allActions = (try? c.decodeIfPresent([Lossy<Action>].self, forKey: .actions))?.compactMap(\.value) ?? []
        actions = Array(allActions.prefix(Self.maxActions))
        insert = try c.decodeIfPresent(String.self, forKey: .insert)
        let rawHandoff = try c.decodeIfPresent(String.self, forKey: .handoff)?.lowercased()
        handoff = rawHandoff.flatMap(Handoff.init(rawValue:))
        let flagged = ((try? c.decodeIfPresent(Bool.self, forKey: .needsApproval)) ?? nil) == true
        needsApproval = flagged && shape == .rich && !actions.isEmpty
        link = (try? c.decodeIfPresent(Link.self, forKey: .link)) ?? nil
    }
}

/// A point as the model wrote it: the `{quote, label}` object, or just the quoted string.
private enum RawPoint: Decodable {
    case point(BuddyBlock.Point)
    case quote(String)

    init(from decoder: any Decoder) throws {
        if let quote = try? String(from: decoder) {
            self = .quote(quote)
        } else {
            self = .point(try BuddyBlock.Point(from: decoder))
        }
    }
}

/// Decodes one array element, yielding nil instead of failing the whole array.
private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: any Decoder) throws {
        value = try? Element(from: decoder)
    }
}

extension BuddyBlock {
    /// The headline limit: the first sentence of `say` has at most 15 words.
    public static let maxHeadlineWords = 15

    /// Word count of the first sentence of `say`.
    public var headlineWordCount: Int {
        Self.firstSentence(of: say).split(whereSeparator: \.isWhitespace).count
    }

    /// Text up to the first sentence end: `.` `!` `?` `…` followed by whitespace or the end. The same
    /// rules as the evals' `buddy_rules.first_sentence`, so a headline counts the same in both. A period
    /// doesn't end the sentence after an abbreviation that never ends one ("e.g.", "Ms. Lee", but
    /// "38 ms." can), after one that can ("etc.", "p.m.") or a dotted acronym ("I.R.S.", "Ph.D.") when
    /// the next word is lower case, or after a capital initial in a name ("J. R. R. Tolkien",
    /// "by J. Smith"). Decimals and file names ("3.5", "index.ts") have no space after the dot.
    public static func firstSentence(of say: String) -> String {
        let words = say.split(whereSeparator: \.isWhitespace).map(String.init)
        for (i, token) in words.enumerated() {
            let core = trimmingTrailing(token, "\"'”’)]")
            guard let last = core.last, ".!?…".contains(last) else { continue }
            if i == words.count - 1 { break }
            if last == "." {
                let next = trimmingLeading(words[i + 1], "\"'“‘([")
                let nextUpper = next.first?.isUppercase == true
                let stem = stem(core)
                let afterNumber = i > 0 && words[i - 1].last?.isNumber == true
                // "Ms. Lee" never ends a sentence; "38 ms." (a unit after a number) can.
                if neverEnd.contains(stem), !(stem == "ms" && afterNumber) { continue }
                if stem == "ms", afterNumber, !nextUpper { continue }
                if canEnd.contains(stem) || stem.contains("."), !nextUpper { continue }
                if isInitial(core) {
                    let previous = i > 0 ? words[i - 1] : ""
                    let inRun = isInitial(previous) || (i + 1 < words.count && isInitial(words[i + 1]))
                    // "by J. Smith", "Ask J. Smith" (sentence start), but not "Plan A. It…".
                    let beforeName = nextUpper && (i <= 1 || previous.isEmpty || previous.first?.isLowercase == true)
                    if inRun || beforeName { continue }
                }
            }
            return words[...i].joined(separator: " ")
        }
        return words.joined(separator: " ")
    }

    /// Never end a sentence: they introduce what follows.
    private static let neverEnd: Set<String> = [
        "e.g", "i.e", "vs", "mr", "mrs", "ms", "dr", "st", "no", "fig", "approx", "jr", "sr", "dept", "cf",
    ]
    /// End a sentence only when the next word starts with a capital ("…ends at 5 p.m. Then…").
    private static let canEnd: Set<String> = ["etc", "a.m", "p.m", "inc", "ltd", "co", "est", "min", "max"]

    private static func stem(_ token: String) -> String {
        let bare = trimming(token, "\"'“”‘’()[]")
        return trimmingLeading(trimmingTrailing(bare, "."), "\"'“‘([").lowercased()
    }

    private static func isInitial(_ token: String) -> Bool {
        let core = Array(trimming(token, "\"'“”‘’()[]"))
        return core.count == 2 && core[0].isLetter && core[0].isUppercase && core[1] == "."
    }

    private static func trimming(_ s: String, _ set: String) -> String {
        trimmingTrailing(trimmingLeading(s, set), set)
    }

    private static func trimmingLeading(_ s: String, _ set: String) -> String {
        String(s.drop(while: { set.contains($0) }))
    }

    private static func trimmingTrailing(_ s: String, _ set: String) -> String {
        var s = Substring(s)
        while let last = s.last, set.contains(last) { s = s.dropLast() }
        return String(s)
    }
}
