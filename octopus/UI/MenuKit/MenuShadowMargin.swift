import SwiftUI

////////////////////
//// Transparent margin around a menu card, where the card's soft shadow draws
/// Beside a sidebar icon the margin is dropped on the icon-facing side, and the
/// card keeps a small clearance from the icon. The panel then never covers the
/// icon or its badges, so it never takes their clicks or hover.
// `edge` is the card side that faces the icon (nil for the centre or notch menus).

enum MenuShadowMargin {
    static var size: CGFloat { WindowMenuMetrics.shadowInset }

    static func insets(facing edge: HorizontalEdge?) -> EdgeInsets {
        EdgeInsets(top: size, leading: edge == .leading ? 0 : size, bottom: size, trailing: edge == .trailing ? 0 : size)
    }

    static func panelSize(card: CGSize, facing edge: HorizontalEdge?) -> CGSize {
        let insets = insets(facing: edge)
        return CGSize(width: card.width + insets.leading + insets.trailing, height: card.height + insets.top + insets.bottom)
    }

    static func cardFrame(panel: CGRect, facing edge: HorizontalEdge?) -> CGRect {
        let insets = insets(facing: edge)
        return CGRect(x: panel.minX + insets.leading, y: panel.minY + insets.bottom,
                      width: panel.width - insets.leading - insets.trailing,
                      height: panel.height - insets.top - insets.bottom)
    }

    /// The icon frame widened so a card placed beside it clears the magnified icon's badges.
    static func clearedIcon(_ icon: CGRect) -> CGRect {
        icon.insetBy(dx: -SidebarIconBadgeMetrics.menuClearance, dy: 0)
    }
}

//// Views pad with insets(facing:); controllers size panels with panelSize(card:facing:).
//////////////////
