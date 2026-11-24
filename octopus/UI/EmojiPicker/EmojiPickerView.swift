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
    @State private var showsCopied = false

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
        .onChange(of: model.openCount) {
            searchFocused = true
            showsCopied = false
        }
    }

    // MARK: - Copied badge

    /// Shows the badge briefly after each copy; a newer copy cancels this task
    /// and restarts the timer instead of hiding the new badge early.
    private func flashCopied() async {
        guard model.copyCount > 0 else { return }
        withAnimation(.easeOut(duration: 0.15)) { showsCopied = true }
        guard (try? await Task.sleep(for: .seconds(1.2))) != nil else { return }
        withAnimation(.easeIn(duration: 0.2)) { showsCopied = false }
    }

    private var copiedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Copied \(model.lastCopied?.emoji ?? "")")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
        )
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
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.groups) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            // A legacy (always-visible) scroller would cover the last emoji column.
            .scrollIndicators(.never)
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
        .overlay(alignment: .bottom) {
            if showsCopied { copiedBadge }
        }
        .task(id: model.copyCount) { await flashCopied() }
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
            // Unpinned and transparent so it sits on the popover material, not a grey bar.
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.top, 8)
                .padding(.bottom, 2)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let emoji = model.hovered ?? model.selectedEmoji {
                Text(emoji.emoji).font(.system(size: 24))
                VStack(alignment: .leading, spacing: 1) {
                    Text(emoji.description.capitalized)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let alias = emoji.aliases.first {
                        Text(":\(alias):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 8)
            keyHints
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    // Short keycaps keep the footer on one line; the tooltip spells out every key.
    private var keyHints: some View {
        HStack(spacing: 6) {
            KeyHint(key: "↩", label: "Copy")
            KeyHint(key: "⇥", label: "Filter")
            KeyHint(key: "esc", label: nil)
        }
        .fixedSize()
        .help("Return copies and closes · Option-Return copies and stays open · Tab / Shift-Tab change category · Esc clears search, then closes")
    }
}

/// One footer shortcut: a small keycap with an optional caption.
private struct KeyHint: View {
    let key: String
    let label: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            if let label {
                Text(label).font(.system(size: 10))
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// One emoji button; highlights for keyboard selection, grows slightly on hover
/// and names itself in a tooltip when the pointer rests on it.
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
                .scaleEffect(hovered == emoji ? 1.15 : 1)
                .animation(.easeOut(duration: 0.12), value: hovered == emoji)
        }
        .buttonStyle(.plain)
        // Native tooltip: appears after the pointer rests on the emoji.
        .help(emoji.description.capitalized)
        .onHover { inside in
            if inside {
                hovered = emoji
            } else if hovered == emoji {
                hovered = nil
            }
        }
    }
}
