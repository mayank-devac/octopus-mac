import AppKit
import ApplicationServices

enum MissionControlReading: Equatable {
    case hidden, visible, unavailable
}

struct MissionControlMonitorState {
    enum Phase: Equatable {
        case stopped
        case monitoring(MissionControlReading)
    }

    private(set) var phase: Phase = .stopped
    private(set) var generation = 0
    var isVisible: Bool { phase == .monitoring(.visible) }

    mutating func start() {
        guard phase == .stopped else { return }
        generation += 1
        phase = .monitoring(.hidden)
    }

    mutating func stop() {
        guard phase != .stopped else { return }
        generation += 1
        phase = .stopped
    }

    mutating func receive(_ reading: MissionControlReading, generation: Int) {
        guard phase != .stopped, generation == self.generation else { return }
        phase = .monitoring(reading)
    }
}

@MainActor
final class MissionControlMonitor {
    var onVisibilityChange: ((Bool) -> Void)?
    var onStopped: (() -> Void)?
    var onReading: ((MissionControlReading) -> Void)?
    var isRunning: Bool { state.phase != .stopped }
    private var state = MissionControlMonitorState()
    private let queue = DispatchQueue(label: "com.octopus.mission-control", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var enabled = false
    private enum Suspension: Hashable { case systemSleep, displaySleep, inactiveSession }
    private var suspensions = Set<Suspension>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let lifecycle: [(Suspension, Notification.Name, Notification.Name)] = [
            (.systemSleep, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (.displaySleep, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (.inactiveSession, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ]
        for (reason, suspend, resume) in lifecycle {
            workspaceObservers.append(workspace.addObserver(forName: suspend, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspensions.insert(reason)
                    self?.reconcile()
                }
            })
            workspaceObservers.append(workspace.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspensions.remove(reason)
                    self?.reconcile()
                }
            })
        }
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } })
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reconcile()
    }

    func stop() {
        enabled = false
        reconcile()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func reconcile() {
        guard enabled, suspensions.isEmpty, AXIsProcessTrusted() else {
            timer?.invalidate()
            timer = nil
            let wasVisible = state.isVisible
            let wasRunning = isRunning
            state.stop()
            if wasVisible { onVisibilityChange?(false) }
            if wasRunning { onStopped?() }
            return
        }
        guard timer == nil else { return }
        state.start()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.04
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    private func poll() {
        guard AXIsProcessTrusted() else { reconcile(); return }
        guard !inFlight else { return }
        let sources = MissionControlAXProbe.sources()
        let generation = state.generation
        inFlight = true
        queue.async { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 0.16
            var reading: MissionControlReading = sources.isEmpty ? .unavailable : .hidden
            for (pid, owner) in sources {
                let result = MissionControlAXProbe.read(pid: pid, owner: owner, deadline: deadline)
                if result == .visible { reading = .visible; break }
                if result == .unavailable { reading = .unavailable }
            }
            let completedReading = reading
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard AXIsProcessTrusted() else { self.reconcile(); return }
                let wasVisible = self.state.isVisible
                guard generation == self.state.generation, self.isRunning else { return }
                self.state.receive(completedReading, generation: generation)
                self.onReading?(completedReading)
                if wasVisible != self.state.isVisible { self.onVisibilityChange?(self.state.isVisible) }
            }
        }
    }
}

enum MissionControlAXProbe {
    enum Owner: Equatable { case dock, windowManager }

    static func sources() -> [(pid_t, Owner)] {
        var owners: [(String, Owner)] = [("com.apple.dock", .dock), ("com.apple.WindowManager", .windowManager)]
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 { owners.reverse() }
        return owners.compactMap { bundleID, owner in
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.processIdentifier else { return nil }
            return (pid, owner)
        }
    }

    static func reading(deadline: TimeInterval) -> MissionControlReading {
        let owners = sources()
        var result: MissionControlReading = owners.isEmpty ? .unavailable : .hidden
        for (pid, owner) in owners {
            let next = read(pid: pid, owner: owner, deadline: deadline)
            if next == .visible { return .visible }
            if next == .unavailable { result = .unavailable }
        }
        return result
    }

    // Require one exact display and one complete Spaces list. Never infer a monitor
    // from array position or a localised desktop title.
    static func spaceButtons<Node>(root: Node, owner: Owner, displayID: CGDirectDisplayID,
                                   children: (Node) -> [Node]?, identifier: (Node) -> String?,
                                   screen: (Node) -> CGDirectDisplayID?) -> [Node]? {
        guard let roots = children(root) else { return nil }
        let displays: [Node]
        if owner == .dock {
            let groups = roots.filter { identifier($0) == "mc" }
            guard groups.count == 1, let group = groups.first, let items = children(group) else { return nil }
            displays = items
        } else { displays = roots }
        let matches = displays.filter { identifier($0) == "mc.display" && screen($0) == displayID }
        guard matches.count == 1, let display = matches.first, let groups = children(display) else { return nil }
        let spaces = groups.filter { identifier($0) == "mc.spaces" }
        guard spaces.count == 1, let space = spaces.first, let groups = children(space) else { return nil }
        let lists = groups.filter { identifier($0) == "mc.spaces.list" }
        guard lists.count == 1, let list = lists.first else { return nil }
        return children(list)
    }

    static func selectionButtons(displayID: CGDirectDisplayID, deadline: TimeInterval) -> [AXUIElement]? {
        for (pid, owner) in sources() {
            let buttons = spaceButtons(root: AXUIElementCreateApplication(pid), owner: owner, displayID: displayID,
                children: { element in
                    // Unlike visibility probing, action mapping requires complete
                    // groups so a truncated tree cannot hide an ambiguous match.
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                    AXUIElementSetMessagingTimeout(element, 0.04)
                    var count: CFIndex = 0
                    guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
                          count <= 128 else { return nil }
                    return readChildren(of: element, limit: 128, deadline: deadline)
                }, identifier: { identifier(of: $0, deadline: deadline) }, screen: {
                    let value: NSNumber? = $0.getAttributeValue(NSAccessibility.Attribute(rawValue: "AXDisplayID"))
                    return value?.uint32Value
                })
            if let buttons, !buttons.isEmpty {
                guard buttons.allSatisfy({ button in
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                    AXUIElementSetMessagingTimeout(button, 0.04)
                    let role: String? = button.getAttributeValue(.role)
                    var actions: CFArray?
                    return role == kAXButtonRole as String
                        && AXUIElementCopyActionNames(button, &actions) == .success
                        && (actions as? [String])?.contains(kAXPressAction as String) == true
                }) else { return nil }
                return buttons
            }
        }
        return nil
    }

    static func read(pid: pid_t, owner: Owner, deadline: TimeInterval) -> MissionControlReading {
        classify(root: AXUIElementCreateApplication(pid), owner: owner,
                 children: { readChildren(of: $0, limit: 64, deadline: deadline) },
                 identifier: { identifier(of: $0, deadline: deadline) })
    }

    // Hammerspoon's Dock tree starts at "mc". On macOS 27, WindowManager
    // owns the display groups directly; Dock's empty stub is not evidence of visibility.
    static func classify<Node>(root: Node, owner: Owner, children: (Node) -> [Node]?,
                               identifier: (Node) -> String?) -> MissionControlReading {
        guard let rootChildren = children(root) else { return .unavailable }
        var displays = rootChildren
        if owner == .dock {
            displays = []
            for child in rootChildren {
                guard let id = identifier(child) else { return .unavailable }
                if id == "mc" {
                    guard let groups = children(child) else { return .unavailable }
                    displays = groups
                    break
                }
            }
        }
        for display in displays {
            guard let id = identifier(display) else { return .unavailable }
            guard id == "mc.display" else { continue }
            guard let groups = children(display) else { return .unavailable }
            for group in groups {
                guard let id = identifier(group) else { return .unavailable }
                if id == "mc.spaces" { return .visible }
            }
        }
        return .hidden
    }

    private static func readChildren(of element: AXUIElement, limit: Int, deadline: TimeInterval) -> [AXUIElement]? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.04)
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else { return nil }
        var children: [AXUIElement] = []
        for range in childRanges(count: count, limit: limit) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var value: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString,
                range.lowerBound, range.count, &value) == .success,
                  let elements = value as? [AXUIElement] else { return nil }
            children += elements
        }
        return children
    }

    static func childRanges(count: Int, limit: Int) -> [Range<Int>] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return [0..<count] }
        // WindowManager places its Spaces strip after window thumbnails. Inspect
        // both ends without letting a crowded desktop turn into an unbounded scan.
        let tail = max(1, limit / 2)
        return [(count - tail)..<count, 0..<(limit - tail)].filter { !$0.isEmpty }
    }

    private static func identifier(of element: AXUIElement, deadline: TimeInterval) -> String? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.04)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return "" }
        guard result == .success else { return nil }
        return value as? String
    }
}
