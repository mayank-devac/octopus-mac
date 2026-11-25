//
//  MacJiView.swift
//  octopus
//
//  The MacJi panel: the typed term, a grid of ranked results and a footer
//  with key hints. Resting on an emoji (pointer or keyboard) names it.
//  Keys are handled by `MacJiController`; this view reflects the model.
//

import SwiftUI

struct MacJiView: View {
    static let cardSize = CGSize(width: 320, height: 236)
    /// How long the pointer or selection must rest before the name appears.
    private static let nameDelay = Duration.milliseconds(550)

    @ObservedObject var model: MacJiModel
    let onPick: (Emoji) -> Void
    @State private var showsCopied = false
    @State private var showsName = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: MacJiModel.columnCount)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
            Divider()
            footer
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .menuCard(cornerRadius: 12)
        .padding(MenuShadowMargin.size)
        .task(id: model.focusedEmoji?.emoji) { await revealName() }
        .task(id: model.copyCount) { await flashCopied() }
    }

    ////////////////////
    //// Delayed feedback
    /// A new focus or copy cancels the running task, restarting its timer.

    private func revealName() async {
        showsName = false
        guard model.focusedEmoji != nil, (try? await Task.sleep(for: Self.nameDelay)) != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { showsName = true }
    }

    private func flashCopied() async {
        guard model.copyCount > 0 else { return }
        withAnimation(.easeOut(duration: 0.15)) { showsCopied = true }
        guard (try? await Task.sleep(for: .seconds(1.2))) != nil else { return }
        withAnimation(.easeIn(duration: 0.2)) { showsCopied = false }
    }

    //// Both tasks restart when their id changes.
    //////////////////

    private var header: some View {
        HStack(spacing: 6) {
            Text("MacJi")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(model.trigger + model.query)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if !model.results.isEmpty {
                Text("\(model.results.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.results) { emoji in
                        EmojiCell(emoji: emoji, isSelected: model.selection == emoji.emoji, hovered: $model.hovered) {
                            onPick(emoji)
                        }
                        .id(emoji.emoji)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            // A new term starts at the top instead of keeping the old scroll offset.
            .id(model.query)
            .onChange(of: model.selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
        .overlay {
            if model.results.isEmpty {
                Text("No emoji for “\(model.query)”")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottom) {
            if showsCopied { EmojiCopiedBadge(emoji: model.lastCopied) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if showsName, let emoji = model.focusedEmoji {
                Text(emoji.emoji).font(.system(size: 18))
                Text(emoji.description.capitalized)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                KeyHint(key: "↩", label: "Insert")
                KeyHint(key: "⇧↩", label: "Copy")
                KeyHint(key: "esc", label: nil)
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}
