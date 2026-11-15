import CoreGraphics

////////////////////
//// Sizes for the close / hide / quit badges on a hovered sidebar icon
/// Three badges plus two gaps equal the 40 pt icon height. The column overlaps
/// the icon's leading edge, like the window-count badge, so it stays inside the
/// icon's hit area on both sidebar sides.
// Menus beside the icon keep `menuClearance` away so they never cover a badge.

enum SidebarIconBadgeMetrics {
    static let size: CGFloat = 12
    static let spacing: CGFloat = 2
    static let symbolSize: CGFloat = 6.5
    static let hoverScale: CGFloat = 1.3
    /// Badge column centre, measured inward from the icon's leading edge.
    static let leadingInset: CGFloat = 4
    /// Extra gap between an icon and a menu card beside it.
    static let menuClearance: CGFloat = 10
}

//////////////////
