import SwiftUI

////////////////////
//// Window list: every window of the workspace apps, grouped by app
/// Rows of the highlighted app share a soft tint; the focused row has a stronger
/// pill that glides between rows. A close button appears on the focused row.
/// Rows reuse SidebarPointerRegion so click and drag behave like the classic menu.
// A chevron pages through windows that do not fit.

struct WindowMenuWindowList: View {
    @ObservedObject var state: WindowMenuState
    let presenter: WindowMenuPresenter
    @Namespace private var focusSpace
    private typealias Metrics = WindowMenuMetrics

    private var windows: [WindowMenuWindow] { state.content.windows }

    var body: some View {
        if let message = placeholderMessage {
            placeholder(message)
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                                row(window, showsDivider: index < windows.count - 1)
                                    .id(WindowMenuTarget.window(window.id))
                            }
                        }
                    }
                    .onChange(of: state.scrollRequest) { _, request in
                        guard let request, case .window = request.target else { return }
                        withAnimation(MenuMotion.highlight) { proxy.scrollTo(request.target, anchor: request.anchor) }
                    }
                }
                if WindowMenuLayout.hasMoreWindows(windows.count, isCenter: state.isCenter) { moreButton }
            }
        }
    }

    ////////////////////
    //// Rows

    private func row(_ window: WindowMenuWindow, showsDivider: Bool) -> some View {
        let target = WindowMenuTarget.window(window.id)
        let isFocused = state.focus == target
        let isGrouped = state.highlightedAppID == window.appID
        let app = state.content.apps.first { $0.id == window.appID }
        let pill = RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
        return HStack(spacing: 8) {
            WindowMenuAppIcon(pid: app?.pid, bundleURL: app?.bundleURL, size: Metrics.windowIconSize)
            Text(window.title)
                .font(.system(size: 13, weight: isFocused ? .medium : .regular))
                .foregroundStyle(window.isMinimized ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if window.isMinimized {
                Image(systemName: "minus.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(WindowMenuStrings.minimised)
            }
            if let label = window.desktopLabel {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(MenuPalette.hoverFill))
            }
            // Room for the close button overlay, so titles never run under it.
            Color.clear.frame(width: Metrics.windowCloseWidth)
        }
        .padding(.leading, 8)
        .frame(height: Metrics.windowRowHeight)
        .background {
            ZStack {
                if isGrouped { pill.fill(MenuPalette.groupFill) }
                if isFocused { pill.fill(MenuPalette.focusFill).matchedGeometryEffect(id: "focus", in: focusSpace) }
            }
        }
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(height: 0.5)
                    .padding(.horizontal, 8).allowsHitTesting(false)
            }
        }
        .overlay {
            SidebarPointerRegion(onClick: { presenter.activate(target) }, onAnchor: { _ in },
                                 onDrag: presenter.onDragWindow.map { drag in
                                     { source, event in drag(window.id, window.title, source, event) }
                                 })
        }
        .overlay(alignment: .trailing) { closeButton(window, isVisible: isFocused) }
        .background(SidebarGeometryAnchor(id: target) { presenter.anchors.apply($1, for: $0) })
        .animation(MenuMotion.highlight, value: isFocused)
        .animation(MenuMotion.highlight, value: isGrouped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WindowMenuStrings.focusWindow(window.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { presenter.activate(target) }
        .accessibilityActions {
            if window.canClose {
                Button(WindowMenuStrings.closeWindow(window.title)) { presenter.activate(.closeWindow(window.id)) }
            }
        }
    }

    private func closeButton(_ window: WindowMenuWindow, isVisible: Bool) -> some View {
        let target = WindowMenuTarget.closeWindow(window.id)
        let isHovered = state.hovered == target
        let shows = isVisible && window.canClose
        return Button { presenter.activate(target) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isHovered ? Color.white : Color.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(isHovered ? MenuPalette.badgeClose : MenuPalette.hoverFill))
                .frame(width: Metrics.windowCloseWidth, height: Metrics.windowRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .focusEffectDisabled()
        .opacity(shows ? 1 : 0)
        .allowsHitTesting(shows)
        .background(SidebarGeometryAnchor(id: target) { presenter.anchors.apply($1, for: $0) })
        .help(WindowMenuStrings.closeWindow(window.title))
    }

    //// Hovering the close area focuses its row first, so the button never appears under a still pointer by surprise.
    //////////////////

    private var moreButton: some View {
        let isHovered = state.hovered == .moreWindows
        return Button { presenter.activate(.moreWindows) } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.footerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .focusEffectDisabled()
        .background(SidebarGeometryAnchor(id: WindowMenuTarget.moreWindows) { presenter.anchors.apply($1, for: $0) })
        .help(WindowMenuStrings.moreWindows)
        .accessibilityLabel(WindowMenuStrings.moreWindows)
    }

    ////////////////////
    //// Empty and unavailable states

    private var placeholderMessage: String? {
        switch state.status {
        case .loading: return WindowMenuStrings.loading
        case .needsPermission: return WindowMenuStrings.needsPermission
        case .ready: return windows.isEmpty ? WindowMenuStrings.noWindows : nil
        }
    }

    private func placeholder(_ message: String) -> some View {
        VStack(spacing: 4) {
            Text(message).font(.callout).foregroundStyle(.secondary)
            if state.status == .needsPermission {
                Button(WindowMenuStrings.allowAccess) { AccessibilityPermissionGuide.shared.open() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    //////////////////
}

//////////////////
