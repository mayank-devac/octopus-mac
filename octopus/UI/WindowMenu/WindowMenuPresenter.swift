import AppKit

////////////////////
//// Shared behaviour of the centre and sidebar window menus
/// Owns the menu state and pointer anchors, rebuilds content from inventory
/// entries and profiles, and turns keys, hover and clicks into actions.
/// Panels, positioning and dismissal stay with each owning controller:
///   - CenterWindowMenuController (keyboard shortcut, centred)
// - CyclePanelController (beside a hovered sidebar icon)

@MainActor
final class WindowMenuPresenter {
    let state = WindowMenuState()
    let anchors = MenuAnchorRegistry<WindowMenuTarget>()

    // Inputs
    var profiles: () -> (profiles: [Profile], currentID: UUID?) = { ([], nil) }
    var recentBundleIdentifiers: () -> [String] = { [] }
    /// Which apps fill the strip; read on each rebuild so the setting applies live.
    var appScope: () -> WindowMenuAppScope = { .workspace }
    /// True lists only the hovered strip app's windows; read on each presentation.
    var showsHoveredAppOnly: () -> Bool = { false }

    // Outputs
    var onActivateWindow: (SidebarWindowID) -> Void = { _ in }
    var onActivateApp: (WindowMenuApp) -> Void = { _ in }
    /// A traffic-light click, already resolved (minimise vs restore, fill vs full screen vs zoom).
    var onWindowControl: (SidebarWindowID, WindowControlCommand) -> Void = { _, _ in }
    /// Nil disables dragging rows (the centre menu has no drop targets).
    var onDragWindow: ((SidebarWindowID, String, NSView, NSEvent) -> Void)?
    /// The card size may have changed; the owner resizes its panel.
    var onLayoutChange: () -> Void = {}

    private var running: [WindowMenuRunningApp] = []
    private var focusPID: pid_t?
    private var selectedWorkspaceID: UUID?
    private var appPageStart = 0
    private var windowPageStart = 0
    private let zoomClicks = WindowZoomClickResolver()
    private var showsHoveredAppOnlyNow = false
    private var widenTask: Task<Void, Never>?

    /// How long a narrowed list waits, once the pointer leaves the strip and rows, before listing every window.
    static let widenDelay: Duration = .milliseconds(550)

    var cardSize: CGSize {
        WindowMenuLayout.cardSize(content: state.content, isCenter: state.isCenter, status: state.status)
    }

    ////////////////////
    //// Presentation lifecycle

    /// A new presentation: current profile, nothing focused, appear animation replays.
    func present(placement: WindowMenuState.Placement, entries: [SidebarEntry], focusPID: pid_t?, status: WindowMenuStatus) {
        running = WindowMenuSource.runningApps(from: entries)
        self.focusPID = focusPID
        selectedWorkspaceID = profiles().currentID
        appPageStart = 0
        windowPageStart = 0
        showsHoveredAppOnlyNow = showsHoveredAppOnly()
        cancelWiden()
        state.begin(placement: placement, content: buildContent(isCenter: placement == .center),
                    status: status, restingAppID: nil)
        settleRestingApp(reveal: true)
    }

    /// New inventory data for the open menu. A different hovered app moves the highlight to it.
    func update(entries: [SidebarEntry], focusPID: pid_t?, status: WindowMenuStatus) {
        running = WindowMenuSource.runningApps(from: entries)
        let focusChanged = focusPID != self.focusPID
        self.focusPID = focusPID
        let before = cardSize
        state.update(content: buildContent(isCenter: state.isCenter), status: status, restingAppID: state.restingAppID)
        if focusChanged { state.setFocus(nil, reveal: false) }
        settleRestingApp(reveal: focusChanged)
        if cardSize != before { onLayoutChange() }
    }

    func reset() {
        cancelWiden()
        running = []
        focusPID = nil
        state.reset()
    }

    func selectWorkspace(_ id: UUID) {
        guard id != selectedWorkspaceID else { return }
        selectedWorkspaceID = id
        appPageStart = 0
        windowPageStart = 0
        let before = cardSize
        state.update(content: buildContent(isCenter: state.isCenter), status: state.status, restingAppID: state.restingAppID)
        settleRestingApp(reveal: false)
        if cardSize != before { onLayoutChange() }
    }

    //// Rebuilding never replays the appear animation; only present() does.
    //////////////////

    ////////////////////
    //// Input

    /// Arrow keys move focus; Return activates it. Escape is left to the owner.
    func handle(_ key: MenuKey) -> Bool {
        switch key {
        case .cancel:
            return false
        case .confirm:
            if let focus = state.focus { activate(focus) }
            return true
        case .up, .down, .left, .right:
            let next = WindowMenuNavigator.move(state.focus, key, in: state.content)
            if case .workspace(let id)? = next { selectWorkspace(id) }
            // Keys walk every window, so only an app icon keeps the list narrowed.
            cancelWiden()
            if case .app(let id)? = next { narrow(to: id) } else { state.setNarrowedApp(nil) }
            state.setFocus(next, reveal: true)
            return true
        }
    }

    /// Pointer position over the card. Hovering an app tints its windows and scrolls the list to them.
    func updatePointer(at point: CGPoint) {
        let target = anchors.target(at: point)
        state.setHovered(target)
        switch target {
        case .app(let id)?:
            narrow(to: id)
            guard state.focus != target else { return }
            state.setFocus(target, reveal: false)
            if let window = WindowMenuNavigator.firstWindow(ofApp: id, in: state.content) {
                state.requestScroll(to: window, anchor: nil)
            }
        case .window?:
            cancelWiden()
            state.setFocus(target, reveal: false)
        case .recent?:
            scheduleWiden()
            state.setFocus(target, reveal: false)
        case .windowControl(let id, _)?:
            cancelWiden()
            state.setFocus(.window(id), reveal: false)
        case .moreApps?, .moreWindows?:
            cancelWiden()
        case .workspace?, nil:
            scheduleWiden()
        }
    }

    func activate(_ target: WindowMenuTarget) {
        switch target {
        case .window(let id):
            onActivateWindow(id)
        case .windowControl(let id, let control):
            activateControl(control, of: id)
        case .app(let id):
            if let app = state.content.apps.first(where: { $0.id == id }) { onActivateApp(app) }
        case .recent(let id):
            if let app = state.content.recentApps.first(where: { $0.id == id }) { onActivateApp(app) }
        case .workspace(let id):
            selectWorkspace(id)
            if let app = state.content.apps.first { state.setFocus(.app(app.id), reveal: true) }
        case .moreApps:
            pageApps()
        case .moreWindows:
            pageWindows()
        }
    }

    //// Escape and outside clicks belong to the owner, which also hides its panel.
    //////////////////

    ////////////////////
    //// Hovered-app-only list
    /// Hovering an app icon lists only its windows. The list stays narrowed while
    /// the pointer is over the strip or the rows, so it does not jump while the
    // user moves down to pick a window. Leaving both widens it after `widenDelay`
    // (immediately when the app has only one window);
    // coming back before then cancels the wait and the next exit starts it afresh.

    private func narrow(to appID: String) {
        guard showsHoveredAppOnlyNow else { return }
        cancelWiden()
        state.setNarrowedApp(appID)
    }

    private func scheduleWiden() {
        guard state.narrowedAppID != nil, widenTask == nil else { return }
        // A single window needs no picking time, so its list widens at once.
        guard state.listedWindows.count > 1 else {
            state.setNarrowedApp(nil)
            return
        }
        widenTask = Task { [weak self] in
            try? await Task.sleep(for: Self.widenDelay)
            guard !Task.isCancelled, let self else { return }
            self.widenTask = nil
            self.state.setNarrowedApp(nil)
        }
    }

    private func cancelWiden() {
        widenTask?.cancel()
        widenTask = nil
    }

    //// Re-hovering any strip icon narrows to that app straight away.
    //////////////////

    ////////////////////
    //// Window controls
    /// Click count and ⌥ come from the triggering mouse event; keyboard and
    // accessibility activation count as a plain single click.

    private func activateControl(_ control: WindowControl, of id: SidebarWindowID) {
        switch control {
        case .close:
            onWindowControl(id, .close)
        case .minimize:
            let isMinimized = state.content.windows.first { $0.id == id }?.isMinimized ?? false
            onWindowControl(id, isMinimized ? .restore : .minimize)
        case .zoom:
            let event = NSApp.currentEvent
            let isMouse = event?.type == .leftMouseUp || event?.type == .leftMouseDown
            zoomClicks.handle(clickCount: isMouse ? event?.clickCount ?? 1 : 1,
                              option: isMouse && event?.modifierFlags.contains(.option) == true) { [weak self] intent in
                self?.onWindowControl(id, .zoom(intent))
            }
        }
    }

    //////////////////

    ////////////////////
    //// Paging for the "more" chevrons
    /// Each click reveals the next page and wraps to the start after the last one.

    private func pageApps() {
        let apps = state.content.apps
        guard !apps.isEmpty else { return }
        let visible = WindowMenuLayout.stripCapacity(
            isCenter: state.isCenter, workspaceCount: state.content.workspaces.count, reservingChevron: false)
        appPageStart = appPageStart + visible < apps.count ? appPageStart + visible : 0
        state.requestScroll(to: .app(apps[appPageStart].id), anchor: .leading)
    }

    private func pageWindows() {
        let windows = state.listedWindows
        guard !windows.isEmpty else { return }
        let visible = WindowMenuLayout.maximumRows(isCenter: state.isCenter)
        windowPageStart = windowPageStart + visible < windows.count ? windowPageStart + visible : 0
        state.requestScroll(to: .window(windows[windowPageStart].id), anchor: .top)
    }

    //////////////////

    private func buildContent(isCenter: Bool) -> WindowMenuContent {
        let source = profiles()
        return WindowMenuCatalogue.content(
            workspaces: WindowMenuCatalogue.workspaces(from: source.profiles),
            selectedWorkspaceID: selectedWorkspaceID ?? source.currentID,
            running: running, focusPID: focusPID,
            appScope: appScope(),
            recentBundleIdentifiers: isCenter ? recentBundleIdentifiers() : [],
            installed: WindowMenuSource.installedApp)
    }

    // Highlight the focus app's windows when nothing else is focused.
    private func settleRestingApp(reveal: Bool) {
        let resting = focusPID.flatMap { pid in state.content.apps.first { $0.pid == pid }?.id }
        state.update(content: state.content, status: state.status, restingAppID: resting)
        if reveal, let resting, let window = WindowMenuNavigator.firstWindow(ofApp: resting, in: state.content) {
            state.requestScroll(to: window, anchor: nil)
        }
    }
}

//////////////////
