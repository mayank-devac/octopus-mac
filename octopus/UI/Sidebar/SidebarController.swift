import AppKit
import SwiftUI

@MainActor
final class SidebarController {
    private let inventory = SidebarWindowInventory()
    private let viewState = SidebarViewState()
    private lazy var dragController = SidebarDragController(inventory: inventory)
    private let cycleController: CyclePanelController
    private let panel: SidebarPanel
    private var settingsObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var anchors: [SidebarEntryID: NSView] = [:]
    private var hoveredEntryID: SidebarEntryID?
    private var settings: Settings?
    private var screen: NSScreen?
    private var edgeFrame = CGRect.zero
    private var sidebarFrame = CGRect.zero
    private var wasFullScreen = false
    private var pointerWasInSidebar = false

    private struct Settings: Equatable {
        let enabled = UserDefaults.standard.bool(forKey: "sidebarEnabled")
        let desktopScope = SidebarDesktopScope.saved(UserDefaults.standard.string(forKey: "sidebarDesktopScope"))
        let side = SidebarSide(rawValue: UserDefaults.standard.string(forKey: "sidebarSide") ?? "right") ?? .right
        let position = UserDefaults.standard.double(forKey: "sidebarPosition")
        let monitor = UserDefaults.standard.string(forKey: "sidebarMonitor") ?? "primary"
        let autoHide = UserDefaults.standard.bool(forKey: "sidebarAutoHide")
        let showSingleWindowMenu = UserDefaults.standard.bool(forKey: "sidebarShowSingleWindowMenu")
        let activeAppClickAction = SidebarActiveAppClickAction.saved(UserDefaults.standard.string(forKey: "sidebarActiveAppClickAction"))
        let appSpacing = UserDefaults.standard.double(forKey: "sidebarAppSpacing")

        func matchesExceptAppSpacing(_ other: Settings) -> Bool {
            enabled == other.enabled && desktopScope == other.desktopScope
                && side == other.side && position == other.position
                && monitor == other.monitor && autoHide == other.autoHide
                && showSingleWindowMenu == other.showSingleWindowMenu
                && activeAppClickAction == other.activeAppClickAction
        }
    }

    init(cycleController: CyclePanelController) {
        self.cycleController = cycleController
        panel = SidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        let hostingView = NSHostingView(rootView: SidebarView(
            inventory: inventory, state: viewState,
            onClick: { [weak self] entryID in self?.activate(entryID) },
            onAnchor: { [weak self] entryID, view in self?.anchors[entryID] = view },
            onDrag: { [weak self] entryID, id, title, source, event in
                self?.beginDrag(entryID, target: id, title: title, source: source, event: event)
            },
            onPlacement: { [weak self] id, target in self?.dragController.place(id, at: target) }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        inventory.onChange = { [weak self] in self?.inventoryChanged() }
        inventory.onDesktopChange = { [weak self] in
            self?.cancelInteraction()
            if self?.settings?.desktopScope == .visibleDesktops { self?.panel.orderOut(nil) }
        }
        cycleController.onSidebarActivate = { [weak self] id in self?.inventory.focus(id) }
        cycleController.onSidebarWindowAction = { [weak self] action in self?.inventory.perform(action) }
        cycleController.onSidebarDismiss = { [weak self] in
            self?.updatePointer()
        }
        cycleController.onSidebarDrag = { [weak self] id, title, source, event in
            self?.dragController.begin(id: id, title: title, source: source, event: event)
        }
        cycleController.onSidebarPlacement = { [weak self] id, target in self?.dragController.place(id, at: target) }
        dragController.excludedFrames = { [weak self] in
            guard let self else { return [] }
            var frames = self.panel.isVisible ? [self.panel.frame] : []
            if self.cycleController.sidebarEntryID != nil { frames.append(self.cycleController.panel.frame) }
            return frames
        }
        dragController.onInteractionChange = { [weak self] dragging in
            guard let self else { return }
            if dragging {
                self.cancelPendingHover()
                for work in [self.dismissWork, self.hideWork, self.revealWork] { work?.cancel() }
                self.dismissWork = nil
                self.hideWork = nil
                self.revealWork = nil
            } else {
                self.cycleController.dismissSidebar()
                self.updatePointer()
            }
        }
        inventory.onPlacementResult = { [weak self] result in
            if let message = result.message { self?.dragController.showFeedback(message) }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
        applySettings()
    }

    func stop() {
        stopSidebar()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        cycleController.onSidebarActivate = nil
        cycleController.onSidebarWindowAction = nil
        cycleController.onSidebarDismiss = nil
        cycleController.onSidebarDrag = nil
        cycleController.onSidebarPlacement = nil
        dragController.stop()
        inventory.onPlacementResult = nil
    }

    private func applySettings() {
        let next = Settings()
        guard next != settings else { return }
        let spacingOnlyChange = settings.map {
            $0.matchesExceptAppSpacing(next) && $0.appSpacing != next.appSpacing
        } ?? false
        let wasEnabled = settings?.enabled ?? false
        settings = next
        inventory.setDesktopScope(next.desktopScope)
        if !spacingOnlyChange { cancelInteraction() }
        guard next.enabled else { stopSidebar(); return }
        if !wasEnabled {
            inventory.start()
            installMouseMonitors()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.cancelInteraction()
                    self?.panel.orderOut(nil)
                    self?.layout()
                    self?.inventory.refresh()
                }
            }
        }
        layout()
        if spacingOnlyChange { return }
        if shouldAutoHide { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func stopSidebar() {
        cancelInteraction()
        dragController.stop()
        inventory.stop()
        panel.orderOut(nil)
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private var isFullScreen: Bool {
        guard let screen, let id = SidebarSettings.displayID(screen) else { return false }
        return inventory.fullScreenDisplays.contains(id)
    }

    private var shouldAutoHide: Bool { settings?.autoHide == true || isFullScreen }

    private func layout() {
        guard let settings, settings.enabled, let target = SidebarSettings.selectedScreen() else { return }
        screen = target
        let usable = isFullScreen ? target.frame : target.visibleFrame
        let frame = SidebarLayout.sidebarFrame(in: usable, count: inventory.entries.count,
                                              side: settings.side, position: settings.position,
                                              appSpacing: SidebarLayout.appSpacing,
                                              separatorCount: inventory.separatorIndices.count)
        sidebarFrame = frame
        if viewState.side != settings.side { viewState.side = settings.side }
        // Grow only toward the desktop so icons and click targets stay at the edge.
        let drawingFrame = CGRect(
            x: settings.side == .right ? frame.minX - SidebarLayout.drawingPadding : frame.minX,
            y: frame.minY, width: frame.width + SidebarLayout.drawingPadding, height: frame.height
        ).intersection(usable)
        if panel.frame != drawingFrame { panel.setFrame(drawingFrame, display: true) }
        let menuFrame = cycleController.sidebarEntryID == nil ? nil : cycleController.panel.frame
        panel.ignoresMouseEvents = !SidebarLayout.acceptsSidebarPointer(
            at: NSEvent.mouseLocation, sidebar: sidebarFrame, menu: menuFrame)
        edgeFrame = CGRect(x: settings.side == .left ? target.frame.minX : target.frame.maxX - 3,
                           y: frame.minY, width: 3, height: frame.height)
    }

    private func inventoryChanged() {
        guard settings?.enabled == true else { return }
        dragController.validateInventory()
        guard !dragController.isActive else { return }
        layout()
        if isFullScreen && !wasFullScreen { cancelInteraction(); panel.orderOut(nil) }
        wasFullScreen = isFullScreen
        // A refresh must not raise the sidebar over the popup's overlapping edge.
        if !shouldAutoHide, !panel.isVisible { panel.orderFrontRegardless() }
        // A second window can appear while the pointer stays on an app whose menu was hidden.
        if let entryID = cycleController.sidebarEntryID ?? (panel.isVisible ? hoveredEntryID : nil) {
            if let entry = inventory.entries.first(where: { $0.id == entryID }), let icon = iconFrame(entryID) {
                showMenu(entry, icon: icon)
            } else {
                cycleController.dismissSidebar()
            }
        }
        updatePointer()
    }

    private func iconFrame(_ entryID: SidebarEntryID) -> CGRect? {
        guard let view = anchors[entryID], let window = view.window else { return nil }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        guard rect.intersects(sidebarFrame), !view.visibleRect.isEmpty else { return nil }
        // Reserve the enlarged icon's width so it cannot grow over the menu.
        let contentHeight = SidebarLayout.iconSlotHeight + SidebarLayout.labelHeight
        let iconCenterY = rect.maxY - (SidebarLayout.rowHeight - contentHeight) / 2 - SidebarLayout.iconSlotHeight / 2
        let size = SidebarLayout.iconSize * (1 + SidebarLayout.magnificationGrowth)
        return CGRect(x: rect.midX - size / 2, y: iconCenterY - size / 2, width: size, height: size)
    }

    private func sidebarRowFrame(_ entryID: SidebarEntryID) -> CGRect? {
        guard let view = anchors[entryID], let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func hoveredSidebarEntryID(at point: CGPoint) -> SidebarEntryID? {
        inventory.entries.first { entry in
            sidebarRowFrame(entry.id)?.contains(point) == true
        }?.id
    }

    private func cancelPendingHover() {
        hoverWork?.cancel()
        hoverWork = nil
    }

    private func hover(_ entryID: SidebarEntryID, inside: Bool) {
        guard settings?.enabled == true else { return }
        cancelPendingHover()
        if inside {
            hoveredEntryID = entryID
            dismissWork?.cancel()
            dismissWork = nil
            if cycleController.sidebarEntryID == entryID {
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoveredEntryID == entryID, self.panel.isVisible,
                      !self.cycleController.isKeyboardSwitcherVisible else { return }
                let point = NSEvent.mouseLocation
                guard self.sidebarFrame.contains(point), self.hoveredSidebarEntryID(at: point) == entryID,
                      !(self.cycleController.sidebarEntryID != nil && self.cycleController.panel.frame.contains(point)) else {
                    self.hoverWork = nil
                    self.updatePointer()
                    return
                }
                self.hoverWork = nil
                // Show the published list immediately and refresh in the background.
                if let entry = self.inventory.entries.first(where: { $0.id == entryID }), let icon = self.iconFrame(entryID) {
                    self.showMenu(entry, icon: icon)
                }
                self.inventory.refresh()
            }
            hoverWork = work
            DispatchQueue.main.async(execute: work)
        } else {
            if hoveredEntryID == entryID { hoveredEntryID = nil }
            updatePointer()
        }
    }

    private func showMenu(_ entry: SidebarEntry, icon: CGRect) {
        guard let screen, let settings else { return }
        guard !entry.windows.isEmpty,
              entry.windows.count > 1 || entry.hasOtherWindows || settings.showSingleWindowMenu else {
            cycleController.dismissSidebar()
            return
        }
        cycleController.showSidebar(for: entry, icon: icon,
                                    screen: isFullScreen ? screen.frame : screen.visibleFrame, side: settings.side)
    }

    private func activate(_ entryID: SidebarEntryID) {
        cancelPendingHover()
        guard let entry = inventory.entries.first(where: { $0.id == entryID }) else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let action = SidebarIconClickPolicy.action(for: entry, frontmostPID: frontmostPID,
                                                  setting: settings?.activeAppClickAction ?? .minimize)
        cycleController.dismissSidebar()
        if let action { inventory.perform(action, frontmostPID: frontmostPID) }
        else { inventory.refresh() }
    }

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.handleMouse(event)
            }
        }
    }

    private func handleMouse(_ event: NSEvent) {
        guard !dragController.isActive else { return }
        let point = NSEvent.mouseLocation
        // One pointer-position path owns row and button hover. Native row/button hover
        // callbacks must not compete with it or miss movement over overlapping controls.
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged].contains(event.type) {
            cycleController.updateSidebarPointer(at: point)
        } else if event.type == .scrollWheel {
            // Scroll views update their row geometry after the event is delivered.
            DispatchQueue.main.async { [weak self] in
                self?.cycleController.updateSidebarPointer(at: NSEvent.mouseLocation)
            }
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           !sidebarFrame.contains(point),
           !(cycleController.sidebarEntryID != nil && cycleController.panel.frame.contains(point)) {
            cancelPendingHover()
            hoveredEntryID = nil
            cycleController.dismissSidebar()
        }
        if event.type == .scrollWheel, panel.isVisible, sidebarFrame.contains(point) {
            // A scrolling icon is no longer a stable menu anchor.
            cancelPendingHover()
            hoveredEntryID = nil
            cycleController.dismissSidebar()
        }
        updatePointer()
    }

    private func updatePointer() {
        guard settings?.enabled == true, !dragController.isActive else { return }
        let point = NSEvent.mouseLocation
        let inSidebar = panel.isVisible && sidebarFrame.contains(point)
        let inMenu = cycleController.sidebarEntryID != nil && cycleController.panel.frame.contains(point)
        // The popup can overlap the sidebar's wide icon hit area. Give it all input there.
        panel.ignoresMouseEvents = !panel.isVisible || !SidebarLayout.acceptsSidebarPointer(
            at: point, sidebar: sidebarFrame,
            menu: cycleController.sidebarEntryID == nil ? nil : cycleController.panel.frame)
        let inEdge = edgeFrame.contains(point)

        // Pointer position is the only hover source. Rebuilding native tracking areas
        // during magnification must not generate exits or reopen the same app's menu.
        let pointerEntryID = inSidebar && !inMenu ? hoveredSidebarEntryID(at: point) : nil
        let highlightedEntryID = pointerEntryID ?? (inMenu ? hoveredEntryID : nil)
        if viewState.highlightedEntryID != highlightedEntryID { viewState.highlightedEntryID = highlightedEntryID }
        if let pointerEntryID, pointerEntryID != hoveredEntryID {
            hover(pointerEntryID, inside: true)
        } else if pointerEntryID == nil, let hoveredEntryID, !inMenu {
            hover(hoveredEntryID, inside: false)
        }

        if inSidebar, !pointerWasInSidebar, inventory.entries.isEmpty { inventory.refresh() }
        pointerWasInSidebar = inSidebar

        if cycleController.sidebarEntryID != nil, hoveredEntryID == nil, !inMenu {
            if dismissWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.dismissWork = nil
                    guard self.hoveredEntryID == nil, !self.cycleController.panel.frame.contains(NSEvent.mouseLocation) else { return }
                    self.cycleController.dismissSidebar()
                }
                dismissWork = work
                // Allow a brief accidental exit; returning to the menu cancels this work.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        } else {
            dismissWork?.cancel()
            dismissWork = nil
        }

        if !panel.isVisible, inEdge, !cycleController.isKeyboardSwitcherVisible {
            if revealWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.revealWork = nil
                    guard self.settings?.enabled == true, self.edgeFrame.contains(NSEvent.mouseLocation),
                          !self.cycleController.isKeyboardSwitcherVisible else { return }
                    self.panel.orderFrontRegardless()
                    self.inventory.refresh()
                    self.updatePointer()
                }
                revealWork = work
                // Reveal immediately when the pointer reaches the edge.
                DispatchQueue.main.async(execute: work)
            }
        } else {
            revealWork?.cancel()
            revealWork = nil
        }

        // Keep auto-hide from bypassing the window menu's dismissal grace period.
        if shouldAutoHide, panel.isVisible, !inSidebar, !inMenu, !inEdge,
           cycleController.sidebarEntryID == nil {
            if hideWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hideWork = nil
                    let point = NSEvent.mouseLocation
                    guard self.shouldAutoHide, !self.sidebarFrame.contains(point), !self.edgeFrame.contains(point),
                          !(self.cycleController.sidebarEntryID != nil && self.cycleController.panel.frame.contains(point)) else { return }
                    self.panel.orderOut(nil)
                    self.cycleController.dismissSidebar()
                    self.hoveredEntryID = nil
                    self.viewState.highlightedEntryID = nil
                }
                hideWork = work
                DispatchQueue.main.async(execute: work)
            }
        } else {
            hideWork?.cancel()
            hideWork = nil
        }
    }

    private func cancelInteraction() {
        dragController.cancel()
        hoveredEntryID = nil
        cycleController.dismissSidebar()
        cancelPendingHover()
        for work in [dismissWork, revealWork, hideWork] { work?.cancel() }
        dismissWork = nil
        revealWork = nil
        hideWork = nil
        pointerWasInSidebar = false
        viewState.highlightedEntryID = nil
    }

    private func beginDrag(_ entryID: SidebarEntryID, target: SidebarWindowID?, title: String, source: NSView, event: NSEvent) {
        guard let target else {
            dragController.showFeedback("No current window is available to move. Choose a window from the app's list.")
            if let entry = inventory.entries.first(where: { $0.id == entryID }), let icon = iconFrame(entryID) {
                showMenu(entry, icon: icon)
            }
            return
        }
        dragController.begin(id: target, title: title, source: source, event: event)
    }
}

private final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
