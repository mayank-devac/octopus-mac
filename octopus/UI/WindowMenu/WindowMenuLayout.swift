import CoreGraphics

////////////////////
//// Window menu geometry: card size, panel frame, rows per page
/// The view lays out blocks with these exact heights, so the panel that hosts
// the card never clips or leaves empty space. Values live in WindowMenuMetrics.

enum WindowMenuLayout {
    private typealias Metrics = WindowMenuMetrics

    static func cardSize(content: WindowMenuContent, isCenter: Bool, status: WindowMenuStatus) -> CGSize {
        var height = Metrics.padding * 2
        if isCenter { height += Metrics.recentStripHeight + Metrics.sectionSpacing }
        height += headerHeight(workspaceCount: content.workspaces.count)
        height += Metrics.sectionSpacing
        height += listHeight(windowCount: content.windows.count, isCenter: isCenter, status: status)
        return CGSize(width: isCenter ? Metrics.centerWidth : Metrics.sidebarWidth, height: height)
    }

    /// The workspace switch appears only with two or more workspaces.
    static func showsWorkspaceSwitch(workspaceCount: Int) -> Bool { workspaceCount > 1 }

    static func headerHeight(workspaceCount: Int) -> CGFloat {
        guard showsWorkspaceSwitch(workspaceCount: workspaceCount) else { return Metrics.appStripHeight }
        let switchHeight = CGFloat(workspaceCount) * Metrics.workspaceItemHeight + Metrics.workspacePadding * 2
        return max(Metrics.appStripHeight, switchHeight)
    }

    static func listHeight(windowCount: Int, isCenter: Bool, status: WindowMenuStatus) -> CGFloat {
        guard status == .ready, windowCount > 0 else { return Metrics.emptyListHeight }
        let rows = min(windowCount, maximumRows(isCenter: isCenter))
        return CGFloat(rows) * Metrics.windowRowHeight + (hasMoreWindows(windowCount, isCenter: isCenter) ? Metrics.footerHeight : 0)
    }

    static func maximumRows(isCenter: Bool) -> Int {
        isCenter ? Metrics.centerMaximumRows : Metrics.sidebarMaximumRows
    }

    static func hasMoreWindows(_ windowCount: Int, isCenter: Bool) -> Bool {
        windowCount > maximumRows(isCenter: isCenter)
    }

    /// App cells that fit beside the optional workspace switch and the "more" chevron.
    static func visibleAppCount(isCenter: Bool, workspaceCount: Int) -> Int {
        var width = (isCenter ? Metrics.centerWidth : Metrics.sidebarWidth) - Metrics.padding * 2
        if showsWorkspaceSwitch(workspaceCount: workspaceCount) { width -= Metrics.workspaceWidth + Metrics.sectionSpacing }
        width -= Metrics.stripChevronWidth
        return max(1, Int((width + Metrics.appCellSpacing) / (Metrics.appCellSize + Metrics.appCellSpacing)))
    }
}

//// Keep in step with the block heights in WindowMenuView.
//////////////////
