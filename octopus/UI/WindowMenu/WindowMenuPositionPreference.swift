import AppKit

////////////////////
//// Where the centre window menu opens: General > "Window menu position"
/// Cursor (default) centres the card on the pointer; Screen centre keeps the
/// Spotlight-like spot. A display chosen in "Window menu display" that does not
/// hold the pointer always uses its centre, since the pointer is elsewhere.
// The card stays centred on its anchor as it grows, clamped to the visible frame.

enum WindowMenuPositionPreference: String {
    case cursor
    case screenCenter

    static let key = "windowMenuPosition"

    static func current(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .cursor
    }

    /// The point the card centres on, and the area it must stay inside.
    struct Anchor: Equatable {
        let center: CGPoint
        let bounds: CGRect
    }

    @MainActor
    static func anchor(in defaults: UserDefaults = .standard) -> Anchor? {
        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointer) }
        let chosen = WindowMenuDisplayPreference.chosenScreen(in: defaults)
        guard let screen = chosen ?? pointerScreen ?? NSScreen.main else { return nil }
        let followsPointer = current(in: defaults) == .cursor && screen == pointerScreen
        return anchor(pointer: followsPointer ? pointer : nil, visibleFrame: screen.visibleFrame)
    }

    /// Pure part of `anchor()`: nil pointer means the screen's raised centre.
    static func anchor(pointer: CGPoint?, visibleFrame frame: CGRect) -> Anchor {
        let center = pointer
            ?? CGPoint(x: frame.midX, y: frame.midY + frame.height * WindowMenuMetrics.centerVerticalBias)
        return Anchor(center: center, bounds: frame)
    }

    /// Centres `size` on the anchor, then slides it back inside the bounds.
    static func panelFrame(size: CGSize, anchor: Anchor) -> CGRect {
        let bounds = anchor.bounds
        let x = min(max(anchor.center.x - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(anchor.center.y - size.height / 2, bounds.minY), bounds.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

//// A panel taller than the screen keeps its top edge visible (the clamp to maxY wins).
//////////////////
