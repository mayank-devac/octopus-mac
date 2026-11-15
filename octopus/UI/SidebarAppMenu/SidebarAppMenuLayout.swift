import CoreGraphics

////////////////////
//// Sidebar app menu card size, matching the block heights in SidebarAppMenuView

enum SidebarAppMenuLayout {
    private typealias Metrics = SidebarAppMenuMetrics

    static func cardSize(for sections: [SidebarAppMenuSection]) -> CGSize {
        let body = sections.reduce(CGFloat(0)) { height, section in
            height + sectionHeight(section)
        }
        let dividers = CGFloat(sections.count) * Metrics.dividerHeight
        return CGSize(width: Metrics.width, height: Metrics.padding * 2 + Metrics.headerHeight + dividers + body)
    }

    static func sectionHeight(_ section: SidebarAppMenuSection) -> CGFloat {
        let title = section.title == nil ? 0 : Metrics.sectionTitleHeight
        switch section.layout {
        case .rows: return title + CGFloat(section.items.count) * Metrics.rowHeight
        case .chips: return title + Metrics.chipRowHeight
        }
    }
}

//// One divider sits above each section, below the header.
//////////////////
