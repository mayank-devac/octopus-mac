//
//  EmojiPickerTests.swift
//  octopusTests
//
//  Emoji search, category filtering and recents ordering.
//

import AppKit
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

    @Test func gridRowsMatchColumnsAndNeverMixGroups() {
        let groups = catalog.sections(matching: "").map { EmojiGroup(title: $0.category.rawValue, emojis: $0.emojis) }
        let rows = EmojiPickerModel.grid(for: groups, columns: 1)
        #expect(rows.map { $0.map(\.emoji) } == [["😍"], ["❤️"], ["🐶"]])
        #expect(EmojiPickerModel.grid(for: groups, columns: 9).map(\.count) == [2, 1])
    }

    @Test func keysMapToPickerActionsAndLeaveTypingToSearch() {
        #expect(EmojiPickerKeyAction(keyCode: 125, modifiers: []) == .move(.down))
        #expect(EmojiPickerKeyAction(keyCode: 123, modifiers: .option) == nil)
        #expect(EmojiPickerKeyAction(keyCode: 36, modifiers: []) == .copy(keepOpen: false))
        #expect(EmojiPickerKeyAction(keyCode: 36, modifiers: .option) == .copy(keepOpen: true))
        #expect(EmojiPickerKeyAction(keyCode: 48, modifiers: .shift) == .previousCategory)
        #expect(EmojiPickerKeyAction(keyCode: 53, modifiers: []) == .cancel)
        #expect(EmojiPickerKeyAction(keyCode: 0, modifiers: []) == nil)
    }
}
