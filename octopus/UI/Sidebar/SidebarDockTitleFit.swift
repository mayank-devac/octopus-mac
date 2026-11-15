import AppKit

////////////////////
//// Title fit
/// Every row reserves two title lines, so a one-line title leaves an empty line below it.
// Vertical sidebars drop that empty line from each row so the gap after every title matches.

extension SidebarEntry {
    // The text shown under the icon: the preferred window's title, or the app name.
    var sidebarTitle: String { preferredWindow?.title ?? application.title }

    // An app without windows is drawn dimmed, with its title in a small pill.
    var showsAsWindowless: Bool { windows.isEmpty && preferredID == nil && !hasOtherWindows }
}

extension SidebarLayout {
    // Title padding inside the row: the windowless pill keeps a little, Dock titles need none.
    static func dockTitlePadding(windowless: Bool) -> CGFloat { windowless ? 2 : 0 }

    // Horizontal padding around a title: the Dock has no frost pill, Floating pads its pill.
    static func titlePadding(isDock: Bool, windowless: Bool) -> CGFloat {
        isDock ? dockTitlePadding(windowless: windowless) : windowless ? 2 : 4
    }

    // Height of the unused title line under a row; zero when its title wraps to two lines.
    // Measured at the widest hover zoom, the narrowest the title gets, so a two-line title is never cut.
    static func titleTrim(for entry: SidebarEntry, fontSize: Double, isDock: Bool,
                          maximumScale: CGFloat = 1 + magnificationGrowth) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .medium)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let itemWidth = isDock ? dockTitledBarWidth : width
        let padding = titlePadding(isDock: isDock, windowless: entry.showsAsWindowless)
        let titleWidth = (itemWidth - 6) / maximumScale - padding * 2
        guard lineHeight > 0, titleWidth > 0 else { return 0 }
        let height = (entry.sidebarTitle as NSString).boundingRect(
            with: CGSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        ).height
        let lines = min(titleLineLimit, max(1, Int((height / lineHeight).rounded(.up))))
        return CGFloat(titleLineLimit - lines) * lineHeight
    }
}

extension SidebarConfiguration {
    // Trim for one row: only titled vertical sidebars trim; the Mac Notch bar keeps one row height.
    func titleTrim(for entry: SidebarEntry, maximumScale: CGFloat = 1 + SidebarLayout.magnificationGrowth) -> CGFloat {
        guard showsWindowTitles, idleBehavior != .notch else { return 0 }
        return SidebarLayout.titleTrim(for: entry, fontSize: fontSize, isDock: style == .dock,
                                       maximumScale: maximumScale)
    }
}

//// Keep the view and the window height on this one measurement so they agree.
//////////////////
