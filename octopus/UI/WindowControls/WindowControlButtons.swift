import SwiftUI

////////////////////
//// Close / minimise / zoom traffic lights for a window row
/// Mirrors a title bar: red closes, yellow minimises (or restores a minimised
/// window), green zooms. Glyphs appear while the pointer is over the group,
/// as they do in a real title bar.
/// Each button reports its frame through `anchor`, so menus that track the
// pointer themselves (MenuAnchorRegistry) can hit-test it.

enum WindowControl: CaseIterable, Hashable {
    case close, minimize, zoom

    var color: Color {
        switch self {
        case .close: return MenuPalette.badgeClose
        case .minimize: return MenuPalette.windowMinimize
        case .zoom: return MenuPalette.windowZoom
        }
    }

    // A minimised window's yellow button restores it, so it shows the restore glyph.
    func symbol(isMinimized: Bool) -> String {
        switch self {
        case .close: return "xmark"
        case .minimize: return isMinimized ? "plus" : "minus"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        }
    }

    func title(windowTitle: String, isMinimized: Bool) -> String {
        switch self {
        case .close: return WindowControlStrings.close(windowTitle)
        case .minimize: return isMinimized ? WindowControlStrings.restore(windowTitle) : WindowControlStrings.minimize(windowTitle)
        case .zoom: return WindowControlStrings.zoom(windowTitle)
        }
    }
}

struct WindowControlButtons<Anchor: View>: View {
    let windowTitle: String
    let isMinimized: Bool
    /// True while the pointer is over any of the buttons; reveals the glyphs.
    let showsGlyphs: Bool
    let isEnabled: (WindowControl) -> Bool
    let onSelect: (WindowControl) -> Void
    @ViewBuilder let anchor: (WindowControl) -> Anchor
    private typealias Metrics = WindowControlMetrics

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            ForEach(WindowControl.allCases, id: \.self) { control in
                button(control)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
    }

    private func button(_ control: WindowControl) -> some View {
        let enabled = isEnabled(control)
        let title = control.title(windowTitle: windowTitle, isMinimized: isMinimized)
        return Button { if enabled { onSelect(control) } } label: {
            Circle()
                .fill(enabled ? control.color : MenuPalette.windowControlDisabled)
                .overlay(Circle().strokeBorder(MenuPalette.windowControlStroke, lineWidth: 0.5))
                .overlay {
                    Image(systemName: control.symbol(isMinimized: isMinimized))
                        .font(.system(size: Metrics.symbolSize, weight: .bold))
                        .foregroundStyle(MenuPalette.badgeSymbol)
                        .opacity(showsGlyphs && enabled ? 1 : 0)
                }
                .frame(width: Metrics.diameter, height: Metrics.diameter)
                // A taller hit area than the dot, so the row height stays easy to hit.
                .frame(height: WindowMenuMetrics.windowRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .focusEffectDisabled()
        .allowsHitTesting(enabled)
        .background(anchor(control))
        .help(title)
        .accessibilityLabel(title)
    }
}

//// Disabled buttons stay visible but grey, like a title bar without that control.
//////////////////
