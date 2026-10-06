import AppKit

@MainActor
final class SidebarDragController: NSObject, NSDraggingSource {
    private static let pasteboardType = NSPasteboard.PasteboardType("app.octopus.window-placement")
    private let inventory: SidebarWindowInventory
    private var sessionID: UUID?
    private var target: SidebarPlacementTarget?
    private var windowID: SidebarWindowID?
    private var title = ""
    private var dropPanels: [NSPanel] = []
    private var previewPanel: NSPanel?
    private var feedbackPanel: NSPanel?
    private var feedbackWork: DispatchWorkItem?
    private var generation = 0
    var excludedFrames: () -> [CGRect] = { [] }
    var onInteractionChange: ((Bool) -> Void)?
    var isActive: Bool { sessionID != nil }

    init(inventory: SidebarWindowInventory) {
        self.inventory = inventory
        super.init()
    }

    func begin(id: SidebarWindowID, title: String, source: NSView, event: NSEvent) {
        guard !isActive, AXIsProcessTrusted() else { return }
        dismissFeedback()
        generation += 1
        let nonce = UUID()
        sessionID = nonce
        windowID = id
        self.title = title
        target = nil
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
        inventory.preparePlacement(id) { [weak self] prepared in
            guard let self, self.sessionID == nonce else { return }
            guard let prepared else {
                self.cancel()
                self.showFeedback("This window cannot be moved on the current desktop.")
                return
            }
            self.target = prepared
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
        guard !isActive else { return }
        let requestGeneration = generation
        inventory.preparePlacement(id) { [weak self] target in
            guard let self, !self.isActive, self.generation == requestGeneration else { return }
            guard let target else { self.showFeedback("This window cannot be moved on the current desktop."); return }
            guard target.canResize else { self.showFeedback("This window has a fixed size. Drag it to move it."); return }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let original = SidebarPlacementGeometry.flip(target.frame, primaryTop: primaryTop)
            guard let screen = NSScreen.screens.max(by: {
                $0.frame.intersection(original).area < $1.frame.intersection(original).area
            }), !self.inventory.fullScreenDisplays.contains(SidebarSettings.displayID(screen) ?? 0) else { return }
            let frame = SidebarPlacementGeometry.frame(for: snap, in: screen.visibleFrame)
            self.inventory.perform(.place(id, SidebarPlacementRequest(
                frame: SidebarPlacementGeometry.flip(frame, primaryTop: primaryTop),
                workArea: SidebarPlacementGeometry.flip(screen.visibleFrame, primaryTop: primaryTop),
                resize: true, desktopGeneration: target.desktopGeneration)))
        }
    }

    func showFeedback(_ message: String) {
        dismissFeedback()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first else { return }
        let size = CGSize(width: min(400, screen.visibleFrame.width), height: 66)
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.minY + 32, width: size.width, height: size.height)
        let panel = Self.panel(frame: frame, ignoresMouse: true)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.frame = panel.contentView!.bounds.insetBy(dx: 12, dy: 10)
        label.autoresizingMask = [.width, .height]
        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        feedbackPanel = panel
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { [weak self] in self?.dismissFeedback() }
        feedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication && isActive ? .private : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

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

    fileprivate func update(at point: CGPoint) -> NSDragOperation {
        guard isActive, AXIsProcessTrusted(),
              !excludedFrames().contains(where: { $0.contains(point) }),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              !inventory.fullScreenDisplays.contains(SidebarSettings.displayID(screen) ?? 0) else {
            previewPanel?.orderOut(nil); return []
        }
        guard let target else {
            showPreview(frame: CGRect(x: point.x - 100, y: point.y - 48, width: 200, height: 40),
                        label: "Checking window…", valid: false)
            return []
        }
        let snap = SidebarPlacementGeometry.snap(at: point, screen: screen.frame)
        guard snap == nil || target.canResize else {
            showPreview(frame: CGRect(x: point.x - 140, y: point.y - 48, width: 280, height: 40),
                        label: "Fixed-size window — move away from the edge", valid: false)
            return []
        }
        let frame = snap.map { SidebarPlacementGeometry.frame(for: $0, in: screen.visibleFrame) }
            ?? SidebarPlacementGeometry.freeFrame(at: point, size: target.frame.size, in: screen.visibleFrame)
        showPreview(frame: frame, label: "\(title) · \(snap?.title ?? "Move window")", valid: true)
        return .private
    }

    fileprivate func drop(at point: CGPoint) -> Bool {
        guard update(at: point) == .private, let target,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        let snap = SidebarPlacementGeometry.snap(at: point, screen: screen.frame)
        let frame = snap.map { SidebarPlacementGeometry.frame(for: $0, in: screen.visibleFrame) }
            ?? SidebarPlacementGeometry.freeFrame(at: point, size: target.frame.size, in: screen.visibleFrame)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let request = SidebarPlacementRequest(frame: SidebarPlacementGeometry.flip(frame, primaryTop: primaryTop),
            workArea: SidebarPlacementGeometry.flip(screen.visibleFrame, primaryTop: primaryTop),
            resize: snap != nil, desktopGeneration: target.desktopGeneration)
        // Remove overlays before activating the target app.
        finish()
        inventory.perform(.place(target.id, request))
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

    private func finish() {
        generation += 1
        sessionID = nil
        target = nil
        windowID = nil
        previewPanel?.close()
        previewPanel = nil
        dropPanels.forEach { $0.close() }
        dropPanels.removeAll()
        onInteractionChange?(false)
    }

    private func dismissFeedback() {
        feedbackWork?.cancel()
        feedbackWork = nil
        feedbackPanel?.close()
        feedbackPanel = nil
    }

    private static func panel(frame: CGRect, ignoresMouse: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = ignoresMouse
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private final class DropView: NSView {
        weak var controller: SidebarDragController?
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
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
                .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.92), .paragraphStyle: style])
            text.draw(in: textRect)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
