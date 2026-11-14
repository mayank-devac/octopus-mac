import AppKit
import SwiftUI

// Dock style backgrounds. Sizes and timing come from SidebarDockReveal; SidebarView places these
// behind its icon column (vertical sidebar) or its notch bar (Mac Notch).

// Vertical Dock: one frosted panel attached to the screen edge; only its inner corners are rounded.
// It grows out of the edge from a thin, vertically centred sliver.
struct SidebarDockBar: View {
    let side: SidebarSide
    let width: CGFloat
    let isOpen: Bool
    // Compact mode keeps the closed bar visible as a full-height edge pill.
    let isStrip: Bool
    let isDark: Bool
    // User's Dock opacity; fades the glass and its drop shadow together.
    let opacity: Double

    var body: some View {
        let isRight = side == .right
        let radius = SidebarLayout.dockCornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isRight ? radius : 0, bottomLeadingRadius: isRight ? radius : 0,
            bottomTrailingRadius: isRight ? 0 : radius, topTrailingRadius: isRight ? 0 : radius,
            style: .continuous)
        GeometryReader { proxy in
            let size = SidebarDockReveal.barSize(full: CGSize(width: width, height: proxy.size.height),
                                                 isOpen: isOpen, strip: isStrip)
            SidebarDockGlass()
                .clipShape(shape)
                .background { shape.fill(Color.black.opacity(isDark ? 0.4 : 0.14)).blur(radius: 6).offset(y: 2) }
                .opacity(opacity)
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRight ? .trailing : .leading)
        }
        .allowsHitTesting(false)
    }
}

// Mac Notch + Dock: the bar hangs from the top edge and grows down and out of the notch.
struct SidebarNotchDockBar: View {
    let isOpen: Bool
    let notchSize: CGSize

    var body: some View {
        let radius = SidebarLayout.dockCornerRadius
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                           style: .continuous)
        let flare = SidebarDockReveal.notchFlareRadius
        GeometryReader { proxy in
            let size = SidebarDockReveal.notchBarSize(full: proxy.size, isOpen: isOpen, notch: notchSize)
            // Solid notch black, so the bar reads as the notch itself widening.
            shape.fill(Color.black)
                .overlay(alignment: .topLeading) {
                    SidebarNotchFlare(mirrored: true).fill(Color.black)
                        .frame(width: flare, height: flare).offset(x: -flare)
                        .opacity(isOpen ? 1 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    SidebarNotchFlare().fill(Color.black)
                        .frame(width: flare, height: flare).offset(x: flare)
                        .opacity(isOpen ? 1 : 0)
                }
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }
}

// Concave corner that joins the bar's side edge to the screen top. The right flare curves from
// its top-right back to the bar edge at its bottom-left; `mirrored` gives the left one.
struct SidebarNotchFlare: Shape {
    var mirrored = false

    func path(in rect: CGRect) -> Path {
        let x: (CGFloat) -> CGFloat = { mirrored ? rect.maxX - $0 : rect.minX + $0 }
        return Path { path in
            path.move(to: CGPoint(x: x(0), y: rect.minY))
            path.addLine(to: CGPoint(x: x(rect.width), y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: x(0), y: rect.maxY), control: CGPoint(x: x(0), y: rect.minY))
            path.closeSubpath()
        }
    }
}

// Behind-window blur so the dock reads as frosted glass over the desktop, like the sidebar.
struct SidebarDockGlass: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        let material: NSVisualEffectView.Material = colorScheme == .dark ? .hudWindow : .popover
        if nsView.material != material { nsView.material = material }
    }
}
