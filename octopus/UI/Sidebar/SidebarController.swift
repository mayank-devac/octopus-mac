import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
final class SidebarController {
    private let cycleController: CyclePanelController
    private var displays: [SidebarDisplayTarget: SidebarDisplayController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var radialPresented = false
    private var missionControlPresented = false
    private lazy var missionControl = MissionControlController(windowSeeds: { [weak self] in
        self?.displays.values.reduce(into: [SidebarWindowID: AXUIElement]()) { seeds, display in
            seeds.merge(display.missionControlWindowSeeds) { existing, _ in existing }
        } ?? [:]
    }) { [weak self] presented in
        guard let self else { return }
        self.missionControlPresented = presented
        self.displays.values.forEach { $0.setMissionControlPresented(presented) }
    }
    var hasActiveInteraction: Bool { missionControlPresented || displays.values.contains { $0.hasActiveInteraction } }

    func setRadialPresented(_ presented: Bool) {
        radialPresented = presented
        displays.values.forEach { $0.setRadialPresented(presented) }
    }

    init(cycleController: CyclePanelController) {
        self.cycleController = cycleController
        for (index, name) in SidebarNumberShortcuts.names.enumerated() {
            SidebarNumberShortcuts.assign(nil, to: name)
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.activateNumberedApp(at: index) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reconcile() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reconcile(screensChanged: true) } })
        reconcile()
    }

    private func reconcile(screensChanged: Bool = false) {
        let defaults = UserDefaults.standard
        let multiDisplay = defaults.bool(forKey: SidebarSettings.multiDisplayKey)
        let screens = NSScreen.screens
        if multiDisplay {
            for screen in screens {
                guard let id = SidebarSettings.monitorID(screen) else { continue }
                SidebarSettings.rememberDisplay(id: id, name: screen.localizedName)
            }
        }
        let targets = SidebarSettings.targets(connectedDisplayIDs: screens.compactMap(SidebarSettings.monitorID))
        for id in Array(displays.keys) where !targets.contains(id) {
            displays.removeValue(forKey: id)?.stop()
        }
        for id in targets {
            if let controller = displays[id] {
                controller.applySettings()
                if screensChanged { controller.screensChanged() }
            } else {
                let controller = SidebarDisplayController(cycleController: cycleController, displayID: id.displayID)
                controller.setRadialPresented(radialPresented)
                controller.setMissionControlPresented(missionControlPresented)
                controller.otherSidebarFrames = { [weak self] in
                    self?.displays.values.flatMap { $0.interactionFrames } ?? []
                }
                controller.otherDragActive = { [weak self] in
                    self?.displays.contains { $0.key != id && $0.value.isDragging } ?? false
                }
                controller.pairTargetsProvider = { [weak self] in self?.displays.values.flatMap { $0.pairTargets } ?? [] }
                controller.onPairHover = { [weak self] target, direction in
                    self?.displays.values.forEach { $0.showPairHighlight(target, direction: direction) }
                }
                controller.onTabGroupHover = { [weak self] target in
                    self?.displays.values.forEach { $0.showTabGroupHighlight(target) }
                }
                controller.onPairDragState = { [weak self] active in
                    self?.displays.values.forEach { $0.freezePairCatalogue(active) }
                }
                controller.onPairDragScroll = { [weak self] point in
                    self?.displays.values.forEach { $0.scrollSidebarDuringDrag(at: point) }
                }
                displays[id] = controller
            }
        }
        missionControl.updateTargets(displays.values.compactMap { $0.missionControlTarget })
        let enabled = defaults.bool(forKey: SidebarNumberShortcuts.enabledKey) && !displays.isEmpty
        let unavailable = enabled ? SidebarNumberShortcuts.unavailablePositions() : []
        let shortcuts = SidebarNumberShortcuts.shortcuts
        for (index, name) in SidebarNumberShortcuts.names.enumerated() {
            let shortcut = enabled && !unavailable.contains(index) ? shortcuts[index] : nil
            SidebarNumberShortcuts.assign(shortcut, to: name)
        }
    }

    private func activateNumberedApp(at index: Int) {
        guard UserDefaults.standard.bool(forKey: SidebarNumberShortcuts.enabledKey),
              !radialPresented, !missionControlPresented, !hasActiveInteraction, !cycleController.isKeyboardSwitcherVisible,
              !SidebarNumberShortcuts.unavailablePositions().contains(index) else { return }
        if let single = displays[.single] {
            single.activateNumberedApp(at: index)
        } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
                  let id = SidebarSettings.monitorID(screen) {
            displays[.display(id)]?.activateNumberedApp(at: index)
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        SidebarNumberShortcuts.names.forEach { SidebarNumberShortcuts.assign(nil, to: $0) }
        displays.values.forEach { $0.stop() }
        displays.removeAll()
        missionControl.stop()
    }

    func focusWindow(_ id: SidebarWindowID, completion: @escaping (Bool) -> Void) -> SidebarPendingAction? {
        guard let owner = displays.values.first(where: { $0.containsWindow(id) }) else { completion(false); return nil }
        return owner.focusWindow(id, completion: completion)
    }
}

// Each display owns its panel, hover state and drag session. The window popup is shared.
@MainActor
private final class SidebarDisplayController {
    private let inventory = SidebarWindowInventory()
    private var radialPresented = false
    private var missionControlPresented = false

    func setMissionControlPresented(_ presented: Bool) {
        guard missionControlPresented != presented else { return }
        missionControlPresented = presented
        if presented {
            cancelInteraction()
            anchors.values.forEach { ($0 as? SidebarPointerRegion.PointerView)?.cancelOperation(nil) }
            desktopMenu.hide()
            viewState.isExpanded = false
            panel.ignoresMouseEvents = true
            notchPanel.ignoresMouseEvents = true
            panel.orderOut(nil)
            notchPanel.orderOut(nil)
        } else {
            notchPanel.ignoresMouseEvents = false
            layout()
            restoreSidebarIfNeeded()
            updatePointer()
        }
    }

    private var targetScreen: NSScreen? {
        if let displayID {
            return NSScreen.screens.first { SidebarSettings.monitorID($0) == displayID }
        }
        return SidebarSettings.selectedScreen()
    }

    private func notchTrigger(on screen: NSScreen) -> CGRect? {
        guard let settings, settings.idleBehavior == .notch else { return nil }
        return SidebarLayout.notchTriggerFrame(
            screenFrame: screen.frame, safeTopInset: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
            virtualWidth: CGFloat(settings.configuration.virtualNotchWidth))
    }

    var missionControlTarget: MissionControlTarget? {
        guard let settings, settings.enabled, let screen = targetScreen,
              let id = SidebarSettings.monitorID(screen) else { return nil }
        return MissionControlTarget(id: id, screen: screen, side: settings.side, position: settings.position)
    }

    var missionControlWindowSeeds: [SidebarWindowID: AXUIElement] {
        var seeds: [SidebarWindowID: AXUIElement] = [:]
        for entry in inventory.entries {
            for window in entry.windows {
                guard let id = window.cgWindowID else { continue }
                seeds[SidebarWindowID(pid: entry.pid, windowID: id)] = window.element
            }
        }
        return seeds
    }
    var hasActiveInteraction: Bool { dragController.isActive || positionScrollCapture.isActive || frozeForAnotherDrag }
    func setRadialPresented(_ presented: Bool) {
        radialPresented = presented
        if presented { cancelInteraction() }
        else { updatePointer() }
    }
    func containsWindow(_ id: SidebarWindowID) -> Bool {
        inventory.entries.contains { $0.pid == id.pid && $0.windows.contains { $0.cgWindowID == id.windowID } }
    }

    func focusWindow(_ id: SidebarWindowID, completion: @escaping (Bool) -> Void) -> SidebarPendingAction? {
        inventory.focus(id, completion: completion)
    }
    private let viewState = SidebarViewState()
    private lazy var dragController = SidebarDragController(inventory: inventory)
    private let cycleController: CyclePanelController
    private let panel: SidebarPanel
    private let notchPanel: SidebarPanel
    private let displayID: String?
    private let menuOwnerID = UUID()
    var otherSidebarFrames: () -> [CGRect] = { [] }
    var otherDragActive: () -> Bool = { false }
    var pairTargetsProvider: () -> [SidebarIconPairTarget] = { [] }
    var onPairHover: (SidebarIconPairTarget?, PairDropDirection?) -> Void = { _, _ in }
    var onTabGroupHover: (SidebarIconPairTarget?) -> Void = { _ in }
    var onPairDragState: (Bool) -> Void = { _ in }
    var onPairDragScroll: (CGPoint) -> Void = { _ in }
    var isDragging: Bool { dragController.isActive }
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var anchors: [SidebarEntryID: NSView] = [:]
    private var iconAnchors: [SidebarEntryID: NSView] = [:]
    private var frozeForAnotherDrag = false
    private var pairVisibleWindowIDs: Set<SidebarWindowID>?
    private var desktopAnchors: [UInt64: NSView] = [:]
    private var monitorAnchors: [String: NSView] = [:]
    private let desktopMenu = SidebarDesktopMenu()
    private var lastDragScroll: TimeInterval = 0
    private var hoveredEntryID: SidebarEntryID?
    private var settings: Settings?
    private var screen: NSScreen?
    private var edgeFrame = CGRect.zero
    private var sidebarFrame = CGRect.zero
    private var compactFrame = CGRect.zero
    private var notchFrame = CGRect.zero
    private var wasFullScreen = false
    private var needsSpacePresentation = false
    private var pointerWasInSidebar = false
    private let positionScrollCapture = SidebarPositionScrollCapture()
    private var idleOpacityTarget: CGFloat = 1

    private struct Settings: Equatable {
        let configuration: SidebarConfiguration
        let enabled: Bool
        let monitor: String
        var desktopScope: SidebarDesktopScope { configuration.desktopScope }
        var side: SidebarSide { configuration.side }
        var position: Double { configuration.position }
        var idleBehavior: SidebarIdleBehavior { configuration.idleBehavior }
        var showSingleWindowMenu: Bool { configuration.showSingleWindowMenu }
        var appSpacing: Double { configuration.appSpacing }

        init(displayID: String?) {
            configuration = SidebarSettings.configuration(for: displayID)
            enabled = UserDefaults.standard.bool(forKey: "sidebarEnabled") && configuration.enabled
            monitor = displayID ?? UserDefaults.standard.string(forKey: "sidebarMonitor") ?? "primary"
        }

        func matchesExceptAppSpacing(_ other: Settings) -> Bool {
            var adjusted = configuration
            adjusted.appSpacing = other.configuration.appSpacing
            return enabled == other.enabled && monitor == other.monitor && adjusted == other.configuration
        }

        func matchesExceptPosition(_ other: Settings) -> Bool {
            var adjusted = configuration
            adjusted.position = other.configuration.position
            return enabled == other.enabled && monitor == other.monitor && adjusted == other.configuration
        }
    }

    private var ownsMenu: Bool { cycleController.sidebarOwnerID == menuOwnerID }
    private var presentation: SidebarPresentation {
        SidebarPresentation(behavior: settings?.idleBehavior ?? .compact,
                            hasNotchTrigger: !notchFrame.isEmpty, fullScreen: isFullScreen)
    }
    private var pointerFrame: CGRect {
        presentation.pointerFrame(sidebar: sidebarFrame, compact: compactFrame, expanded: viewState.isExpanded)
    }
    private var sidebarEntryID: SidebarEntryID? { ownsMenu ? cycleController.sidebarEntryID : nil }
    var interactionFrames: [CGRect] {
        (panel.isVisible ? [panel.frame] : []) + (notchPanel.isVisible ? [notchPanel.frame] : [])
            + desktopMenu.interactionFrames
    }

    private func dismissSidebar() {
        if ownsMenu { cycleController.dismissSidebar() }
    }

    private func isHoveringMenuOrIcon(_ entryID: SidebarEntryID) -> Bool {
        guard sidebarEntryID == entryID, panel.isVisible else { return false }
        let point = NSEvent.mouseLocation
        return (cycleController.panel.isVisible && cycleController.panel.frame.contains(point))
            || (sidebarFrame.contains(point) && hoveredSidebarEntryID(at: point) == entryID)
    }

    private func claimMenu() {
        guard !ownsMenu else { return }
        cycleController.dismissSidebar()
        cycleController.sidebarOwnerID = menuOwnerID
        configureMenuCallbacks()
    }

    private func configureMenuCallbacks() {
        cycleController.onSidebarActivate = { [weak self] id in self?.inventory.focus(id) }
        cycleController.onSidebarWindowAction = { [weak self] action in self?.inventory.perform(action) }
        cycleController.onSidebarDismiss = { [weak self] in self?.updatePointer() }
        cycleController.onSidebarDrag = { [weak self] id, title, source, event in
            self?.dragController.begin(id: id, title: title, source: source, event: event,
                                       allowDesktopTransfer: true, allowPairing: true)
        }
        cycleController.onSidebarPlacement = { [weak self] id, target in self?.dragController.place(id, at: target) }
    }

    init(cycleController: CyclePanelController, displayID: String?) {
        self.cycleController = cycleController
        self.displayID = displayID
        panel = SidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notchPanel = SidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for window in [panel, notchPanel] {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.level = SidebarWindowLevels.sidebar
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
        }
        let notchHostingView = NSHostingView(rootView: SidebarNotchTriggerView(
            onReveal: { [weak self] in self?.revealSidebarFromPersistentTrigger() }))
        notchHostingView.sizingOptions = []
        notchPanel.contentView = notchHostingView
        notchPanel.level = SidebarWindowLevels.notch
        let hostingView = NSHostingView(rootView: SidebarView(
            inventory: inventory, state: viewState,
            onClick: { [weak self] entryID in self?.activate(entryID) },
            onAnchor: { [weak self] entryID, change in
                guard let self else { return }
                change.apply(to: &self.anchors, id: entryID)
            },
            onIconAnchor: { [weak self] entryID, change in
                guard let self else { return }
                change.apply(to: &self.iconAnchors, id: entryID)
            },
            pairTargetsProvider: { [weak self] in self?.pairTargetsProvider() ?? [] },
            onPairCommand: { source, target, direction in
                AppDelegate.instance?.windowLayoutController.snapPair(WindowPairSnapRequest(source: source,
                    target: target, direction: direction, startedAt: ProcessInfo.processInfo.systemUptime))
            },
            onDrag: { [weak self] entryID, id, title, source, event in
                self?.beginDrag(entryID, target: id, title: title, source: source, event: event)
            },
            onPlacement: { [weak self] id, target in self?.dragController.place(id, at: target) },
            onMouseAction: { [weak self] entryID, action, target in
                self?.performMouseAction(action, entryID: entryID, target: target)
            },
            onDesktopAnchor: { [weak self] id, change in
                guard let self else { return }
                change.apply(to: &self.desktopAnchors, id: id)
            },
            onDesktopTransfer: { [weak self] id, desktop in self?.inventory.moveToDesktop(id, to: desktop) },
            onMonitorAnchor: { [weak self] id, change in
                guard let self else { return }
                change.apply(to: &self.monitorAnchors, id: id)
            },
            onReveal: { [weak self] in self?.revealSidebarFromPersistentTrigger() }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        inventory.onChange = { [weak self] in self?.inventoryChanged() }
        inventory.onDesktopChange = { [weak self] in
            guard let self else { return }
            self.needsSpacePresentation = true
            // All-desktop entries retain their identity across a Space switch. Keep
            // the hovered icon and its menu until pointer/inventory reconciliation,
            // instead of closing and reopening them during the same transition.
            self.cancelInteraction(preservingHoveredEntry: self.settings?.desktopScope == .allDesktops)
            if self.settings?.desktopScope == .visibleDesktops { self.panel.orderOut(nil) }
        }
        dragController.snapDistanceProvider = { [weak self] in
            self?.settings?.configuration.snapDistance ?? SidebarSettings.defaultSnapDistance
        }
        dragController.excludedFrames = { [weak self] in
            guard let self else { return [] }
            var frames = self.otherSidebarFrames()
            if self.sidebarEntryID != nil { frames.append(self.cycleController.panel.frame) }
            frames.append(contentsOf: self.desktopMenu.interactionFrames)
            return frames
        }
        dragController.desktopDropTarget = { [weak self] point, source in self?.desktopDropTarget(at: point, source: source) }
        dragController.pairTargetsProvider = { [weak self] in self?.pairTargetsProvider() ?? [] }
        dragController.onPairHover = { [weak self] target, direction in self?.onPairHover(target, direction) }
        dragController.sourceIsVisible = { [weak self] id in self?.inventory.entries.contains { $0.visibleIDs.contains(id) } == true }
        dragController.preparePair = { source, target, completion in
            guard let controller = AppDelegate.instance?.windowLayoutController else { completion(nil); return nil }
            return controller.preparePair(source: source, target: target, completion: completion)
        }
        dragController.onPairDrop = { request in AppDelegate.instance?.windowLayoutController.snapPair(request) }
        dragController.onTabGroupHover = { [weak self] target in self?.onTabGroupHover(target) }
        dragController.prepareTabGroup = { source, target, completion in
            guard let controller = AppDelegate.instance?.windowTabGroupController else { completion(nil); return nil }
            return controller.prepareTabs(source: source, target: target, completion: completion)
        }
        dragController.onTabGroupDrop = { prepared in AppDelegate.instance?.windowTabGroupController.commitTabs(prepared) }
        dragController.prepareSnap = { window, request, completion in
            guard let controller = AppDelegate.instance?.windowLayoutController else { completion(nil); return nil }
            return controller.prepareSnap(window: window, request: request, completion: completion)
        }
        dragController.onSnapDrop = { prepared in AppDelegate.instance?.windowLayoutController.commitSnap(prepared) }
        dragController.sidebarDragContains = { [weak self] point in
            guard let self else { return false }
            return self.otherSidebarFrames().contains { $0.contains(point) } || self.desktopMenu.contains(point)
        }
        // The pointer can be on another display's sidebar while this controller owns the drag.
        dragController.onSidebarDragUpdate = { [weak self] point in self?.onPairDragScroll(point) }
        dragController.onDesktopHover = { [weak self] desktopID in
            guard let self, self.viewState.dropDesktopID != desktopID else { return }
            self.viewState.dropDesktopID = desktopID
        }
        dragController.onInteractionChange = { [weak self] dragging in
            guard let self else { return }
            if dragging {
                self.updateIdleOpacity(inUse: true)
                self.viewState.dragDesktops = self.inventory.desktops
                self.viewState.dragSections = SidebarDesktopSection.make(entries: self.inventory.entries,
                    desktops: self.inventory.desktops, scope: self.inventory.desktopScope)
                self.viewState.highlightedEntryID = nil
                self.cancelPendingHover()
                for work in [self.dismissWork, self.hideWork, self.revealWork] { work?.cancel() }
                self.dismissWork = nil
                self.hideWork = nil
                self.revealWork = nil
                self.onPairDragState(true)
            } else {
                self.desktopMenu.hide()
                self.viewState.dragDesktops = nil
                self.viewState.dragSections = nil
                self.viewState.dropDesktopID = nil
                self.onPairDragState(false)
                self.dismissSidebar()
                self.layout()
                self.updatePointer()
            }
        }
        inventory.onPlacementResult = { [weak self] result in
            if let message = result.message { self?.dragController.showFeedback(message) }
        }
        applySettings()
    }

    // Freeze displayed identities across all sidebars, while keeping actual window state live.
    func freezePairCatalogue(_ active: Bool) {
        if active {
            // A drag on another display must cancel delayed single clicks before they can hide its source.
            anchors.values.forEach { ($0 as? SidebarPointerRegion.PointerView)?.cancelOperation(nil) }
        }
        if active { pairVisibleWindowIDs = Set(inventory.entries.flatMap { $0.visibleIDs }) }
        else { pairVisibleWindowIDs = nil }
        if active, viewState.dragSections == nil {
            viewState.highlightedEntryID = nil
            cancelPendingHover()
            for work in [dismissWork, hideWork, revealWork] { work?.cancel() }
            dismissWork = nil
            hideWork = nil
            revealWork = nil
            viewState.dragDesktops = inventory.desktops
            viewState.dragSections = SidebarDesktopSection.make(entries: inventory.entries,
                desktops: inventory.desktops, scope: inventory.desktopScope)
            frozeForAnotherDrag = true
        } else if !active, frozeForAnotherDrag {
            viewState.dragSections = nil
            viewState.dragDesktops = nil
            frozeForAnotherDrag = false
            layout()
            updatePointer()
        }
        if !active { showPairHighlight(nil, direction: nil) }
    }

    var pairTargets: [SidebarIconPairTarget] {
        guard panel.isVisible, presentation.showsMainSidebar(expanded: viewState.isExpanded), inventory.hasPermission else { return [] }
        let entries = viewState.dragSections?.flatMap(\.entries) ?? inventory.entries
        return entries.compactMap { entry in
            guard let id = entry.preferredID, let view = iconAnchors[entry.id],
                  let frame = SidebarDesktopDropTarget.visibleFrame(of: view, within: sidebarFrame) else { return nil }
            let excluded = desktopMenu.interactionFrames + (cycleController.panel.isVisible ? [cycleController.panel.frame] : [])
            guard !excluded.contains(where: { $0.intersects(frame) }) else { return nil }
            let live = inventory.entries.first { $0.id == entry.id }
            return SidebarIconPairTarget(ownerID: menuOwnerID, entryID: entry.id, window: id,
                title: entry.application.title, frame: frame, isVisible: live?.visibleIDs.contains(id) == true,
                reservesPairDrop: pairVisibleWindowIDs?.contains(id) == true)
        }
    }

    func showPairHighlight(_ target: SidebarIconPairTarget?, direction: PairDropDirection?) {
        let entry = target?.ownerID == menuOwnerID ? target?.entryID : nil
        if viewState.pairDropEntryID != entry { viewState.pairDropEntryID = entry }
        let selected = entry == nil ? nil : direction
        if viewState.pairDropDirection != selected { viewState.pairDropDirection = selected }
    }

    func showTabGroupHighlight(_ target: SidebarIconPairTarget?) {
        let entry = target?.ownerID == menuOwnerID ? target?.entryID : nil
        if viewState.tabGroupDropEntryID != entry { viewState.tabGroupDropEntryID = entry }
    }

    func stop() {
        stopSidebar()
        if ownsMenu {
            cycleController.sidebarOwnerID = nil
            cycleController.onSidebarActivate = nil
            cycleController.onSidebarWindowAction = nil
            cycleController.onSidebarDismiss = nil
            cycleController.onSidebarDrag = nil
            cycleController.onSidebarPlacement = nil
        }
        dragController.stop()
        inventory.onPlacementResult = nil
        inventory.onDesktopTransferResult = nil
        panel.contentView = nil
        panel.close()
        notchPanel.contentView = nil
        notchPanel.close()
    }

    func applySettings() {
        if positionScrollCapture.isActive,
           positionScrollCapture.modifiers != MouseShortcutStore.shared.positionScrollModifiers {
            positionScrollCapture.stop()
        }
        let next = Settings(displayID: displayID)
        guard next != settings else { return }
        let spacingOnlyChange = settings.map {
            $0.matchesExceptAppSpacing(next) && $0.appSpacing != next.appSpacing
        } ?? false
        let positionOnlyChange = settings.map {
            $0.matchesExceptPosition(next) && $0.position != next.position
        } ?? false
        let wasEnabled = settings?.enabled ?? false
        if settings?.idleBehavior != next.idleBehavior { viewState.isExpanded = false }
        settings = next
        viewState.configuration = next.configuration
        updateInventoryScope(next)
        if (!spacingOnlyChange && !positionOnlyChange) || dragController.isActive { cancelInteraction() }
        guard next.enabled else { stopSidebar(); return }
        if !wasEnabled {
            inventory.start()
            installMouseMonitors()
        }
        layout()
        if spacingOnlyChange { return }
        if positionOnlyChange {
            updatePointer()
            return
        }
        if presentation.restoresMainSidebar(expanded: viewState.isExpanded, menuVisible: false) {
            restoreSidebarIfNeeded()
        } else {
            panel.orderOut(nil)
        }
        updateIdleOpacity(inUse: false)
        updatePointer()
    }

    private func stopSidebar() {
        cancelInteraction()
        dragController.stop()
        inventory.stop()
        panel.orderOut(nil)
        notchPanel.orderOut(nil)
        viewState.isExpanded = false
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    func screensChanged() {
        cancelInteraction()
        needsSpacePresentation = true
        panel.orderOut(nil)
        notchPanel.orderOut(nil)
        layout()
        inventory.refresh()
        restoreSidebarIfNeeded()
        updatePointer()
    }

    private func restoreSidebarIfNeeded() {
        let menuVisible = ownsMenu && cycleController.panel.isVisible && cycleController.panel.isOnActiveSpace
        // Auto-hide applies when idle, not while this sidebar's window list is open.
        guard !missionControlPresented, settings?.enabled == true, screen != nil,
              presentation.restoresMainSidebar(expanded: viewState.isExpanded, menuVisible: menuVisible),
              needsSpacePresentation || !panel.isVisible || !panel.isOnActiveSpace else { return }
        // Ordering below an existing popup does not explicitly bring the sidebar
        // forward. Establish both windows' order, even while another app is active.
        bringSidebarForward(keepingMenuAbove: menuVisible)
        needsSpacePresentation = !panel.isVisible || !panel.isOnActiveSpace
    }

    private func bringSidebarForward(keepingMenuAbove: Bool) {
        guard !missionControlPresented else { return }
        // These calls preserve the sidebar levels and do not take keyboard focus.
        panel.orderFrontRegardless()
        if keepingMenuAbove {
            cycleController.panel.orderFrontRegardless()
        }
    }

    private var isFullScreen: Bool {
        guard let screen, let id = SidebarSettings.displayID(screen) else { return false }
        return inventory.fullScreenDisplays.contains(id)
    }

    private func revealSidebarFromPersistentTrigger() {
        guard !missionControlPresented, presentation.usesPersistentTrigger, settings?.enabled == true, !viewState.isExpanded,
              !dragController.isActive, !otherDragActive(), !cycleController.isKeyboardSwitcherVisible else { return }
        hideWork?.cancel()
        hideWork = nil
        viewState.isExpanded = true
        layout()
        bringSidebarForward(keepingMenuAbove: ownsMenu && cycleController.panel.isVisible)
    }

    // Fade mode dims the idle sidebar so content behind the icons stays visible.
    private func updateIdleOpacity(inUse: Bool) {
        let target = presentation.fadesWhenIdle && !inUse ? SidebarSettings.idleSidebarOpacity : 1
        guard idleOpacityTarget != target else { return }
        idleOpacityTarget = target
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = target
        }
    }

    private func layout() {
        guard !missionControlPresented, let settings, settings.enabled else { return }
        guard let target = targetScreen else {
            screen = nil
            notchFrame = .zero
            panel.orderOut(nil)
            notchPanel.orderOut(nil)
            return
        }
        screen = target
        notchFrame = notchTrigger(on: target) ?? .zero
        updateInventoryScope(settings)
        let monitors = NSScreen.screens.enumerated().compactMap { index, screen -> SidebarMonitor? in
            guard let id = SidebarSettings.monitorID(screen) else { return nil }
            return SidebarMonitor(id: id, name: screen.localizedName, isPrimary: index == 0, number: index + 1)
        }.filter { settings.configuration.displayScope == .allDisplays || $0.id == SidebarSettings.monitorID(target) }
        if viewState.monitors != monitors { viewState.monitors = monitors }
        let usable = isFullScreen ? target.frame : target.visibleFrame
        let sections = viewState.dragSections ?? SidebarDesktopSection.make(entries: inventory.entries,
            desktops: inventory.desktops, scope: inventory.desktopScope)
        let groups = SidebarMonitorGroup.make(sections: sections, desktops: inventory.desktops,
            monitors: monitors, scope: inventory.desktopScope)
        let policy = presentation
        let frames = policy.layout(configuration: settings.configuration, notch: notchFrame,
            available: usable, screen: target.frame, groups: groups,
            entryCount: inventory.entries.count, expanded: viewState.isExpanded)
        if viewState.side != settings.side { viewState.side = settings.side }
        if viewState.isTopCentered != policy.hasTopTrigger { viewState.isTopCentered = policy.hasTopTrigger }
        sidebarFrame = frames.sidebar
        compactFrame = frames.compact
        edgeFrame = frames.edgeTrigger
        if viewState.topContentWidth != frames.topContentWidth { viewState.topContentWidth = frames.topContentWidth }
        let bottomPadding = policy.hasTopTrigger ? sidebarFrame.minY - frames.drawing.minY : 0
        if viewState.topDrawingBottomPadding != bottomPadding { viewState.topDrawingBottomPadding = bottomPadding }
        if panel.frame != frames.drawing { panel.setFrame(frames.drawing, display: true) }
        if presentation.hasTopTrigger {
            if notchPanel.frame != notchFrame { notchPanel.setFrame(notchFrame, display: true) }
            notchPanel.orderFrontRegardless()
            if !viewState.isExpanded { panel.orderOut(nil) }
        } else {
            notchPanel.orderOut(nil)
        }
        let menuFrame = sidebarEntryID == nil ? nil : cycleController.panel.frame
        panel.ignoresMouseEvents = !SidebarLayout.acceptsSidebarPointer(
            at: NSEvent.mouseLocation, sidebar: pointerFrame, menu: menuFrame)

    }

    private func updateInventoryScope(_ settings: Settings) {
        let filter: String?
        if settings.configuration.displayScope == .currentDisplay {
            // Resolve the single sidebar's actual screen, including its disconnected-display fallback.
            filter = displayID ?? SidebarSettings.selectedScreen().flatMap { SidebarSettings.monitorID($0) } ?? ""
        } else {
            filter = nil
        }
        inventory.setDesktopScope(settings.desktopScope, displayIdentifier: filter)
    }

    private func inventoryChanged() {
        guard !missionControlPresented, settings?.enabled == true else { return }
        if let desktops = viewState.dragDesktops, desktops.contains(where: { desktop in
            return !inventory.desktops.contains(where: {
                $0.id == desktop.id && $0.displayIdentifier == desktop.displayIdentifier
                    && ($0.number != nil) == (desktop.number != nil)
            })
        }) { dragController.cancel() }
        dragController.validateInventory()
        guard !dragController.isActive, !frozeForAnotherDrag else { return }
        layout()
        if isFullScreen && !wasFullScreen { cancelInteraction(); panel.orderOut(nil) }
        wasFullScreen = isFullScreen
        restoreSidebarIfNeeded()
        // A second window can appear while the pointer stays on an app whose menu was hidden.
        if let entryID = sidebarEntryID ?? (panel.isVisible ? hoveredEntryID : nil) {
            if let entry = inventory.entries.first(where: { $0.id == entryID }), let icon = iconFrame(entryID) {
                showMenu(entry, icon: icon)
            } else {
                dismissSidebar()
            }
        }
        updatePointer()
    }

    private func desktopDropTarget(at point: CGPoint, source: SidebarDesktop?) -> SidebarDesktopDropTarget? {
        guard inventory.desktopScope == .allDesktops, panel.isVisible, let source else {
            desktopMenu.hide(); return nil
        }
        let sections = viewState.dragSections ?? []
        let groups = SidebarMonitorGroup.make(sections: sections, desktops: viewState.dragDesktops ?? [],
            monitors: viewState.monitors, scope: inventory.desktopScope)
        let hoveredMonitor = groups.first { group in
            guard let id = group.monitor?.id, let view = monitorAnchors[id],
                  let frame = SidebarDesktopDropTarget.visibleFrame(of: view, within: sidebarFrame) else { return false }
            return frame.contains(point)
        }
        if let group = hoveredMonitor, group.monitor?.id == source.displayIdentifier,
           group.desktops.contains(where: { SidebarDesktopTransferPolicy.allows(source: source, destination: $0) }),
           let id = group.monitor?.id, let view = monitorAnchors[id],
           let anchor = SidebarDesktopDropTarget.visibleFrame(of: view, within: sidebarFrame), let screen {
            dismissSidebar()
            desktopMenu.show(desktops: group.desktops, sourceID: source.id, anchor: anchor,
                side: viewState.side, screen: screen.visibleFrame,
                belowBar: presentation.hasTopTrigger ? sidebarFrame : nil)
        } else if hoveredMonitor != nil || !desktopMenu.contains(point) {
            desktopMenu.hide()
        }
        if desktopMenu.frame?.contains(point) == true { return desktopMenu.target(at: point) }
        _ = desktopMenu.target(at: point)
        let targets = sections.compactMap { section -> SidebarDesktopDropTarget? in
            guard let desktop = section.desktop, let view = desktopAnchors[desktop.id],
                  let frame = SidebarDesktopDropTarget.visibleFrame(of: view, within: sidebarFrame) else { return nil }
            return SidebarDesktopDropTarget(desktop: desktop, frame: frame)
        }
        let excluded = sidebarEntryID == nil ? [] : [cycleController.panel.frame]
        return SidebarDesktopDropTarget.resolve(at: point, targets: targets, sidebar: sidebarFrame, excluded: excluded)
    }

    func scrollSidebarDuringDrag(at point: CGPoint) {
        // A drag from another sidebar must be able to reveal this display's notch destinations.
        if presentation.hasTopTrigger, notchFrame.contains(point), !viewState.isExpanded {
            viewState.isExpanded = true
            layout()
            bringSidebarForward(keepingMenuAbove: false)
        }
        desktopMenu.scroll(at: point)
        guard sidebarFrame.contains(point),
              ProcessInfo.processInfo.systemUptime - lastDragScroll >= 0.06,
              let scroll = (Array(desktopAnchors.values) + Array(monitorAnchors.values) + Array(anchors.values))
                .compactMap({ $0.enclosingScrollView }).first,
              let document = scroll.documentView else { return }
        let delta = SidebarLayout.dragScrollDelta(at: point, frame: sidebarFrame,
            horizontal: presentation.hasTopTrigger, flipped: document.isFlipped)
        guard delta != .zero else { return }
        lastDragScroll = ProcessInfo.processInfo.systemUptime
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.x += delta.x
        bounds.origin.y += delta.y
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
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

    private func hoveredSidebarEntryID(at point: CGPoint) -> SidebarEntryID? {
        inventory.entries.first { entry in
            guard let view = anchors[entry.id] else { return false }
            return SidebarDesktopDropTarget.visibleFrame(of: view, within: sidebarFrame)?.contains(point) == true
        }?.id
    }

    private func isInNotchMenuBridge(_ point: CGPoint) -> Bool {
        guard presentation.hasTopTrigger, panel.isVisible, let id = sidebarEntryID,
              cycleController.panel.isVisible, let view = anchors[id],
              let row = SidebarDesktopDropTarget.visibleFrame(of: view, within: sidebarFrame) else { return false }
        return SidebarLayout.notchMenuBridge(menu: cycleController.panel.frame, anchor: row).contains(point)
    }

    private func cancelPendingHover() {
        hoverWork?.cancel()
        hoverWork = nil
    }

    private func hover(_ entryID: SidebarEntryID, inside: Bool) {
        guard !missionControlPresented, settings?.enabled == true else { return }
        cancelPendingHover()
        if inside {
            hoveredEntryID = entryID
            dismissWork?.cancel()
            dismissWork = nil
            if sidebarEntryID == entryID {
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoveredEntryID == entryID, self.panel.isVisible,
                      !self.cycleController.isKeyboardSwitcherVisible else { return }
                let point = NSEvent.mouseLocation
                guard self.sidebarFrame.contains(point), self.hoveredSidebarEntryID(at: point) == entryID,
                      !(self.sidebarEntryID != nil && self.cycleController.panel.frame.contains(point)) else {
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
        guard !missionControlPresented, let screen, let settings else { return }
        guard !otherDragActive(), ownsMenu || (panel.isVisible && sidebarFrame.contains(NSEvent.mouseLocation)) else { return }
        guard !entry.windows.isEmpty,
              entry.windows.count > 1 || entry.hasOtherWindows || settings.showSingleWindowMenu else {
            dismissSidebar()
            return
        }
        guard !cycleController.isKeyboardSwitcherVisible else { return }
        claimMenu()
        cycleController.showSidebar(for: entry, icon: icon,
                                    screen: isFullScreen ? screen.frame : screen.visibleFrame,
                                    side: settings.side, belowBar: presentation.hasTopTrigger ? sidebarFrame : nil)
    }

    private func activate(_ entryID: SidebarEntryID) {
        guard !missionControlPresented else { return }
        guard let entry = inventory.entries.first(where: { $0.id == entryID }) else { return }
        guard !inventory.hasPendingAction(for: entry.pid) else { return }
        cancelPendingHover()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let action = SidebarIconClickPolicy.action(for: entry, frontmostPID: frontmostPID,
                                                  setting: .none)
        if !isHoveringMenuOrIcon(entryID) { dismissSidebar() }
        if let action { inventory.perform(action, frontmostPID: frontmostPID) }
        else { inventory.refresh() }
    }

    func activateNumberedApp(at index: Int) {
        guard inventory.hasPermission, !hasActiveInteraction, !radialPresented, !missionControlPresented else { return }
        let entries = viewState.displayedGroups(in: inventory).flatMap(\.sections).flatMap(\.entries)
        guard entries.indices.contains(index) else { return }
        activate(entries[index].id)
    }

    private func performMouseAction(_ action: MouseShortcutAction, entryID: SidebarEntryID, target: SidebarWindowID?) {
        guard !missionControlPresented else { return }
        guard let entry = inventory.entries.first(where: { $0.id == entryID }) else { return }
        guard !inventory.hasPendingAction(for: entry.pid) else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowAction = SidebarIconMousePolicy.action(action, for: entry, frontmostPID: frontmostPID, target: target)
        cancelPendingHover()
        if !isHoveringMenuOrIcon(entryID) { dismissSidebar() }
        if let windowAction { inventory.perform(windowAction, frontmostPID: frontmostPID) }
        else { inventory.refresh() }
    }

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .flagsChanged]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            // AppKit runs this monitor on the main thread. Return a Sendable decision from the
            // actor assertion rather than passing NSEvent itself across its generic result boundary.
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if self.scrollPosition(event) { return true }
                self.handleMouse(event)
                return false
            }
            return consumed ? nil : event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.handleMouse(event)
            }
        }
    }

    // Start over this sidebar, then keep its identity while the pointer moves away.
    private func scrollPosition(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, event.window === panel, panel.isVisible,
              !positionScrollCapture.isActive,
              !presentation.hasTopTrigger,
              settings?.enabled == true, !dragController.isActive, !otherDragActive(),
              !cycleController.isKeyboardSwitcherVisible,
              SidebarPositionScrollShortcut.matches(event.modifierFlags,
                  required: MouseShortcutStore.shared.positionScrollModifiers),
              event.scrollingDeltaY.isFinite, event.scrollingDeltaY != 0,
              screen != nil else { return false }
        let point = panel.convertToScreen(CGRect(origin: event.locationInWindow, size: .zero)).origin
        guard SidebarLayout.acceptsSidebarPointer(at: point, sidebar: pointerFrame,
            menu: sidebarEntryID == nil ? nil : cycleController.panel.frame) else { return false }
        // Modifier scrolling must not move the sidebar through trackpad inertia.
        guard event.momentumPhase.isEmpty else { return true }
        cancelInteraction()
        let required = MouseShortcutStore.shared.positionScrollModifiers
        guard positionScrollCapture.start(modifiers: required, onScroll: { [weak self] event in
            guard let self else { return }
            guard MouseShortcutStore.shared.positionScrollModifiers == required else {
                self.positionScrollCapture.stop()
                return
            }
            self.movePosition(event)
        }, onEnd: { [weak self] in self?.updatePointer() }) else {
            dragController.showFeedback("Sidebar scroll capture is unavailable. Check Accessibility access for Octopus.")
            return true
        }
        movePosition(event)
        return true
    }

    private func movePosition(_ event: NSEvent) {
        guard settings?.enabled == true, !dragController.isActive, !otherDragActive(),
              !cycleController.isKeyboardSwitcherVisible, let screen else {
            positionScrollCapture.stop()
            return
        }
        guard event.momentumPhase.isEmpty else { return }
        let usable = isFullScreen ? screen.frame : screen.visibleFrame
        let current = SidebarSettings.configuration(for: displayID).position
        guard let next = SidebarLayout.scrolledPosition(current, deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice,
            availableTravel: usable.height - sidebarFrame.height) else { return }
        SidebarSettings.savePosition(next, for: displayID)
        applySettings()
    }

    private func handleMouse(_ event: NSEvent) {
        guard !radialPresented, !missionControlPresented else { return }
        guard !dragController.isActive, !otherDragActive() else { return }
        let point = NSEvent.mouseLocation
        // One pointer-position path owns row and button hover. Native row/button hover
        // callbacks must not compete with it or miss movement over overlapping controls.
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged].contains(event.type) {
            if ownsMenu { cycleController.updateSidebarPointer(at: point) }
        } else if event.type == .scrollWheel {
            // Scroll views update their row geometry after the event is delivered.
            DispatchQueue.main.async { [weak self] in
                if let self, self.ownsMenu { self.cycleController.updateSidebarPointer(at: NSEvent.mouseLocation) }
            }
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           !pointerFrame.contains(point),
           !notchFrame.contains(point),
           !(sidebarEntryID != nil && cycleController.panel.frame.contains(point)) {
            cancelPendingHover()
            hoveredEntryID = nil
            dismissSidebar()
        }
        if event.type == .scrollWheel, panel.isVisible, pointerFrame.contains(point) {
            // A scrolling icon is no longer a stable menu anchor.
            cancelPendingHover()
            hoveredEntryID = nil
            dismissSidebar()
        }
        updatePointer()
    }

    private func updatePointer() {
        guard !radialPresented, !missionControlPresented else { return }
        guard settings?.enabled == true, !dragController.isActive, !otherDragActive() else { return }
        restoreSidebarIfNeeded()
        let point = NSEvent.mouseLocation
        let inCompact = presentation.usesCompactStrip && panel.isVisible && panel.isOnActiveSpace && compactFrame.contains(point)
        let inNotch = presentation.hasTopTrigger && notchPanel.isVisible && notchFrame.contains(point)
        if inCompact || inNotch { revealSidebarFromPersistentTrigger() }
        let inSidebar = presentation.showsMainSidebar(expanded: viewState.isExpanded) && panel.isVisible && panel.isOnActiveSpace && sidebarFrame.contains(point)
        let inMenu = sidebarEntryID != nil && cycleController.panel.isVisible
            && cycleController.panel.isOnActiveSpace
            && (cycleController.panel.frame.contains(point) || isInNotchMenuBridge(point))
        // The popup can overlap the sidebar's wide icon hit area. Give it all input there.
        panel.ignoresMouseEvents = !panel.isVisible || !SidebarLayout.acceptsSidebarPointer(
            at: point, sidebar: pointerFrame,
            menu: sidebarEntryID == nil ? nil : cycleController.panel.frame)
        let inEdge = edgeFrame.contains(point)

        // Pointer position is the only hover source. Rebuilding native tracking areas
        // during magnification must not generate exits or reopen the same app's menu.
        let pointerEntryID = inSidebar && !inMenu && !positionScrollCapture.isActive ? hoveredSidebarEntryID(at: point) : nil
        let highlightedEntryID = pointerEntryID ?? (inMenu ? hoveredEntryID : nil)
        if viewState.highlightedEntryID != highlightedEntryID { viewState.highlightedEntryID = highlightedEntryID }
        if let pointerEntryID, pointerEntryID != hoveredEntryID {
            hover(pointerEntryID, inside: true)
        } else if pointerEntryID == nil, let hoveredEntryID, !inMenu {
            hover(hoveredEntryID, inside: false)
        }

        if inSidebar, !pointerWasInSidebar, inventory.entries.isEmpty { inventory.refresh() }
        pointerWasInSidebar = inSidebar

        if sidebarEntryID != nil, hoveredEntryID == nil, !inMenu {
            if dismissWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.dismissWork = nil
                    guard self.hoveredEntryID == nil, !self.cycleController.panel.frame.contains(NSEvent.mouseLocation) else { return }
                    self.dismissSidebar()
                }
                dismissWork = work
                // Dismiss on the next UI turn without a fixed hover grace delay.
                DispatchQueue.main.async(execute: work)
            }
        } else {
            dismissWork?.cancel()
            dismissWork = nil
        }

        if (!panel.isVisible || !panel.isOnActiveSpace), inEdge, !cycleController.isKeyboardSwitcherVisible {
            if revealWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.revealWork = nil
                    guard self.settings?.enabled == true, self.edgeFrame.contains(NSEvent.mouseLocation),
                          !self.otherDragActive(),
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

        // Hide the sidebar only after its window menu has closed.
        if presentation.closesWhenOutside(expanded: viewState.isExpanded), panel.isVisible,
           !positionScrollCapture.isActive, !inSidebar, !inCompact, !inNotch, !inMenu, !inEdge,
           sidebarEntryID == nil {
            if hideWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hideWork = nil
                    let point = NSEvent.mouseLocation
                    let inNotch = self.presentation.hasTopTrigger && self.notchFrame.contains(point)
                    guard self.presentation.closesWhenOutside(expanded: self.viewState.isExpanded),
                          self.sidebarEntryID == nil,
                          !self.positionScrollCapture.isActive,
                          !self.dragController.isActive, !self.otherDragActive(),
                          !self.pointerFrame.contains(point), !inNotch,
                          !self.edgeFrame.contains(point) else { return }
                    if self.presentation.usesPersistentTrigger { self.viewState.isExpanded = false }
                    if self.presentation.usesCompactStrip { self.layout() }
                    else { self.panel.orderOut(nil) }
                    self.dismissSidebar()
                    self.hoveredEntryID = nil
                    self.viewState.highlightedEntryID = nil
                }
                hideWork = work
                if presentation.closeDelay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + presentation.closeDelay, execute: work)
                } else {
                    DispatchQueue.main.async(execute: work)
                }
            }
        } else {
            hideWork?.cancel()
            hideWork = nil
        }

        updateIdleOpacity(inUse: inSidebar || inCompact || inNotch || inMenu
            || sidebarEntryID != nil || positionScrollCapture.isActive)
    }

    private func cancelInteraction(preservingHoveredEntry: Bool = false) {
        let keepMenu = preservingHoveredEntry && !dragController.isActive
            && sidebarEntryID.map { isHoveringMenuOrIcon($0) } == true
        positionScrollCapture.stop()
        dragController.cancel()
        if !keepMenu {
            hoveredEntryID = nil
            dismissSidebar()
        }
        cancelPendingHover()
        for work in [dismissWork, revealWork, hideWork] { work?.cancel() }
        dismissWork = nil
        revealWork = nil
        hideWork = nil
        pointerWasInSidebar = false
        if !preservingHoveredEntry { viewState.highlightedEntryID = nil }
    }

    private func beginDrag(_ entryID: SidebarEntryID, target: SidebarWindowID?, title: String, source: NSView, event: NSEvent) {
        guard let target else { return }
        dragController.begin(id: target, title: title, source: source, event: event, allowDesktopTransfer: true, allowPairing: true)
    }
}

private final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
