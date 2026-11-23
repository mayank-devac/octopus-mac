//
//  EmojiPickerView.swift
//  octopus
//
//  The emoji menu-bar window: search field, category filter buttons,
//  a sectioned emoji grid and a footer naming the hovered/copied emoji.
//

import SwiftUI

struct EmojiPickerView: View {
    @StateObject private var model = EmojiPickerModel()
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 2)]

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(10)
            categoryBar
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            Divider()
            grid
            Divider()
            footer
        }
        .frame(width: 360, height: 440)
        .onAppear { searchFocused = true }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
    }

    // MARK: - Category filters

    private var categoryBar: some View {
        HStack(spacing: 2) {
            filterButton(nil, symbol: "square.grid.2x2", title: "All")
            ForEach(EmojiCategory.allCases) { category in
                filterButton(category, symbol: category.symbol, title: category.rawValue)
            }
        }
    }

    private func filterButton(_ category: EmojiCategory?, symbol: String, title: String) -> some View {
        let selected = model.category == category
        return Button { model.category = category } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.15) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if model.showsRecents {
                    section("Recently Used", emojis: model.recentEmojis)
                }
                ForEach(model.sections) { section in
                    self.section(section.category.rawValue, emojis: section.emojis)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        // A new filter starts at the top instead of keeping the old scroll offset.
        .id(model.category)
        .overlay {
            if !model.hasResults {
                Text("No emoji found")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ title: String, emojis: [Emoji]) -> some View {
        Section {
            ForEach(emojis) { emoji in
                EmojiCell(emoji: emoji, hovered: $model.hovered) { model.pick(emoji) }
            }
        } header: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .background(.bar)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let emoji = model.hovered {
                Text(emoji.emoji).font(.title2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(emoji.description.capitalized).lineLimit(1)
                    if let alias = emoji.aliases.first {
                        Text(":\(alias):").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let emoji = model.lastCopied {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Copied \(emoji.emoji) to clipboard")
            } else {
                Text("Click an emoji to copy it").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

/// One emoji button; reports hover to the footer and highlights itself.
private struct EmojiCell: View {
    let emoji: Emoji
    @Binding var hovered: Emoji?
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            Text(emoji.emoji)
                .font(.system(size: 24))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered == emoji ? Color.primary.opacity(0.1) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = emoji
            } else if hovered == emoji {
                hovered = nil
            }
        }
    }
}
