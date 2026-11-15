import AppKit

////////////////////
//// App icons for running and not-running apps
/// Not-running apps (pinned, recent, workspace) have no NSRunningApplication,
/// so their icon comes from the bundle on disk. Results are cached by path.
// Every icon is flattened to one fixed bitmap: see `flattened(_:)`.

@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// Large enough for the biggest magnified sidebar icon on a Retina display.
    static let renderSize: CGFloat = 128

    static func icon(pid: pid_t?, bundleURL: URL?) -> NSImage? {
        if let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            let key = (app.bundleURL?.path ?? "pid:\(pid)") as NSString
            return cached(key) { icon }
        }
        guard let bundleURL else { return nil }
        return cached(bundleURL.path as NSString) { NSWorkspace.shared.icon(forFile: bundleURL.path) }
    }

    private static func cached(_ key: NSString, load: () -> NSImage) -> NSImage {
        if let cached = cache.object(forKey: key) { return cached }
        let icon = flattened(load())
        cache.setObject(icon, forKey: key)
        return icon
    }

    // System icons carry many size variants, and for older app icons the small
    // ones (16/32pt) are drawn on a grey plate. SwiftUI picks a variant per draw,
    // so a hover animation flips between plated and plain. Drawing once at a large
    // size keeps only the plain variant.
    static func flattened(_ icon: NSImage) -> NSImage {
        var pixelRect = NSRect(x: 0, y: 0, width: renderSize * 2, height: renderSize * 2)
        guard let bitmap = icon.cgImage(forProposedRect: &pixelRect, context: nil, hints: nil) else { return icon }
        return NSImage(cgImage: bitmap, size: NSSize(width: renderSize, height: renderSize))
    }
}

//////////////////
