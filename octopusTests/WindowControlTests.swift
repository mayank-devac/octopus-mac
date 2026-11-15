import Testing
@testable import octopus

////////////////////
//// Traffic-light click routing
/// Pure mapping only; the double-click delay, hover glyphs and real AX
// zoom / full screen need the running app.

struct WindowControlTests {
    private let id = SidebarWindowID(pid: 42, windowID: 7)

    @Test func greenClickFillsDoubleClickGoesFullScreenAndOptionZooms() {
        #expect(WindowZoomIntent.intent(clickCount: 1, option: false) == .fill)
        #expect(WindowZoomIntent.intent(clickCount: 2, option: false) == .fullScreen)
        #expect(WindowZoomIntent.intent(clickCount: 1, option: true) == .zoom)
        #expect(WindowZoomIntent.intent(clickCount: 2, option: true) == .zoom)
    }

    @Test func commandsMapToInventoryActionsExceptFill() {
        #expect(WindowControlCommand.close.sidebarAction(for: id) == .close(id))
        #expect(WindowControlCommand.minimize.sidebarAction(for: id) == .minimize(id, requireFocused: false))
        #expect(WindowControlCommand.restore.sidebarAction(for: id) == .focus(id))
        #expect(WindowControlCommand.zoom(.fill).sidebarAction(for: id) == nil)
        #expect(WindowControlCommand.zoom(.fullScreen).sidebarAction(for: id) == .toggleFullScreen(id))
        #expect(WindowControlCommand.zoom(.zoom).sidebarAction(for: id) == .zoom(id))
        #expect(!WindowControlCommand.close.dismissesMenu && WindowControlCommand.zoom(.fill).dismissesMenu)
    }
}

//////////////////
