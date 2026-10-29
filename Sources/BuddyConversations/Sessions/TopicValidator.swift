import BuddyCore
import Foundation

/// Checks the model's proposed title and symbol before anything shows them. Pure: each field that
/// fails keeps the fallback's value.
public enum TopicValidator {
    /// 2–4 words, at most 24 characters, no trailing punctuation or quotes, and no email, URL or
    /// digits-only word (a title is a topic, never a secret or a number from the screen). The symbol
    /// must be in the allowlist and, where the caller can check, exist on this Mac.
    public static func validate(_ topic: SessionTopic?, fallback: SessionTopic,
                                symbolExists: (String) -> Bool = { _ in true }) -> SessionTopic {
        guard let topic else { return fallback }
        // A model may write Markdown ("**Munich** dining"): its marks go, their text stays (U49).
        let plain = MarkdownPreview.line(topic.title)
        let title = isValidTitle(plain) ? clean(plain) : fallback.title
        let symbol = topic.symbol.flatMap { SymbolAllowlist.contains($0) && symbolExists($0) ? $0 : nil } ?? fallback.symbol
        return SessionTopic(title: title, symbol: symbol)
    }

    public static let maxTitleLength = 24

    static func isValidTitle(_ raw: String) -> Bool {
        let title = clean(raw)
        let words = title.split(whereSeparator: \.isWhitespace)
        guard (2...4).contains(words.count), title.count <= maxTitleLength else { return false }
        guard let last = title.last, !".,;:!?…\"'”’)".contains(last), !"\"'“‘(".contains(title.first ?? " ") else { return false }
        return !words.contains { word in
            word.contains("@") || word.contains("://") || word.lowercased().hasPrefix("www.")
                || word.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        }
    }

    private static func clean(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The SF Symbols a session may show: shape-distinct objects only. No states (checkmarks, clocks,
/// exclamation marks), no brand logos, no chat bubbles (every session is a chat; a bubble names no
/// topic), and no insects or animals (brand rule).
public enum SymbolAllowlist {
    public static let symbols: Set<String> = [
        // Work and data
        "chart.bar", "chart.line.uptrend.xyaxis", "chart.line.downtrend.xyaxis", "chart.pie", "tablecells", "function",
        "percent", "dollarsign.circle", "banknote",
        // Code
        "hammer", "terminal", "curlybraces", "chevron.left.forwardslash.chevron.right", "server.rack", "externaldrive",
        "wrench.and.screwdriver", "cpu",
        // Writing
        "square.and.pencil", "doc.text", "text.quote", "envelope", "paperplane", "newspaper", "pencil", "list.bullet",
        // Study
        "book.closed", "graduationcap", "brain", "atom", "flask",
        // Design
        "paintpalette", "paintbrush", "photo", "play.rectangle", "rectangle.3.group", "cube",
        // People and meetings
        "person.2", "person.3", "calendar", "phone",
        // Travel and life
        "airplane", "car", "map", "house", "fork.knife", "cart", "gift", "heart", "cloud.sun",
        // Ops and process
        "arrow.triangle.2.circlepath", "checklist", "gearshape", "shippingbox", "lock", "flag",
        // Research
        "magnifyingglass", "globe", "link", "lightbulb",
    ]

    public static func contains(_ symbol: String) -> Bool { symbols.contains(symbol) }
}
