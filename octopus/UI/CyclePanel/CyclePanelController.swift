//
//  CyclePanelController.swift
//  octopus
//
//

import AppKit
import SwiftUI

enum CyclePanelPresentation {
    case keyboard, sidebar

    func shouldCommit(required: NSEvent.ModifierFlags, pressed: NSEvent.ModifierFlags) -> Bool {
        self == .keyboard && !required.isEmpty && !required.isSubset(of: pressed)
    }
}

@MainActor
final class CyclePanelController: NSObject {
    private(set) var panel: CyclePanel!
    private let state = CyclePanelState()
    private let modifierManager: ModifierManager
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var currentApplication: Application?
    private var currentSidebarEntryID: SidebarEntryID?
    private var panelAnchorCenter: CGPoint?
    private var isDismissing = false
    private(set) var presentation = CyclePanelPresentation.keyboard
    private var sidebarAnchor: (icon: CGRect, screen: CGRect, side: SidebarSide, bar: CGRect?)?
    private var sidebarRowAnchors: [CyclePanelItem.ID: NSView] = [:]
    private var sidebarHideAnchor: NSView?
    private var sidebarQuitAnchor: NSView?
    private var sidebarActionClickGate = SidebarClickGate()
    var onSidebarActivate: ((SidebarWindowID) -> Void)?
    var onSidebarWindowAction: ((SidebarWindowAction) -> Void)?
    var onSidebarDismiss: (() -> Void)?
    var onSidebarDrag: ((SidebarWindowID, String, NSView, NSEvent) -> Void)?
    var onSidebarPlacement: ((SidebarWindowID, SidebarSnapTarget) -> Void)?
    // Prevent another display's hover/refresh from dismissing or replacing this menu's actions.
    var sidebarOwnerID: UUID?
    var sidebarApplicationID: pid_t? {
        presentation == .sidebar && panel.isVisible ? currentApplication?.pid : nil
    }
    var sidebarEntryID: SidebarEntryID? {
        presentation == .sidebar && panel.isVisible ? currentSidebarEntryID : nil
    }
    var isKeyboardSwitcherVisible: Bool { panel.isVisible && presentation == .keyboard }

    private let panelContentWidth: CGFloat = 400
    private let sidebarContentWidth: CGFloat = 260
    private let maxPanelFrameHeightCap: CGFloat = 520

    // Keep these aligned with CyclePanelView.
    private let headerHeight: CGFloat = 44
    private let dividerHeight: CGFloat = 1
    private let rowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 4
    private let listVerticalPadding: CGFloat = 8
    private static let releaseModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private var minPanelContentHeight: CGFloat {
        // Minimum height that still matches the layout for one row.
        headerHeight + dividerHeight + (listVerticalPadding * 2) + rowHeight
    }
    
    init(modifierManager: ModifierManager) {
        self.modifierManager = modifierManager
        super.init()
        createPanel()
    }
    
    private func createPanel() {
        let contentRect = NSRect(x: 0, y: 0, width: panelContentWidth, height: 300)
        panel = CyclePanel(contentRect: contentRect)
        panel.acceptsMouseMovedEvents = true
        
        panel.onResignKey = { [weak self] in
            guard self?.presentation == .keyboard else { return }
            self?.hideSwitcher()
        }
        let contentView = CyclePanelView(state: state, onActivate: { [weak self] id in
            guard let self, self.presentation == .sidebar,
                  let index = self.state.items.firstIndex(where: { $0.id == id }) else { return }
            self.state.selectedIndex = index
            self.activateSelectedWindow()
        }, onAnchor: { [weak self] id, view in
            self?.sidebarRowAnchors[id] = view
        }, onWindowAction: { [weak self] itemID in
            guard let self, self.presentation == .sidebar, let pid = self.currentApplication?.pid,
                  case .window(let id) = itemID,
                  let status = self.state.sidebarWindowStates[id] else { return }
            if let event = NSApp.currentEvent,
               (event.type == .leftMouseDown || event.type == .leftMouseUp),
               !self.sidebarActionClickGate.accepts(timestamp: event.timestamp, clickCount: event.clickCount) { return }
            let target = SidebarWindowID(pid: pid, windowID: id)
            let focusOrRestore = self.state.sidebarAppIsHidden || status.isMinimized || !status.isOnScreen
            guard status.canMinimize || (focusOrRestore && !status.isMinimized) else { return }
            self.onSidebarWindowAction?(focusOrRestore ? .focus(target) : .minimize(target, requireFocused: false))
        }, onWindowClose: { [weak self] itemID in
            guard let self, self.presentation == .sidebar, let pid = self.currentApplication?.pid,
                  case .window(let id) = itemID,
                  self.state.sidebarWindowStates[id]?.canClose == true else { return }
            if let event = NSApp.currentEvent,
               (event.type == .leftMouseDown || event.type == .leftMouseUp),
               !self.sidebarActionClickGate.accepts(timestamp: event.timestamp, clickCount: event.clickCount) { return }
            self.onSidebarWindowAction?(.close(SidebarWindowID(pid: pid, windowID: id)))
        }, onToggleAppVisibility: { [weak self] in
            guard let self, self.presentation == .sidebar,
                  let pid = self.currentApplication?.pid,
                  let action = self.state.sidebarAppVisibilityAction(pid: pid) else { return }
            // Capture the action before dismissing the panel resets its visibility state.
            self.hideSwitcher()
            self.onSidebarWindowAction?(action)
        }, onHideAnchor: { [weak self] view in
            self?.sidebarHideAnchor = view
        }, onQuitApp: { [weak self] in
            guard let self, self.presentation == .sidebar, let pid = self.currentApplication?.pid else { return }
            self.hideSwitcher()
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }, onQuitAnchor: { [weak self] view in
            self?.sidebarQuitAnchor = view
        }, onDrag: { [weak self] id, title, source, event in
            guard let self, self.presentation == .sidebar else { return }
            self.onSidebarDrag?(id, title, source, event)
        }, onPlacement: { [weak self] itemID, target in
            guard let self, self.presentation == .sidebar, let pid = self.currentApplication?.pid,
                  case .window(let id) = itemID else { return }
            self.onSidebarPlacement?(SidebarWindowID(pid: pid, windowID: id), target)
        })
        let hostingView = NSHostingView(rootView: contentView)
        // Panel dimensions are controlled by updatePanelSize, not content-size probes.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        guard let containerView = panel.contentView else { return }
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }
    
    // Called when user presses the configured window-switching shortcut.
    func showSwitcher(for application: Application, startIndex: Int = 0) {
        if presentation == .sidebar { hideSwitcher() }
        presentation = .keyboard
        panel.level = .floating
        panel.hidesOnDeactivate = true
        currentApplication = application
        state.setApplication(application)
        
        // Instant switch if the user opted in and there is one actual window
        if UserDefaults.standard.string(forKey: "instantSwitch") == "whenOnlyOneWindowOpen",
           state.items.count == 1,
           case .window = state.currentItem {
            activateSelectedWindow()
            return
        }
        
        // If starting index is provided (e.g., already on that app), use it
        if startIndex > 0 && startIndex < state.items.count {
            state.selectedIndex = startIndex
        }
        
        if !panel.isVisible {
            let defaults = UserDefaults.standard
            // Preserve the earlier primary-display toggle until a display is explicitly chosen.
            let display = defaults.string(forKey: "windowMenuDisplay")
                ?? (defaults.bool(forKey: "showWindowMenuOnPrimaryDisplay") ? "primary" : "automatic")
            let screens = NSScreen.screens
            if display != "automatic",
               let screen = screens.first(where: { SidebarSettings.monitorID($0) == display }) ?? screens.first {
                // screens.first is the primary display and the fallback for a disconnected selection.
                let visibleFrame = screen.visibleFrame
                panel.setFrameOrigin(CGPoint(x: visibleFrame.midX - panel.frame.width / 2,
                                             y: visibleFrame.midY - panel.frame.height / 2))
            } else {
                panel.center()
            }
            panelAnchorCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            updatePanelSize()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installFlagsMonitor()
            installKeyDownMonitor()
        } else {
            if panelAnchorCenter == nil {
                panelAnchorCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            }
            updatePanelSize()
        }
    }

    func showSidebar(for entry: SidebarEntry, icon: CGRect, screen: CGRect, side: SidebarSide,
                     belowBar: CGRect? = nil) {
        guard !isKeyboardSwitcherVisible, !entry.windows.isEmpty else { return }
        panel.level = SidebarWindowLevels.menu
        let isRefresh = sidebarEntryID == entry.id
        let selectedID = isRefresh ? state.currentWindow?.cgWindowID : nil
        presentation = .sidebar
        removeFlagsMonitor()
        currentApplication = entry.application
        currentSidebarEntryID = entry.id
        sidebarAnchor = (icon, screen, side, belowBar)
        state.setWindows(entry.windows, applicationTitle: entry.application.title,
                         selectedID: selectedID ?? entry.preferredID?.windowID,
                         preserveInteraction: isRefresh, sidebarWindowStates: entry.windowStates,
                         sidebarAppIsHidden: entry.isHidden)
        updatePanelSize()
        // Refreshing the same menu must not steal focus or order the panel forward again.
        if isRefresh { return }
        // Keep the menu visible over the other app while still accepting Enter/arrow keys.
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        installKeyDownMonitor()
    }

    func dismissSidebar() {
        if presentation == .sidebar { hideSwitcher() }
    }

    func updateSidebarPointer(at point: CGPoint) {
        guard presentation == .sidebar, panel.isVisible else { return }
        let target = panel.frame.contains(point) ? Self.sidebarPointerTarget(
            at: point, items: state.items, anchors: sidebarRowAnchors, hideAnchor: sidebarHideAnchor,
            quitAnchor: sidebarQuitAnchor) : nil
        state.setSidebarPointerTarget(target)
    }

    static func sidebarPointerTarget(at point: CGPoint, items: [CyclePanelItem],
                                     anchors: [CyclePanelItem.ID: NSView], hideAnchor: NSView?,
                                     quitAnchor: NSView? = nil) -> SidebarPointerTarget? {
        for item in items {
            guard let view = anchors[item.id], let window = view.window else { continue }
            // Since macOS 14, unclipped NSViews can report a visibleRect larger than
            // their bounds. Without this intersection the first row claims later rows.
            let visibleBounds = view.bounds.intersection(view.visibleRect)
            guard !visibleBounds.isEmpty else { continue }
            let rect = window.convertToScreen(view.convert(visibleBounds, to: nil))
            if rect.contains(point) {
                let fullRect = window.convertToScreen(view.convert(view.bounds, to: nil))
                let actionWidth = SidebarLayout.menuWindowActionWidth
                if point.x >= fullRect.maxX - actionWidth { return .windowClose(item.id) }
                return point.x >= fullRect.maxX - actionWidth * 2 ? .windowAction(item.id) : .row(item.id)
            }
        }
        if let view = hideAnchor, let window = view.window {
            let visibleBounds = view.bounds.intersection(view.visibleRect)
            if !visibleBounds.isEmpty,
               window.convertToScreen(view.convert(visibleBounds, to: nil)).contains(point) {
                return .hideApp
            }
        }
        if let view = quitAnchor, let window = view.window {
            let visibleBounds = view.bounds.intersection(view.visibleRect)
            if !visibleBounds.isEmpty,
               window.convertToScreen(view.convert(visibleBounds, to: nil)).contains(point) {
                return .quitApp
            }
        }
        return nil
    }

    private func updatePanelSize() {
        let isSidebar = presentation == .sidebar
        let rowHeight = isSidebar ? SidebarLayout.menuRowHeight : self.rowHeight
        let rowSpacing = isSidebar ? dividerHeight : self.rowSpacing
        let listVerticalPadding = isSidebar ? SidebarLayout.menuPadding : self.listVerticalPadding
        let itemCount = state.items.count
        let rowsHeight = CGFloat(itemCount) * rowHeight
        let spacingHeight = CGFloat(max(0, itemCount - 1)) * rowSpacing
        let listHeight = rowsHeight + spacingHeight + (listVerticalPadding * 2)
        let headerHeight = state.showsHeader ? self.headerHeight + dividerHeight : 0
        let actionHeight = isSidebar ? SidebarLayout.menuActionHeight + dividerHeight : 0
        let desiredContentHeight = headerHeight + listHeight + actionHeight

        let maxContentHeightByScreen: CGFloat = {
            let visibleFrameHeight = sidebarAnchor?.screen.height ?? (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? maxPanelFrameHeightCap
            let maxFrameHeight = min(maxPanelFrameHeightCap, visibleFrameHeight * 0.6)
            let maxFrameRect = NSRect(x: 0, y: 0, width: panelContentWidth, height: maxFrameHeight)
            return panel.contentRect(forFrameRect: maxFrameRect).height
        }()

        let minimumContentHeight = headerHeight + (listVerticalPadding * 2) + rowHeight + actionHeight
        let clampedContentHeight = max(minimumContentHeight, min(desiredContentHeight, maxContentHeightByScreen))
        let contentWidth = sidebarAnchor == nil ? panelContentWidth : sidebarContentWidth
        let targetContentRect = NSRect(x: 0, y: 0, width: contentWidth, height: clampedContentHeight)
        let targetFrameSize = panel.frameRect(forContentRect: targetContentRect).size

        // Keep the panel pinned to the same center while the switcher shortcut is held.
        let center = panelAnchorCenter ?? CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let newOrigin = CGPoint(
            x: center.x - targetFrameSize.width / 2,
            y: center.y - targetFrameSize.height / 2
        )
        let newFrame: CGRect
        if let anchor = sidebarAnchor {
            if let bar = anchor.bar {
                newFrame = SidebarLayout.notchMenuFrame(size: targetFrameSize, icon: anchor.icon,
                                                       bar: bar, screen: anchor.screen)
            } else {
                newFrame = SidebarLayout.menuFrame(size: targetFrameSize, icon: anchor.icon,
                                                   screen: anchor.screen, side: anchor.side)
            }
        } else {
            newFrame = NSRect(origin: newOrigin, size: targetFrameSize)
        }

        if panel.frame != newFrame { panel.setFrame(newFrame, display: true, animate: false) }
    }
    
    // Called when user presses the switcher shortcut again while panel is visible.
    func cycleNext() {
        state.cycleNext()
    }
    
    func isShowingSwitcher(for application: Application) -> Bool {
        guard let currentApplication else { return false }
        
        if let currentBundleID = currentApplication.bundleIdentifier,
           let targetBundleID = application.bundleIdentifier {
            return currentBundleID == targetBundleID
        }
        
        if let currentURL = currentApplication.bundleUrl,
           let targetURL = application.bundleUrl {
            return currentURL == targetURL
        }
        
        return currentApplication.title == application.title
    }
    
    // Called when user releases a configured switcher modifier.
    func activateSelectedWindow() {
        if presentation == .sidebar {
            let id = state.currentWindow?.cgWindowID
            let pid = currentApplication?.pid
            hideSwitcher()
            if let id, let pid { onSidebarActivate?(SidebarWindowID(pid: pid, windowID: id)) }
            return
        }
        guard let item = state.currentItem else {
            hideSwitcher()
            return
        }
        
        switch item {
        case .window(let window):
            window.focus()
            hideSwitcher()
        case .action:
            let application = currentApplication
            hideSwitcher()
            
            Task { @MainActor in
                guard let application else {
                    NSSound.beep()
                    return
                }
                
                let success = await application.performNoWindowAction()
                if !success {
                    NSSound.beep()
                }
            }
        }
    }
    
    private func hideSwitcher() {
        guard !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }
        let wasSidebar = presentation == .sidebar
        // Reset before orderOut, which can synchronously send windowDidResignKey.
        presentation = .keyboard
        panel.hidesOnDeactivate = true
        sidebarAnchor = nil
        removeFlagsMonitor()
        removeKeyDownMonitor()
        state.reset()
        currentApplication = nil
        currentSidebarEntryID = nil
        panelAnchorCenter = nil
        if panel.isVisible { panel.orderOut(nil) }
        if wasSidebar { onSidebarDismiss?() }
    }
    
    private func installFlagsMonitor() {
        guard localFlagsMonitor == nil, globalFlagsMonitor == nil else { return }
        
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            
            self.activateIfSwitcherModifierWasReleased(event.modifierFlags)
            
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.activateIfSwitcherModifierWasReleased(event.modifierFlags)
            }
        }
    }

    private func activateIfSwitcherModifierWasReleased(_ modifierFlags: NSEvent.ModifierFlags) {
        guard panel.isVisible else { return }

        let requiredModifiers = modifierManager.activateModifiers.intersection(Self.releaseModifierMask)
        let pressedModifiers = modifierFlags.intersection(Self.releaseModifierMask)
        if presentation.shouldCommit(required: requiredModifiers, pressed: pressedModifiers) {
            activateSelectedWindow()
        }
    }
    
    private func removeFlagsMonitor() {
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }

        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
    }

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if self.panel.isVisible, self.presentation == .sidebar {
                switch event.keyCode {
                case 36, 76:
                    self.activateSelectedWindow()
                    return nil
                case 125:
                    self.state.cycleNext()
                    return nil
                case 126:
                    self.state.cyclePrevious()
                    return nil
                default: break
                }
            }

            // Escape closes the switcher.
            if self.panel.isVisible, event.keyCode == 53 {
                self.hideSwitcher()
                return nil
            }

            return event
        }
    }

    private func removeKeyDownMonitor() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
    }
    
    deinit {
        // Capture the monitor in a local variable before deinit (while still on main actor)
        let localMonitor = localFlagsMonitor
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        let globalMonitor = globalFlagsMonitor
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        let keyMonitor = keyDownMonitor
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}
