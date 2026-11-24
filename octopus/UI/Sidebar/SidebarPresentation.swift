import AppKit

// Resolve the saved visibility choice once; geometry and interaction use this same policy.
struct SidebarPresentation {
    enum Mode { case edge, compact, notch }
    let mode: Mode
    let autoHides: Bool
    let fadesWhenIdle: Bool
    // Seconds the pointer rests at the screen edge before a hidden sidebar slides in; 0 reveals at once.
    let revealDelay: TimeInterval
    // Step aside: after the pointer rests unused on the sidebar for `stepAsideDelay`, it fades and lets clicks through.
    let stepsAside: Bool
    let stepAsideDelay: TimeInterval

    // `delayedOpening` is nil unless Delay opening is on for a mode that offers it
    // (see `SidebarConfiguration.activeDelayedOpening`).
    init(behavior: SidebarIdleBehavior, hasNotchTrigger: Bool, fullScreen: Bool,
         delayedOpening: SidebarDelayedOpening? = nil, openingDelay: TimeInterval = SidebarSettings.defaultOpeningDelay) {
        let hidesUntilEdge = delayedOpening == .hideUntilEdge
        switch behavior {
        // Hide until edge replaces Compact's strip with the hidden edge sidebar.
        case .compact where !hidesUntilEdge:
            mode = .compact
        case .notch where hasNotchTrigger:
            mode = .notch
        default:
            mode = .edge
        }
        autoHides = mode == .edge && (behavior == .hide || behavior == .notch || fullScreen || hidesUntilEdge)
        // A sidebar that only appears while in use has no idle state to fade.
        fadesWhenIdle = behavior == .fade && !hidesUntilEdge
        revealDelay = hidesUntilEdge ? openingDelay : 0
        stepsAside = delayedOpening == .stepAside
        stepAsideDelay = stepsAside ? openingDelay : 0
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
        // Height of the notch zone at the top of a Dock notch bar; zero for other styles.
        let notchInset: CGFloat
    }

    func layout(configuration: SidebarConfiguration, notch: CGRect, available: CGRect,
                screen: CGRect, groups: [SidebarMonitorGroup], entryCount: Int, expanded: Bool) -> Layout {
        let side = configuration.side
        let spacing = CGFloat(configuration.appSpacing)
        let displayedCount = groups.flatMap(\.sections).reduce(0) { $0 + $1.entries.count }
        let collapsedCompact = usesCompactStrip && !expanded
        let style = configuration.style
        let rowHeight = configuration.rowHeight
        let contentHeight: CGFloat?
        // A Dock strip keeps its open height so each small icon grows in place into its Dock icon.
        if collapsedCompact && style != .dock {
            contentHeight = SidebarLayout.compactContentHeight(count: displayedCount, appSpacing: spacing,
                                                               itemHeight: rowHeight)
        } else {
            // Rows with one-line titles drop their unused line, matching the view.
            let titleTrim = groups.flatMap(\.sections).flatMap(\.entries)
                .reduce(0) { $0 + configuration.titleTrim(for: $1) }
            contentHeight = configuration.desktopScope == .allDesktops
                ? SidebarMonitorGroup.contentHeight(groups, spacing: spacing, style: style, rowHeight: rowHeight) - titleTrim
                : SidebarLayout.listContentHeight(count: entryCount, appSpacing: spacing, itemHeight: rowHeight) - titleTrim
        }
        let edge = SidebarLayout.sidebarFrame(in: available, count: entryCount, side: side,
            position: configuration.position, appSpacing: spacing, contentHeight: contentHeight,
            minimumHeight: collapsedCompact && style != .dock ? 0 : rowHeight, itemHeight: rowHeight)
        let sidebar: CGRect
        let compact: CGRect
        let drawing: CGRect
        var notchInset: CGFloat = 0
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
                availableFrame: available, groupedWidth: SidebarMonitorGroup.notchContentWidth(groups, spacing: spacing),
                itemHeight: rowHeight)
            // Dock style reaches the screen top, over the menu bar, so the bar grows out of the notch.
            notchInset = style == .dock ? max(0, screen.maxY - notch.minY) : 0
            let frames = SidebarLayout.notchSidebarFrames(contentSize: notchSize, below: notch,
                availableFrame: available, topExtension: notchInset)
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
        // The notch zone sits above the usable area, which excludes the menu bar.
        let drawingBounds = notchInset > 0
            ? CGRect(x: available.minX, y: available.minY, width: available.width,
                     height: screen.maxY - available.minY)
            : available
        return Layout(sidebar: sidebar, compact: compact, drawing: drawing.intersection(drawingBounds),
                      edgeTrigger: edgeTrigger, topContentWidth: hasTopTrigger ? sidebar.width : nil,
                      notchInset: notchInset)
    }
}
