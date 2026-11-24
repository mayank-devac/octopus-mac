//
//  EmojiPickerModel.swift
//  octopus
//
//  State for the emoji picker: search text, category filter, keyboard
//  selection, hover/copy feedback and the persisted recents list.
//

import AppKit

/// A titled block of the grid ("Recently Used" or a category).
struct EmojiGroup: Identifiable {
    let title: String
    let emojis: [Emoji]

    var id: String { title }
}

/// One grid cell. The group is part of the identity because a recent emoji
/// also appears in its own category.
struct EmojiSlot: Hashable {
    let group: String
    let emoji: String
}

@MainActor
final class EmojiPickerModel: ObservableObject {
    /// Fixed so arrow keys move through the same rows the grid draws.
    static let columnCount = 9

    @Published var query = "" { didSet { refreshGroups(selectFirst: true) } }
    /// `nil` shows all categories.
    @Published var category: EmojiCategory? = nil { didSet { refreshGroups(selectFirst: true) } }
    @Published var hovered: Emoji?
    @Published var selection: EmojiSlot?
    @Published private(set) var groups: [EmojiGroup] = []
    @Published private(set) var lastCopied: Emoji?
    /// Bumped on each open so the view can refocus the search field.
    @Published private(set) var openCount = 0

    private let catalog: EmojiCatalog
    private let defaults: UserDefaults
    private var recents: [Emoji] = []

    init(catalog: EmojiCatalog = .bundled, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        recents = catalog.emojis(for: defaults.stringArray(forKey: EmojiPickerSettings.recentsKey) ?? [])
        refreshGroups(selectFirst: false)
    }

    var selectedEmoji: Emoji? {
        selection.flatMap { catalog.emojis(for: [$0.emoji]).first }
    }

    /// Starts each open fresh: empty search, all categories, nothing selected.
    func prepareForOpen() {
        query = ""
        category = nil
        selection = nil
        hovered = nil
        lastCopied = nil
        openCount += 1
    }

    ////////////////////
    //// Keyboard actions
    /// Arrows move through the drawn rows, Tab cycles the category filters and
    // Return copies the selection, falling back to the first result.

    func moveSelection(_ key: MenuKey) {
        selection = MenuGridNavigator.move(selection, key, in: Self.grid(for: groups))
    }

    func cycleCategory(forward: Bool) {
        let filters: [EmojiCategory?] = [nil] + EmojiCategory.allCases
        let index = filters.firstIndex(of: category) ?? 0
        category = filters[(index + (forward ? 1 : filters.count - 1)) % filters.count]
    }

    /// Returns false when there is nothing to copy.
    @discardableResult
    func copySelection() -> Bool {
        guard let slot = selection ?? Self.grid(for: groups).first?.first,
              let emoji = catalog.emojis(for: [slot.emoji]).first else { return false }
        return pick(emoji)
    }

    //// Selection follows search: typing selects the first result for Return.
    //////////////////

    /// Copies the emoji to the clipboard and records it as recently used.
    @discardableResult
    func pick(_ emoji: Emoji) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(emoji.emoji, forType: .string) else { return false }
        lastCopied = emoji
        let stored = EmojiPickerSettings.recents(adding: emoji.emoji, to: recents.map(\.emoji))
        defaults.set(stored, forKey: EmojiPickerSettings.recentsKey)
        recents = catalog.emojis(for: stored)
        refreshGroups(selectFirst: false)
        return true
    }

    /// Splits each group into rows of `columns`; groups never share a row.
    static func grid(for groups: [EmojiGroup], columns: Int = columnCount) -> [[EmojiSlot]] {
        groups.flatMap { group in
            stride(from: 0, to: group.emojis.count, by: columns).map { start in
                group.emojis[start..<min(start + columns, group.emojis.count)]
                    .map { EmojiSlot(group: group.title, emoji: $0.emoji) }
            }
        }
    }

    /// Recents only appear while browsing everything, like the system picker.
    private func refreshGroups(selectFirst: Bool) {
        let browsing = category == nil && query.allSatisfy(\.isWhitespace)
        let recentGroup = browsing && !recents.isEmpty ? [EmojiGroup(title: "Recently Used", emojis: recents)] : []
        groups = recentGroup + catalog.sections(matching: query, in: category).map {
            EmojiGroup(title: $0.category.rawValue, emojis: $0.emojis)
        }
        let slots = Self.grid(for: groups).joined()
        if selectFirst {
            selection = browsing ? nil : slots.first
        } else if let selection, !slots.contains(selection) {
            self.selection = nil
        }
    }
}
