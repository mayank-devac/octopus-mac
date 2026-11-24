//
//  EmojiCatalog.swift
//  octopus
//
//  The bundled emoji database and its search. Data comes from github/gemoji
//  (`Resources/emoji.json`, MIT, notice in `LICENSES/gemoji-MIT.txt`).
//  To update it, replace the JSON with the latest `db/emoji.json` from gemoji.
//

import Foundation

/// One emoji record, decoded straight from gemoji's `emoji.json`.
struct Emoji: Decodable, Hashable, Identifiable {
    let emoji: String
    let description: String
    let category: String
    let aliases: [String]
    let tags: [String]

    var id: String { emoji }
}

/// The picker's category filters, in gemoji (Unicode) order.
/// Raw values must match gemoji's `category` strings exactly.
enum EmojiCategory: String, CaseIterable, Identifiable {
    case smileys = "Smileys & Emotion"
    case people = "People & Body"
    case animals = "Animals & Nature"
    case food = "Food & Drink"
    case travel = "Travel & Places"
    case activities = "Activities"
    case objects = "Objects"
    case symbols = "Symbols"
    case flags = "Flags"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .smileys: "face.smiling"
        case .people: "person"
        case .animals: "pawprint"
        case .food: "fork.knife"
        case .travel: "car"
        case .activities: "soccerball"
        case .objects: "lightbulb"
        case .symbols: "heart"
        case .flags: "flag"
        }
    }
}

struct EmojiSection: Identifiable {
    let category: EmojiCategory
    let emojis: [Emoji]

    var id: String { category.rawValue }
}

struct EmojiCatalog {
    /// An emoji with its parsed category and a lowercased search string.
    private struct Entry {
        let emoji: Emoji
        let category: EmojiCategory
        let keywords: String
    }

    private let entries: [Entry]
    private let byCharacter: [String: Emoji]

    /// Records with an unknown category (a newer gemoji release) are skipped
    /// until `EmojiCategory` learns about them.
    init(emojis: [Emoji]) {
        entries = emojis.compactMap { emoji in
            guard let category = EmojiCategory(rawValue: emoji.category) else { return nil }
            let keywords = ([emoji.description] + emoji.aliases + emoji.tags).joined(separator: " ").lowercased()
            return Entry(emoji: emoji, category: category, keywords: keywords)
        }
        byCharacter = Dictionary(entries.map { ($0.emoji.emoji, $0.emoji) }, uniquingKeysWith: { first, _ in first })
    }

    /// Loaded once on first use; an unreadable resource yields an empty picker.
    static let bundled = EmojiCatalog.load(from: .main)

    static func load(from bundle: Bundle) -> EmojiCatalog {
        guard let url = bundle.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let emojis = try? JSONDecoder().decode([Emoji].self, from: data)
        else { return EmojiCatalog(emojis: []) }
        return EmojiCatalog(emojis: emojis)
    }

    ////////////////////
    //// Search and filter
    /// Every whitespace-separated term must appear in the name, an alias or a tag.
    // Results keep catalog order and are grouped into non-empty category sections.

    func sections(matching query: String, in filter: EmojiCategory? = nil) -> [EmojiSection] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matched = entries.filter { entry in
            (filter == nil || entry.category == filter) && terms.allSatisfy(entry.keywords.contains)
        }
        return EmojiCategory.allCases.compactMap { category in
            let emojis = matched.filter { $0.category == category }.map(\.emoji)
            return emojis.isEmpty ? nil : EmojiSection(category: category, emojis: emojis)
        }
    }

    //// An empty query returns every section, so the picker can browse the full set.
    //////////////////

    /// Resolves stored characters (e.g. recents), dropping ones no longer in the catalog.
    func emojis(for characters: [String]) -> [Emoji] {
        characters.compactMap { byCharacter[$0] }
    }
}
