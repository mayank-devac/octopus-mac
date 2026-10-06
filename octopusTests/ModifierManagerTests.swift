import AppKit
import KeyboardShortcuts
import Testing
@testable import octopus

struct ModifierManagerTests {
    // One synchronous main-actor test keeps shared preferences and shortcut
    // registrations together, and restores only the values it touches.
    @MainActor @Test func numpadOptInClearsOldShortcutsAndPreservesMainRow() {
        let defaults = UserDefaults.standard
        let preferenceKeys = ["numpadShortcutsEnabled"] + ["bind", "activate", "profile"].flatMap { action in
            ["Enabled", "Control", "Option", "Shift", "Command"].map { action + $0 }
        }
        let savedPreferences = preferenceKeys.map { ($0, defaults.object(forKey: $0)) }
        let shortcutNames = KeyboardShortcuts.Name.bindShortcuts
            + KeyboardShortcuts.Name.activateShortcuts
            + KeyboardShortcuts.Name.profileShortcuts
            + KeyboardShortcuts.Name.bindKeypadShortcuts
            + KeyboardShortcuts.Name.activateKeypadShortcuts
            + KeyboardShortcuts.Name.profileKeypadShortcuts
        let savedShortcuts = shortcutNames.map { ($0, KeyboardShortcuts.getShortcut(for: $0)) }
        defer {
            for (name, shortcut) in savedShortcuts {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            }
            for (key, value) in savedPreferences {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        for key in preferenceKeys {
            defaults.removeObject(forKey: key)
        }
        // Reproduce an upgrade with keypad shortcuts saved by the old version.
        for names in [KeyboardShortcuts.Name.bindKeypadShortcuts,
                      KeyboardShortcuts.Name.activateKeypadShortcuts,
                      KeyboardShortcuts.Name.profileKeypadShortcuts] {
            for number in 0...9 {
                KeyboardShortcuts.setShortcut(.init(keypadKeys[number], modifiers: .control), for: names[number])
            }
        }

        let manager = ModifierManager()
        func expectConfiguredShortcuts() {
            let actions: [([KeyboardShortcuts.Name], [KeyboardShortcuts.Name], NSEvent.ModifierFlags)] = [
                (KeyboardShortcuts.Name.bindShortcuts, KeyboardShortcuts.Name.bindKeypadShortcuts, manager.bindModifiers),
                (KeyboardShortcuts.Name.activateShortcuts, KeyboardShortcuts.Name.activateKeypadShortcuts, manager.activateModifiers),
                (KeyboardShortcuts.Name.profileShortcuts, KeyboardShortcuts.Name.profileKeypadShortcuts, manager.profileModifiers)
            ]
            for (mainNames, keypadNames, modifiers) in actions {
                for number in 0...9 {
                    let mainShortcut: KeyboardShortcuts.Shortcut? = modifiers.isEmpty
                        ? nil : .init(numberKeys[number], modifiers: modifiers)
                    let keypadShortcut: KeyboardShortcuts.Shortcut? = modifiers.isEmpty || !manager.numpadShortcutsEnabled
                        ? nil : .init(keypadKeys[number], modifiers: modifiers)
                    #expect(KeyboardShortcuts.getShortcut(for: mainNames[number]) == mainShortcut)
                    #expect(KeyboardShortcuts.getShortcut(for: keypadNames[number]) == keypadShortcut)
                }
            }
        }

        #expect(!manager.numpadShortcutsEnabled)
        expectConfiguredShortcuts()

        manager.numpadShortcutsEnabled = true
        #expect(defaults.bool(forKey: "numpadShortcutsEnabled"))
        expectConfiguredShortcuts()
        #expect(ModifierManager().numpadShortcutsEnabled)

        manager.numpadShortcutsEnabled = false
        expectConfiguredShortcuts()
        manager.activateOption = true
        expectConfiguredShortcuts()
        #expect(!ModifierManager().numpadShortcutsEnabled)
        expectConfiguredShortcuts()

        manager.numpadShortcutsEnabled = true
        expectConfiguredShortcuts()

        // No modifiers disables an action, even when numpad support is on.
        manager.activateControl = false
        manager.activateOption = false
        manager.bindControl = false
        manager.bindOption = false
        manager.bindShift = false
        manager.profileControl = false
        manager.profileOption = false
        #expect(!manager.activateEnabled && !manager.bindEnabled && !manager.profileEnabled)
        expectConfiguredShortcuts()

        manager.resetToDefaults()
        #expect(manager.numpadShortcutsEnabled)
        #expect(manager.activateModifiers == .control)
        #expect(manager.profileModifiers == [.control, .option])
        #expect(manager.bindModifiers == [.control, .option, .shift])
        expectConfiguredShortcuts()

        manager.numpadShortcutsEnabled = false
        manager.resetToDefaults()
        #expect(!manager.numpadShortcutsEnabled)
        expectConfiguredShortcuts()
    }
}
