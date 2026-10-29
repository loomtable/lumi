import BuddyCore
import Foundation

/// The instant title and symbol a new session shows before any answer: the first content words of
/// the question, and a symbol from a keyword, else the origin app's default, else none (the tile
/// draws a monogram). Pure.
public enum LocalTopic {
    /// The title of a session with no words yet.
    public static let placeholder = "New session"

    public static func from(utterance: String, originBundleID: String?) -> SessionTopic {
        let words = contentWords(MarkdownPreview.line(utterance))
        var title = ""
        for word in words.prefix(4) {
            let next = title.isEmpty ? word : title + " " + word
            if next.count > TopicValidator.maxTitleLength { break }
            title = next
        }
        if title.isEmpty { title = placeholder }
        title = title.prefix(1).uppercased() + title.dropFirst()
        let symbol = keywordSymbol(words.map { $0.lowercased() }) ?? originBundleID.flatMap(appSymbol)
        return SessionTopic(title: title, symbol: symbol)
    }

    /// The question's words as typed or heard, with filler, stop words, emails and URLs dropped.
    static func contentWords(_ utterance: String) -> [String] {
        let tokens = utterance.replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(["-", "'", "@", ".", ":", "/"])) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:")) }
            .filter { !$0.isEmpty }
        let lower = tokens.map { $0.lowercased() }
        let fillerWords = fillers.map { $0.split(separator: " ").map(String.init) }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if let filler = fillerWords.first(where: { i + $0.count <= lower.count && Array(lower[i..<i + $0.count]) == $0 }) {
                i += filler.count
                continue
            }
            if !stopWords.contains(lower[i]), !tokens[i].contains("@"), !tokens[i].contains("://") { out.append(tokens[i]) }
            i += 1
        }
        return out
    }

    static let fillers = [
        "hey lumi", "hi lumi", "ok lumi", "lumi", "can you", "could you", "would you", "please", "help me", "i want to",
        "i need to", "tell me", "show me", "what's", "what is", "how do i", "how can i", "let's", "quickly",
    ]

    static let stopWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "it", "its", "it's", "is", "are", "was", "were", "be", "to",
        "of", "in", "on", "for", "with", "at", "by", "from", "and", "or", "but", "so", "me", "my", "i", "you", "your",
        "we", "our", "do", "does", "did", "here", "there", "about", "into", "up", "out", "what", "why", "how", "which",
        "who", "when", "where", "can", "could", "should", "would", "will", "just", "some", "any", "all", "um", "uh", "like",
    ]

    /// About forty stems; the first word that matches wins.
    static let keywords: [(stems: [String], symbol: String)] = [
        (["bug", "crash", "error", "fix", "debug", "broken"], "hammer"),
        (["flight", "trip", "hotel", "travel", "vacation"], "airplane"),
        (["budget", "burn", "cost", "expense", "runway"], "chart.line.downtrend.xyaxis"),
        (["revenue", "sales", "growth", "signup", "metric"], "chart.line.uptrend.xyaxis"),
        (["email", "mail", "inbox", "reply"], "envelope"),
        (["meeting", "calendar", "schedule", "standup"], "calendar"),
        (["lecture", "study", "exam", "homework", "course", "class", "learn", "lesson"], "book.closed"),
        (["design", "logo", "colour", "color", "mockup", "figma"], "paintpalette"),
        (["code", "function", "swift", "python", "repo", "test", "refactor"], "chevron.left.forwardslash.chevron.right"),
        (["deploy", "server", "database", "api"], "server.rack"),
        (["recipe", "dinner", "lunch", "food", "restaurant"], "fork.knife"),
        (["shop", "buy", "order", "cart"], "cart"),
        (["renewal", "churn", "subscription"], "arrow.triangle.2.circlepath"),
        (["research", "compare", "competitor", "pricing"], "magnifyingglass"),
        (["write", "draft", "essay", "post", "blog"], "square.and.pencil"),
        (["doc", "report", "notes", "summary"], "doc.text"),
        (["photo", "image", "picture"], "photo"),
        (["video", "youtube", "film", "movie", "clip"], "play.rectangle"),
        (["weather", "forecast", "rain"], "cloud.sun"),
        (["spreadsheet", "sheet", "table", "cell"], "tablecells"),
        (["plan", "todo", "tasks", "checklist"], "checklist"),
        (["settings", "config", "setup"], "gearshape"),
        (["security", "password", "login", "auth"], "lock"),
        (["invoice", "payment", "price", "tax"], "dollarsign.circle"),
        (["map", "route", "directions"], "map"),
    ]

    static func keywordSymbol(_ words: [String]) -> String? {
        for word in words {
            if let hit = keywords.first(where: { $0.stems.contains { word == $0 || word.hasPrefix($0) && word.count <= $0.count + 3 } }) {
                return hit.symbol
            }
        }
        return nil
    }

    static let apps: [String: String] = [
        "com.apple.dt.Xcode": "hammer", "com.apple.iWork.Numbers": "tablecells", "com.microsoft.Excel": "tablecells",
        "com.apple.mail": "envelope", "com.figma.Desktop": "paintpalette", "com.apple.Terminal": "terminal",
        "com.googlecode.iterm2": "terminal", "com.apple.Safari": "globe", "com.google.Chrome": "globe",
        "company.thebrowser.Browser": "globe", "org.mozilla.firefox": "globe", "com.microsoft.VSCode": "curlybraces",
        "com.apple.iWork.Pages": "doc.text", "com.apple.iWork.Keynote": "rectangle.3.group", "com.apple.Notes": "doc.text",
        "com.apple.iCal": "calendar", "com.tinyspeck.slackmacgap": "person.2", "com.apple.Preview": "doc.text",
        "com.apple.finder": "externaldrive",
    ]

    static func appSymbol(_ bundleID: String) -> String? { apps[bundleID] }
}
