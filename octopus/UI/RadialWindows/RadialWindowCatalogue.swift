import AppKit

@MainActor
final class RadialWindowCatalogue {
    private let inventory = SidebarWindowInventory(tracksFrontmostFocus: true)
    private var running = false
    private var hasSnapshot = false
    var onChange: () -> Void = {}
    var onDesktopChange: () -> Void = {}
    var hasPermission: Bool { inventory.hasPermission }
    var cachedSnapshot: Snapshot? { hasSnapshot ? snapshot() : nil }
    var items: [RadialWindowItem] {
        Self.project(entries: inventory.entries, recency: inventory.recentWindows,
                     frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    init() {
        inventory.onChange = { [weak self] in
            guard let self else { return }
            self.hasSnapshot = self.inventory.hasPermission
            self.onChange()
        }
        inventory.onDesktopChange = { [weak self] in self?.onDesktopChange() }
        inventory.setDesktopScope(.allDesktops)
    }

    func start() { guard !running else { return }; running = true; inventory.start() }
    func stop() {
        guard running else { return }
        running = false
        hasSnapshot = false
        inventory.stop()
    }
    func refresh(completion: @escaping () -> Void) { inventory.refresh(completion: completion) }

    struct Snapshot {
        let items: [RadialWindowItem]
        let requirements: [SidebarWindowID: SidebarFocusRequirement]
    }

    func snapshot() -> Snapshot {
        let items = self.items
        let ids = Set(items.map(\.id))
        var requirements: [SidebarWindowID: SidebarFocusRequirement] = [:]
        for entry in inventory.entries {
            for window in entry.windows {
                guard let number = window.cgWindowID else { continue }
                let id = SidebarWindowID(pid: entry.pid, windowID: number)
                if ids.contains(id) { requirements[id] = inventory.focusRequirement(for: window) }
            }
        }
        return Snapshot(items: items, requirements: requirements)
    }

    static func project(entries: [SidebarEntry], recency: [SidebarWindowID: UInt64],
                        frontmostPID: pid_t?) -> [RadialWindowItem] {
        var seen = Set<SidebarWindowID>()
        var focused: SidebarWindowID?
        var items: [RadialWindowItem] = []
        for entry in entries where entry.application.runningApplication?.isTerminated != true {
            if entry.pid == frontmostPID, let focusedID = entry.focusedID { focused = focusedID }
            for window in entry.windows {
                guard let number = window.cgWindowID, number != 0,
                      entry.pid != ProcessInfo.processInfo.processIdentifier else { continue }
                let id = SidebarWindowID(pid: entry.pid, windowID: number)
                guard seen.insert(id).inserted else { continue }
                items.append(RadialWindowItem(id: id, applicationName: entry.application.title,
                    title: window.title, icon: entry.application.runningApplication?.icon))
            }
        }
        items.sort { lhs, rhs in
            if (lhs.id == focused) != (rhs.id == focused) { return rhs.id == focused }
            let left = recency[lhs.id] ?? 0, right = recency[rhs.id] ?? 0
            if left != right { return left > right }
            let app = lhs.applicationName.localizedCaseInsensitiveCompare(rhs.applicationName)
            if app != .orderedSame { return app == .orderedAscending }
            let title = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if title != .orderedSame { return title == .orderedAscending }
            if lhs.id.pid != rhs.id.pid { return lhs.id.pid < rhs.id.pid }
            return lhs.id.windowID < rhs.id.windowID
        }
        // Keep identical titles distinguishable without changing native identity or focus matching.
        let counts = Dictionary(grouping: items.indices, by: { "\(items[$0].applicationName)\u{0}\(items[$0].title)" })
        for indices in counts.values where indices.count > 1 {
            for (ordinal, index) in indices.enumerated() {
                let item = items[index]
                items[index] = RadialWindowItem(id: item.id, applicationName: item.applicationName,
                    title: "\(item.title) (\(ordinal + 1))", icon: item.icon)
            }
        }
        return items
    }

    func focus(_ id: SidebarWindowID, requirement: SidebarFocusRequirement,
               completion: @escaping (Bool) -> Void) -> SidebarPendingAction? {
        inventory.focus(id, requirement: requirement, completion: completion)
    }
}
