import CoreGraphics

////////////////////
//// Sizes for the close / hide / quit badges on a hovered sidebar icon
/// Three badges plus two gaps fit inside the 44 pt icon height. The column overlaps
/// the icon's trailing edge, like the window-count badge mirrors it, so it stays
/// inside the icon's hit area on both sidebar sides.
// Menus beside the icon keep `menuClearance` away so they never cover a badge.

enum SidebarIconBadgeMetrics {
    static let size: CGFloat = 14
    static let spacing: CGFloat = 1
    static let symbolSize: CGFloat = 8
    static let hoverScale: CGFloat = 1.2
    /// Badge column centre, measured inward from the icon edge the column sits on.
    static let leadingInset: CGFloat = 5
    /// Extra gap between an icon and a menu card beside it.
    static let menuClearance: CGFloat = 10
}

//////////////////
