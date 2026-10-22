import AppKit

struct MissionControlTarget {
    let id: String
    let screen: NSScreen
    let side: SidebarSide
    let position: Double
}

enum MissionControlPlacement {
    static func availableFrame(screen: CGRect, visibleFrame: CGRect) -> CGRect {
        let visible = screen.intersection(visibleFrame)
        guard !visible.isNull else { return .zero }
        // Leave room for Mission Control's expanded desktop strip as well as
        // the menu bar and Dock already excluded by the screen's visible frame.
        let desktopStripHeight = max(180, screen.height * 0.2)
        let top = min(visible.maxY, screen.maxY - desktopStripHeight)
        return CGRect(x: visible.minX, y: visible.minY + 8, width: visible.width,
                      height: max(0, top - visible.minY - 16))
    }

    static func frame(in available: CGRect, size: CGSize, side: SidebarSide, position: Double) -> CGRect {
        let anchor = SidebarLayout.sidebarFrame(in: available, count: 0, side: side, position: position,
                                                contentHeight: size.height, minimumHeight: 0)
        let width = min(size.width, available.width)
        return CGRect(x: side == .left ? available.minX : available.maxX - width,
                      y: anchor.minY, width: width, height: anchor.height)
    }

    static func collapsed(_ frame: CGRect, side: SidebarSide) -> CGRect {
        CGRect(x: side == .left ? frame.minX : frame.maxX - 1, y: frame.minY, width: 1, height: frame.height)
    }
}

@MainActor
final class MissionControlController {
    private let monitor = MissionControlMonitor()
    private let reader = MissionControlSnapshotReader()
    private let windowSeeds: () -> [SidebarWindowID: AXUIElement]
    private let onVisibilityChange: (Bool) -> Void
    private var targets: [MissionControlTarget] = []
    private var panels: [String: MissionControlPanel] = [:]
    private var visible = false
    private var snapshots = MissionControlSnapshotState()
    private var refreshTimer: Timer?
    private var refreshInFlight = false

    init(windowSeeds: @escaping () -> [SidebarWindowID: AXUIElement], onVisibilityChange: @escaping (Bool) -> Void) {
        self.windowSeeds = windowSeeds
        self.onVisibilityChange = onVisibilityChange
        monitor.onVisibilityChange = { [weak self] visible in self?.setVisible(visible) }
    }

    func updateTargets(_ targets: [MissionControlTarget]) {
        self.targets = targets
        let ids = Set(targets.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) { removePanel(id) }
        if let snapshot = snapshots.snapshot, snapshot.screens != connectedScreens() {
            snapshots.reset()
            for id in Array(panels.keys) { removePanel(id) }
            reader.queue.async { [reader] in reader.reset() }
        }
        monitor.setEnabled(!targets.isEmpty)
        if visible { present(); refresh() }
    }

    func stop() {
        monitor.stop()
        setVisible(false)
        refreshTimer?.invalidate()
        refreshTimer = nil
        for id in Array(panels.keys) { removePanel(id) }
        targets.removeAll()
        reader.queue.async { [reader] in reader.reset(clearDiscovery: true) }
    }

    private func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        snapshots.reset()
        let clearDiscovery = !AXIsProcessTrusted()
        reader.queue.async { [reader] in reader.reset(clearDiscovery: clearDiscovery) }
        if visible {
            onVisibilityChange(true)
            let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.1
            refreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            refresh()
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            for id in Array(panels.keys) { removePanel(id) }
            onVisibilityChange(false)
        }
    }

    private func connectedScreens() -> [MissionControlScreen] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = SidebarSettings.displayID(screen),
                  let id = SidebarSettings.monitorID(screen) else { return nil }
            let bounds = CGDisplayBounds(displayID)
            guard MissionControlSnapshot.validBounds(bounds) else { return nil }
            return MissionControlScreen(id: id, bounds: bounds)
        }.sorted { $0.id < $1.id }
    }

    private func refresh() {
        guard visible, !targets.isEmpty, !refreshInFlight, AXIsProcessTrusted() else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map { app in
            MissionControlApplication(pid: app.processIdentifier, name: app.localizedName ?? "Application",
                icon: app.icon ?? app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                    ?? NSImage(named: NSImage.applicationIconName), isHidden: app.isHidden)
        }
        let screens = connectedScreens()
        let seeds = windowSeeds()
        let generation = snapshots.generation
        refreshInFlight = true
        reader.queue.async { [weak self, reader] in
            let snapshot = reader.read(applications: apps, screens: screens, seeds: seeds)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard self.visible, generation == self.snapshots.generation, screens == self.connectedScreens() else {
                    if self.visible { self.refresh() }
                    return
                }
                guard AXIsProcessTrusted(), self.snapshots.receive(snapshot, generation: generation) else { return }
                self.present()
            }
        }
    }

    private func removePanel(_ id: String) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func present() {
        guard let snapshot = snapshots.snapshot else { return }
        for target in targets {
            let available = MissionControlPlacement.availableFrame(screen: target.screen.frame,
                                                                   visibleFrame: target.screen.visibleFrame)
            guard let layout = MissionControlLayout.make(snapshot: snapshot, screenID: target.id,
                screenSize: target.screen.frame.size, availableSize: available.size) else {
                removePanel(target.id)
                continue
            }
            let frame = MissionControlPlacement.frame(in: available, size: layout.size,
                                                     side: target.side, position: target.position)
            if let panel = panels[target.id] {
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                (panel.contentView as? MissionControlView)?.configure(layout: layout, applications: snapshot.applications, side: target.side)
                continue
            }
            let panel = MissionControlPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isMovable = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.level = .screenSaver
            let view = MissionControlView(frame: CGRect(origin: .zero, size: frame.size))
            view.autoresizingMask = [.width, .height]
            view.configure(layout: layout, applications: snapshot.applications, side: target.side)
            panel.contentView = view
            panels[target.id] = panel
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.orderFrontRegardless()
            } else {
                panel.setFrame(MissionControlPlacement.collapsed(frame, side: target.side), display: false)
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
    }
}

private final class MissionControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
