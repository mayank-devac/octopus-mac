//
//  EmojiPickerTests.swift
//  octopusTests
//
//  Emoji search, category filtering and recents ordering.
//

import Testing
@testable import octopus

struct EmojiPickerTests {
    private let catalog = EmojiCatalog(emojis: [
        Emoji(emoji: "😍", description: "smiling face with heart-eyes", category: "Smileys & Emotion",
              aliases: ["heart_eyes"], tags: ["love", "crush"]),
        Emoji(emoji: "🐶", description: "dog face", category: "Animals & Nature",
              aliases: ["dog"], tags: ["pet"]),
        Emoji(emoji: "❤️", description: "red heart", category: "Smileys & Emotion",
              aliases: ["heart"], tags: ["love"]),
        Emoji(emoji: "🆕", description: "future", category: "Unknown Category", aliases: [], tags: []),
    ])

    @Test func emptyQueryGroupsEverythingByCategoryOrder() {
        let sections = catalog.sections(matching: "")
        #expect(sections.map(\.category) == [.smileys, .animals])
        #expect(sections[0].emojis.map(\.emoji) == ["😍", "❤️"])
    }

    @Test func searchMatchesNameAliasAndTagsWithEveryTerm() {
        #expect(catalog.sections(matching: "PET").flatMap(\.emojis).map(\.emoji) == ["🐶"])
        #expect(catalog.sections(matching: "love heart").flatMap(\.emojis).map(\.emoji) == ["😍", "❤️"])
        #expect(catalog.sections(matching: "love dog").isEmpty)
    }

    @Test func categoryFilterKeepsOnlyThatSection() {
        let sections = catalog.sections(matching: "", in: .animals)
        #expect(sections.map(\.category) == [.animals])
    }

    @Test func recentsMoveToFrontWithoutDuplicatesAndStayCapped() {
        let recents = EmojiPickerSettings.recents(adding: "🐶", to: ["😍", "🐶", "❤️"], limit: 2)
        #expect(recents == ["🐶", "😍"])
        #expect(catalog.emojis(for: ["🆕", "❤️"]).map(\.emoji) == ["❤️"])
    }
}
