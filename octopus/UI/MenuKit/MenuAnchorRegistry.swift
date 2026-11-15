import AppKit

////////////////////
//// Pointer hit testing for menu panels
/// Menus register a `SidebarGeometryAnchor` per hoverable element. One pointer
/// path then maps the screen point to a target, so overlapping SwiftUI controls
// cannot swallow or replay hover events (same rule as the classic sidebar menu).

@MainActor
final class MenuAnchorRegistry<Target: Hashable> {
    private var anchors: [Target: NSView] = [:]

    func apply(_ change: SidebarAnchorChange, for target: Target) {
        change.apply(to: &anchors, id: target)
    }

    func removeAll() { anchors.removeAll() }

    /// The smallest visible element under the point wins, so a button inside a row beats the row.
    func target(at point: CGPoint) -> Target? {
        var best: (target: Target, area: CGFloat)?
        for (target, view) in anchors {
            guard let rect = Self.visibleScreenRect(of: view), rect.contains(point) else { continue }
            let area = rect.width * rect.height
            if area < best?.area ?? .infinity { best = (target, area) }
        }
        return best?.target
    }

    static func visibleScreenRect(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        // Since macOS 14, unclipped views can report a visibleRect larger than their bounds.
        let visible = view.bounds.intersection(view.visibleRect)
        guard !visible.isEmpty else { return nil }
        return window.convertToScreen(view.convert(visible, to: nil))
    }
}

//// Anchors remove themselves on dismantle, so stale rows never match.
//////////////////
