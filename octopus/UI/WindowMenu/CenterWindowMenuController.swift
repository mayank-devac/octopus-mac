import AppKit
import SwiftUI
import KeyboardShortcuts

////////////////////
//// Centre window menu, opened with the "Open window menu" shortcut (default ⇧Space)
/// Shows recently quit apps, the current workspace's apps and their windows.
/// The panel becomes key without activating Octopus, so the frontmost app keeps
/// its state and Escape returns to it untouched.
///
/// Window data comes from a private SidebarWindowInventory that runs only while
/// the menu is open, plus a grace period so a chosen focus action can finish.
// Escape, an outside click, losing key status or the shortcut again closes it.

@MainActor
final class CenterWindowMenuController {
    private let panel = CyclePanel(contentRect: .zero)
    private let presenter = WindowMenuPresenter()
    private let inventory = SidebarWindowInventory()
    private let recents = RecentAppsStore()
    private let pointer = MenuPointerTracker()
    private let keys = MenuKeyMonitor()
    private let fader = MenuPanelFader()
    private var inventoryStop: DispatchWorkItem?
    private var hasFreshData = false
    private var isPresented = false
    private var focusPID: pid_t?
    private var anchorCenter: CGPoint?

    /// Keeps a finished focus or launch alive after the menu closes.
    private static let inventoryGracePeriod: TimeInterval = 10

    /// Set by AppDelegate: false while another Octopus interaction owns the screen.
    var canPresent: () -> Bool = { true }

    init(profileManager: ProfileManager) {
        panel.showsBackdrop = false
        panel.level = SidebarWindowLevels.menu
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.contentView?.addFillingSubview(NSHostingView(rootView: WindowMenuView(state: presenter.state, presenter: presenter)))

        presenter.profiles = { [weak profileManager] in
            (profileManager?.profiles ?? [], profileManager?.currentProfileID)
        }
        presenter.recentBundleIdentifiers = { [weak recents] in recents?.notRunning() ?? [] }
        configureActions()
        configureInput()
        inventory.onChange = { [weak self] in
            self?.hasFreshData = true
            self?.refresh()
        }
    }

    func start() {
        recents.start()
        KeyboardShortcuts.onKeyDown(for: .showWindowMenu) { [weak self] in self?.toggle() }
    }

    func stop() {
        KeyboardShortcuts.disable(.showWindowMenu)
        hide(animated: false)
        inventoryStop?.cancel()
        inventoryStop = nil
        inventory.stop()
        recents.stop()
    }

    func toggle() {
        if isPresented { hide() } else { show() }
    }

    ////////////////////
    //// Show and hide

    private func show() {
        guard canPresent() else { return }
        isPresented = true
        inventoryStop?.cancel()
        inventoryStop = nil
        if inventory.entries.isEmpty { hasFreshData = false }
        inventory.start()
        focusPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        presenter.present(placement: .center, entries: inventory.entries, focusPID: focusPID, status: status)
        inventory.refresh()

        anchorCenter = Self.anchorCenter()
        layoutPanel()
        fader.cancel(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        keys.start()
        pointer.start()
    }

    private func hide(animated: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        keys.stop()
        pointer.stop()
        let finish: () -> Void = { [weak self] in self?.presenter.reset() }
        if animated && panel.isVisible {
            fader.fadeOut(panel, completion: finish)
        } else {
            panel.orderOut(nil)
            finish()
        }
        scheduleInventoryStop()
    }

    private func scheduleInventoryStop() {
        inventoryStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPresented else { return }
            self.inventory.stop()
            self.inventoryStop = nil
        }
        inventoryStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inventoryGracePeriod, execute: work)
    }

    //// The inventory restarts empty, so the first open after the grace period shows "Loading".
    //////////////////

    ////////////////////
    //// Content and layout

    private var status: WindowMenuStatus {
        if !inventory.hasPermission { return .needsPermission }
        return hasFreshData || !inventory.entries.isEmpty ? .ready : .loading
    }

    private func refresh() {
        guard isPresented else { return }
        presenter.update(entries: inventory.entries, focusPID: focusPID, status: status)
    }

    // Keep the card centred on the same point as its height changes.
    private func layoutPanel() {
        guard let center = anchorCenter else { return }
        let size = MenuShadowMargin.panelSize(card: presenter.cardSize, facing: nil)
        let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }

    private static func anchorCenter() -> CGPoint {
        let screen = WindowMenuDisplayPreference.chosenScreen()
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return CGPoint(x: frame.midX, y: frame.midY + frame.height * WindowMenuMetrics.centerVerticalBias)
    }

    //////////////////

    ////////////////////
    //// Wiring

    private func configureActions() {
        presenter.onActivateWindow = { [weak self] id in
            guard let self else { return }
            self.hide()
            self.inventory.focus(id)
        }
        presenter.onActivateApp = { [weak self] app in
            guard let self else { return }
            self.hide()
            if let pid = app.pid {
                self.inventory.perform(.activateApp(pid))
            } else if let identifier = app.bundleIdentifier, let url = app.bundleURL {
                Application.activateOrLaunch(bundleIdentifier: identifier, bundleURL: url)
            }
        }
        presenter.onCloseWindow = { [weak self] id in self?.inventory.perform(.close(id)) }
        presenter.onLayoutChange = { [weak self] in self?.layoutPanel() }
    }

    private func configureInput() {
        keys.onKey = { [weak self] key in
            guard let self else { return false }
            if key == .cancel { self.hide(); return true }
            return self.presenter.handle(key)
        }
        pointer.onMove = { [weak self] point in self?.presenter.updatePointer(at: point) }
        pointer.onMouseDown = { [weak self] point in
            guard let self else { return }
            // The transparent shadow margin is outside the menu.
            if !MenuShadowMargin.cardFrame(panel: self.panel.frame, facing: nil).contains(point) { self.hide() }
        }
    }

    //////////////////
}

//// AppDelegate owns start/stop; nothing else references this controller.
//////////////////
