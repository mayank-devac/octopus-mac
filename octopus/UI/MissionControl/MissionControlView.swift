import AppKit

final class MissionControlView: NSView {
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

    func configure(layout: MissionControlLayout, applications: [pid_t: MissionControlApplication], side: SidebarSide) {
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
            view.configure(tile: tile, scale: layout.scale, applications: applications)
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

private final class MissionControlDesktopView: NSView {
    private var iconViews: [SidebarWindowID: NSImageView] = [:]
    private var active = false
    private var scale: CGFloat = 1
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(tile: MissionControlLayout.Tile, scale: CGFloat, applications: [pid_t: MissionControlApplication]) {
        active = tile.isActive
        self.scale = scale
        setAccessibilityLabel("\(tile.desktop.title)\(active ? ", active" : ""), \(tile.icons.count) windows")
        let ids = Set(tile.icons.map(\.windowID))
        for id in Array(iconViews.keys) where !ids.contains(id) {
            iconViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for icon in tile.icons {
            let view: NSImageView
            if let existing = iconViews[icon.windowID] { view = existing }
            else {
                view = NSImageView(frame: icon.frame)
                view.imageScaling = .scaleProportionallyUpOrDown
                view.setAccessibilityElement(true)
                view.setAccessibilityRole(.image)
                iconViews[icon.windowID] = view
                addSubview(view)
            }
            view.frame = icon.frame
            view.image = applications[icon.windowID.pid]?.icon
            view.setAccessibilityLabel("\(applications[icon.windowID.pid]?.name ?? "Application") window on \(tile.desktop.title)")
        }
        setAccessibilityChildren(tile.icons.compactMap { iconViews[$0.windowID] })
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 8 * scale, yRadius: 8 * scale)
        NSColor.white.withAlphaComponent(active ? 0.06 : 0.025).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(active ? 0.32 : 0.13).setStroke()
        path.lineWidth = active ? 1 : 0.5
        path.stroke()
    }
}
