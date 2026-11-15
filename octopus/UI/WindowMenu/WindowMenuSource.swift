import AppKit

////////////////////
//// Copy sidebar inventory data into window menu snapshots
/// The inventory lists one entry per app per Desktop; the menu wants one app
/// with all its windows, so entries are merged by process.
// Pinned placeholders (negative pid) are not running and are skipped.

@MainActor
enum WindowMenuSource {
    static func runningApps(from entries: [SidebarEntry]) -> [WindowMenuRunningApp] {
        var order: [pid_t] = []
        var apps: [pid_t: WindowMenuRunningApp] = [:]
        for entry in entries where entry.pid > 0 {
            let windows = entry.windows.compactMap { window -> WindowMenuWindowSnapshot? in
                guard let id = window.cgWindowID, id != kCGNullWindowID else { return nil }
                let state = entry.windowStates[id]
                return WindowMenuWindowSnapshot(windowID: id, title: window.title,
                                                isMinimized: state?.isMinimized ?? false,
                                                canMinimize: state?.canMinimize ?? false,
                                                canClose: state?.canClose ?? true)
            }
            if var existing = apps[entry.pid] {
                let known = Set(existing.windows.map(\.windowID))
                existing.windows += windows.filter { !known.contains($0.windowID) }
                apps[entry.pid] = existing
            } else {
                order.append(entry.pid)
                apps[entry.pid] = WindowMenuRunningApp(pid: entry.pid, bundleIdentifier: entry.application.bundleIdentifier,
                                                       title: entry.application.title, bundleURL: entry.application.bundleUrl,
                                                       windows: windows)
            }
        }
        return order.compactMap { apps[$0] }
    }

    ////////////////////
    //// Installed-app lookup
    /// Launch Services lookups are not free, so results (including misses) are cached
    // for the app's lifetime; an app installed later appears after the next launch.

    private static var installedCache: [String: WindowMenuInstalledApp?] = [:]

    static func installedApp(_ bundleIdentifier: String) -> WindowMenuInstalledApp? {
        if let cached = installedCache[bundleIdentifier] { return cached }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { url in
            // Finder may show or hide the extension; the menu never shows it.
            let name = FileManager.default.displayName(atPath: url.path)
            return WindowMenuInstalledApp(title: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, bundleURL: url)
        }
        installedCache[bundleIdentifier] = app
        return app
    }

    //////////////////
}

//////////////////
