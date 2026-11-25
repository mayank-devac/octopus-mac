//
//  MacJiSearch.swift
//  octopus
//
//  Ranks catalog matches for a short typed term so the likeliest emoji
//  comes first: "roc" puts 🚀 rocket before 🪨 rock-tagged emoji.
//

import Foundation

enum MacJiSearch {
    static let resultLimit = 64

    ////////////////////
    //// Ranked results
    /// 0 exact alias · 1 alias prefix · 2 word prefix in name or tags · 3 substring.
    // Ties keep catalog (Unicode) order.

    static func results(for query: String, in catalog: EmojiCatalog, limit: Int = resultLimit) -> [Emoji] {
        let term = query.lowercased()
        let matches = catalog.sections(matching: term).flatMap(\.emojis)
        return matches.enumerated()
            .map { (rank: rank($0.element, term), order: $0.offset, emoji: $0.element) }
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .prefix(limit)
            .map { $0.emoji }
    }

    private static func rank(_ emoji: Emoji, _ term: String) -> Int {
        if emoji.aliases.contains(term) { return 0 }
        if emoji.aliases.contains(where: { $0.hasPrefix(term) }) { return 1 }
        let words = ([emoji.description] + emoji.tags).joined(separator: " ").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains(where: { $0.hasPrefix(term) }) ? 2 : 3
    }

    //// Capped so a one-letter term stays fast to draw.
    //////////////////
}
