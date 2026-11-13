import AppKit

////////////////////
//// Dock title fit
/// Every row reserves two title lines, so a one-line title leaves an empty line below it.
// The Dock's last row drops that empty line so the bar's top and bottom padding match.

extension SidebarEntry {
    // The text shown under the icon: the preferred window's title, or the app name.
    var sidebarTitle: String { preferredWindow?.title ?? application.title }

    // An app without windows is drawn dimmed, with its title in a small pill.
    var showsAsWindowless: Bool { windows.isEmpty && preferredID == nil && !hasOtherWindows }
}

extension SidebarLayout {
    // Title padding inside the row: the windowless pill keeps a little, Dock titles need none.
    static func dockTitlePadding(windowless: Bool) -> CGFloat { windowless ? 2 : 0 }

    // Height of the unused title line under the Dock's last row; zero when its title wraps to two lines.
    // Measured at the widest hover zoom, the narrowest the title gets, so a two-line title is never cut.
    static func dockLastRowTrim(for entry: SidebarEntry, fontSize: Double,
                                maximumScale: CGFloat = 1 + magnificationGrowth) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .medium)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let width = (dockTitledBarWidth - 6) / maximumScale - dockTitlePadding(windowless: entry.showsAsWindowless) * 2
        guard lineHeight > 0, width > 0 else { return 0 }
        let height = (entry.sidebarTitle as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        ).height
        let lines = min(titleLineLimit, max(1, Int((height / lineHeight).rounded(.up))))
        return CGFloat(titleLineLimit - lines) * lineHeight
    }
}

//// Keep the view and the window height on this one measurement so they agree.
//////////////////
