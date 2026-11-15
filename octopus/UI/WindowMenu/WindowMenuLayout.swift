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
        return CGSize(width: cardWidth(content: content, isCenter: isCenter), height: height)
    }

    static func cardWidth(content: WindowMenuContent, isCenter: Bool) -> CGFloat {
        isCenter ? Metrics.centerWidth
            : sidebarCardWidth(appCount: content.apps.count, workspaceCount: content.workspaces.count)
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

    ////////////////////
    //// Sidebar card width

    /// Cells the strip can show at full width, optionally reserving room for the
    /// "more" chevron so it never covers a cell.
    static func stripCapacity(isCenter: Bool, workspaceCount: Int, reservingChevron: Bool) -> Int {
        var width = (isCenter ? Metrics.centerWidth : Metrics.sidebarWidth)
            - Metrics.padding * 2 - Metrics.stripInnerPadding
        if showsWorkspaceSwitch(workspaceCount: workspaceCount) { width -= Metrics.workspaceWidth + Metrics.sectionSpacing }
        if reservingChevron { width -= Metrics.stripChevronWidth }
        return max(1, Int((width + Metrics.appCellSpacing) / (Metrics.appCellSize + Metrics.appCellSpacing)))
    }

    /// The sidebar card hugs its content: workspace switch plus the app strip,
    /// clamped between the minimum and maximum widths, so short app lists leave
    /// no dead trailing space and the window rows stay compact.
    static func sidebarCardWidth(appCount: Int, workspaceCount: Int) -> CGFloat {
        let cells = min(max(appCount, 1), stripCapacity(isCenter: false, workspaceCount: workspaceCount, reservingChevron: false))
        var width = Metrics.padding * 2 + Metrics.stripInnerPadding
        if showsWorkspaceSwitch(workspaceCount: workspaceCount) { width += Metrics.workspaceWidth + Metrics.sectionSpacing }
        width += CGFloat(cells) * Metrics.appCellSize + CGFloat(max(0, cells - 1)) * Metrics.appCellSpacing
        return min(max(width, Metrics.sidebarMinimumWidth), Metrics.sidebarWidth)
    }

    /// Width of the workspace app strip's scroll area, so short app lists can
    /// be pushed against the side that faces the sidebar.
    static func stripWidth(content: WindowMenuContent, isCenter: Bool, reservingChevron: Bool) -> CGFloat {
        var width = cardWidth(content: content, isCenter: isCenter) - Metrics.padding * 2
        if showsWorkspaceSwitch(workspaceCount: content.workspaces.count) { width -= Metrics.workspaceWidth + Metrics.sectionSpacing }
        if reservingChevron { width -= Metrics.stripChevronWidth }
        return max(0, width)
    }

    ////////////////////
    //// Sidebar panel frame
    /// The card is pinned by its top rather than centred on the icon: the app
    /// strip stays level with the hovered icon (lifted by `sidebarStripLift`)
    // however many window rows the list shows, so the menu never jumps.

    static func sidebarPanelFrame(size: CGSize, icon: CGRect, screen: CGRect, side: SidebarSide) -> CGRect {
        let beside = SidebarLayout.menuFrame(size: size, icon: icon, screen: screen, side: side)
        let top = icon.midY + Metrics.sidebarStripLift + Metrics.appStripHeight / 2 + Metrics.padding + MenuShadowMargin.size
        let y = min(max(top - beside.height, screen.minY), screen.maxY - beside.height)
        return CGRect(x: beside.minX, y: y, width: beside.width, height: beside.height)
    }

    //// Only y changes; x and screen clamping come from SidebarLayout.menuFrame.
    //////////////////
}

//// Keep in step with the block heights in WindowMenuView.
//////////////////
