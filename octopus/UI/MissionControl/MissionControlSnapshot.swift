import AppKit

struct MissionControlApplication {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    var isHidden = false
}

struct MissionControlScreen: Equatable {
    let id: String
    // AX window positions and CGDisplayBounds both use global, top-left coordinates.
    let bounds: CGRect
}

struct MissionControlWindowRecord {
    let id: SidebarWindowID
    var bounds: CGRect?
    var desktopIDs: Set<UInt64>?
    var isMinimized: Bool?
    var isStandardWindow = true
}

struct MissionControlSnapshot {
    struct Window: Equatable {
        let id: SidebarWindowID
        let bounds: CGRect
        let desktopIDs: Set<UInt64>
        let screenID: String
    }

    let desktops: [SidebarDesktop]
    let activeIDs: Set<UInt64>
    let applications: [pid_t: MissionControlApplication]
    let windows: [Window]
    let screens: [MissionControlScreen]

    func desktops(on screenID: String) -> [SidebarDesktop] {
        desktops.filter { $0.displayIdentifier == screenID || $0.displayIdentifier == "Main" }
            .sorted { $0.order < $1.order }
    }

    static func validBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width > 1 && bounds.height > 1 && !bounds.isNull && !bounds.isInfinite
    }

    static func make(catalog: SidebarSpaceReader.Catalog, applications: [MissionControlApplication],
                     records: [MissionControlWindowRecord], screens: [MissionControlScreen],
                     ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Self {
        let apps = Dictionary(uniqueKeysWithValues: applications.filter { !$0.isHidden && $0.pid != ownPID }.map { ($0.pid, $0) })
        let desktops = Dictionary(uniqueKeysWithValues: catalog.desktops.map { ($0.id, $0) })
        let displayFrames = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.bounds) })
        var seen = Set<SidebarWindowID>()
        let windows = records.compactMap { record -> Window? in
            guard apps[record.id.pid] != nil, record.id.windowID != 0, record.isStandardWindow,
                  record.isMinimized == false, let bounds = record.bounds, validBounds(bounds),
                  let membership = record.desktopIDs else { return nil }
            let members = membership.compactMap { desktops[$0] }
            guard !members.isEmpty,
                  let displayID = SidebarWindowPolicy.displayIdentifier(desktops: members, bounds: bounds,
                                                                         displayFrames: displayFrames),
                  let screenBounds = displayFrames[displayID], screenBounds.intersects(bounds),
                  members.contains(where: { $0.displayIdentifier == displayID || $0.displayIdentifier == "Main" }),
                  seen.insert(record.id).inserted else { return nil }
            return Window(id: record.id, bounds: bounds, desktopIDs: Set(members.map(\.id)), screenID: displayID)
        }.sorted { ($0.id.pid, $0.id.windowID) < ($1.id.pid, $1.id.windowID) }
        return Self(desktops: catalog.desktops, activeIDs: catalog.activeIDs, applications: apps,
                    windows: windows, screens: screens)
    }
}

struct MissionControlSnapshotState {
    private(set) var snapshot: MissionControlSnapshot?
    private(set) var generation = 0

    mutating func reset() {
        generation += 1
        snapshot = nil
    }

    mutating func receive(_ snapshot: MissionControlSnapshot?, generation: Int) -> Bool {
        guard generation == self.generation, let snapshot else { return false }
        self.snapshot = snapshot
        return true
    }
}

// This reader never reads Mission Control thumbnails. Window frames come from
// each application's AX windows, which retain their normal desktop coordinates.
final class MissionControlSnapshotReader {
    let queue = DispatchQueue(label: "com.octopus.mission-control.snapshot", qos: .utility)
    private let spaces = SidebarSpaceReader()
    private let discovery = SidebarWindowDiscovery()
    private var records: [SidebarWindowID: MissionControlWindowRecord] = [:]
    private var applicationCursor = 0
    private var windowCursors: [pid_t: Int] = [:]

    func reset(clearDiscovery: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        records.removeAll()
        windowCursors.removeAll()
        applicationCursor = 0
        if clearDiscovery { discovery.reset() }
    }

    func read(applications: [MissionControlApplication], screens: [MissionControlScreen],
              seeds: [SidebarWindowID: AXUIElement]) -> MissionControlSnapshot? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard AXIsProcessTrusted(), let catalog = spaces.readCatalog(), !catalog.desktops.isEmpty,
              let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        var owners: [CGWindowID: pid_t] = [:]
        for info in raw {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            owners[id] = pid
        }
        let apps = applications.filter { !$0.isHidden }.sorted { $0.pid < $1.pid }
        let pids = Set(apps.map(\.pid))
        owners = owners.filter { pids.contains($0.value) }
        records = records.filter { pids.contains($0.key.pid) && owners[$0.key.windowID] == $0.key.pid }
        windowCursors = windowCursors.filter { pids.contains($0.key) }
        discovery.retainApplications(pids)
        let membership = spaces.read(windowIDs: Set(owners.keys), catalog: catalog.desktops)
        for id in Array(records.keys) {
            if let desktops = membership[id.windowID] { records[id]?.desktopIDs = Set(desktops.map(\.id)) }
        }
        let firstApplication = applicationCursor
        for offset in 0..<apps.count {
            guard AXIsProcessTrusted(), ProcessInfo.processInfo.systemUptime < deadline else { break }
            let index = (firstApplication + offset) % apps.count
            applicationCursor = (index + 1) % apps.count
            let app = apps[index]
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.04)
            let current: [AXUIElement]? = element.getAttributeValue(.windows)
            let known = seeds.filter { $0.key.pid == app.pid }.sorted { $0.key.windowID < $1.key.windowID }.map(\.value)
            guard current != nil || !known.isEmpty else { continue }
            let candidates = Set(owners.filter { $0.value == app.pid }.keys)
            let found = discovery.read(pid: app.pid, current: (current ?? []) + known, candidates: candidates, deadline: deadline)
            var verified = Set<SidebarWindowID>()
            var processed = 0
            let cursor = windowCursors[app.pid, default: 0]
            for offset in 0..<found.windows.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let window = found.windows[(cursor + offset) % found.windows.count]
                AXUIElementSetMessagingTimeout(window, 0.04)
                processed += 1
                guard let id = window.getWindowID(), owners[id] == app.pid else { continue }
                let identity = SidebarWindowID(pid: app.pid, windowID: id)
                guard verified.insert(identity).inserted else { continue }
                let role: String? = window.getAttributeValue(.role)
                let subrole: String? = window.getAttributeValue(.subrole)
                guard role != nil else { continue }
                guard SidebarWindowPolicy.isTopLevelWindow(role: role, subrole: subrole) else {
                    records.removeValue(forKey: identity)
                    continue
                }
                let minimized: Bool? = window.getAttributeValue(.minimized)
                let bounds = window.getWindowFrame()
                let desktops = membership[id].map { Set($0.map(\.id)) }
                records[identity] = MissionControlWindowRecord(id: identity,
                    bounds: bounds ?? records[identity]?.bounds,
                    desktopIDs: desktops ?? records[identity]?.desktopIDs,
                    isMinimized: minimized ?? records[identity]?.isMinimized)
            }
            windowCursors[app.pid] = cursor + processed
            if processed == found.windows.count, !found.needsAnotherPass {
                records = records.filter { $0.key.pid != app.pid || verified.contains($0.key) }
            }
        }
        guard AXIsProcessTrusted() else { return nil }
        return MissionControlSnapshot.make(catalog: catalog, applications: applications,
                                           records: Array(records.values), screens: screens)
    }
}
