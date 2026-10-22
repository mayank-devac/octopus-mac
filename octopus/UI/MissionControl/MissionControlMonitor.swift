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
        var owners: [(String, MissionControlAXProbe.Owner)] = [
            ("com.apple.dock", .dock), ("com.apple.WindowManager", .windowManager)
        ]
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 { owners.reverse() }
        let sources = owners.compactMap { bundleID, owner -> (pid_t, MissionControlAXProbe.Owner)? in
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.processIdentifier else { return nil }
            return (pid, owner)
        }
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
                self.state.receive(completedReading, generation: generation)
                if wasVisible != self.state.isVisible { self.onVisibilityChange?(self.state.isVisible) }
            }
        }
    }
}

enum MissionControlAXProbe {
    enum Owner: Equatable { case dock, windowManager }

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
