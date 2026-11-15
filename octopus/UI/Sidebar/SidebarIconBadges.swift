import SwiftUI

////////////////////
//// Close / hide / quit badges on a hovered sidebar icon
/// A coloured column on the icon's leading edge (the same side as the window-count
/// badge, whichever side the sidebar is on). Each badge grows a little on hover.
/// Clicks use SidebarPointerRegion, which accepts the first click in the
// non-activating sidebar panel, like the icon itself.

enum SidebarIconBadge: CaseIterable {
    case close, hide, quit

    var symbol: String {
        switch self {
        case .close: return "xmark"
        case .hide: return "eye.slash"
        case .quit: return "power"
        }
    }

    var color: Color {
        switch self {
        case .close: return MenuPalette.badgeClose
        case .hide: return MenuPalette.badgeHide
        case .quit: return MenuPalette.badgeQuit
        }
    }

    var title: String {
        switch self {
        case .close: return SidebarIconBadgeStrings.close
        case .hide: return SidebarIconBadgeStrings.hide
        case .quit: return SidebarIconBadgeStrings.quit
        }
    }
}

struct SidebarIconBadgeColumn: View {
    /// Close needs the window under the icon; without one it is shown disabled.
    let canClose: Bool
    let onSelect: (SidebarIconBadge) -> Void

    var body: some View {
        VStack(spacing: SidebarIconBadgeMetrics.spacing) {
            ForEach(SidebarIconBadge.allCases, id: \.self) { badge in
                SidebarIconBadgeButton(badge: badge, isEnabled: badge != .close || canClose) { onSelect(badge) }
            }
        }
    }
}

private struct SidebarIconBadgeButton: View {
    let badge: SidebarIconBadge
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Metrics = SidebarIconBadgeMetrics

    var body: some View {
        Image(systemName: badge.symbol)
            .font(.system(size: Metrics.symbolSize, weight: .heavy))
            .foregroundStyle(MenuPalette.badgeSymbol)
            .frame(width: Metrics.size, height: Metrics.size)
            .background(Circle().fill(badge.color))
            .overlay(Circle().stroke(MenuPalette.badgeStroke, lineWidth: 0.75))
            .scaleEffect(isHovered && isEnabled && !reduceMotion ? Metrics.hoverScale : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(MenuMotion.hoverGrow, value: isHovered)
            .overlay {
                SidebarPointerRegion(onClick: { if isEnabled { action() } }, onAnchor: { _ in })
            }
            .onHover { isHovered = $0 }
            .help(badge.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isEnabled { action() } }
    }
}

//// The hover grow is cosmetic; clicks work even if the panel misses a hover event.
//////////////////
