import SwiftUI

////////////////////
//// Close / hide / quit badges on a hovered sidebar icon
/// A coloured column on the icon's edge away from the screen edge (trailing for a
/// left sidebar, leading for a right one). Each badge grows a little on hover.
/// The hide badge follows the app's hidden state and swaps its eye symbol when it changes.
/// Clicks use SidebarPointerRegion, which accepts the first click in the
// non-activating sidebar panel, like the icon itself.

enum SidebarIconBadge: CaseIterable {
    case close, hide, quit

    // Filled eyes stay legible at the badge's 8 pt symbol size; the outline slash blurs.
    func symbol(appIsHidden: Bool) -> String {
        switch self {
        case .close: return "xmark"
        case .hide: return appIsHidden ? "eye.fill" : "eye.slash.fill"
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

    func title(appIsHidden: Bool) -> String {
        switch self {
        case .close: return SidebarIconBadgeStrings.close
        case .hide: return appIsHidden ? SidebarIconBadgeStrings.show : SidebarIconBadgeStrings.hide
        case .quit: return SidebarIconBadgeStrings.quit
        }
    }
}

struct SidebarIconBadgeColumn: View {
    /// Close needs the window under the icon; without one it is shown disabled.
    let canClose: Bool
    /// Hidden apps get a "show" eye on the hide badge, since the click unhides them.
    let appIsHidden: Bool
    let onSelect: (SidebarIconBadge) -> Void

    var body: some View {
        VStack(spacing: SidebarIconBadgeMetrics.spacing) {
            ForEach(SidebarIconBadge.allCases, id: \.self) { badge in
                SidebarIconBadgeButton(badge: badge, appIsHidden: appIsHidden,
                                       isEnabled: badge != .close || canClose) { onSelect(badge) }
            }
        }
    }
}

private struct SidebarIconBadgeButton: View {
    let badge: SidebarIconBadge
    let appIsHidden: Bool
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias Metrics = SidebarIconBadgeMetrics

    private var title: String { badge.title(appIsHidden: appIsHidden) }

    var body: some View {
        Image(systemName: badge.symbol(appIsHidden: appIsHidden))
            .font(.system(size: Metrics.symbolSize, weight: .bold))
            .foregroundStyle(MenuPalette.badgeSymbol)
            // Hide ↔ show swaps the eye with a symbol replace instead of a hard cut.
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion ? nil : MenuMotion.hoverGrow, value: appIsHidden)
            .frame(width: Metrics.size, height: Metrics.size)
            .background(Circle().fill(badge.color))
            .scaleEffect(isHovered && isEnabled && !reduceMotion ? Metrics.hoverScale : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(MenuMotion.hoverGrow, value: isHovered)
            .overlay {
                SidebarPointerRegion(onClick: { if isEnabled { action() } }, onAnchor: { _ in })
            }
            .onHover { isHovered = $0 }
            .help(title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isEnabled { action() } }
    }
}

//// The hover grow is cosmetic; clicks work even if the panel misses a hover event.
//////////////////
