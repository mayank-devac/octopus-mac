//
//  EmojiPickerComponents.swift
//  octopus
//
//  Views shared by the menu-bar emoji picker and MacJi: emoji cells,
//  footer keycaps and the "Copied" badge.
//

import SwiftUI

/// Confirms a copy; shown briefly over the bottom of the grid.
struct EmojiCopiedBadge: View {
    let emoji: Emoji?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Copied \(emoji?.emoji ?? "")")
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
}

/// One footer shortcut: a small keycap with an optional caption.
struct KeyHint: View {
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
struct EmojiCell: View {
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
