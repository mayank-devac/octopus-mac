import AppKit

// A nonactivating message: feedback must never take focus from the window being moved.
@MainActor
final class WindowPlacementFeedback {
    private var panel: NSPanel?
    private var pendingDismissal: DispatchWorkItem?

    func showFeedback(_ message: String, on preferredScreen: NSScreen? = nil) {
        stop()
        guard let screen = preferredScreen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first else { return }
        let size = CGSize(width: min(400, screen.visibleFrame.width), height: 66)
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.minY + 32, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = SidebarWindowLevels.dragPreview
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
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
        self.panel = panel
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        pendingDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func stop() {
        pendingDismissal?.cancel()
        pendingDismissal = nil
        panel?.close()
        panel = nil
    }
}
