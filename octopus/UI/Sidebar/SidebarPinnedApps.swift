import AppKit

////////////////////
//// Apps kept in the sidebar after they quit ("Keep in Sidebar")
/// A pinned app that is not running appears as a dimmed placeholder entry, like a
/// Dock item. Placeholders have no windows and a negative process ID, so no AX
/// code ever runs for them; clicking one launches the app, and once it runs the
/// real entry replaces it.
// Placeholders show in the single sidebar, or the primary display's sidebar.

@MainActor
enum SidebarPinnedApps {
    static let didChange = Notification.Name("octopus.sidebarPinnedAppsDidChange")

    static func load(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: PreferenceKeys.sidebarPinnedApps) ?? []
    }

    static func isPinned(_ bundleIdentifier: String, in defaults: UserDefaults = .standard) -> Bool {
        load(in: defaults).contains(bundleIdentifier)
    }

    static func toggle(_ bundleIdentifier: String, in defaults: UserDefaults = .standard) {
        defaults.set(toggling(bundleIdentifier, in: load(in: defaults)), forKey: PreferenceKeys.sidebarPinnedApps)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func isPlaceholder(_ entry: SidebarEntry) -> Bool { entry.pid < 0 }

    ////////////////////
    //// Pure helpers (tested)

    nonisolated static func toggling(_ bundleIdentifier: String, in pinned: [String]) -> [String] {
        pinned.contains(bundleIdentifier) ? pinned.filter { $0 != bundleIdentifier } : pinned + [bundleIdentifier]
    }

    /// Pinned apps that are not running need a placeholder, in pin order.
    nonisolated static func placeholderIdentifiers(pinned: [String], running: Set<String>) -> [String] {
        var seen = Set<String>()
        return pinned.filter { !running.contains($0) && seen.insert($0).inserted }
    }

    /// Stable, negative and unique per pin position, so it can never match a real process.
    nonisolated static func placeholderPID(at index: Int) -> pid_t { -pid_t(index + 1) }

    //////////////////

    ////////////////////
    //// Placeholder entries

    static func appendingPlaceholders(to entries: [SidebarEntry], displayIdentifier: String?) -> [SidebarEntry] {
        guard showsPlaceholders(on: displayIdentifier) else { return entries }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let placeholders = placeholderIdentifiers(pinned: load(), running: running).enumerated().compactMap { index, identifier -> SidebarEntry? in
            // An uninstalled pinned app is skipped until it is installed again.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                  let application = Application(url: url), application.runningApplication == nil else { return nil }
            return SidebarEntry(pid: placeholderPID(at: index), application: application, windows: [], preferredID: nil)
        }
        return entries + placeholders
    }

    static func launch(_ entry: SidebarEntry) {
        guard let identifier = entry.application.bundleIdentifier, let url = entry.application.bundleUrl else { return }
        Application.activateOrLaunch(bundleIdentifier: identifier, bundleURL: url)
    }

    private static func showsPlaceholders(on displayIdentifier: String?) -> Bool {
        guard let displayIdentifier else { return true }
        return NSScreen.screens.first.flatMap(SidebarSettings.monitorID) == displayIdentifier
    }

    //// Placeholders sit with windowless apps, after every running app.
    //////////////////
}

//////////////////
