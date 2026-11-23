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
    private var defaultsObserver: NSObjectProtocol?

    func start() {
        EmojiPickerSettings.registerDefaults()
        popover.behavior = .transient
        let host = NSHostingController(rootView: EmojiPickerView())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        KeyboardShortcuts.onKeyDown(for: .showEmojiPicker) { [weak self] in
            self?.togglePopover()
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
        // An accessory app must activate for the search field to receive typing.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
