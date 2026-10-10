import AppKit
import SwiftUI

@MainActor
final class SidebarDesktopMenu {
    private let state = DesktopMenuState()
    private let panel = CyclePanel(contentRect: .zero)
    private var anchors: [UInt64: NSView] = [:]
    private var anchor = CGRect.zero
    private var lastScroll: TimeInterval = 0

    var frame: CGRect? { panel.isVisible ? panel.frame : nil }
    var interactionFrames: [CGRect] { frame.map { SidebarDesktopMenuGeometry.interactionFrames(menu: $0, anchor: anchor) } ?? [] }
    func contains(_ point: CGPoint) -> Bool { interactionFrames.contains { $0.contains(point) } }

    init() {
        panel.level = SidebarWindowLevels.menu
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true // The drag controller's native receiver owns input.
        let host = NSHostingView(rootView: DesktopMenuView(state: state, onAnchor: { [weak self] id, view in
            self?.anchors[id] = view
        }))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                host.topAnchor.constraint(equalTo: content.topAnchor),
                host.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
    }

    func show(desktops: [SidebarDesktop], sourceID: UInt64, anchor: CGRect,
              side: SidebarSide, screen: CGRect) {
        let desktops = desktops.filter { $0.number != nil }.sorted { $0.order < $1.order }
        guard !desktops.isEmpty else { hide(); return }
        if state.desktops != desktops { state.desktops = desktops }
        if state.sourceID != sourceID { state.sourceID = sourceID }
        self.anchor = anchor
        let height = CGFloat(desktops.count) * SidebarLayout.menuRowHeight
            + CGFloat(max(0, desktops.count - 1)) + SidebarLayout.menuPadding * 2
        let next = SidebarLayout.menuFrame(size: CGSize(width: 280, height: min(520, height)),
            icon: anchor, screen: screen, side: side)
        if panel.frame != next { panel.setFrame(next, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
        if state.selectedID != nil { state.selectedID = nil }
    }

    func target(at point: CGPoint) -> SidebarDesktopDropTarget? {
        guard let frame, frame.contains(point) else {
            if state.selectedID != nil { state.selectedID = nil }
            return nil
        }
        let target = state.desktops.compactMap { desktop -> SidebarDesktopDropTarget? in
            guard desktop.id != state.sourceID, let view = anchors[desktop.id],
                  let row = SidebarDesktopDropTarget.visibleFrame(of: view, within: frame),
                  row.contains(point) else { return nil }
            return SidebarDesktopDropTarget(desktop: desktop, frame: row)
        }.first
        if state.selectedID != target?.desktop.id { state.selectedID = target?.desktop.id }
        return target
    }

    func scroll(at point: CGPoint) {
        guard let frame, frame.contains(point), ProcessInfo.processInfo.systemUptime - lastScroll >= 0.06,
              let scroll = anchors.values.compactMap({ $0.enclosingScrollView }).first,
              let document = scroll.documentView else { return }
        let direction: CGFloat
        if point.y > frame.maxY - 18 { direction = document.isFlipped ? -1 : 1 }
        else if point.y < frame.minY + 18 { direction = document.isFlipped ? 1 : -1 }
        else { return }
        lastScroll = ProcessInfo.processInfo.systemUptime
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y += direction * 10
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

enum SidebarDesktopMenuGeometry {
    static func interactionFrames(menu: CGRect, anchor: CGRect) -> [CGRect] {
        // Preserve the short route from the heading into its popup, without
        // treating every app beside a tall popup as part of the popup.
        let bottom = max(menu.minY, anchor.minY)
        let top = min(menu.maxY, anchor.maxY)
        let bridge = CGRect(x: min(menu.minX, anchor.minX), y: bottom,
            width: max(menu.maxX, anchor.maxX) - min(menu.minX, anchor.minX), height: max(0, top - bottom))
        return [menu, anchor, bridge].filter { !$0.isEmpty }.map { $0.insetBy(dx: -3, dy: -3) }
    }
}

@MainActor private final class DesktopMenuState: ObservableObject {
    @Published var desktops: [SidebarDesktop] = []
    @Published var sourceID: UInt64?
    @Published var selectedID: UInt64?
}

private struct DesktopMenuView: View {
    @ObservedObject var state: DesktopMenuState
    let onAnchor: (UInt64, NSView?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(state.desktops.enumerated()), id: \.element.id) { index, desktop in
                    CyclePanelRow(title: desktop.title, isSelected: state.selectedID == desktop.id, isCompact: true)
                        .opacity(desktop.id == state.sourceID ? 0.45 : 1)
                        .background(CyclePanelRowAnchor(onAnchor: { onAnchor(desktop.id, $0) }))
                    if index < state.desktops.count - 1 {
                        Divider().frame(height: 1).padding(.horizontal, 6)
                    }
                }
            }
            .padding(SidebarLayout.menuPadding)
        }
        .background(Color.clear)
    }
}
