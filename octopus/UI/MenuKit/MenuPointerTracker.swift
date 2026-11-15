import AppKit

////////////////////
//// Pointer events for a menu panel that Octopus shows without activating itself
/// Local and global monitors together see the pointer over our panel and over
/// other apps. Hover comes from the pointer position only; clicks outside the
// menu are reported so the owner can dismiss it.

@MainActor
final class MenuPointerTracker {
    var onMove: ((CGPoint) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private static let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
    private static let downEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    var isRunning: Bool { localMonitor != nil }

    func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.moveEvents.union(Self.downEvents)) { [weak self] event in
            self?.handle(event.type)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.moveEvents.union(Self.downEvents)) { [weak self] event in
            let type = event.type
            Task { @MainActor in self?.handle(type) }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handle(_ type: NSEvent.EventType) {
        let point = NSEvent.mouseLocation
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            onMouseDown?(point)
        } else if type == .scrollWheel {
            // Scroll views move their rows after the event is delivered.
            DispatchQueue.main.async { [weak self] in self?.onMove?(NSEvent.mouseLocation) }
        } else {
            onMove?(point)
        }
    }
}

//// Owners must call stop() when the menu hides; monitors are not free.
//////////////////
