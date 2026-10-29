import Foundation

/// A session's short title and SF Symbol, as the answering model proposed it on turn 1 or 3.
/// Raw: `TopicValidator` checks both fields before anything shows them.
public struct SessionTopic: Codable, Sendable, Equatable {
    /// 2–4 words once validated.
    public var title: String
    /// An SF Symbol name from Lumi's allowlist once validated.
    public var symbol: String?

    public init(title: String, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    /// Lenient: a blank title fails the topic; a blank or non-string symbol is just nil.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "empty title")
        }
        self.title = title
        let symbol = ((try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.symbol = symbol?.isEmpty == false ? symbol : nil
    }

    private enum CodingKeys: String, CodingKey { case title, symbol }
}
