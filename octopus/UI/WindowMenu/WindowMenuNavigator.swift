import Foundation

////////////////////
//// Arrow-key movement through the window menu
/// Layout, top to bottom: recent strip (centre only), workspace switch + app
/// strip, window list.
///   ↑ ↓  move between rows; inside the list they move one window.
///   ← →  move along a strip; inside the list they jump to the previous or next
///        app's first window; ← from the first app reaches the workspace switch.
// Focus is stored as a target, not an index, so it survives content refreshes.

enum WindowMenuNavigator {
    static func move(_ focus: WindowMenuTarget?, _ key: MenuKey, in content: WindowMenuContent) -> WindowMenuTarget? {
        switch focus {
        case nil, .moreApps?, .moreWindows?:
            return initialFocus(in: content)
        case .window(let id)?, .closeWindow(let id)?:
            return moveInList(from: id, key, in: content)
        case .app(let id)?:
            return moveInApps(from: id, key, in: content)
        case .recent(let id)?:
            return moveInRecents(from: id, key, in: content)
        case .workspace(let id)?:
            return moveInWorkspaces(from: id, key, in: content)
        }
    }

    static func initialFocus(in content: WindowMenuContent) -> WindowMenuTarget? {
        if let window = firstWindow(in: content) { return window }
        if let app = content.apps.first { return .app(app.id) }
        if let recent = content.recentApps.first { return .recent(recent.id) }
        return nil
    }

    static func firstWindow(ofApp appID: String, in content: WindowMenuContent) -> WindowMenuTarget? {
        guard let window = content.windows.first(where: { $0.appID == appID }) else { return nil }
        return .window(window.id)
    }

    private static func firstWindow(in content: WindowMenuContent) -> WindowMenuTarget? {
        guard let window = content.windows.first else { return nil }
        return .window(window.id)
    }

    ////////////////////
    //// Per-section moves

    private static func moveInList(from id: SidebarWindowID, _ key: MenuKey, in content: WindowMenuContent) -> WindowMenuTarget? {
        let windows = content.windows
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return initialFocus(in: content) }
        let current = WindowMenuTarget.window(id)
        let groupStarts = windows.indices.filter { $0 == 0 || windows[$0].appID != windows[$0 - 1].appID }
        let groupStart = groupStarts.last { $0 <= index } ?? 0
        switch key {
        case .down:
            return index + 1 < windows.count ? .window(windows[index + 1].id) : current
        case .up:
            if index > 0 { return .window(windows[index - 1].id) }
            return content.apps.contains { $0.id == windows[index].appID } ? .app(windows[index].appID) : current
        case .right:
            guard let next = groupStarts.first(where: { $0 > index }) else { return current }
            return .window(windows[next].id)
        case .left:
            guard let previous = groupStarts.last(where: { $0 < groupStart }) else { return current }
            return .window(windows[previous].id)
        case .confirm, .cancel:
            return current
        }
    }

    private static func moveInApps(from id: String, _ key: MenuKey, in content: WindowMenuContent) -> WindowMenuTarget? {
        let apps = content.apps
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return initialFocus(in: content) }
        let current = WindowMenuTarget.app(id)
        switch key {
        case .left:
            if index > 0 { return .app(apps[index - 1].id) }
            guard content.workspaces.count > 1, let selected = content.selectedWorkspaceID else { return current }
            return .workspace(selected)
        case .right:
            return index + 1 < apps.count ? .app(apps[index + 1].id) : current
        case .down:
            return firstWindow(ofApp: id, in: content) ?? firstWindow(in: content) ?? current
        case .up:
            guard !content.recentApps.isEmpty else { return current }
            return .recent(content.recentApps[min(index, content.recentApps.count - 1)].id)
        case .confirm, .cancel:
            return current
        }
    }

    private static func moveInRecents(from id: String, _ key: MenuKey, in content: WindowMenuContent) -> WindowMenuTarget? {
        let recents = content.recentApps
        guard let index = recents.firstIndex(where: { $0.id == id }) else { return initialFocus(in: content) }
        let current = WindowMenuTarget.recent(id)
        switch key {
        case .left: return index > 0 ? .recent(recents[index - 1].id) : current
        case .right: return index + 1 < recents.count ? .recent(recents[index + 1].id) : current
        case .down:
            if !content.apps.isEmpty { return .app(content.apps[min(index, content.apps.count - 1)].id) }
            return firstWindow(in: content) ?? current
        case .up, .confirm, .cancel: return current
        }
    }

    private static func moveInWorkspaces(from id: UUID, _ key: MenuKey, in content: WindowMenuContent) -> WindowMenuTarget? {
        let workspaces = content.workspaces
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return initialFocus(in: content) }
        let current = WindowMenuTarget.workspace(id)
        switch key {
        case .up: return index > 0 ? .workspace(workspaces[index - 1].id) : current
        case .down: return index + 1 < workspaces.count ? .workspace(workspaces[index + 1].id) : current
        case .right:
            if let app = content.apps.first { return .app(app.id) }
            return firstWindow(in: content) ?? current
        case .left, .confirm, .cancel: return current
        }
    }

    //// Edges hold focus in place instead of wrapping, so holding a key is predictable.
    //////////////////
}

//////////////////
