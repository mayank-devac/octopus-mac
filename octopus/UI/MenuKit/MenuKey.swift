import AppKit

////////////////////
//// Keyboard input shared by the window menus and the app menu
/// Panels are key without activating Octopus, so a local monitor sees their keys.

enum MenuKey: Equatable {
    case up, down, left, right, confirm, cancel

    init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .confirm
        case 53: self = .cancel
        default: return nil
        }
    }
}

@MainActor
final class MenuKeyMonitor {
    /// Return true when the key was handled; handled keys are not passed on.
    var onKey: ((MenuKey) -> Bool)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = MenuKey(keyCode: event.keyCode), self?.onKey?(key) == true else { return event }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

//////////////////
