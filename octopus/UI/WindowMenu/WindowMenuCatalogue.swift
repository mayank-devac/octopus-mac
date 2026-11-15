import Foundation

////////////////////
//// Build what the window menu shows from profiles and running apps
/// Workspaces are Octopus profiles. Workspace apps are the apps bound to the
/// profile's slots, in slot order. The window list holds every window of the
/// running workspace apps, grouped by app in strip order.
// A workspace with no bound apps falls back to every running app with windows.

enum WindowMenuCatalogue {

    ////////////////////
    //// Workspaces
    /// Numbered profiles come first by number, then the rest in saved order.

    static func workspaces(from profiles: [Profile]) -> [WindowMenuWorkspace] {
        let numbered: [Profile] = profiles.filter { $0.profileNumber != nil }
            .sorted { (left: Profile, right: Profile) in (left.profileNumber ?? 0) < (right.profileNumber ?? 0) }
        let unnumbered: [Profile] = profiles.filter { $0.profileNumber == nil }
        return (numbered + unnumbered).enumerated().map { index, profile in
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return WindowMenuWorkspace(id: profile.id, label: label(for: profile, name: name, position: index),
                                       name: name.isEmpty ? "Workspace" : name,
                                       bundleIdentifiers: bundleIdentifiers(in: profile.bindings))
        }
    }

    private static func label(for profile: Profile, name: String, position: Int) -> String {
        if let number = profile.profileNumber { return String(number) }
        // Unnumbered workspaces show their switch position so the pills stay
        // distinguishable instead of repeating a shared name initial.
        return String(position + 1)
    }

    /// Slot order; a multi-app slot contributes its apps in their saved order.
    static func bundleIdentifiers(in bindings: Bindings) -> [String] {
        var seen = Set<String>()
        return bindings.compactMap { $0 }.flatMap { binding -> [String] in
            switch binding {
            case .application(let identifier): return [identifier]
            case .workspace(let workspace): return workspace.bundleIdentifiers
            }
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    //// Profiles without a number show their switch position so every workspace stays reachable.
    //////////////////

    ////////////////////
    //// Menu content
    /// `focusPID` is the hovered sidebar app (or frontmost app for the centre menu);
    /// it is added to the strip when the workspace does not include it.
    // `includesOpenApps` appends every other running app with windows after the workspace apps.

    static func content(workspaces: [WindowMenuWorkspace], selectedWorkspaceID: UUID?,
                        running: [WindowMenuRunningApp], focusPID: pid_t?,
                        includesOpenApps: Bool = false,
                        recentBundleIdentifiers: [String] = [],
                        recentLimit: Int = WindowMenuMetrics.recentAppLimit,
                        installed: (String) -> WindowMenuInstalledApp?) -> WindowMenuContent {
        let workspace = workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first
        var apps = workspaceApps(workspace?.bundleIdentifiers ?? [], running: running, installed: installed)
        if apps.isEmpty || includesOpenApps {
            let shownPIDs = Set(apps.compactMap(\.pid))
            apps += running.filter { !$0.windows.isEmpty && !shownPIDs.contains($0.pid) }.map(app(for:))
        }
        if let focusPID, !apps.contains(where: { $0.pid == focusPID }),
           let focused = running.first(where: { $0.pid == focusPID }) {
            apps.insert(app(for: focused), at: 0)
        }
        let runningByPID = Dictionary(running.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let windows = apps.flatMap { app -> [WindowMenuWindow] in
            guard let pid = app.pid, let source = runningByPID[pid] else { return [] }
            return source.windows.map { window in
                WindowMenuWindow(id: SidebarWindowID(pid: pid, windowID: window.windowID), appID: app.id,
                                 title: window.title, isMinimized: window.isMinimized,
                                 canMinimize: window.canMinimize, canClose: window.canClose)
            }
        }
        let runningBundleIDs = Set(running.compactMap(\.bundleIdentifier))
        let recentApps = recentBundleIdentifiers.filter { !runningBundleIDs.contains($0) }.compactMap { identifier in
            installed(identifier).map {
                WindowMenuApp(id: identifier, bundleIdentifier: identifier, title: $0.title, bundleURL: $0.bundleURL, pid: nil)
            }
        }
        return WindowMenuContent(workspaces: workspaces, selectedWorkspaceID: workspace?.id,
                                 apps: apps, windows: windows, recentApps: Array(recentApps.prefix(recentLimit)))
    }

    private static func workspaceApps(_ identifiers: [String], running: [WindowMenuRunningApp],
                                      installed: (String) -> WindowMenuInstalledApp?) -> [WindowMenuApp] {
        identifiers.compactMap { identifier in
            if let source = running.first(where: { $0.bundleIdentifier == identifier }) { return app(for: source) }
            // A bound app that is no longer installed is skipped rather than shown broken.
            return installed(identifier).map {
                WindowMenuApp(id: identifier, bundleIdentifier: identifier, title: $0.title, bundleURL: $0.bundleURL, pid: nil)
            }
        }
    }

    private static func app(for source: WindowMenuRunningApp) -> WindowMenuApp {
        WindowMenuApp(id: source.bundleIdentifier ?? "pid:\(source.pid)", bundleIdentifier: source.bundleIdentifier,
                      title: source.title, bundleURL: source.bundleURL, pid: source.pid)
    }

    //// Window order follows the strip, so arrow keys walk apps left to right.
    //////////////////
}

//////////////////
