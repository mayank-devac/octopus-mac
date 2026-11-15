import AppKit

////////////////////
//// App icons for running and not-running apps
/// Not-running apps (pinned, recent, workspace) have no NSRunningApplication,
// so their icon comes from the bundle on disk. Results are cached by path.

@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(pid: pid_t?, bundleURL: URL?) -> NSImage? {
        if let pid, pid > 0, let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        guard let bundleURL else { return nil }
        let key = bundleURL.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

//////////////////
