import AppKit

////////////////////
//// What a traffic-light click asks for, and how owners carry it out
/// Green button:
///   click         → fill the screen (the snap engine's maximise placement)
///   double-click  → toggle native full screen
///   ⌥-click       → the app's own zoom (its standard size), like ⌥ on a title bar
// Yellow minimises, or restores a window that is already minimised.

enum WindowZoomIntent: Equatable {
    case fill, fullScreen, zoom

    static func intent(clickCount: Int, option: Bool) -> WindowZoomIntent {
        if option { return .zoom }
        return clickCount >= 2 ? .fullScreen : .fill
    }
}

enum WindowControlCommand: Equatable {
    case close, minimize, restore
    case zoom(WindowZoomIntent)

    /// The inventory action for this command; nil for fill, which goes through
    /// SidebarDragController.place(_:at: .maximize) so it shares snap placement rules.
    func sidebarAction(for id: SidebarWindowID) -> SidebarWindowAction? {
        switch self {
        case .close: return .close(id)
        case .minimize: return .minimize(id, requireFocused: false)
        // Focus restores a minimised window through WindowPresentation.
        case .restore: return .focus(id)
        case .zoom(.fill): return nil
        case .zoom(.fullScreen): return .toggleFullScreen(id)
        case .zoom(.zoom): return .zoom(id)
        }
    }

    /// Zoom changes the screen layout, so menus close instead of covering the result.
    var dismissesMenu: Bool {
        if case .zoom = self { return true }
        return false
    }
}

////////////////////
//// Single vs double click on the green button
/// A single click waits one double-click interval before filling: the inventory
/// ignores a second action while the first is still running, so a fill started
/// on the first click would swallow the double-click's full screen.
// ⌥-click and the second click of a double-click act at once.

@MainActor
final class WindowZoomClickResolver {
    private var pendingFill: DispatchWorkItem?

    func handle(clickCount: Int, option: Bool, delay: TimeInterval = NSEvent.doubleClickInterval,
                perform: @escaping (WindowZoomIntent) -> Void) {
        cancel()
        let intent = WindowZoomIntent.intent(clickCount: clickCount, option: option)
        guard intent == .fill else { perform(intent); return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFill = nil
            perform(.fill)
        }
        pendingFill = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pendingFill?.cancel()
        pendingFill = nil
    }
}

//// The delay only affects fill; every other control acts on the first click.
//////////////////
