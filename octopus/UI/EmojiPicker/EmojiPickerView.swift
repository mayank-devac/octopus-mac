//
//  EmojiPickerView.swift
//  octopus
//
//  The emoji menu-bar popover: search field, category filter buttons,
//  a sectioned emoji grid and a footer naming the selected/hovered emoji.
//  Keyboard handling lives in `EmojiPickerController`; this view only
//  reflects `model.selection`.
//

import SwiftUI

struct EmojiPickerView: View {
    @ObservedObject var model: EmojiPickerModel
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: EmojiPickerModel.columnCount)

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
        .onChange(of: model.openCount) { searchFocused = true }
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
        .help("\(title) (Tab / Shift-Tab)")
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groups) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            // A new filter starts at the top instead of keeping the old scroll offset.
            .id(model.category)
            .onChange(of: model.selection) { _, slot in
                if let slot { proxy.scrollTo(slot) }
            }
        }
        .overlay {
            if model.groups.isEmpty {
                Text("No emoji found")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ group: EmojiGroup) -> some View {
        Section {
            ForEach(group.emojis) { emoji in
                let slot = EmojiSlot(group: group.title, emoji: emoji.emoji)
                EmojiCell(emoji: emoji, isSelected: model.selection == slot, hovered: $model.hovered) {
                    model.selection = slot
                    model.pick(emoji)
                }
                .id(slot)
            }
        } header: {
            Text(group.title)
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
            if let emoji = model.hovered ?? model.selectedEmoji {
                Text(emoji.emoji).font(.title2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(emoji.description.capitalized).lineLimit(1)
                    if let alias = emoji.aliases.first {
                        Text(":\(alias):").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let emoji = model.lastCopied {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Copied \(emoji.emoji)")
            }
            Spacer()
            Text("↩ copy  ⌥↩ keep open  ⇥ filter  esc close")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

/// One emoji button; highlights for keyboard selection and pointer hover.
private struct EmojiCell: View {
    let emoji: Emoji
    let isSelected: Bool
    @Binding var hovered: Emoji?
    let onPick: () -> Void

    private var highlight: Color {
        if isSelected { return Color.accentColor.opacity(0.3) }
        return hovered == emoji ? Color.primary.opacity(0.1) : .clear
    }

    var body: some View {
        Button(action: onPick) {
            Text(emoji.emoji)
                .font(.system(size: 24))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(highlight))
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
