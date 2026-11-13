import AppKit
import QuartzCore

// A thin glow on the screen edge that shows where an auto-hidden sidebar will appear.
// Geometry and state are pure so the controller only applies them.
enum SidebarEdgeMark {
    enum Emphasis: Equatable { case hidden, idle, near }

    /// Panel width: the line plus room for its glow toward the screen interior.
    static let panelWidth: CGFloat = 8
    static let edgeInset: CGFloat = 1
    static let idleLineWidth: CGFloat = 2
    static let nearLineWidth: CGFloat = 3
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

    static func opacity(_ emphasis: Emphasis) -> CGFloat {
        switch emphasis {
        case .hidden: return 0
        case .idle: return idleOpacity
        case .near: return nearOpacity
        }
    }
}

// Draws the line with faded ends and a soft blue glow. It never takes pointer input.
final class SidebarEdgeMarkView: NSView {
    private let line = CAGradientLayer()
    private var side: SidebarSide = .right
    private var lineWidth = SidebarEdgeMark.idleLineWidth

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        let core = NSColor(srgbRed: 0.92, green: 0.95, blue: 1, alpha: 1).cgColor
        let soft = NSColor(srgbRed: 0.80, green: 0.86, blue: 1, alpha: 0.9).cgColor
        let clear = NSColor(srgbRed: 0.80, green: 0.86, blue: 1, alpha: 0).cgColor
        line.colors = [clear, soft, core, soft, clear]
        line.locations = [0, 0.14, 0.5, 0.86, 1]
        line.startPoint = CGPoint(x: 0.5, y: 0)
        line.endPoint = CGPoint(x: 0.5, y: 1)
        line.cornerRadius = 1
        line.shadowColor = NSColor(srgbRed: 0.59, green: 0.70, blue: 1, alpha: 1).cgColor
        line.shadowOffset = .zero
        line.shadowOpacity = 0.6
        line.shadowRadius = 3
        layer?.addSublayer(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
