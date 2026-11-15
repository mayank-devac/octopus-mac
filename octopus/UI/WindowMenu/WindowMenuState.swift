import SwiftUI

////////////////////
//// Observable state behind WindowMenuView
/// Written only by WindowMenuPresenter. `focus` is the single selection that
/// both arrow keys and pointer hover move; `hovered` adds pointer-only button
// highlights (such as a row's close button).

/// Asks a scroll view to reveal a target; a fresh ID repeats the same target.
struct WindowMenuScrollRequest: Equatable {
    let target: WindowMenuTarget
    let anchor: UnitPoint?
    let id = UUID()
}

@MainActor
final class WindowMenuState: ObservableObject {
    enum Placement: Equatable {
        case center
        /// The edge the card grows from: the side facing the sidebar icon (nil below the notch bar).
        case sidebar(HorizontalEdge?)
    }

    @Published private(set) var placement: Placement = .center
    @Published private(set) var content = WindowMenuContent()
    @Published private(set) var status: WindowMenuStatus = .ready
    @Published private(set) var focus: WindowMenuTarget?
    @Published private(set) var hovered: WindowMenuTarget?
    @Published private(set) var presentationID = UUID()
    @Published private(set) var scrollRequest: WindowMenuScrollRequest?
    /// The app highlighted when nothing is focused: the hovered sidebar app or the frontmost app.
    @Published private(set) var restingAppID: String?

    var isCenter: Bool { placement == .center }

    var appearEdge: HorizontalEdge? {
        if case .sidebar(let edge) = placement { return edge }
        return nil
    }

    /// The app whose windows are tinted in the list.
    var highlightedAppID: String? {
        switch focus {
        case .app(let id)?: return id
        case .window(let id)?, .closeWindow(let id)?: return content.windows.first { $0.id == id }?.appID
        default: return restingAppID
        }
    }

    ////////////////////
    //// Mutations (presenter only)

    func begin(placement: Placement, content: WindowMenuContent, status: WindowMenuStatus, restingAppID: String?) {
        self.placement = placement
        self.content = content
        self.status = status
        self.restingAppID = restingAppID
        focus = nil
        hovered = nil
        scrollRequest = nil
        presentationID = UUID()
    }

    /// Refresh rows while keeping focus on anything that still exists.
    func update(content: WindowMenuContent, status: WindowMenuStatus, restingAppID: String?) {
        if self.content != content { self.content = content }
        if self.status != status { self.status = status }
        if self.restingAppID != restingAppID { self.restingAppID = restingAppID }
        if let focus, !contains(focus) { self.focus = nil }
        if let hovered, !contains(hovered) { self.hovered = nil }
    }

    func setFocus(_ target: WindowMenuTarget?, reveal: Bool) {
        if focus != target { focus = target }
        if reveal, let target { requestScroll(to: target, anchor: nil) }
    }

    func setHovered(_ target: WindowMenuTarget?) {
        if hovered != target { hovered = target }
    }

    func requestScroll(to target: WindowMenuTarget, anchor: UnitPoint?) {
        scrollRequest = WindowMenuScrollRequest(target: target, anchor: anchor)
    }

    func reset() {
        begin(placement: placement, content: WindowMenuContent(), status: .ready, restingAppID: nil)
    }

    //////////////////

    private func contains(_ target: WindowMenuTarget) -> Bool {
        switch target {
        case .recent(let id): return content.recentApps.contains { $0.id == id }
        case .workspace(let id): return content.workspaces.contains { $0.id == id }
        case .app(let id): return content.apps.contains { $0.id == id }
        case .window(let id), .closeWindow(let id): return content.windows.contains { $0.id == id }
        case .moreApps, .moreWindows: return true
        }
    }
}

//// Views read this state; they never write it.
//////////////////
