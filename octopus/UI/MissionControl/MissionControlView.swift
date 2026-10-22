import AppKit

final class MissionControlView: NSView {
    var onSelection: ((UInt64, SidebarWindowID?) -> Void)?
    var onPress: ((Bool) -> Void)?
    private var desktopViews: [UInt64: MissionControlDesktopView] = [:]
    private var scale: CGFloat = 1
    private var side: SidebarSide = .right
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mission Control desktop map")
    }

    required init?(coder: NSCoder) { return nil }

    func configure(layout: MissionControlLayout, applications: [pid_t: MissionControlApplication], side: SidebarSide,
                   selectableWindows: Set<SidebarWindowID> = []) {
        scale = layout.scale
        self.side = side
        let ids = Set(layout.tiles.map { $0.desktop.id })
        for id in Array(desktopViews.keys) where !ids.contains(id) {
            desktopViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for tile in layout.tiles {
            let view: MissionControlDesktopView
            if let existing = desktopViews[tile.desktop.id] { view = existing }
            else {
                view = MissionControlDesktopView(frame: tile.frame)
                desktopViews[tile.desktop.id] = view
                addSubview(view)
            }
            view.frame = tile.frame
            view.onPress = { [weak self] in self?.onPress?($0) }
            view.select = { [weak self] windowID in self?.onSelection?(tile.desktop.id, windowID) }
            view.configure(tile: tile, scale: layout.scale, applications: applications, selectableWindows: selectableWindows)
        }
        setAccessibilityChildren(layout.tiles.compactMap { desktopViews[$0.desktop.id] })
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(18 * scale, bounds.width / 2, bounds.height / 2)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let attachedEdge = CGRect(x: side == .left ? bounds.minX : bounds.maxX - radius,
                                  y: bounds.minY, width: radius, height: bounds.height)
        NSBezierPath(rect: attachedEdge).fill()
    }
}

private final class MissionControlDesktopView: MissionControlButton {
    var select: ((SidebarWindowID?) -> Void)?
    private var iconViews: [SidebarWindowID: MissionControlButton] = [:]
    private var active = false
    private var scale: CGFloat = 1
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        invoke = { [weak self] in self?.select?(nil) }
    }

    required init?(coder: NSCoder) { return nil }

    func configure(tile: MissionControlLayout.Tile, scale: CGFloat, applications: [pid_t: MissionControlApplication],
                   selectableWindows: Set<SidebarWindowID>) {
        active = tile.isActive
        self.scale = scale
        setAccessibilityLabel("\(tile.desktop.title)\(active ? ", active" : ""), \(tile.icons.count) windows")
        let ids = Set(tile.icons.map(\.windowID))
        for id in Array(iconViews.keys) where !ids.contains(id) {
            iconViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for icon in tile.icons {
            let view: MissionControlButton
            if let existing = iconViews[icon.windowID] { view = existing }
            else {
                view = MissionControlButton(frame: icon.frame)
                iconViews[icon.windowID] = view
                addSubview(view)
            }
            view.frame = icon.frame
            view.isEnabled = selectableWindows.contains(icon.windowID)
            view.onPress = { [weak self] in self?.onPress?($0) }
            view.invoke = { [weak self] in self?.select?(icon.windowID) }
            view.image = applications[icon.windowID.pid]?.icon
            view.setAccessibilityLabel("\(applications[icon.windowID.pid]?.name ?? "Application") window on \(tile.desktop.title)")
        }
        setAccessibilityChildren(tile.icons.compactMap { iconViews[$0.windowID] })
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 8 * scale, yRadius: 8 * scale)
        NSColor.white.withAlphaComponent(hovered ? 0.1 : (active ? 0.06 : 0.025)).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(active ? 0.32 : 0.13).setStroke()
        path.lineWidth = active ? 1 : 0.5
        path.stroke()
    }
}

// Native button tracking accepts a release only inside the pressed button. Child
// icon buttons win AppKit hit testing; the outer map's padding remains inert.
private class MissionControlButton: NSButton {
    var invoke: (() -> Void)?
    var onPress: ((Bool) -> Void)?
    private(set) var hovered = false
    private var tracking: NSTrackingArea?
    private var trackingPress = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        target = self
        action = #selector(choose)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func choose() {
        if trackingPress, let event = NSApp.currentEvent, event.type == .leftMouseUp {
            let point = convert(event.locationInWindow, from: nil)
            // Releasing over a child icon is outside the background target.
            guard hitTest(convert(point, to: superview)) === self else { return }
        }
        invoke?()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        trackingPress = true
        onPress?(true)
        defer {
            trackingPress = false
            onPress?(false)
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor.white.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
