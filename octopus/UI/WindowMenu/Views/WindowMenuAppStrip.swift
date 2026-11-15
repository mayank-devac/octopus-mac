import SwiftUI

////////////////////
//// Horizontal strip of app cells
/// Workspace kind: the selected workspace's apps. Running apps get a ring, the
/// highlighted app gets a soft tile that glides between cells, and a chevron
/// pages through apps that do not fit.
// Recent kind: recently quit apps (centre menu), inside a tinted tray.

struct WindowMenuAppStrip: View {
    enum Kind { case workspace, recent }

    let kind: Kind
    @ObservedObject var state: WindowMenuState
    let presenter: WindowMenuPresenter
    @Namespace private var highlightSpace
    private typealias Metrics = WindowMenuMetrics

    private var apps: [WindowMenuApp] { kind == .recent ? state.content.recentApps : state.content.apps }

    private var overflows: Bool {
        kind == .workspace && apps.count > WindowMenuLayout.stripCapacity(
            isCenter: state.isCenter, workspaceCount: state.content.workspaces.count, reservingChevron: false)
    }

    /// With the sidebar on the right, apps sit against the trailing edge so they are a short reach from it.
    private var alignsTrailing: Bool { kind == .workspace && state.appearEdge == .trailing }

    private var contentAlignment: Alignment { alignsTrailing ? .trailing : .leading }

    /// Filling the strip lets a short app list be pushed to the trailing edge; overflowing lists still scroll.
    private var minimumContentWidth: CGFloat? {
        guard alignsTrailing else { return nil }
        return WindowMenuLayout.stripWidth(content: state.content, isCenter: state.isCenter, reservingChevron: overflows)
    }

    var body: some View {
        HStack(spacing: 0) {
            if apps.isEmpty {
                Text(kind == .recent ? WindowMenuStrings.recentEmpty : WindowMenuStrings.noWindows)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Metrics.appCellSpacing) {
                            ForEach(apps) { app in
                                cell(app).id(target(for: app))
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(minWidth: minimumContentWidth, maxHeight: .infinity, alignment: contentAlignment)
                    }
                    .onChange(of: state.scrollRequest) { _, request in
                        guard let request, apps.contains(where: { target(for: $0) == request.target }) else { return }
                        withAnimation(MenuMotion.highlight) { proxy.scrollTo(request.target, anchor: request.anchor) }
                    }
                }
            }
            if overflows { moreButton }
        }
        .padding(.horizontal, kind == .recent ? 6 : 0)
        .background {
            if kind == .recent {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MenuPalette.stripFill)
            }
        }
    }

    ////////////////////
    //// Cells

    private func target(for app: WindowMenuApp) -> WindowMenuTarget {
        kind == .recent ? .recent(app.id) : .app(app.id)
    }

    private func cell(_ app: WindowMenuApp) -> some View {
        let target = target(for: app)
        let isFocused = state.focus == target
        let isHighlighted = isFocused || (kind == .workspace && state.highlightedAppID == app.id)
        let tile = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { presenter.activate(target) } label: {
            ZStack {
                if isHighlighted {
                    tile.fill(isFocused ? MenuPalette.focusFill : MenuPalette.groupFill)
                        .matchedGeometryEffect(id: "highlight", in: highlightSpace)
                }
                WindowMenuAppIcon(pid: app.pid, bundleURL: app.bundleURL, size: Metrics.appIconSize)
                    .opacity(app.isRunning || kind == .recent ? 1 : MenuPalette.inactiveAppOpacity)
                    // The running ring hugs the icon's whole frame and scales with it.
                    .overlay {
                        if kind == .workspace && app.isRunning {
                            RoundedRectangle(cornerRadius: Metrics.appIconSize * Metrics.runningRingCornerRatio,
                                             style: .continuous)
                                .strokeBorder(MenuPalette.runningRing.opacity(0.75), lineWidth: Metrics.runningRingWidth)
                        }
                    }
                    .scaleEffect(isHighlighted ? Metrics.highlightedAppScale : 1)
            }
            .frame(width: Metrics.appCellSize, height: Metrics.appCellSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .focusEffectDisabled()
        .background(SidebarGeometryAnchor(id: target) { presenter.anchors.apply($1, for: $0) })
        .animation(MenuMotion.highlight, value: isHighlighted)
        .animation(MenuMotion.highlight, value: isFocused)
        .help(app.title)
        .accessibilityLabel(app.isRunning ? WindowMenuStrings.runningApp(app.title) : WindowMenuStrings.openApp(app.title))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var moreButton: some View {
        let isHovered = state.hovered == .moreApps
        return Button { presenter.activate(.moreApps) } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: Metrics.stripChevronWidth, height: Metrics.appCellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .focusEffectDisabled()
        .background(SidebarGeometryAnchor(id: WindowMenuTarget.moreApps) { presenter.anchors.apply($1, for: $0) })
        .help(WindowMenuStrings.moreApps)
        .accessibilityLabel(WindowMenuStrings.moreApps)
    }

    //// The tile uses one geometry ID per strip, so it slides rather than fades.
    //////////////////
}

//////////////////
