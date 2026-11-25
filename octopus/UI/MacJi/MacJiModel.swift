//
//  MacJiModel.swift
//  octopus
//
//  State for the MacJi panel: the typed term, ranked results, keyboard
//  selection, hover and copy feedback.
//

import AppKit

@MainActor
final class MacJiModel: ObservableObject {
    /// Fixed so arrow keys move through the same rows the grid draws.
    nonisolated static let columnCount = 8

    @Published private(set) var trigger = MacJiSettings.defaultTrigger
    @Published private(set) var query = ""
    @Published private(set) var results: [Emoji] = []
    /// The selected emoji character; the first result after each new term.
    @Published var selection: String?
    @Published var hovered: Emoji?
    @Published private(set) var lastCopied: Emoji?
    /// Bumped on every copy so copying the same emoji twice re-shows the badge.
    @Published private(set) var copyCount = 0

    private let catalog: EmojiCatalog

    init(catalog: EmojiCatalog = .bundled) {
        self.catalog = catalog
    }

    var selectedEmoji: Emoji? {
        results.first { $0.emoji == selection }
    }

    /// The pointer wins over the keyboard so the shown name matches what is under it.
    var focusedEmoji: Emoji? {
        hovered ?? selectedEmoji
    }

    func update(query: String, trigger: String) {
        self.trigger = trigger
        guard query != self.query else { return }
        self.query = query
        results = MacJiSearch.results(for: query, in: catalog)
        selection = results.first?.emoji
        hovered = nil
    }

    /// Clears per-session feedback so the next open starts fresh.
    func reset() {
        query = ""
        results = []
        selection = nil
        hovered = nil
        lastCopied = nil
    }

    func moveSelection(_ key: MenuKey) {
        selection = MenuGridNavigator.move(selection, key, in: Self.rows(of: results.map(\.emoji)))
    }

    /// Returns false when the clipboard refused the text.
    @discardableResult
    func copy(_ emoji: Emoji) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(emoji.emoji, forType: .string) else { return false }
        lastCopied = emoji
        copyCount += 1
        return true
    }

    nonisolated static func rows<ID>(of items: [ID], columns: Int = columnCount) -> [[ID]] {
        stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
    }
}
