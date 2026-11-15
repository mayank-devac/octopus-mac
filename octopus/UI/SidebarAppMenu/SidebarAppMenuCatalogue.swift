import Foundation

////////////////////
//// Which items the sidebar app menu shows, in order
///   Windows        – up to five of the app's windows (running apps)
///   Snap           – left half · maximise · right half (needs a target window)
///   Move to Desktop– numbered chips (needs a movable target window)
///   Actions        – Open | Show/Hide, Close Window, Keep in/Remove from Sidebar, Show in Finder
// Quit            – last, in red (running apps)

enum SidebarAppMenuCatalogue {
    private typealias Strings = SidebarAppMenuStrings

    static func sections(for context: SidebarAppMenuContext) -> [SidebarAppMenuSection] {
        var sections: [SidebarAppMenuSection] = []

        if context.isRunning, !context.windows.isEmpty {
            let rows = context.windows.prefix(SidebarAppMenuMetrics.maximumWindowRows).map { window in
                SidebarAppMenuItem(command: .focusWindow(window.id), title: window.title,
                                   symbol: window.isMinimized ? "minus.circle" : "macwindow")
            }
            sections.append(SidebarAppMenuSection(id: "windows", title: Strings.windowsSection, layout: .rows, items: rows))
        }

        if context.targetWindow != nil {
            let snaps: [(SidebarSnapTarget, String)] = [(.left, "rectangle.lefthalf.filled"),
                                                        (.maximize, "rectangle.fill"),
                                                        (.right, "rectangle.righthalf.filled")]
            sections.append(SidebarAppMenuSection(id: "snap", title: Strings.snapSection, layout: .chips, items: snaps.map {
                SidebarAppMenuItem(command: .snap($0.0), title: $0.0.title, symbol: $0.1)
            }))
            if !context.desktops.isEmpty {
                sections.append(SidebarAppMenuSection(id: "desktops", title: Strings.desktopSection, layout: .chips,
                                                      items: context.desktops.map {
                    SidebarAppMenuItem(command: .moveToDesktop($0.id), title: Strings.moveToDesktop($0.number),
                                       symbol: "\($0.number).square")
                }))
            }
        }

        var actions: [SidebarAppMenuItem] = []
        if context.isRunning {
            actions.append(context.isHidden
                ? SidebarAppMenuItem(command: .toggleHidden, title: Strings.show, symbol: "eye")
                : SidebarAppMenuItem(command: .toggleHidden, title: Strings.hide, symbol: "eye.slash"))
            if context.canCloseTarget {
                actions.append(SidebarAppMenuItem(command: .closeWindow, title: Strings.closeWindow, symbol: "xmark.square"))
            }
        } else {
            actions.append(SidebarAppMenuItem(command: .open, title: Strings.open, symbol: "arrow.up.forward.app"))
        }
        if context.canPin {
            actions.append(context.isPinned
                ? SidebarAppMenuItem(command: .togglePin, title: Strings.unpin, symbol: "pin.slash")
                : SidebarAppMenuItem(command: .togglePin, title: Strings.pin, symbol: "pin"))
        }
        if context.hasBundleURL {
            actions.append(SidebarAppMenuItem(command: .showInFinder, title: Strings.showInFinder, symbol: "folder"))
        }
        sections.append(SidebarAppMenuSection(id: "actions", title: nil, layout: .rows, items: actions))

        if context.isRunning {
            sections.append(SidebarAppMenuSection(id: "quit", title: nil, layout: .rows, items: [
                SidebarAppMenuItem(command: .quit, title: Strings.quit, symbol: "power", isDestructive: true)
            ]))
        }
        return sections
    }

    /// Navigation rows: each row item is its own row; a chip section is one row.
    static func grid(for sections: [SidebarAppMenuSection]) -> [[SidebarAppMenuCommand]] {
        sections.flatMap { section -> [[SidebarAppMenuCommand]] in
            switch section.layout {
            case .rows: return section.items.map { [$0.command] }
            case .chips: return [section.items.map(\.command)]
            }
        }
    }
}

//// Menu height comes from SidebarAppMenuLayout, which reads these same sections.
//////////////////
