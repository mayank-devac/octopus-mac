import SwiftUI

////////////////////
//// Sidebar app menu card
/// Header (icon, name, window count), then sections separated by hairlines.
/// Row sections are full-width items; chip sections are a row of square buttons.
/// One highlight pill glides between items as the pointer or arrow keys move,
// and the chosen item blinks before the menu fades out.

struct SidebarAppMenuView: View {
    @ObservedObject var state: SidebarAppMenuState
    let anchors: MenuAnchorRegistry<SidebarAppMenuCommand>
    let onSelect: (SidebarAppMenuCommand) -> Void
    @Namespace private var highlightSpace
    private typealias Metrics = SidebarAppMenuMetrics

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(state.sections) { section in
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 0.5)
                    .padding(.horizontal, 6)
                    .frame(height: Metrics.dividerHeight)
                sectionView(section)
                    .frame(height: SidebarAppMenuLayout.sectionHeight(section))
            }
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .menuCard(cornerRadius: Metrics.cornerRadius)
        .modifier(MenuAppearModifier(presentationID: state.presentationID, edge: state.appearEdge))
        .padding(MenuShadowMargin.insets(facing: state.appearEdge))
        .animation(MenuMotion.highlight, value: state.focus)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SidebarAppMenuStrings.accessibilityLabel)
    }

    ////////////////////
    //// Header

    private var header: some View {
        HStack(spacing: 10) {
            WindowMenuAppIcon(pid: state.pid, bundleURL: state.bundleURL, size: Metrics.headerIconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.context?.title ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: Metrics.headerHeight)
    }

    private var subtitle: String {
        guard let context = state.context else { return "" }
        return context.isRunning ? SidebarAppMenuStrings.windowCount(context.windows.count) : SidebarAppMenuStrings.notRunning
    }

    //////////////////

    ////////////////////
    //// Sections

    @ViewBuilder
    private func sectionView(_ section: SidebarAppMenuSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .frame(height: Metrics.sectionTitleHeight, alignment: .bottomLeading)
            }
            switch section.layout {
            case .rows:
                ForEach(section.items) { row($0) }
            case .chips:
                HStack(spacing: Metrics.chipSpacing) {
                    ForEach(section.items) { chip($0) }
                }
                .padding(.horizontal, 6)
                .frame(height: Metrics.chipRowHeight)
            }
        }
    }

    private func row(_ item: SidebarAppMenuItem) -> some View {
        let isFocused = state.focus == item.command
        let isFlashing = state.flashing == item.command
        let tint = item.isDestructive ? MenuPalette.destructive : Color.accentColor
        return Button { onSelect(item.command) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isFocused ? Color.white : item.isDestructive ? MenuPalette.destructive : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: Metrics.rowHeight)
            .background { highlight(isFocused: isFocused, isFlashing: isFlashing, tint: tint, cornerRadius: Metrics.rowCornerRadius) }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle(pressedScale: 0.98))
        .focusEffectDisabled()
        .background(SidebarGeometryAnchor(id: item.command) { anchors.apply($1, for: $0) })
        .help(item.title)
        .accessibilityLabel(item.title)
    }

    private func chip(_ item: SidebarAppMenuItem) -> some View {
        let isFocused = state.focus == item.command
        let isFlashing = state.flashing == item.command
        return Button { onSelect(item.command) } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? Color.white : Color.primary)
                .frame(width: Metrics.chipSize, height: Metrics.chipSize)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous).fill(MenuPalette.hoverFill)
                        highlight(isFocused: isFocused, isFlashing: isFlashing, tint: .accentColor, cornerRadius: Metrics.rowCornerRadius)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .focusEffectDisabled()
        .background(SidebarGeometryAnchor(id: item.command) { anchors.apply($1, for: $0) })
        .help(item.title)
        .accessibilityLabel(item.title)
    }

    @ViewBuilder
    private func highlight(isFocused: Bool, isFlashing: Bool, tint: Color, cornerRadius: CGFloat) -> some View {
        if isFocused || isFlashing {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(isFlashing ? 0.6 : 0.9))
                .matchedGeometryEffect(id: "highlight", in: highlightSpace)
        }
    }

    //// Chips keep a faint tile so they read as buttons before hover.
    //////////////////
}

//////////////////
