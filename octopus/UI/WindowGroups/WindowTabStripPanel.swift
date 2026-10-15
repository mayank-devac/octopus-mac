import AppKit

@MainActor
final class WindowTabStripPanel: NSPanel {
    var onSelect: (WindowLayoutIdentity) -> Void = { _ in }
    var onDetach: (WindowLayoutIdentity, CGPoint?) -> Void = { _, _ in }
    var onClose: (WindowLayoutIdentity) -> Void = { _ in }
    private let scroll = NSScrollView()
    private let row = NSView()
    private var buttons: [WindowTabButton] = []
    private var displayedMembers: [WindowLayoutIdentity] = []
    private var displayedSelection: WindowLayoutIdentity?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(groupID: UUID) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .normal
        collectionBehavior = [.stationary]
        let background = NSVisualEffectView()
        background.material = .titlebar
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true
        contentView = background
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = row
        background.addSubview(scroll)
        setAccessibilityLabel("Grouped windows")
        setAccessibilityIdentifier("window-tabs-\(groupID.uuidString)")
    }

    required init?(coder: NSCoder) { fatalError("Tab strips are created programmatically") }

    func cancelDrag() { buttons.forEach { $0.cancelDrag() } }

    func show(_ group: WindowTabGroup, workArea: CGRect) {
        guard let active = group.active else { orderOut(nil); return }
        var axFrame = CGRect(x: group.frame.minX, y: group.frame.minY - WindowTabGeometry.stripHeight,
                             width: group.frame.width, height: WindowTabGeometry.stripHeight)
        // At the screen's top edge keep the native traffic-light controls reachable.
        if axFrame.minY < workArea.minY {
            axFrame.origin.y = group.frame.minY
            axFrame.origin.x += 80
            axFrame.size.width = max(1, axFrame.width - 80)
        }
        let frame = SidebarPlacementGeometry.flip(axFrame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        setFrame(frame, display: false)
        scroll.frame = CGRect(origin: .zero, size: frame.size)
        let identities = group.members.map(\.window.id)
        let membersChanged = identities != displayedMembers
        if membersChanged {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = group.members.map { member in
                let button = WindowTabButton(identity: member.window.id)
                button.onClick = { [weak self] in self?.onSelect(member.window.id) }
                button.onDetach = { [weak self] point in self?.onDetach(member.window.id, point) }
                button.onClose = { [weak self] in self?.onClose(member.window.id) }
                button.stripContains = { [weak self] point in self?.frame.insetBy(dx: -12, dy: -12).contains(point) == true }
                row.addSubview(button)
                return button
            }
            displayedMembers = identities
        }
        let width = min(230, max(140, frame.width / CGFloat(max(1, buttons.count))))
        row.frame = CGRect(x: 0, y: 0, width: max(frame.width, width * CGFloat(buttons.count)), height: frame.height)
        for (index, member) in group.members.enumerated() {
            let button = buttons[index]
            let app = NSRunningApplication(processIdentifier: member.window.id.window.pid)
            let name = app?.localizedName ?? "Window"
            button.title = member.title.isEmpty || member.title == name ? name : "\(name) · \(member.title)"
            button.toolTip = button.title
            button.setAccessibilityLabel(button.title)
            button.image = app?.icon
            button.image?.size = CGSize(width: 16, height: 16)
            button.frame = CGRect(x: CGFloat(index) * width + 3, y: 3, width: width - 6, height: frame.height - 6)
            let selected = member.window.id == group.selected
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.clear).cgColor
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        if membersChanged || displayedSelection != group.selected {
            if let index = group.members.firstIndex(where: { $0.window.id == group.selected }) {
                row.scrollToVisible(buttons[index].frame)
            }
            displayedSelection = group.selected
        }
        // A normal-level panel ordered relative to its actual window does not float
        // above unrelated applications, and ordering it never activates Stack King.
        order(.above, relativeTo: Int(active.window.id.window.windowID))
    }
}

@MainActor
private final class WindowTabButton: NSButton {
    var onClick: () -> Void = {}
    var onDetach: (CGPoint?) -> Void = { _ in }
    var onClose: () -> Void = {}
    var stripContains: (CGPoint) -> Bool = { _ in false }
    private var start: CGPoint?
    private var dragged = false

    init(identity: WindowLayoutIdentity) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        alignment = .left
        font = .systemFont(ofSize: 11, weight: .medium)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 5
        target = self
        action = #selector(selectTab)
        setAccessibilityIdentifier("window-tab-\(identity.window.pid)-\(identity.window.windowID)")
        let menu = NSMenu()
        for (title, selector) in [("Move out", #selector(moveOut)), ("Close window", #selector(closeTab))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func cancelDrag() {
        guard start != nil else { return }
        start = nil
        dragged = false
        highlight(false)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        dragged = false
        highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = NSEvent.mouseLocation
        dragged = dragged || hypot(point.x - start.x, point.y - start.y) >= 6
        if dragged { NSCursor.closedHand.set() }
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        highlight(false)
        NSCursor.arrow.set()
        if dragged, !stripContains(NSEvent.mouseLocation) {
            onDetach(WindowGroupDragMonitor.pointer())
        } else if !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    @objc private func selectTab() { onClick() }
    @objc private func moveOut() { onDetach(nil) }
    @objc private func closeTab() { onClose() }
}
