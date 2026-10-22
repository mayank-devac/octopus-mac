import AppKit

struct MissionControlApplication {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    var isHidden = false
    var launchDate: Date? = nil
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
    var focusRequirement: SidebarFocusRequirement? = nil
    var verifiedAt = ProcessInfo.processInfo.systemUptime

    // A partial AX read must not renew the lifetime of old geometry or state.
    mutating func verify(bounds: CGRect?, desktopIDs: Set<UInt64>?, minimized: Bool?,
                         requirement: SidebarFocusRequirement, now: TimeInterval) {
        guard let bounds, MissionControlSnapshot.validBounds(bounds), let desktopIDs,
              let minimized else { return }
        self.bounds = bounds
        self.desktopIDs = desktopIDs
        self.isMinimized = minimized
        focusRequirement = requirement
        verifiedAt = now
    }
}

struct MissionControlSnapshot {
    struct Window: Equatable {
        let id: SidebarWindowID
        let bounds: CGRect
        let desktopIDs: Set<UInt64>
        let screenID: String
        let verifiedAt: TimeInterval
    }

    let desktops: [SidebarDesktop]
    let activeIDs: Set<UInt64>
    let applications: [pid_t: MissionControlApplication]
    let windows: [Window]
    let screens: [MissionControlScreen]
    var focusRequirements: [SidebarWindowID: SidebarFocusRequirement] = [:]

    func removingExpiredWindows(at now: TimeInterval) -> Self {
        let fresh = windows.filter { MissionControlSnapshotState.isFresh(since: $0.verifiedAt, now: now) }
        let ids = Set(fresh.map(\.id))
        return Self(desktops: desktops, activeIDs: activeIDs, applications: applications,
                    windows: fresh, screens: screens, focusRequirements: focusRequirements.filter { ids.contains($0.key) })
    }

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
            return Window(id: record.id, bounds: bounds, desktopIDs: Set(members.map(\.id)),
                          screenID: displayID, verifiedAt: record.verifiedAt)
        }.sorted { ($0.id.pid, $0.id.windowID) < ($1.id.pid, $1.id.windowID) }
        return Self(desktops: catalog.desktops, activeIDs: catalog.activeIDs, applications: apps,
                    windows: windows, screens: screens, focusRequirements: Dictionary(records.compactMap { record in
                        guard windows.contains(where: { $0.id == record.id }), let requirement = record.focusRequirement else { return nil }
                        return (record.id, requirement)
                    }, uniquingKeysWith: { first, _ in first }))
    }
}

struct MissionControlSnapshotState {
    static let maximumAge: TimeInterval = 2
    private(set) var snapshot: MissionControlSnapshot?
    private(set) var receivedAt: TimeInterval?
    private(set) var generation = 0

    static func isFresh(since timestamp: TimeInterval, now: TimeInterval) -> Bool {
        now >= timestamp && now - timestamp < maximumAge
    }

    mutating func invalidateRequests() { generation += 1 }

    mutating func clearCache() {
        snapshot = nil
        receivedAt = nil
    }

    func freshSnapshot(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> MissionControlSnapshot? {
        guard let receivedAt, Self.isFresh(since: receivedAt, now: now) else { return nil }
        // The cache age applies to the whole snapshot. Individual windows may
        // be retained across partial active-map scans and are live-validated
        // before an action, so do not expire them a second time here.
        return snapshot
    }

    mutating func receive(_ snapshot: MissionControlSnapshot?, generation: Int,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard generation == self.generation, let snapshot else { return false }
        self.snapshot = snapshot
        receivedAt = now
        return true
    }
}

// This reader never reads Mission Control thumbnails. Window frames come from
// each application's AX windows, which retain their normal desktop coordinates.
final class MissionControlSnapshotReader {
    private struct Topology: Equatable {
        let screens: [MissionControlScreen]
        let desktops: [SidebarDesktop]
    }

    let queue = DispatchQueue(label: "com.octopus.mission-control.snapshot", qos: .utility)
    private let spaces = SidebarSpaceReader()
    private let discovery = SidebarWindowDiscovery()
    private var records: [SidebarWindowID: MissionControlWindowRecord] = [:]
    private var applicationCursor = 0
    private var windowCursors: [pid_t: Int] = [:]
    private var topology: Topology?

    func reset(clearDiscovery: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        records.removeAll()
        windowCursors.removeAll()
        applicationCursor = 0
        topology = nil
        if clearDiscovery { discovery.reset() }
    }

    func read(applications: [MissionControlApplication], screens: [MissionControlScreen],
              seeds: [SidebarWindowID: AXUIElement]) -> MissionControlSnapshot? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard AXIsProcessTrusted() else {
            reset(clearDiscovery: true)
            return nil
        }
        guard let catalog = spaces.readCatalog(), !catalog.desktops.isEmpty,
              let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let currentTopology = Topology(screens: screens, desktops: catalog.desktops)
        if topology != currentTopology {
            records.removeAll()
            windowCursors.removeAll()
            applicationCursor = 0
            discovery.reset()
            topology = currentTopology
        }
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
        records = records.filter { id, record in
            pids.contains(id.pid) && owners[id.windowID] == id.pid
                && record.focusRequirement?.launchDate == apps.first(where: { $0.pid == id.pid })?.launchDate
        }
        windowCursors = windowCursors.filter { pids.contains($0.key) }
        discovery.retainApplications(pids)
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
            var validated = Set<SidebarWindowID>()
            var foundIDs = Set<CGWindowID>()
            var processed = 0
            let cursor = windowCursors[app.pid, default: 0]
            for offset in 0..<found.windows.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let window = found.windows[(cursor + offset) % found.windows.count]
                AXUIElementSetMessagingTimeout(window, 0.04)
                processed += 1
                guard let id = window.getWindowID(), owners[id] == app.pid else { continue }
                foundIDs.insert(id)
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
                if minimized == true {
                    records.removeValue(forKey: identity)
                    continue
                }
                guard minimized != nil else { continue }
                let desktops: Set<UInt64>
                let membership = spaces.readResult(windowID: id, catalog: catalog.desktops, deadline: deadline)
                switch membership.state {
                case .verified(let members):
                    guard !members.isEmpty else {
                        records.removeValue(forKey: identity)
                        continue
                    }
                    desktops = Set(members.map(\.id))
                case .failed, .notRead:
                    continue
                }
                let bounds = window.getWindowFrame()
                guard let bounds, MissionControlSnapshot.validBounds(bounds) else { continue }
                var record = records[identity] ?? MissionControlWindowRecord(
                    id: identity, bounds: nil, desktopIDs: nil, isMinimized: nil)
                record.verify(bounds: bounds, desktopIDs: desktops, minimized: minimized,
                              requirement: SidebarFocusRequirement(element: window, launchDate: app.launchDate),
                              now: ProcessInfo.processInfo.systemUptime)
                records[identity] = record
                validated.insert(identity)
            }
            windowCursors[app.pid] = cursor + processed
            if current != nil && candidates.isSubset(of: foundIDs), processed == found.windows.count,
               !found.needsAnotherPass {
                records = records.filter { $0.key.pid != app.pid || validated.contains($0.key) }
            }
        }
        guard AXIsProcessTrusted() else {
            reset(clearDiscovery: true)
            return nil
        }
        return MissionControlSnapshot.make(catalog: catalog, applications: applications,
                                           records: Array(records.values), screens: screens)
    }
}
