import AppKit

////////////////////
//// Display chosen in General > "Window menu display"
/// Shared by the keyboard window switcher and the centre window menu.
// Nil means Automatic; a disconnected display falls back to the primary one.

enum WindowMenuDisplayPreference {
    static let key = "windowMenuDisplay"

    @MainActor
    static func chosenScreen(in defaults: UserDefaults = .standard) -> NSScreen? {
        // Preserve the earlier primary-display toggle until a display is explicitly chosen.
        let display = defaults.string(forKey: key)
            ?? (defaults.bool(forKey: "showWindowMenuOnPrimaryDisplay") ? "primary" : "automatic")
        guard display != "automatic" else { return nil }
        let screens = NSScreen.screens
        // screens.first is the primary display and the fallback for a disconnected selection.
        return screens.first { SidebarSettings.monitorID($0) == display } ?? screens.first
    }
}

//////////////////
