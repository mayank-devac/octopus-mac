import AppKit
import QuartzCore

// A thin glow on the screen edge that shows where an auto-hidden sidebar will appear.
// Geometry and state are pure so the controller only applies them.
enum SidebarEdgeMark {
    enum Emphasis: Equatable { case hidden, idle, near }

    /// Panel width: the line plus room for its glow toward the screen interior.
    static let panelWidth: CGFloat = 10
    static let edgeInset: CGFloat = 1
    static let idleLineWidth: CGFloat = 4
    static let nearLineWidth: CGFloat = 5
    static let idleOpacity: CGFloat = 0.38
    static let nearOpacity: CGFloat = 0.75
    /// How far from the edge the pointer brightens the mark.
    static let nearDistance: CGFloat = 40
    static let fadeDuration: TimeInterval = 0.25
    /// How long the sidebar stays open after its side changes, unless the pointer takes over.
    static let sideChangePeekDuration: TimeInterval = 2.5

    static func frame(edgeTrigger: CGRect, side: SidebarSide) -> CGRect {
        guard !edgeTrigger.isEmpty else { return .zero }
        let x = side == .left ? edgeTrigger.minX : edgeTrigger.maxX - panelWidth
        return CGRect(x: x, y: edgeTrigger.minY, width: panelWidth, height: edgeTrigger.height)
    }

    static func emphasis(available: Bool, sidebarShown: Bool, pointer: CGPoint,
                         edgeTrigger: CGRect, side: SidebarSide) -> Emphasis {
        guard available, !sidebarShown, !edgeTrigger.isEmpty else { return .hidden }
        let distance = side == .left ? pointer.x - edgeTrigger.minX : edgeTrigger.maxX - pointer.x
        let inBand = pointer.y >= edgeTrigger.minY && pointer.y <= edgeTrigger.maxY
        return inBand && distance >= 0 && distance <= nearDistance ? .near : .idle
    }

    ////////////////////
    //// Custom color
    /// The chosen color is stored as "#RRGGBB" so profiles and preferences stay plain text.
    // Anything unreadable falls back to the automatic macOS accent color.

    static func color(hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    // Palette and crayon picks are catalog colors, which cannot convert to sRGB until resolved to components.
    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingType(.componentBased)?.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    //// Both directions round-trip, so reopening the picker shows the saved color.
    //////////////////

    static func opacity(_ emphasis: Emphasis) -> CGFloat {
        switch emphasis {
        case .hidden: return 0
        case .idle: return idleOpacity
        case .near: return nearOpacity
        }
    }
}

// Owns the mark's panel and fade state. The display controller reports the sidebar's current
// state on each update; this decides the emphasis and applies it.
@MainActor
final class SidebarEdgeMarkController {
    private let panel: NSPanel
    private let view = SidebarEdgeMarkView()
    private var emphasis = SidebarEdgeMark.Emphasis.hidden
    private var side = SidebarSide.right
    private var fadeGeneration = 0

    // The mark is visual only; the sidebar's edge trigger keeps handling the pointer.
    init(panel: NSPanel) {
        self.panel = panel
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.alphaValue = 0
        panel.contentView = view
    }

    func update(available: Bool, sidebarShown: Bool, edgeTrigger: CGRect, side nextSide: SidebarSide,
                color: NSColor? = nil) {
        view.customColor = color
        let next = SidebarEdgeMark.emphasis(available: available, sidebarShown: sidebarShown,
            pointer: NSEvent.mouseLocation, edgeTrigger: edgeTrigger, side: nextSide)
        let frame = SidebarEdgeMark.frame(edgeTrigger: edgeTrigger, side: nextSide)
        let unchanged = next == emphasis && side == nextSide && (next == .hidden || panel.frame == frame)
        guard !unchanged else { return }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A move to another edge or position jumps there; only brightness changes animate.
        let moved = side != nextSide || panel.frame != frame
        emphasis = next
        side = nextSide
        if next == .hidden {
            fade(to: 0, animated: animate)
            return
        }
        if moved {
            panel.setFrame(frame, display: false)
            view.needsLayout = true
        }
        view.apply(side: nextSide, emphasis: next, animated: animate && !moved)
        if !panel.isVisible { panel.orderFrontRegardless() }
        fade(to: SidebarEdgeMark.opacity(next), animated: animate)
    }

    func hide() {
        fadeGeneration += 1
        emphasis = .hidden
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    func close() {
        panel.contentView = nil
        panel.close()
    }

    private func fade(to alpha: CGFloat, animated: Bool) {
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? SidebarEdgeMark.fadeDuration : 0
            panel.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread, but the handler type is Sendable.
            MainActor.assumeIsolated {
                // Only the latest fade may remove the panel; an older one must not cut a newer fade short.
                guard let self, generation == self.fadeGeneration, self.emphasis == .hidden else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}

// Draws the line with faded ends and a soft glow. It never takes pointer input.
final class SidebarEdgeMarkView: NSView {
    private let line = CAGradientLayer()
    private var side: SidebarSide = .right
    private var lineWidth = SidebarEdgeMark.idleLineWidth
    // The user's chosen color; nil follows the system appearance.
    var customColor: NSColor? {
        didSet { if customColor != oldValue { applyAppearanceColors() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        line.locations = [0, 0.14, 0.5, 0.86, 1]
        line.startPoint = CGPoint(x: 0.5, y: 0)
        line.endPoint = CGPoint(x: 0.5, y: 1)
        line.cornerRadius = 1
        line.shadowOffset = .zero
        line.shadowOpacity = 0.6
        line.shadowRadius = 3
        applyAppearanceColors()
        layer?.addSublayer(line)
        // Changing the accent in System Settings does not change the appearance, so listen for it directly.
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsDidChange),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    //////////////////// Appearance colors
    /// A chosen color wins; otherwise the mark uses the macOS accent (theme) color.
    // Colors are rebuilt whenever the appearance, the accent color or the chosen color changes.
    // The accent is dynamic, so its cgColor is resolved under this view's appearance.
    private func applyAppearanceColors() {
        let base = customColor ?? NSColor.controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            line.colors = [base.withAlphaComponent(0), base.withAlphaComponent(0.9), base,
                           base.withAlphaComponent(0.9), base.withAlphaComponent(0)].map(\.cgColor)
            line.shadowColor = base.cgColor
            CATransaction.commit()
        }
    }

    @objc private func systemColorsDidChange() {
        applyAppearanceColors()
    }
    //// Panel appearance follows the system, so no manual override is needed.
    //////////////////

    func apply(side: SidebarSide, emphasis: SidebarEdgeMark.Emphasis, animated: Bool) {
        self.side = side
        lineWidth = emphasis == .near ? SidebarEdgeMark.nearLineWidth : SidebarEdgeMark.idleLineWidth
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(SidebarEdgeMark.fadeDuration)
        line.shadowRadius = emphasis == .near ? 5 : 3
        layoutLine()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLine()
        CATransaction.commit()
    }

    private func layoutLine() {
        let x = side == .left ? SidebarEdgeMark.edgeInset : bounds.width - SidebarEdgeMark.edgeInset - lineWidth
        line.frame = CGRect(x: x, y: 0, width: lineWidth, height: bounds.height)
    }
}
