//
//  EmojiPickerController.swift
//  octopus
//
//  Owns the emoji menu-bar item and its popover. An AppKit status item is used
//  instead of SwiftUI `MenuBarExtra` because `MenuBarExtra` cannot be opened
//  from code, and the `showEmojiPicker` shortcut needs to toggle it.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// No default: the obvious choice (Control-Command-Space) is the system emoji viewer.
    static let showEmojiPicker = Self("showEmojiPicker")
}

@MainActor
final class EmojiPickerController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = EmojiPickerModel()
    private var defaultsObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    /// The app that was frontmost before opening, so Return can hand focus back for ⌘V.
    private var previousApp: NSRunningApplication?

    func start() {
        EmojiPickerSettings.registerDefaults()
        popover.behavior = .transient
        let host = NSHostingController(rootView: EmojiPickerView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        KeyboardShortcuts.onKeyDown(for: .showEmojiPicker) { [weak self] in
            self?.togglePopover()
        }
        // Only keys sent to the popover's window are handled; other Octopus windows are untouched.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.window === self.popover.contentViewController?.view.window,
                  let action = EmojiPickerKeyAction(keyCode: event.keyCode, modifiers: event.modifierFlags)
            else { return event }
            self.perform(action)
            return nil
        }
        // Follow the Preferences > General toggle that shows or hides the item.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncStatusItem() }
        }
        syncStatusItem()
    }

    func stop() {
        KeyboardShortcuts.disable(.showEmojiPicker)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        popover.performClose(nil)
        removeStatusItem()
    }

    ////////////////////
    //// Status item visibility
    /// Insert or remove the item to match the stored preference.

    private func syncStatusItem() {
        let shown = UserDefaults.standard.bool(forKey: EmojiPickerSettings.showMenuBarItemKey)
        if shown, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Emoji")
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            statusItem = item
        } else if !shown {
            removeStatusItem()
        }
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    //// The popover anchors to this item, so it only opens while the item is shown.
    //////////////////

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == NSRunningApplication.current ? nil : frontmost
        model.prepareForOpen()
        // An accessory app must activate for the search field to receive typing.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    ////////////////////
    //// Keyboard actions
    /// Return copies and closes, handing focus back so ⌘V pastes immediately.

    private func perform(_ action: EmojiPickerKeyAction) {
        switch action {
        case .move(let key):
            model.moveSelection(key)
        case .nextCategory:
            model.cycleCategory(forward: true)
        case .previousCategory:
            model.cycleCategory(forward: false)
        case .copy(let keepOpen):
            guard model.copySelection() else { NSSound.beep(); return }
            if !keepOpen { closeRestoringFocus() }
        case .cancel:
            if model.query.isEmpty {
                closeRestoringFocus()
            } else {
                model.query = ""
            }
        }
    }

    private func closeRestoringFocus() {
        popover.performClose(nil)
        previousApp?.activate()
        previousApp = nil
    }

    //// Pointer clicks outside still close the transient popover normally.
    //////////////////
}
