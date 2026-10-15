import AppKit

@MainActor
final class WindowTabStripPanel: NSPanel {
    var onSelect: (WindowLayoutIdentity) -> Void = { _ in }
    var onDetach: (WindowLayoutIdentity, CGPoint?) -> Void = { _, _ in }
    var onClose: (WindowLayoutIdentity) -> Void = { _ in }
    var onMoveStart: () -> Bool = { true }
    var onMove: (CGRect, CGRect) -> Void = { _, _ in }
    var onMoveCancel: () -> Void = {}
    private let scroll = NSScrollView()
    private let row = WindowTabDragArea()
    private let grip = WindowTabDragArea()
    private var buttons: [WindowTabButton] = []
    private var displayedMembers: [WindowLayoutIdentity] = []
    private var displayedSelection: WindowLayoutIdentity?
    private var windowFrame = CGRect.zero
    private var workArea = CGRect.zero
    private var moveGesture: WindowTabMoveGesture?
    private var moveForegroundPID: pid_t?
    var isDraggingGroup: Bool { moveGesture != nil }

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
        background.addSubview(grip)
        let handle = NSTextField(labelWithString: "≡")
        handle.font = .systemFont(ofSize: 17, weight: .medium)
        handle.textColor = .secondaryLabelColor
        handle.alignment = .center
        handle.frame = CGRect(x: 0, y: 5, width: 28, height: 20)
        grip.addSubview(handle)
        grip.gripOnly = true
        grip.toolTip = "Drag to move the grouped windows"
        grip.setAccessibilityElement(true)
        grip.setAccessibilityRole(.group)
        grip.setAccessibilityLabel("Move grouped windows")
        grip.setAccessibilityHelp("Drag within this display, then release to move the group. Escape cancels.")
        for area in [grip, row] {
            area.onBegin = { [weak self] in self?.beginMove(at: $0) }
            area.onChange = { [weak self] in self?.updateMove(at: $0) }
            area.onEnd = { [weak self] in self?.endMove(at: $0) }
        }
        setAccessibilityLabel("Grouped windows")
        setAccessibilityIdentifier("window-tabs-\(groupID.uuidString)")
    }

    required init?(coder: NSCoder) { fatalError("Tab strips are created programmatically") }

    func cancelDrag() {
        buttons.forEach { $0.cancelDrag() }
        endMove(at: nil)
    }

    private func beginMove(at point: CGPoint) {
        guard moveGesture == nil, onMoveStart() else { return }
        moveGesture = WindowTabMoveGesture(frame: windowFrame, pointer: point, workArea: workArea)
        moveForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func updateMove(at point: CGPoint) {
        guard var gesture = moveGesture else { return }
        gesture.update(pointer: point)
        moveGesture = gesture
        if gesture.moved { NSCursor.closedHand.set(); positionStrip(gesture.frame) }
    }

    private func endMove(at point: CGPoint?) {
        if let point { updateMove(at: point) }
        guard let gesture = moveGesture else { return }
        moveGesture = nil
        NSCursor.arrow.set()
        guard point != nil, gesture.moved, gesture.frame != gesture.original,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == moveForegroundPID else {
            positionStrip(windowFrame)
            onMoveCancel()
            return
        }
        onMove(gesture.original, gesture.frame)
    }

    private func positionStrip(_ window: CGRect) {
        let axFrame = WindowTabGeometry.stripFrame(window: window, workArea: workArea)
        let frame = SidebarPlacementGeometry.flip(axFrame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        setFrame(frame, display: false)
        grip.frame = CGRect(x: 0, y: 0, width: min(28, frame.width), height: frame.height)
        scroll.frame = CGRect(x: 28, y: 0, width: max(1, frame.width - 28), height: frame.height)
    }

    func show(_ group: WindowTabGroup, workArea: CGRect) {
        guard moveGesture == nil else { return }
        guard let active = group.active else { orderOut(nil); return }
        windowFrame = group.frame
        self.workArea = workArea
        positionStrip(group.frame)
        let availableWidth = scroll.frame.width
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
        let width = min(230, max(140, availableWidth / CGFloat(max(1, buttons.count))))
        row.frame = CGRect(x: 0, y: 0, width: max(availableWidth, width * CGFloat(buttons.count)), height: frame.height)
        for (index, member) in group.members.enumerated() {
            let button = buttons[index]
            let app = NSRunningApplication(processIdentifier: member.window.id.window.pid)
            let name = app?.localizedName ?? "Window"
            button.title = member.title.isEmpty || member.title == name ? name : "\(name) · \(member.title)"
            button.toolTip = button.title
            button.setAccessibilityLabel(button.title)
            button.updateCloseLabel()
            button.image = app?.icon
            button.image?.size = CGSize(width: 16, height: 16)
            button.frame = CGRect(x: CGFloat(index) * width + 3, y: 3, width: width - 6, height: frame.height - 6)
            button.needsLayout = true
            button.layoutSubtreeIfNeeded()
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
private final class WindowTabDragArea: NSView {
    var onBegin: (CGPoint) -> Void = { _ in }
    var onChange: (CGPoint) -> Void = { _ in }
    var onEnd: (CGPoint) -> Void = { _ in }
    var gripOnly = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return gripOnly && hit != nil ? self : hit
    }
    override func mouseDown(with event: NSEvent) { onBegin(WindowGroupDragMonitor.pointer()) }
    override func mouseDragged(with event: NSEvent) { onChange(WindowGroupDragMonitor.pointer()) }
    override func mouseUp(with event: NSEvent) { onEnd(WindowGroupDragMonitor.pointer()) }
}

@MainActor
private final class WindowTabButton: NSButton {
    var onClick: () -> Void = {}
    var onDetach: (CGPoint?) -> Void = { _ in }
    var onClose: () -> Void = {}
    var stripContains: (CGPoint) -> Bool = { _ in false }
    private var start: CGPoint?
    private var dragged = false
    private let closeButton = WindowTabCloseButton()

    init(identity: WindowLayoutIdentity) {
        super.init(frame: .zero)
        cell = WindowTabButtonCell(textCell: "")
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
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close window")
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityIdentifier("window-tab-close-\(identity.window.pid)-\(identity.window.windowID)")
        addSubview(closeButton)
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

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: max(0, bounds.width - 22), y: (bounds.height - 18) / 2, width: 18, height: 18)
    }

    func updateCloseLabel() {
        closeButton.toolTip = "Close \(title)"
        closeButton.setAccessibilityLabel("Close \(title)")
    }

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

// Reserve room for the close control while keeping the existing tab button's
// icon, selection, context menu and drag-out behaviour.
private final class WindowTabButtonCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        var available = frame
        available.size.width = max(0, available.width - 24)
        return super.drawTitle(title, withFrame: available, in: controlView)
    }
}

private final class WindowTabCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
