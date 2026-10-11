import AppKit

struct SidebarDesktopTransferTarget {
    let id: SidebarWindowID
    let sourceDesktop: SidebarDesktop
    let desktopGeneration: Int
}

struct SidebarDesktopTransferRequest {
    let sourceDesktop: SidebarDesktop
    let destinationDesktop: SidebarDesktop
    let desktopGeneration: Int
}

enum SidebarDesktopTransferPolicy {
    static func source(desktops: [SidebarDesktop], hidden: Bool, minimized: Bool,
                       fullScreen: Bool, modal: Bool, hasSheets: Bool, canMove: Bool) -> SidebarDesktop? {
        guard !hidden, !minimized, !fullScreen, !modal, !hasSheets, canMove,
              desktops.count == 1, let desktop = desktops.first,
              desktop.number != nil, let display = desktop.displayIdentifier, !display.isEmpty else { return nil }
        return desktop
    }

    static func allows(source: SidebarDesktop, destination: SidebarDesktop) -> Bool {
        source.id != destination.id && source.number != nil && destination.number != nil
            && source.displayIdentifier?.isEmpty == false && source.displayIdentifier == destination.displayIdentifier
    }

    enum Verification: Equatable { case pending, moved, unconfirmed }

    static func verify(membership: Set<UInt64>, destinationID: UInt64, expired: Bool) -> Verification {
        if membership == [destinationID] { return .moved }
        return expired ? .unconfirmed : .pending
    }
}

struct SidebarDesktopSection: Identifiable {
    let desktop: SidebarDesktop?
    let entries: [SidebarEntry]
    var id: UInt64? { desktop?.id }

    static func make(entries: [SidebarEntry], desktops: [SidebarDesktop],
                     scope: SidebarDesktopScope) -> [Self] {
        guard scope == .allDesktops else { return [Self(desktop: nil, entries: entries)] }
        let grouped = Dictionary(grouping: entries, by: { $0.desktop?.id })
        // Empty desktops belong in the monitor's drag popup, not the sidebar.
        var sections = desktops.sorted { $0.order < $1.order }.compactMap { desktop -> Self? in
            let entries = grouped[desktop.id] ?? []
            guard !entries.isEmpty else { return nil }
            return Self(desktop: desktop, entries: entries)
        }
        let unknown = entries.filter { entry in
            entry.desktop == nil || !desktops.contains(where: { $0.id == entry.desktop?.id })
        }
        if !unknown.isEmpty { sections.append(Self(desktop: nil, entries: unknown)) }
        return sections
    }

}

struct SidebarMonitor: Identifiable, Equatable {
    let id: String
    let name: String
    let isPrimary: Bool
    // A lone display needs no identifying name; its heading stays as the desktop drop target.
    var isOnlyDisplay = false
    var title: String {
        guard !isOnlyDisplay else { return "Desktops" }
        return "\(isPrimary ? "1" : "2")" + (name.isEmpty ? "" : " · \(name)")
    }
    static let headerHeight: CGFloat = 40
    static let emptyHeight: CGFloat = 24
}

struct SidebarMonitorGroup: Identifiable {
    let monitor: SidebarMonitor?
    let desktops: [SidebarDesktop]
    let sections: [SidebarDesktopSection]
    var id: String? { monitor?.id }

    static func make(sections: [SidebarDesktopSection], desktops: [SidebarDesktop],
                     monitors: [SidebarMonitor], scope: SidebarDesktopScope) -> [Self] {
        guard scope == .allDesktops else { return [Self(monitor: nil, desktops: [], sections: sections)] }
        var displayIDs = [String]()
        for desktop in desktops {
            if let id = desktop.displayIdentifier, !displayIDs.contains(id) { displayIDs.append(id) }
        }
        displayIDs.sort { left, right in
            let lhs = left == "Main" ? 0 : (monitors.firstIndex(where: { $0.id == left }) ?? Int.max)
            let rhs = right == "Main" ? 0 : (monitors.firstIndex(where: { $0.id == right }) ?? Int.max)
            return lhs < rhs
        }
        var groups = displayIDs.map { id in
            let screen = monitors.first(where: { $0.id == id })
                ?? (id == "Main" ? monitors.first(where: \.isPrimary) : nil)
            let monitor = SidebarMonitor(id: id, name: screen?.name ?? "", isPrimary: screen?.isPrimary ?? false,
                                         isOnlyDisplay: monitors.count == 1)
            return Self(monitor: monitor, desktops: desktops.filter { $0.displayIdentifier == id },
                sections: sections.filter { $0.desktop?.displayIdentifier == id })
        }
        let unknown = sections.filter { $0.desktop?.displayIdentifier == nil }
        if !unknown.isEmpty { groups.append(Self(monitor: nil, desktops: [], sections: unknown)) }
        return groups
    }

    static func contentHeight(_ groups: [Self], spacing: CGFloat) -> CGFloat {
        let rows = groups.flatMap(\.sections).reduce(0) { $0 + $1.entries.count }
        let headers = groups.filter { $0.monitor != nil }.count
        let separators = groups.reduce(0) { $0 + max(0, $1.sections.count - 1) }
        let gaps = groups.reduce(0) { count, group in
            count + max(0, group.sections.reduce(0) { $0 + $1.entries.count } - 1)
        } + max(0, groups.count - 1)
        let empties = groups.filter { $0.monitor != nil && $0.sections.allSatisfy { $0.entries.isEmpty } }.count
        return CGFloat(rows) * SidebarLayout.rowHeight + CGFloat(headers) * SidebarMonitor.headerHeight
            + CGFloat(empties) * SidebarMonitor.emptyHeight
            + CGFloat(separators) * SidebarLayout.desktopSeparatorHeight
            + CGFloat(gaps) * spacing + SidebarLayout.verticalPadding * 2
    }

    static func notchContentWidth(_ groups: [Self], spacing: CGFloat) -> CGFloat {
        groups.reduce(CGFloat(max(0, groups.count - 1)) * spacing) { total, group in
            let entriesWidth = group.sections.reduce(CGFloat.zero) { width, section in
                width + CGFloat(section.entries.count) * SidebarLayout.width
                    + CGFloat(max(0, section.entries.count - 1)) * spacing
            }
            let separators = CGFloat(max(0, group.sections.count - 1))
                * (SidebarLayout.notchSeparatorWidth + spacing)
            let header = group.monitor == nil ? 0 : SidebarLayout.notchMonitorWidth + spacing
            let empty = group.monitor != nil && group.sections.allSatisfy({ $0.entries.isEmpty })
                ? SidebarLayout.notchEmptyWidth : 0
            return total + entriesWidth + separators + header + empty
        }
    }
}

struct SidebarDesktopDropTarget {
    let desktop: SidebarDesktop
    let frame: CGRect

    @MainActor static func visibleFrame(of view: NSView, within sidebar: CGRect) -> CGRect? {
        guard let window = view.window else { return nil }
        let clipped = view.bounds.intersection(view.visibleRect)
        var frame = window.convertToScreen(view.convert(clipped, to: nil)).intersection(sidebar)
        if let clip = view.enclosingScrollView?.contentView {
            frame = frame.intersection(window.convertToScreen(clip.convert(clip.bounds, to: nil)))
        }
        return frame.isEmpty || frame.isNull ? nil : frame
    }

    static func resolve(at point: CGPoint, targets: [Self], sidebar: CGRect, excluded: [CGRect]) -> Self? {
        guard sidebar.contains(point), !excluded.contains(where: { $0.contains(point) }) else { return nil }
        return targets.first { !$0.frame.isEmpty && $0.frame.contains(point) }
    }
}
