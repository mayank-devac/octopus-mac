import AppKit
import SwiftUI

////////////////////
//// Sidebar app menu panel: opened with Control-click on a sidebar icon
/// Each sidebar display owns one. The display forwards pointer moves and clicks
/// (its monitors already see every event), so hover uses the same single
/// pointer path as the window menus.
///
/// Auto-close: an outside click, Escape, losing key status, choosing an item,
/// or leaving the menu for MenuMotion.autoCloseDelay after entering it.
// Commands go back to the display, which re-reads the live entry before acting.

@MainActor
final class SidebarAppMenuController {
    private let panel = CyclePanel(contentRect: .zero)
    private let state = SidebarAppMenuState()
    private let anchors = MenuAnchorRegistry<SidebarAppMenuCommand>()
    private let keys = MenuKeyMonitor()
    private let fader = MenuPanelFader()
    private var entryID: SidebarEntryID?
    private var pointerHasEntered = false
    private var autoClose: DispatchWorkItem?

    var onCommand: ((SidebarAppMenuCommand, SidebarEntryID) -> Void)?
    var onDismiss: (() -> Void)?

    var isVisible: Bool { entryID != nil }

    /// The visible card, without the transparent shadow margin.
    var cardFrame: CGRect {
        MenuShadowMargin.cardFrame(panel: panel.frame, facing: state.appearEdge)
    }

    func contains(_ point: CGPoint) -> Bool { isVisible && cardFrame.contains(point) }

    init() {
        panel.showsBackdrop = false
        panel.hidesOnDeactivate = false
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.contentView?.addFillingSubview(NSHostingView(rootView: SidebarAppMenuView(
            state: state, anchors: anchors, onSelect: { [weak self] in self?.select($0) })))
        keys.onKey = { [weak self] key in self?.handle(key) ?? false }
    }

    ////////////////////
    //// Show and hide

    func show(context: SidebarAppMenuContext, pid: pid_t?, bundleURL: URL?, entryID: SidebarEntryID,
              icon: CGRect, screen: CGRect, side: SidebarSide, belowBar: CGRect?) {
        self.entryID = entryID
        pointerHasEntered = false
        cancelAutoClose()
        let edge: HorizontalEdge? = belowBar != nil ? nil : side == .right ? .trailing : .leading
        state.begin(context: context, pid: pid, bundleURL: bundleURL, appearEdge: edge)

        let size = MenuShadowMargin.panelSize(card: SidebarAppMenuLayout.cardSize(for: state.sections), facing: edge)
        let frame = belowBar.map {
            SidebarLayout.notchMenuFrame(size: size, icon: icon, bar: $0, screen: screen, belowIcon: true)
        } ?? SidebarLayout.menuFrame(size: size, icon: MenuShadowMargin.clearedIcon(icon), screen: screen, side: side)
        panel.level = belowBar == nil ? SidebarWindowLevels.menu : SidebarWindowLevels.notchMenu
        fader.cancel(panel)
        panel.setFrame(frame, display: true, animate: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        keys.start()
    }

    func hide(animated: Bool = true) {
        guard isVisible else { return }
        entryID = nil
        cancelAutoClose()
        keys.stop()
        if animated && panel.isVisible { fader.fadeOut(panel) {} } else { panel.orderOut(nil) }
        onDismiss?()
    }

    //// isVisible turns false at once, even while the panel fades.
    //////////////////

    ////////////////////
    //// Input from the owning sidebar display

    func updatePointer(at point: CGPoint) {
        guard isVisible else { return }
        if cardFrame.contains(point) {
            pointerHasEntered = true
            cancelAutoClose()
            if let command = anchors.target(at: point) { state.setFocus(command) }
        } else if pointerHasEntered, autoClose == nil {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            autoClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + MenuMotion.autoCloseDelay, execute: work)
        }
    }

    /// Closes the menu for a click outside it.
    func handleMouseDown(at point: CGPoint) {
        if isVisible, !cardFrame.contains(point) { hide() }
    }

    private func handle(_ key: MenuKey) -> Bool {
        switch key {
        case .cancel:
            hide()
        case .confirm:
            if let focus = state.focus { select(focus) }
        case .up, .down, .left, .right:
            state.setFocus(MenuGridNavigator.move(state.focus, key, in: state.grid))
        }
        return true
    }

    // Blink the chosen item, then close and run the command.
    private func select(_ command: SidebarAppMenuCommand) {
        guard let entryID, state.flashing == nil else { return }
        state.setFocus(command)
        state.flash(command)
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuMotion.commandFlashDelay) { [weak self] in
            guard let self, self.entryID == entryID else { return }
            self.hide()
            self.onCommand?(command, entryID)
        }
    }

    private func cancelAutoClose() {
        autoClose?.cancel()
        autoClose = nil
    }

    //////////////////
}

//////////////////
