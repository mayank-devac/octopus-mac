import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
final class RadialWindowController {
    var interactionBusy: () -> Bool = { false }
    var onPresentation: (Bool) -> Void = { _ in }
    private let catalogue = RadialWindowCatalogue()
    private let input = RadialWindowInputMonitor()
    private let settings = RadialWindowSettings.shared
    private var panel: NSPanel?
    private var model: RadialWindowModel?
    private var screenFrame = CGRect.zero
    private var openingPoint = CGPoint.zero
    private var requirements: [SidebarWindowID: SidebarFocusRequirement] = [:]
    private var pendingFocus: SidebarPendingAction?
    private var generation = 0
    private var loading = false
    private var enabled = false
    private var configuredMouse = false
    private var configuredKeyboard: KeyboardShortcuts.Shortcut?
    private var configuredKeyboardValid = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var pager = RadialWindowScrollPager()

    func start() {
        guard observers.isEmpty else { return }
        input.canBeginMouse = { [weak self] in
            guard let self else { return false }
            return self.settings.middleClickEnabled && !RadialWindowSettings.mouseConflict(in: MouseShortcutStore.shared.bindings)
                && self.canOpen() && NSEvent.pressedMouseButtons & ~4 == 0
        }
        input.onBeginMouse = { [weak self] point in self?.open(at: point) }
        input.onPointer = { [weak self] point in self?.pointer(point) }
        input.onFinish = { [weak self] point in self?.pointer(point); self?.finish() }
        input.onCancel = { [weak self] in self?.cancel() }
        input.onOtherInput = { [weak self] in
            guard self?.pendingFocus != nil else { return }
            self?.cancel()
        }
        input.onKey = { [weak self] key in self?.key(key) }
        input.onScroll = { [weak self] delta, precise, momentum in
            guard let self, let direction = self.pager.step(delta: delta, precise: precise, momentum: momentum,
                                                           time: ProcessInfo.processInfo.systemUptime) else { return }
            self.model?.changePage(direction)
        }
        catalogue.onDesktopChange = { [weak self] in
            // A committed focus can itself switch Desktops. Keep that focus request alive.
            if self?.model != nil { self?.cancel() }
        }
        catalogue.onChange = { [weak self] in
            guard let self else { return }
            if !self.catalogue.hasPermission { self.cancel() }
            self.configure()
            if !self.loading, let model = self.model {
                model.reconcile(availableIDs: Set(self.catalogue.items.map(\.id)))
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configure() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(); self?.input.updateScreenCoordinates() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.settings.blocksOpening == true { self?.cancel() }
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model != nil { self?.cancel() } }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configure() }
        })
        settings.$editingShortcuts.dropFirst().sink { [weak self] editing in
            if editing { self?.cancel() }
        }.store(in: &subscriptions)
        configure()
    }

    private func configure() {
        let shortcut = KeyboardShortcuts.getShortcut(for: .showRadialWindows)
        let keyboardError = RadialWindowSettings.keyboardError(shortcut)
        let mouseConflict = RadialWindowSettings.mouseConflict(in: MouseShortcutStore.shared.bindings)
        let mouse = settings.middleClickEnabled && !mouseConflict
        let keyboardValid = shortcut != nil && keyboardError == nil
        if configuredMouse != mouse || configuredKeyboard != shortcut || configuredKeyboardValid != keyboardValid { cancel() }
        configuredMouse = mouse
        configuredKeyboard = shortcut
        configuredKeyboardValid = keyboardValid
        enabled = mouse || keyboardValid
        if enabled {
            catalogue.start()
            if catalogue.hasPermission {
                settings.status = input.start() ? keyboardError : "Global input capture is unavailable. Check Accessibility access."
            } else {
                input.stopWhenDrained()
                settings.status = "Allow Octopus in System Settings → Privacy & Security → Accessibility."
            }
        } else {
            input.stopWhenDrained()
            catalogue.stop()
            settings.status = keyboardError
        }
        if settings.middleClickEnabled && mouseConflict {
            settings.status = "Middle click conflicts with a sidebar action. Change that assignment to enable capture."
        }
    }

    private func canOpen() -> Bool {
        enabled && input.isInstalled && catalogue.hasPermission && !settings.blocksOpening
            && model == nil && !interactionBusy()
    }

    func openFromKeyboard() {
        guard canOpen(), NSEvent.pressedMouseButtons == 0,
              let shortcut = KeyboardShortcuts.getShortcut(for: .showRadialWindows),
              RadialWindowSettings.keyboardError(shortcut) == nil else { return }
        let modifiers = shortcut.modifiers.intersection(MouseShortcut.supportedModifiers)
        guard NSEvent.modifierFlags.intersection(MouseShortcut.supportedModifiers).isSuperset(of: modifiers),
              input.beginKeyboard(modifiers: modifiers, key: UInt16(shortcut.carbonKeyCode)) else { return }
        open()
    }

    private func open(at position: CGPoint? = nil) {
        guard canOpen() else { input.cancel(); return }
        let point = position ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { input.cancel(); return }
        pendingFocus?.cancel()
        pendingFocus = nil
        generation += 1
        let request = generation
        screenFrame = screen.visibleFrame
        openingPoint = point
        pager = RadialWindowScrollPager()
        let cached = catalogue.cachedSnapshot
        let model = RadialWindowModel(items: cached?.items, pointer: point)
        self.model = model
        requirements = cached?.requirements ?? [:]
        loading = cached == nil
        onPresentation(true)
        show(model)
        catalogue.refresh { [weak self] in
            guard let self, self.generation == request, self.model === model else { return }
            // Keep visible slots fixed. An empty status circle can accept its first windows.
            guard self.loading || model.items.isEmpty else { return }
            let snapshot = self.catalogue.snapshot()
            self.requirements = snapshot.requirements
            self.loading = false
            model.load(snapshot.items)
            self.show(model)
        }
    }

    private func show(_ model: RadialWindowModel) {
        let frame: CGRect
        if model.items.isEmpty {
            frame = RadialWindowGeometry.statusFrame(at: openingPoint)
        } else if let ringFrame = RadialWindowGeometry.panelFrame(at: openingPoint, available: screenFrame, overflow: model.hasOverflow) {
            frame = ringFrame
        } else {
            model.load([])
            model.message = "Not enough space for the menu"
            frame = RadialWindowGeometry.statusFrame(at: openingPoint)
        }
        if panel == nil {
            panel = RadialWindowPanel(model: model)
        }
        panel?.setFrame(frame, display: true, animate: false)
        panel?.orderFrontRegardless()
    }

    private func pointer(_ point: CGPoint) {
        guard !loading, let model, let panel else { return }
        model.updatePointer(point, centre: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
    }

    private func key(_ code: UInt16) {
        guard !loading, let model else { return }
        switch code {
        case 123, 126: model.navigate(.previous)
        case 124, 125: model.navigate(.next)
        case 116: model.navigate(.previousPage)
        case 121: model.navigate(.nextPage)
        case 36, 76:
            if model.selectsMore { model.navigate(.enter) }
            else { finish() }
        default: break
        }
    }

    private func finish() {
        let selected = loading ? nil : model?.selectedItem
        let requirement = selected.flatMap { requirements[$0.id] }
        cancel()
        guard let selected, let requirement else { return }
        let request = generation
        pendingFocus = catalogue.focus(selected.id, requirement: requirement) { [weak self] _ in
            guard self?.generation == request else { return }
            self?.pendingFocus = nil
        }
    }

    func cancel() {
        generation += 1
        input.cancel()
        pendingFocus?.cancel()
        pendingFocus = nil
        let wasVisible = model != nil
        model = nil
        loading = false
        requirements = [:]
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        if wasVisible { onPresentation(false) }
    }

    func stop() {
        cancel()
        input.stop()
        catalogue.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        workspaceObservers = []
        subscriptions.removeAll()
    }
}

@MainActor
final class RadialWindowPanel: NSPanel {
    init(model: RadialWindowModel) {
        let size = CGSize(width: model.canvasSize, height: model.canvasSize)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RadialWindowView(model: model))
        host.sizingOptions = []
        contentView = host
    }
}
