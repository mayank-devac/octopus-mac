import AppKit

// Resolve the saved visibility choice once; geometry and interaction use this same policy.
struct SidebarPresentation {
    enum Mode { case edge, compact, notch }
    let mode: Mode
    let autoHides: Bool
    let fadesWhenIdle: Bool

    init(behavior: SidebarIdleBehavior, hasNotchTrigger: Bool, fullScreen: Bool) {
        switch behavior {
        case .compact:
            mode = .compact
        case .notch where hasNotchTrigger:
            mode = .notch
        default:
            mode = .edge
        }
        autoHides = mode == .edge && (behavior == .hide || behavior == .notch || fullScreen)
        fadesWhenIdle = behavior == .fade
    }

    var usesCompactStrip: Bool { mode == .compact }
    var hasTopTrigger: Bool { mode == .notch }
    var usesPersistentTrigger: Bool { mode != .edge }
    var closeDelay: TimeInterval { hasTopTrigger ? SidebarLayout.notchCloseDelay : 0 }

    func showsMainSidebar(expanded: Bool) -> Bool { !usesPersistentTrigger || expanded }
    func restoresMainSidebar(expanded: Bool, menuVisible: Bool) -> Bool {
        menuVisible || (!autoHides && (!hasTopTrigger || expanded))
    }
    func closesWhenOutside(expanded: Bool) -> Bool {
        autoHides || (usesPersistentTrigger && expanded)
    }
    func pointerFrame(sidebar: CGRect, compact: CGRect, expanded: Bool) -> CGRect {
        guard usesCompactStrip else { return sidebar }
        return expanded ? sidebar.union(compact) : compact
    }

    struct Layout {
        let sidebar: CGRect
        let compact: CGRect
        let drawing: CGRect
        let edgeTrigger: CGRect
        let topContentWidth: CGFloat?
    }

    func layout(configuration: SidebarConfiguration, notch: CGRect, available: CGRect,
                screen: CGRect, groups: [SidebarMonitorGroup], entryCount: Int, expanded: Bool) -> Layout {
        let side = configuration.side
        let spacing = CGFloat(configuration.appSpacing)
        let displayedCount = groups.flatMap(\.sections).reduce(0) { $0 + $1.entries.count }
        let collapsedCompact = usesCompactStrip && !expanded
        let style = configuration.style
        let contentHeight: CGFloat?
        // A Dock strip keeps its open height so each small icon grows in place into its Dock icon.
        if collapsedCompact && style != .dock {
            contentHeight = SidebarLayout.compactContentHeight(count: displayedCount, appSpacing: spacing,
                                                               itemHeight: style.rowHeight)
        } else if configuration.desktopScope == .allDesktops {
            contentHeight = SidebarMonitorGroup.contentHeight(groups, spacing: spacing, style: style)
        } else {
            contentHeight = nil
        }
        let edge = SidebarLayout.sidebarFrame(in: available, count: entryCount, side: side,
            position: configuration.position, appSpacing: spacing, contentHeight: contentHeight,
            minimumHeight: collapsedCompact && style != .dock ? 0 : style.rowHeight, itemHeight: style.rowHeight)
        let sidebar: CGRect
        let compact: CGRect
        let drawing: CGRect
        switch mode {
        case .compact:
            // The Dock's closed pill is wider than the number strip so its icons stay readable.
            let stripWidth = style == .dock ? SidebarDockReveal.stripWidth : SidebarLayout.compactWidth
            let frames = SidebarLayout.compactFrames(beside: edge, side: side, expanded: expanded, stripWidth: stripWidth)
            sidebar = frames.main
            compact = frames.compact
            // The Dock grows inside its window, so the window keeps its open size; pointer input
            // still follows pointerFrame, which stays the strip while closed.
            drawing = style == .dock
                ? SidebarLayout.compactFrames(beside: edge, side: side, expanded: true, stripWidth: stripWidth).panel
                : frames.panel
        case .notch:
            let notchSize = SidebarLayout.notchBarSize(count: displayedCount, appSpacing: spacing,
                availableFrame: available, groupedWidth: SidebarMonitorGroup.notchContentWidth(groups, spacing: spacing))
            let frames = SidebarLayout.notchSidebarFrames(contentSize: notchSize, below: notch,
                                                         availableFrame: available)
            sidebar = frames.content
            compact = .zero
            drawing = frames.panel
        case .edge:
            sidebar = edge
            compact = .zero
            drawing = CGRect(x: side == .right ? edge.minX - SidebarLayout.drawingPadding : edge.minX,
                             y: edge.minY, width: edge.width + SidebarLayout.drawingPadding, height: edge.height)
        }
        let edgeTrigger = hasTopTrigger ? CGRect.zero : CGRect(
            x: side == .left ? screen.minX : screen.maxX - 3, y: edge.minY, width: 3, height: edge.height)
        return Layout(sidebar: sidebar, compact: compact, drawing: drawing.intersection(available),
                      edgeTrigger: edgeTrigger, topContentWidth: hasTopTrigger ? sidebar.width : nil)
    }
}
