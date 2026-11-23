//
//  EmojiPickerModel.swift
//  octopus
//
//  State for the emoji picker: search text, category filter, hover/copy
//  feedback and the persisted recents list.
//

import AppKit

@MainActor
final class EmojiPickerModel: ObservableObject {
    @Published var query = "" { didSet { refreshSections() } }
    /// `nil` shows all categories.
    @Published var category: EmojiCategory? = nil { didSet { refreshSections() } }
    @Published var hovered: Emoji?
    @Published private(set) var sections: [EmojiSection] = []
    @Published private(set) var recentEmojis: [Emoji] = []
    @Published private(set) var lastCopied: Emoji?

    private let catalog: EmojiCatalog
    private let defaults: UserDefaults

    init(catalog: EmojiCatalog = .bundled, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: EmojiPickerSettings.recentsKey) ?? []
        recentEmojis = catalog.emojis(for: stored)
        refreshSections()
    }

    /// Recents only appear while browsing everything, like the system picker.
    var showsRecents: Bool {
        category == nil && query.allSatisfy(\.isWhitespace) && !recentEmojis.isEmpty
    }

    var hasResults: Bool { showsRecents || !sections.isEmpty }

    /// Copies the emoji to the clipboard and records it as recently used.
    func pick(_ emoji: Emoji) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(emoji.emoji, forType: .string) else { return }
        lastCopied = emoji
        let recents = EmojiPickerSettings.recents(adding: emoji.emoji, to: recentEmojis.map(\.emoji))
        defaults.set(recents, forKey: EmojiPickerSettings.recentsKey)
        recentEmojis = catalog.emojis(for: recents)
    }

    private func refreshSections() {
        sections = catalog.sections(matching: query, in: category)
    }
}
