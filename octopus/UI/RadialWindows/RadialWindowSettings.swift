import AppKit
import Combine
import KeyboardShortcuts

@MainActor
final class RadialWindowSettings: ObservableObject {
    static let shared = RadialWindowSettings()
    static let mouseKey = "radialWindowsMiddleClick"
    @Published private(set) var middleClickEnabled: Bool
    @Published var editingShortcuts = false
    @Published var status: String?
    private let defaults: UserDefaults
    var blocksOpening: Bool { Self.editingBlocksOpening(editingShortcuts, windows: NSApp.windows) }

    static func editingBlocksOpening(_ shortcutsSelected: Bool, windows: [NSWindow]) -> Bool {
        shortcutsSelected && windows.contains { $0.isVisible && PreferencesController.isLikelySettingsWindow($0) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        middleClickEnabled = defaults.bool(forKey: Self.mouseKey)
    }

    static func mouseConflict(in bindings: MouseShortcutBindings) -> Bool {
        MouseShortcutAction.allCases.contains { bindings[$0] == MouseShortcut(button: 2) }
    }

    @discardableResult func setMiddleClick(_ enabled: Bool) -> String? {
        if enabled && Self.mouseConflict(in: MouseShortcutBindings(defaults: defaults)) {
            return "Middle click is assigned to a sidebar action. Clear that assignment first."
        }
        middleClickEnabled = enabled
        defaults.set(enabled, forKey: Self.mouseKey)
        return nil
    }

    static func keyboardError(_ shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut else { return nil }
        guard !shortcut.modifiers.intersection(MouseShortcut.supportedModifiers).isEmpty else {
            return "Choose a shortcut with at least one modifier key."
        }
        if shortcut == .init(.tab, modifiers: .control) || shortcut == .init(.tab, modifiers: [.control, .shift])
            || WindowMonitorShortcuts.conflict(for: shortcut, excluding: .showRadialWindows) {
            return "This shortcut is assigned to another Octopus action. Choose another."
        }
        return nil
    }
}
