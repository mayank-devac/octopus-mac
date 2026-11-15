import SwiftUI

////////////////////
//// Observable state behind SidebarAppMenuView (written by its controller only)

@MainActor
final class SidebarAppMenuState: ObservableObject {
    @Published private(set) var context: SidebarAppMenuContext?
    @Published private(set) var sections: [SidebarAppMenuSection] = []
    @Published private(set) var pid: pid_t?
    @Published private(set) var bundleURL: URL?
    /// One selection moved by both pointer and arrow keys.
    @Published private(set) var focus: SidebarAppMenuCommand?
    /// The chosen item blinks before the menu closes.
    @Published private(set) var flashing: SidebarAppMenuCommand?
    @Published private(set) var presentationID = UUID()
    @Published private(set) var appearEdge: HorizontalEdge?

    var grid: [[SidebarAppMenuCommand]] { SidebarAppMenuCatalogue.grid(for: sections) }

    func begin(context: SidebarAppMenuContext, pid: pid_t?, bundleURL: URL?, appearEdge: HorizontalEdge?) {
        self.context = context
        sections = SidebarAppMenuCatalogue.sections(for: context)
        self.pid = pid
        self.bundleURL = bundleURL
        self.appearEdge = appearEdge
        focus = nil
        flashing = nil
        presentationID = UUID()
    }

    func setFocus(_ command: SidebarAppMenuCommand?) {
        if focus != command { focus = command }
    }

    func flash(_ command: SidebarAppMenuCommand) {
        flashing = command
    }

    func item(for command: SidebarAppMenuCommand) -> SidebarAppMenuItem? {
        sections.lazy.flatMap(\.items).first { $0.command == command }
    }
}

//////////////////
