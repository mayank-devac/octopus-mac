import AppKit

enum SidebarDividerShortcut {
    static func isPressed(_ flags: NSEvent.ModifierFlags, cornerModifiers: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(MouseShortcut.supportedModifiers) == .option
            && !SidebarCornerSnapShortcut.matches(flags, required: cornerModifiers)
    }
}

@MainActor
final class SidebarDragController: NSObject, NSDraggingSource {
    private static let pasteboardType = NSPasteboard.PasteboardType("app.octopus.window-placement")
    private let inventory: SidebarWindowInventory
    private var sessionID: UUID?
    private var target: SidebarPlacementTarget?
    private var transferTarget: SidebarDesktopTransferTarget?
    private var allowDesktopTransfer = false
    private var windowID: SidebarWindowID?
    private var title = ""
    private var dropPanels: [NSPanel] = []
    private var previewPanel: NSPanel?
    private var pairedPreviewPanel: NSPanel?
    private var pairTarget: SidebarIconPairTarget?
    private var pairDirection: PairDropDirection?
    private var tabGroupTarget: SidebarIconPairTarget?
    private var tabGroupPreparation: WindowTabGroupController.Preparation?
    private var tabGroupToken: WindowLayoutBatchToken?
    private var tabGroupDwell: DispatchWorkItem?
    private var tabGroupGeneration = 0
    private var tabGroupDwellReady = false
    private var tabGroupPreparationFinished = false
    private var pairPreparation: WindowPairPreparation?
    private var pairPreparationToken: WindowLayoutBatchToken?
    private var pairPreparationGeneration = 0
    private var allowPairing = false
    private var dragIconPanel: NSPanel?
    private var dragIcon: NSImage?
    private let feedback = WindowPlacementFeedback()
    private var generation = 0
    private var snapDistance = SidebarSettings.defaultSnapDistance
    private var cornerModifiers: NSEvent.ModifierFlags = []
    private var moveSize = VisibleDisplayMoveSize.fullScreen
    private var sourceDisplay: CGRect?
    private var placementRequest: SidebarPlacementRequest?
    private var snapRequest: SidebarPlacementRequest?
    private var snapSettings: WindowSnapSettings?
    private var snapPreparation: WindowLayoutPreparedSnap?
    private var snapPreparationToken: WindowLayoutBatchToken?
    private var snapPreparationGeneration = 0
    private var snapPreparationFailed = false
    private var companionPreviewPanels: [NSPanel] = []
    private var snapApplicationNames: [pid_t: String] = [:]
    private var dividerGesture: WindowLayoutDividerGesture?
    private var dividerPanel: NSPanel?
    private var dividerModifierDown = false
    private var modifierMonitor: Any?
    private var globalModifierMonitor: Any?
    var snapDistanceProvider: () -> Double = { SidebarSettings.snapDistance() }
    var excludedFrames: () -> [CGRect] = { [] }
    var desktopDropTarget: (CGPoint, SidebarDesktop?) -> SidebarDesktopDropTarget? = { _, _ in nil }
    var sidebarDragContains: (CGPoint) -> Bool = { _ in false }
    var onSidebarDragUpdate: ((CGPoint) -> Void)?
    var onDesktopHover: ((UInt64?) -> Void)?
    var onInteractionChange: ((Bool) -> Void)?
    var pairTargetsProvider: () -> [SidebarIconPairTarget] = { [] }
    var sourceIsVisible: (SidebarWindowID) -> Bool = { _ in false }
    var onPairHover: (SidebarIconPairTarget?, PairDropDirection?) -> Void = { _, _ in }
    var preparePair: ((SidebarWindowID, SidebarWindowID, @escaping (WindowPairPreparation?) -> Void) -> WindowLayoutBatchToken?)?
    var onPairDrop: ((WindowPairSnapRequest) -> Void)?
    var onTabGroupHover: (SidebarIconPairTarget?) -> Void = { _ in }
    var prepareTabGroup: ((SidebarWindowID, SidebarWindowID, @escaping (WindowTabGroupController.Preparation?) -> Void) -> WindowLayoutBatchToken?)?
    var onTabGroupDrop: ((WindowTabGroupController.Preparation) -> Void)?
    var prepareSnap: ((SidebarWindowID, SidebarPlacementRequest, @escaping (WindowLayoutPreparedSnap?) -> Void) -> WindowLayoutBatchToken?)?
    var onSnapDrop: ((WindowLayoutPreparedSnap) -> Void)?
    var isActive: Bool { sessionID != nil }

    init(inventory: SidebarWindowInventory) {
        self.inventory = inventory
        super.init()
    }

    func begin(id: SidebarWindowID, title: String, source: NSView, event: NSEvent,
               allowDesktopTransfer: Bool = false, allowPairing: Bool = false) {
        guard !isActive, AXIsProcessTrusted() else { return }
        dismissFeedback()
        // Preview and drop must use the same distance throughout this drag.
        snapDistance = SidebarSettings.normalizedSnapDistance(snapDistanceProvider())
        cornerModifiers = MouseShortcutStore.shared.cornerSnapModifiers
        dividerModifierDown = SidebarDividerShortcut.isPressed(event.modifierFlags, cornerModifiers: cornerModifiers)
        moveSize = WindowLayoutSettings.moveSize()
        sourceDisplay = nil
        generation += 1
        let nonce = UUID()
        sessionID = nonce
        watchModifiers()
        windowID = id
        self.title = title
        target = nil
        transferTarget = nil
        self.allowDesktopTransfer = allowDesktopTransfer
        self.allowPairing = allowPairing
        NotificationCenter.default.post(name: WindowLayoutController.userActionNotification, object: ProcessInfo.processInfo.systemUptime)
        dragIcon = NSRunningApplication(processIdentifier: id.pid)?.icon
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        onInteractionChange?(true)
        installDropSurfaces()
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(nonce.uuidString, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        let location = source.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(origin: location, size: image.size), contents: image)
        let session = source.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        inventory.prepareDrag(id, allowDesktopTransfer: allowDesktopTransfer) { [weak self] placement, transfer in
            guard let self, self.sessionID == nonce else { return }
            guard placement != nil || transfer != nil else {
                self.cancel()
                return
            }
            self.target = placement
            if let placement {
                let original = SidebarPlacementGeometry.flip(placement.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
                self.sourceDisplay = SidebarPlacementGeometry.sourceDisplay(for: original, displays: NSScreen.screens.map(\.frame))
            }
            self.transferTarget = transfer
            _ = self.update(at: NSEvent.mouseLocation)
        }
    }

    func validateInventory() {
        guard let id = windowID, isActive else { return }
        guard inventory.hasPermission,
              inventory.entries.contains(where: { $0.pid == id.pid && $0.windows.contains(where: { $0.cgWindowID == id.windowID }) }) else {
            cancel(); return
        }
    }

    func cancel() {
        guard isActive else { return }
        finish()
    }

    func stop() {
        generation += 1
        cancel()
        dismissFeedback()
    }

    func place(_ id: SidebarWindowID, at snap: SidebarSnapTarget) {
        guard !isActive, !inventory.hasPendingAction(for: id.pid) else { return }
        // A new explicit placement supersedes earlier preparation and any pending automatic layout.
        generation += 1
        let requestGeneration = generation
        NotificationCenter.default.post(name: WindowLayoutController.userActionNotification,
            object: ProcessInfo.processInfo.systemUptime)
        inventory.preparePlacement(id) { [weak self] target in
            guard let self, !self.isActive, self.generation == requestGeneration else { return }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let original = target.map { SidebarPlacementGeometry.flip($0.frame, primaryTop: primaryTop) }
            let screen = original.flatMap { original in NSScreen.screens.max {
                $0.frame.intersection(original).area < $1.frame.intersection(original).area
            } }
            let workArea = screen.map { SidebarPlacementGeometry.flip($0.visibleFrame, primaryTop: primaryTop) }
            let displayIsFullScreen = screen.map {
                self.inventory.fullScreenDisplays.contains(SidebarSettings.displayID($0) ?? 0)
            } ?? false
            if snap == .maximize {
                switch SidebarMaximizePolicy.disposition(target: target, workArea: workArea,
                    displayIsFullScreen: displayIsFullScreen) {
                case .noOp: return
                case .focus: self.inventory.perform(.focus(id)); return
                case .place: break
                }
            }
            guard let target else { self.showFeedback("This window cannot be moved on the current desktop."); return }
            guard target.canResize else { self.showFeedback("This window has a fixed size. Drag it to move it."); return }
            guard let screen, !displayIsFullScreen, let workArea else { return }
            let frame = SidebarPlacementGeometry.frame(for: snap, in: screen.visibleFrame)
            let request = SidebarPlacementRequest(
                frame: SidebarPlacementGeometry.flip(frame, primaryTop: primaryTop),
                workArea: workArea,
                resize: true, desktopGeneration: target.desktopGeneration, snap: snap)
            if snap == .maximize || WindowLayoutSettings.mode() == .legacy {
                self.inventory.perform(.place(id, request)); return
            }
            guard let prepareSnap = self.prepareSnap else { self.showFeedback("Snap preparation is unavailable."); return }
            prepareSnap(id, request) { [weak self] prepared in
                guard let self, !self.isActive, self.generation == requestGeneration else { return }
                guard let prepared, let onSnapDrop = self.onSnapDrop else {
                    self.showFeedback("The window could not be prepared for snapping."); return
                }
                onSnapDrop(prepared)
            }
        }
    }

    func showFeedback(_ message: String) {
        feedback.showFeedback(message)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication && isActive ? .private : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func watchModifiers() {
        // Native drag callbacks need not fire for a stationary pointer. These monitors live only
        // for the session and pass events through, preserving Escape and native drag handling.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            _ = self?.update(at: NSEvent.mouseLocation, scroll: false, modifiers: event.modifierFlags)
            return event
        }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            _ = self?.update(at: NSEvent.mouseLocation, scroll: false, modifiers: event.modifierFlags)
        }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        _ = update(at: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Only our destination can commit. Escape and foreign drops never place a window.
        if isActive { finish() }
    }

    private func installDropSurfaces() {
        for screen in NSScreen.screens {
            let panel = Self.panel(frame: screen.frame, ignoresMouse: false)
            let view = DropView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.registerForDraggedTypes([Self.pasteboardType])
            view.controller = self
            panel.contentView = view
            panel.orderFrontRegardless()
            dropPanels.append(panel)
        }
    }

    fileprivate func accepts(_ info: NSDraggingInfo) -> Bool {
        guard let nonce = sessionID,
              (info.draggingSource as AnyObject?) === self else { return false }
        return info.draggingPasteboard.string(forType: Self.pasteboardType) == nonce.uuidString
    }

    fileprivate func update(at point: CGPoint, scroll: Bool = true, modifiers: NSEvent.ModifierFlags? = nil) -> NSDragOperation {
        placementRequest = nil
        guard isActive else { return [] }
        guard AXIsProcessTrusted() else { cancel(); return [] }
        let flags = modifiers ?? NSEvent.modifierFlags
        let dividerDown = SidebarDividerShortcut.isPressed(flags, cornerModifiers: cornerModifiers)
        let dividerPressed = dividerDown && !dividerModifierDown
        dividerModifierDown = dividerDown
        if var gesture = dividerGesture {
            if !dividerDown {
                clearDivider() // Restore normal pointer-based snap detection when Option is released.
            } else if !dividerContextIsCurrent(gesture.original) {
                clearSnap()
            } else {
                guard dividerPointIsAllowed(point, prepared: gesture.original) else { return [] }
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                guard gesture.update(at: CGPoint(x: point.x, y: top - point.y)) else { clearSnap(); return [] }
                dividerGesture = gesture
                onDesktopHover?(nil)
                return showSnapPreview(gesture.preview, adjusting: true, limited: gesture.isLimited)
            }
        }
        if dividerPressed, previewPanel?.isVisible == true, let prepared = snapPreparation,
           dividerContextIsCurrent(prepared), dividerPointIsAllowed(point, prepared: prepared) {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            if let gesture = WindowLayoutDividerGesture(prepared: prepared, at: CGPoint(x: point.x, y: top - point.y)) {
                dividerGesture = gesture
                onDesktopHover?(nil)
                return showSnapPreview(gesture.preview, adjusting: true)
            }
        }
        if scroll && allowDesktopTransfer { onSidebarDragUpdate?(point) }
        // Resolve icon intent before the broad section callback can open a Desktop-transfer popup.
        if allowPairing, let source = windowID {
            switch SidebarIconPairDrop.resolve(at: point, source: source, sourceVisible: sourceIsVisible(source),
                targets: pairTargetsProvider(), previousTarget: pairTarget?.window, previousDirection: pairDirection,
                tabGrouping: WindowLayoutSettings.tabGroupingEnabled()) {
            case .tabs(let candidate):
                return updateTabGroup(candidate, source: source, point: point)
            case .pair(let candidate, let direction):
                clearTabGroup()
                return updatePair(candidate, direction: direction, source: source, point: point)
            case .blocked:
                clearTabGroup()
                clearPair()
                clearSnap()
                previewPanel?.orderOut(nil)
                // Keep the custom drag image under the pointer when it passes over its own icon.
                showDragIcon(at: point)
                return []
            case .other: clearPair(); clearTabGroup()
            }
        }
        let destination = allowDesktopTransfer ? desktopDropTarget(point, transferTarget?.sourceDesktop) : nil
        if allowDesktopTransfer, sidebarDragContains(point) || destination != nil {
            clearSnap()
            previewPanel?.orderOut(nil)
            if transferTarget != nil { showDragIcon(at: point) } else { dragIconPanel?.orderOut(nil) }
            let valid = destination.flatMap { destination in
                transferTarget.map { SidebarDesktopTransferPolicy.allows(source: $0.sourceDesktop, destination: destination.desktop) }
            } ?? false
            onDesktopHover?(valid ? destination?.desktop.id : nil)
            return valid ? .private : []
        }
        dragIconPanel?.orderOut(nil)
        onDesktopHover?(nil)
        guard
              !excludedFrames().contains(where: { $0.contains(point) }),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              !inventory.fullScreenDisplays.contains(SidebarSettings.displayID(screen) ?? 0) else {
            clearSnap()
            previewPanel?.orderOut(nil); return []
        }
        guard let target else {
            clearSnap()
            previewPanel?.orderOut(nil)
            return []
        }
        let cornerSnapEnabled = SidebarCornerSnapShortcut.matches(
            modifiers ?? NSEvent.modifierFlags, required: cornerModifiers)
        guard let decision = SidebarPlacementGeometry.resolve(at: point, screen: screen.frame,
            workArea: screen.visibleFrame, originalSize: target.frame.size, sourceDisplay: sourceDisplay,
            canResize: target.canResize, distance: snapDistance, cornersEnabled: cornerSnapEnabled,
            moveSize: moveSize) else {
            clearSnap()
            previewPanel?.orderOut(nil)
            return []
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        placementRequest = SidebarPlacementRequest(frame: SidebarPlacementGeometry.flip(decision.frame, primaryTop: primaryTop),
            workArea: SidebarPlacementGeometry.flip(screen.visibleFrame, primaryTop: primaryTop),
            resize: decision.resize, desktopGeneration: target.desktopGeneration, snap: decision.snap,
            crossesDisplay: sourceDisplay != screen.frame)
        if decision.snap != nil, WindowLayoutSettings.mode() == .current, let request = placementRequest {
            return updateSnap(target.id, request: request, previewFrame: decision.frame)
        }
        clearSnap()
        showPreview(frame: decision.frame,
            label: "\(title) · \(decision.snap?.title ?? (decision.resize && moveSize == .fullScreen ? "Full screen" : "Move window"))", valid: true)
        return .private
    }

    fileprivate func drop(at point: CGPoint) -> Bool {
        if dividerGesture != nil { return commitDivider(at: point) }
        guard update(at: point, scroll: false) == .private else {
            if tabGroupTarget != nil {
                showFeedback("Pause over the icon's centre until the tab preview appears. Both windows must be visible on the same display and Desktop.")
            }
            if pairTarget != nil, pairDirection != nil {
                showFeedback(pairPreparation == nil
                    ? "These windows could not be verified for pairing. Try again once both are visible."
                    : "These windows cannot fit in the requested halves. Their positions were kept.")
            }
            return false
        }
        if dividerGesture != nil { return commitDivider(at: point) }
        if tabGroupTarget != nil {
            guard tabGroupDwellReady, let prepared = tabGroupPreparation, let onTabGroupDrop else {
                showFeedback(tabGroupPreparationFinished && tabGroupPreparation == nil
                    ? "These windows cannot form tabs. Both must be visible and resizable on the same display and Desktop."
                    : "Wait for the tab preview before releasing. No windows were changed.")
                return false
            }
            finish()
            onTabGroupDrop(prepared)
            return true
        }
        if let pairTarget, let direction = pairDirection, pairPreparation != nil, let source = windowID, let onPairDrop {
            let request = WindowPairSnapRequest(source: source, target: pairTarget.window, direction: direction,
                startedAt: ProcessInfo.processInfo.systemUptime)
            finish()
            onPairDrop(request)
            return true
        }
        if allowDesktopTransfer, let destination = desktopDropTarget(point, transferTarget?.sourceDesktop), let transferTarget {
            let request = SidebarDesktopTransferRequest(sourceDesktop: transferTarget.sourceDesktop,
                destinationDesktop: destination.desktop, desktopGeneration: transferTarget.desktopGeneration)
            finish()
            inventory.moveToDesktop(transferTarget.id, request: request)
            return true
        }
        // Commit the exact decision just displayed. Inactive-Desktop transfers returned above
        // and remain transfer-only: no frame writes or focus request use the move-size preference.
        guard let target, let request = placementRequest else { return false }
        if request.snap != nil, WindowLayoutSettings.mode() == .current {
            guard let prepared = snapPreparation, let onSnapDrop else {
                showFeedback("Preview not ready—drag again.")
                return false
            }
            finish()
            onSnapDrop(prepared)
            return true
        }
        // Remove overlays before activating the target app.
        finish()
        inventory.perform(.place(target.id, request))
        return true
    }

    private func commitDivider(at point: CGPoint) -> Bool {
        guard let gesture = dividerGesture,
              SidebarDividerShortcut.isPressed(NSEvent.modifierFlags, cornerModifiers: cornerModifiers),
              dividerContextIsCurrent(gesture.original), dividerPointIsAllowed(point, prepared: gesture.original),
              let onSnapDrop else {
            showFeedback("Divider adjustment cancelled; no windows were changed.")
            finish()
            return false
        }
        // Mouse-up commits the last displayed frames; it must not resolve a new edge or unseen layout.
        let displayed = gesture.preview
        finish()
        onSnapDrop(displayed)
        return true
    }

    private func showPreview(frame: CGRect, label: String, valid: Bool) {
        let panel = previewPanel ?? Self.panel(frame: frame, ignoresMouse: true)
        let content = (panel.contentView as? PreviewView) ?? PreviewView(frame: .zero)
        content.label = label
        content.valid = valid
        panel.contentView = content
        panel.setFrame(frame, display: true)
        content.needsDisplay = true
        panel.orderFrontRegardless()
        previewPanel = panel
    }

    private func updateTabGroup(_ candidate: SidebarIconPairTarget, source: SidebarWindowID, point: CGPoint) -> NSDragOperation {
        clearPair()
        clearSnap()
        onDesktopHover?(nil)
        previewPanel?.orderOut(nil)
        showDragIcon(at: point)
        onTabGroupHover(nil)
        if tabGroupTarget?.window != candidate.window || tabGroupTarget?.ownerID != candidate.ownerID {
            clearTabGroup()
            tabGroupTarget = candidate
            let revision = tabGroupGeneration
            let session = sessionID
            // Prepare while the user pauses, rather than adding another native-read wait
            // after the pause. Only the ready state may show the blue target border.
            tabGroupToken = prepareTabGroup?(source, candidate.window) { [weak self] prepared in
                guard let self, self.isActive, self.sessionID == session, self.tabGroupGeneration == revision else { return }
                self.tabGroupPreparation = prepared
                self.tabGroupPreparationFinished = true
                _ = self.update(at: NSEvent.mouseLocation, scroll: false)
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, self.sessionID == session, self.tabGroupGeneration == revision,
                      WindowLayoutSettings.tabGroupingEnabled(),
                      case .tabs(let live) = SidebarIconPairDrop.resolve(at: NSEvent.mouseLocation, source: source,
                        sourceVisible: self.sourceIsVisible(source), targets: self.pairTargetsProvider(),
                        previousTarget: nil, previousDirection: nil, tabGrouping: true),
                      live.window == candidate.window, live.ownerID == candidate.ownerID else { return }
                self.tabGroupDwellReady = true
                _ = self.update(at: NSEvent.mouseLocation, scroll: false)
            }
            tabGroupDwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + WindowTabGeometry.dwell, execute: work)
        }
        // Reserve the centre immediately so AppKit calls performDragOperation even
        // for an early release. drop() decides readiness and explains a rejection.
        guard tabGroupDwellReady, let prepared = tabGroupPreparation else { return .private }
        onTabGroupHover(candidate)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        showPreview(frame: SidebarPlacementGeometry.flip(prepared.frame, primaryTop: top),
            label: "Release to group as tabs · \(title) + \(candidate.title)", valid: true)
        return .private
    }

    // A target change pays one bounded metadata read; pointer movement only updates pure geometry.
    private func updatePair(_ candidate: SidebarIconPairTarget, direction: PairDropDirection?,
                            source: SidebarWindowID, point: CGPoint) -> NSDragOperation {
        clearSnap()
        onDesktopHover?(nil)
        if pairTarget?.window != candidate.window || pairTarget?.ownerID != candidate.ownerID {
            clearPair()
            pairTarget = candidate
            pairDirection = direction
            let revision = pairPreparationGeneration
            let session = sessionID
            pairPreparationToken = preparePair?(source, candidate.window) { [weak self] prepared in
                guard let self, self.isActive, self.sessionID == session, self.pairPreparationGeneration == revision,
                      self.pairTarget?.window == candidate.window else { return }
                self.pairPreparation = prepared
                _ = self.update(at: NSEvent.mouseLocation, scroll: false)
            }
        }
        pairTarget = candidate
        pairDirection = direction
        previewPanel?.orderOut(nil)
        pairedPreviewPanel?.orderOut(nil)
        showDragIcon(at: point)
        dragIconPanel?.alphaValue = 0.55
        guard let prepared = pairPreparation else { onPairHover(nil, nil); return [] }
        onPairHover(candidate, direction)
        guard let direction, let plan = WindowLayoutPlanner.pair(source: prepared.source, target: prepared.target,
            direction: direction, display: prepared.display) else { return [] }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        showPreview(frame: SidebarPlacementGeometry.flip(plan.sourceFrame, primaryTop: top),
            label: "\(title) · \(direction.snap.title)", valid: true)
        let frame = SidebarPlacementGeometry.flip(plan.targetFrame, primaryTop: top)
        let panel = pairedPreviewPanel ?? Self.panel(frame: frame, ignoresMouse: true)
        let view = (panel.contentView as? PreviewView) ?? PreviewView(frame: .zero)
        view.label = "\(candidate.title) · \(direction.opposite.snap.title)"
        panel.contentView = view
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
        pairedPreviewPanel = panel
        return .private
    }

    private func updateSnap(_ id: SidebarWindowID, request: SidebarPlacementRequest,
                            previewFrame: CGRect) -> NSDragOperation {
        let settings = WindowSnapSettings.current()
        if snapRequest != request || snapSettings != settings || snapPreparationToken?.isCancelled == true {
            clearSnap()
            snapRequest = request
            snapSettings = settings
            let revision = snapPreparationGeneration
            let session = sessionID
            if let prepareSnap {
                snapPreparationToken = prepareSnap(id, request) { [weak self] prepared in
                    guard let self, self.isActive, self.sessionID == session,
                          self.snapPreparationGeneration == revision, self.snapRequest == request else { return }
                    self.snapPreparation = prepared
                    if let prepared {
                        for window in prepared.plan.windows {
                            let pid = window.id.window.pid
                            if self.snapApplicationNames[pid] == nil {
                                self.snapApplicationNames[pid] = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown app"
                            }
                        }
                    }
                    self.snapPreparationFailed = prepared == nil
                    _ = self.update(at: NSEvent.mouseLocation, scroll: false)
                }
            } else { snapPreparationFailed = true }
        }
        guard let prepared = snapPreparation else {
            showPreview(frame: previewFrame,
                label: snapPreparationFailed ? "Preview unavailable—drag again" : "Preparing preview…", valid: false)
            return .private
        }
        return showSnapPreview(prepared)
    }

    private func dividerContextIsCurrent(_ prepared: WindowLayoutPreparedSnap) -> Bool {
        isActive && AXIsProcessTrusted() && snapPreparationToken?.isCancelled != true
            && prepared.settings == WindowSnapSettings.current()
            && prepared.plan.anchor.id.window == windowID
            && prepared.displaysMatch(WindowLayoutDisplay.connected())
    }

    private func dividerPointIsAllowed(_ point: CGPoint, prepared: WindowLayoutPreparedSnap) -> Bool {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return SidebarPlacementGeometry.flip(prepared.plan.workArea, primaryTop: top).contains(point)
            && !excludedFrames().contains(where: { $0.contains(point) }) && !sidebarDragContains(point)
    }

    private func showSnapPreview(_ prepared: WindowLayoutPreparedSnap, adjusting: Bool = false,
                                 limited: Bool = false) -> NSDragOperation {
        guard let anchorFrame = prepared.plan.frames[prepared.plan.anchor.id] else { return [] }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func evidence(_ window: WindowLayoutWindow) -> String {
            window.minimumReported ? " · reported minimum" : ""
        }
        let fallback = prepared.fallbackReason == nil ? "" : "Companions unchanged · "
        let adjustable = prepared.allowsDividerAdjustment && SidebarDividerShortcut.isPressed(.option, cornerModifiers: cornerModifiers)
        let hint = adjusting ? (limited ? "Size limit reached · Release mouse to snap · " : "Release mouse to snap · ")
                             : (adjustable ? "Hold ⌥ to adjust divider · " : "")
        showPreview(frame: SidebarPlacementGeometry.flip(anchorFrame, primaryTop: top),
            label: "\(hint)\(fallback)\(evidence(prepared.plan.anchor)) · \(title) · \(prepared.plan.snap.title)", valid: true)
        for (index, window) in prepared.plan.peers.enumerated() {
            guard let target = prepared.plan.frames[window.id] else { continue }
            let frame = SidebarPlacementGeometry.flip(target, primaryTop: top)
            let panel: NSPanel
            if index < companionPreviewPanels.count { panel = companionPreviewPanels[index] }
            else { panel = Self.panel(frame: frame, ignoresMouse: true); companionPreviewPanels.append(panel) }
            let view = (panel.contentView as? PreviewView) ?? PreviewView(frame: .zero)
            let name = snapApplicationNames[window.id.window.pid] ?? "Unknown app"
            view.label = "\(name)\(evidence(window))"
            view.valid = true
            panel.contentView = view
            panel.setFrame(frame, display: true)
            view.needsDisplay = true
            panel.orderFrontRegardless()
        }
        if adjustable { showDivider(prepared, anchor: anchorFrame, primaryTop: top) }
        else { dividerPanel?.orderOut(nil) }
        return .private
    }

    private func showDivider(_ prepared: WindowLayoutPreparedSnap, anchor: CGRect, primaryTop: CGFloat) {
        let vertical = prepared.plan.snap == .left || prepared.plan.snap == .right
        let area = prepared.plan.workArea
        let boundary = vertical ? (prepared.plan.snap == .left ? anchor.maxX : anchor.minX)
                                : (prepared.plan.snap == .top ? anchor.maxY : anchor.minY)
        let axFrame = vertical ? CGRect(x: boundary - 7, y: area.minY, width: 14, height: area.height)
                               : CGRect(x: area.minX, y: boundary - 7, width: area.width, height: 14)
        let frame = SidebarPlacementGeometry.flip(axFrame, primaryTop: primaryTop)
        let panel = dividerPanel ?? Self.panel(frame: frame, ignoresMouse: true)
        let view = (panel.contentView as? DividerView) ?? DividerView(frame: .zero)
        view.vertical = vertical
        panel.contentView = view
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
        dividerPanel = panel
    }

    private func clearDivider() {
        dividerGesture = nil
        dividerPanel?.close()
        dividerPanel = nil
    }

    private func clearSnap() {
        clearDivider()
        snapPreparationGeneration += 1
        snapPreparationToken?.cancel()
        snapPreparationToken = nil
        snapPreparation = nil
        snapRequest = nil
        snapSettings = nil
        snapPreparationFailed = false
        companionPreviewPanels.forEach { $0.close() }
        companionPreviewPanels.removeAll()
        snapApplicationNames.removeAll()
    }

    private func clearPair() {
        guard pairTarget != nil || pairPreparation != nil else { return }
        pairPreparationGeneration += 1
        pairPreparationToken?.cancel()
        pairPreparationToken = nil
        pairTarget = nil
        pairDirection = nil
        pairPreparation = nil
        pairedPreviewPanel?.close()
        pairedPreviewPanel = nil
        onPairHover(nil, nil)
        dragIconPanel?.alphaValue = 0.85
    }

    private func clearTabGroup() {
        guard tabGroupTarget != nil || tabGroupDwell != nil || tabGroupToken != nil else { return }
        tabGroupGeneration += 1
        tabGroupDwell?.cancel()
        tabGroupDwell = nil
        tabGroupToken?.cancel()
        tabGroupToken = nil
        tabGroupTarget = nil
        tabGroupPreparation = nil
        tabGroupDwellReady = false
        tabGroupPreparationFinished = false
        onTabGroupHover(nil)
    }

    private func showDragIcon(at point: CGPoint) {
        guard let image = dragIcon else { return }
        let frame = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
        let panel = dragIconPanel ?? Self.panel(frame: frame, ignoresMouse: true)
        if dragIconPanel == nil {
            let view = NSImageView(frame: CGRect(origin: .zero, size: frame.size))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            panel.contentView = view
            panel.alphaValue = 0.85
            panel.level = SidebarWindowLevels.dragIcon
            dragIconPanel = panel
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func finish() {
        dividerModifierDown = false
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
        modifierMonitor = nil
        globalModifierMonitor = nil
        placementRequest = nil
        sourceDisplay = nil
        clearTabGroup()
        clearPair()
        clearSnap()
        generation += 1
        sessionID = nil
        target = nil
        transferTarget = nil
        allowDesktopTransfer = false
        allowPairing = false
        onDesktopHover?(nil)
        windowID = nil
        previewPanel?.close()
        previewPanel = nil
        dragIconPanel?.close()
        dragIconPanel = nil
        dragIcon = nil
        dropPanels.forEach { $0.close() }
        dropPanels.removeAll()
        onInteractionChange?(false)
    }

    private func dismissFeedback() {
        feedback.stop()
    }

    private static func panel(frame: CGRect, ignoresMouse: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = ignoresMouse
        panel.level = SidebarWindowLevels.dragPreview
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private final class DropView: NSView {
        weak var controller: SidebarDragController?
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func wantsPeriodicDraggingUpdates() -> Bool { true }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let controller, controller.accepts(sender), let window else { return [] }
            return controller.update(at: window.convertToScreen(CGRect(origin: sender.draggingLocation, size: .zero)).origin)
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.accepts(sender) == true }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let controller, controller.accepts(sender), let window else { return false }
            return controller.drop(at: window.convertToScreen(CGRect(origin: sender.draggingLocation, size: .zero)).origin)
        }
    }

    private final class DividerView: NSView {
        var vertical = true
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            let line = vertical ? bounds.insetBy(dx: 5, dy: 0) : bounds.insetBy(dx: 0, dy: 5)
            NSBezierPath(roundedRect: line, xRadius: 2, yRadius: 2).fill()
            let handle = CGRect(x: bounds.midX - (vertical ? 5 : 20), y: bounds.midY - (vertical ? 20 : 5),
                width: vertical ? 10 : 40, height: vertical ? 40 : 10)
            NSBezierPath(roundedRect: handle, xRadius: 5, yRadius: 5).fill()
        }
    }

    private final class PreviewView: NSView {
        var label = ""
        var valid = true
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 2, dy: 2)
            let color = valid ? NSColor.controlAccentColor : .secondaryLabelColor
            color.withAlphaComponent(0.14).setFill()
            color.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            path.lineWidth = 2
            path.fill()
            path.stroke()
            let textRect = CGRect(x: 12, y: max(6, bounds.height - 35), width: max(0, bounds.width - 24), height: 24)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style])
            let horizontalPadding: CGFloat = 8
            let labelRect = CGRect(x: textRect.minX, y: textRect.minY,
                width: min(textRect.width, ceil(text.size().width) + horizontalPadding * 2), height: textRect.height)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
            let paddedTextRect = CGRect(x: labelRect.minX + horizontalPadding, y: labelRect.minY + 3,
                width: max(0, labelRect.width - horizontalPadding * 2), height: labelRect.height - 6)
            text.draw(in: paddedTextRect)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
