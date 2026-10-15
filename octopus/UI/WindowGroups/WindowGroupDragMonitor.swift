import AppKit

struct WindowGroupSurface {
    let id: SidebarWindowID
    let frame: CGRect // AX coordinates
}

@MainActor
final class WindowGroupDragMonitor {
    var enabled: () -> Bool = { false }
    var excludedWindows: (SidebarWindowID) -> Set<SidebarWindowID> = { [$0] }
    var prepare: ((SidebarWindowID, SidebarWindowID, CGRect, @escaping (CGRect?) -> Void) -> Void)?
    var commit: ((SidebarWindowID, SidebarWindowID) -> Void)?
    var onCancel: () -> Void = {}
    var onInput: () -> Void = {}
    var onRelease: () -> Void = {}
    var onGeometryChange: () -> Void = {}
    private var monitor: Any?
    private var localMonitor: Any?
    private var source: WindowGroupSurface?
    private var hover: WindowTabHover?
    private var moved = false
    private var readyTarget: SidebarWindowID?
    private var dwellWork: DispatchWorkItem?
    private var preview: NSPanel?
    private var revision = 0
    private var lastUpdate: TimeInterval = 0

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                                               .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.cancel()
                self?.onInput()
            }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            cancel()
            onInput()
            guard enabled(), AXIsProcessTrusted(),
                  let hit = Self.surface(at: Self.pointer(), excluding: []) else { return }
            source = hit
            hover = WindowTabHover(source: hit.id)
        case .leftMouseDragged:
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastUpdate >= 0.04 else { return }
            lastUpdate = now
            onGeometryChange()
            update(at: Self.pointer(), now: now)
        case .leftMouseUp:
            let point = Self.pointer()
            if enabled(), let source, let target = readyTarget,
               Self.surface(at: point, excluding: excludedWindows(source.id))?.id == target,
               let live = Self.surface(id: target), WindowTabGeometry.centre(of: live.frame).contains(point) {
                commit?(source.id, target)
            }
            cancel()
            onRelease()
        case .keyDown, .rightMouseDown, .otherMouseDown:
            cancel()
            onInput()
        default: break
        }
    }

    private func update(at point: CGPoint, now: TimeInterval) {
        guard enabled(), let source, let current = Self.surface(id: source.id) else { cancel(); return }
        // Moving content, dragging a file, and resizing a window must never form tabs.
        guard abs(current.frame.width - source.frame.width) < 2,
              abs(current.frame.height - source.frame.height) < 2 else { cancel(); return }
        moved = moved || hypot(current.frame.minX - source.frame.minX, current.frame.minY - source.frame.minY) >= 4
        guard moved else { return }
        let candidate = Self.surface(at: point, excluding: excludedWindows(source.id))
        let next = candidate.flatMap { WindowTabGeometry.centre(of: $0.frame).contains(point) ? $0.id : nil }
        guard hover?.target != next else { return }
        clearHover()
        hover?.update(target: next, at: now)
        guard let next else { return }
        let expectedRevision = revision
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision == expectedRevision, self.enabled(),
                  NSEvent.pressedMouseButtons & 1 != 0,
                  self.hover?.isReady(at: ProcessInfo.processInfo.systemUptime) == true,
                  let candidate = Self.surface(at: Self.pointer(), excluding: self.excludedWindows(source.id)),
                  candidate.id == next, WindowTabGeometry.centre(of: candidate.frame).contains(Self.pointer()) else { return }
            self.prepare?(source.id, next, source.frame) { [weak self] frame in
                guard let self, self.revision == expectedRevision, self.enabled(), NSEvent.pressedMouseButtons & 1 != 0,
                      let frame, Self.surface(at: Self.pointer(), excluding: self.excludedWindows(source.id))?.id == next,
                      WindowTabGeometry.centre(of: candidate.frame).contains(Self.pointer()) else { return }
                self.readyTarget = next
                self.showPreview(frame)
            }
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowTabGeometry.dwell, execute: work)
    }

    private func showPreview(_ axFrame: CGRect) {
        let frame = SidebarPlacementGeometry.flip(axFrame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16)
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = SidebarWindowLevels.dragPreview
        panel.collectionBehavior = [.stationary]
        let label = NSTextField(labelWithString: "Release to group as tabs")
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.frame = CGRect(x: 12, y: frame.height / 2 - 15, width: max(0, frame.width - 24), height: 30)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        panel.contentView?.addSubview(label)
        panel.orderFrontRegardless()
        preview = panel
    }

    private func clearHover() {
        revision += 1
        dwellWork?.cancel()
        dwellWork = nil
        readyTarget = nil
        preview?.close()
        preview = nil
        onCancel()
    }

    func cancel() {
        clearHover()
        source = nil
        hover = nil
        moved = false
        lastUpdate = 0
    }

    func stop() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
    }

    static func pointer() -> CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    static func surface(id: SidebarWindowID) -> WindowGroupSurface? {
        guard let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.windowID) as? [[String: Any]],
              let record = records.first,
              (record[kCGWindowIsOnscreen as String] as? Bool) == true,
              let surface = decode(record), surface.id == id else { return nil }
        return surface
    }

    static func frontmostWindow(pid: pid_t) -> SidebarWindowID? {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        // The first normal surface of the active app must be a group member.
        // Another window or a sheet of the same app leaves its own shortcut alone.
        guard let first = records.first(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }) else { return nil }
        return decode(first)?.id
    }

    static func surface(at point: CGPoint, excluding: Set<SidebarWindowID>) -> WindowGroupSurface? {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for record in records {
            guard let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point),
                  let number = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let id = SidebarWindowID(pid: pid, windowID: number)
            if excluding.contains(id) { continue }
            // Menus, sheets, and other app overlays block the drop beneath them.
            guard (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  !app.isHidden, !app.isTerminated else { return nil }
            return WindowGroupSurface(id: id, frame: frame)
        }
        return nil
    }

    private static func decode(_ record: [String: Any]) -> WindowGroupSurface? {
        guard let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let number = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = record[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), SidebarPlacementGeometry.isValid(frame) else { return nil }
        return WindowGroupSurface(id: SidebarWindowID(pid: pid, windowID: number), frame: frame)
    }
}
