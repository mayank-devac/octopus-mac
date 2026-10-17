//
//  ShortcutController.swift
//  octopus
//
//  Created  on 12-09-2025.
//

import KeyboardShortcuts
import Cocoa

let numberKeys: [KeyboardShortcuts.Key] = [
    .zero, .one, .two, .three, .four,
    .five, .six, .seven, .eight, .nine
]

// Numeric-keypad equivalents of `numberKeys`. Numpad keys have distinct virtual
// key codes from the main row (e.g. kVK_ANSI_Keypad0 != kVK_ANSI_0), so they
// must be registered as separate global hotkeys to also fire from the numpad.
let keypadKeys: [KeyboardShortcuts.Key] = [
    .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
    .keypad5, .keypad6, .keypad7, .keypad8, .keypad9
]

extension KeyboardShortcuts.Name {
    static let showRadialWindows = Self("showRadialWindows", default: .init(.space, modifiers: [.control, .option]))
    static let moveWindowLeftMonitor = Self("moveWindowLeftMonitor", default: .init(.leftArrow, modifiers: [.control, .shift]))
    static let moveWindowRightMonitor = Self("moveWindowRightMonitor", default: .init(.rightArrow, modifiers: [.control, .shift]))

    static let bindShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("bind\(number)")
    }
    
    static let activateShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("activate\(number)")
    }
    
    static let profileShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("profile\(number)")
    }

    // Numeric-keypad counterparts registered alongside the main-row shortcuts.
    static let bindKeypadShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("bindKeypad\(number)")
    }

    static let activateKeypadShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("activateKeypad\(number)")
    }

    static let profileKeypadShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("profileKeypad\(number)")
    }
}

enum WindowMonitorShortcuts {
    static func migrateDefaults(in defaults: UserDefaults = .standard,
                                read: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: $0) },
                                write: (KeyboardShortcuts.Shortcut?, KeyboardShortcuts.Name) -> Void = { KeyboardShortcuts.setShortcut($0, for: $1) }) {
        let migrationKey = "monitorMoveControlShiftDefaultsMigrated"
        guard !defaults.bool(forKey: migrationKey) else { return }
        let oldDefaults: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
            (.moveWindowLeftMonitor, .init(.leftArrow, modifiers: .option)),
            (.moveWindowRightMonitor, .init(.rightArrow, modifiers: .option))
        ]
        for (name, oldDefault) in oldDefaults where read(name) == oldDefault {
            write(name.defaultShortcut, name)
        }
        // Run once so explicitly choosing Option later remains a saved user preference.
        // Other combinations and cleared shortcuts never match the old defaults.
        defaults.set(true, forKey: migrationKey)
    }

    static func conflict(for shortcut: KeyboardShortcuts.Shortcut?, excluding name: KeyboardShortcuts.Name,
                         includeRadial: Bool = true) -> Bool {
        guard let shortcut else { return false }
        let names: [KeyboardShortcuts.Name] = [.moveWindowLeftMonitor, .moveWindowRightMonitor, .showRadialWindows]
            + KeyboardShortcuts.Name.bindShortcuts + KeyboardShortcuts.Name.activateShortcuts
            + KeyboardShortcuts.Name.profileShortcuts + KeyboardShortcuts.Name.bindKeypadShortcuts
            + KeyboardShortcuts.Name.activateKeypadShortcuts + KeyboardShortcuts.Name.profileKeypadShortcuts
        return names.contains { $0 != name && (includeRadial || $0 != .showRadialWindows)
            && KeyboardShortcuts.getShortcut(for: $0) == shortcut }
    }
}

@MainActor
final class ShortcutController {
    private let cycleController: CyclePanelController
    private let profileManager: ProfileManager
    private let monitorMoveController = WindowMonitorMoveController()
    private let radialController: RadialWindowController?
    
    init(_ cycleController: CyclePanelController, _ profileManager: ProfileManager,
         radialController: RadialWindowController? = nil) {
        self.cycleController = cycleController
        self.profileManager = profileManager
        self.radialController = radialController
        
        WindowMonitorShortcuts.migrateDefaults()
        monitorMoveController.start()
        setupShortcuts()
    }
    
    private func setupShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .showRadialWindows) { [weak self] in
            self?.radialController?.openFromKeyboard()
        }
        // Key-up fires once per press, even when holding the arrow generates key repeats.
        for (name, direction) in [(KeyboardShortcuts.Name.moveWindowLeftMonitor, WindowMonitorMoveDirection.left),
                                  (.moveWindowRightMonitor, .right)] {
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                // A later modifier change can make an app/profile shortcut collide with this one.
                // Keep the existing action; never also move a window under an ambiguous binding.
                guard !WindowMonitorShortcuts.conflict(for: KeyboardShortcuts.getShortcut(for: name), excluding: name, includeRadial: false) else { return }
                self?.radialController?.cancel()
                self?.monitorMoveController.move(direction)
            }
        }
        for number in 0...9 {
            // Register both the main-row and numeric-keypad shortcut for each
            // number so either physical key triggers the same action.
            for name in [KeyboardShortcuts.Name.bindShortcuts[number], .bindKeypadShortcuts[number]] {
                KeyboardShortcuts.onKeyUp(for: name) {
                    self.handleBind(number: number)
                }
            }

            for name in [KeyboardShortcuts.Name.activateShortcuts[number], .activateKeypadShortcuts[number]] {
                KeyboardShortcuts.onKeyDown(for: name) {
                    self.handleActivate(number: number)
                }
            }

            for name in [KeyboardShortcuts.Name.profileShortcuts[number], .profileKeypadShortcuts[number]] {
                KeyboardShortcuts.onKeyDown(for: name) {
                    self.handleProfile(number: number)
                }
            }
        }
    }

    func stop() {
        KeyboardShortcuts.disable(.moveWindowLeftMonitor, .moveWindowRightMonitor, .showRadialWindows)
        monitorMoveController.stop()
    }
    
    private func handleBind(number: Int) {
        radialController?.cancel()
        guard let application = Application.getFrontApplication() else {
            NSSound.beep()
            return
        }

        guard let bundleIdentifier = application.bundleIdentifier else {
            NSSound.beep()
            return
        }

        profileManager.bind(bundleIdentifier: bundleIdentifier, to: number)

        print("Bound \(application.title) to \(number)")
    }
    
    private func handleActivate(number: Int) {
        radialController?.cancel()
        guard let binding = profileManager.application(for: number) else {
            NSSound.beep()
            return
        }
        
        // If panel is already visible, cycle if same app; otherwise switch to the newly requested app.
        if cycleController.isKeyboardSwitcherVisible {
            if cycleController.isShowingSwitcher(for: binding) {
                cycleController.cycleNext()
            } else {
                cycleController.showSwitcher(for: binding)
            }
            
            return
        }

        // Determine starting index
        var startIndex = 0
        if let frontApp = Application.getFrontApplication(),
           frontApp.title == binding.title {
            // Already on this app, start at second window
            startIndex = 1
        }
        
        cycleController.showSwitcher(for: binding, startIndex: startIndex)
    }
    
    func handleProfile(number: Int) {
        radialController?.cancel()
        guard let profileID = profileManager.profileID(forNumber: number) else {
            NSSound.beep()
            return
        }
        
        profileManager.switchProfile(id: profileID)
    }
}
