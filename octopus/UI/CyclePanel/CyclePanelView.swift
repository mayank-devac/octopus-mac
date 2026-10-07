//
//  CyclePanelView.swift
//  octopus
//
//  Window switcher panel UI
//

import AppKit
import SwiftUI

struct CyclePanelView: View {
    @ObservedObject var state: CyclePanelState
    var onActivate: (CyclePanelItem.ID) -> Void = { _ in }
    var onAnchor: (CyclePanelItem.ID, NSView?) -> Void = { _, _ in }
    var onWindowAction: (CyclePanelItem.ID) -> Void = { _ in }
    var onToggleAppVisibility: () -> Void = {}
    var onHideAnchor: (NSView?) -> Void = { _ in }
    var onQuitApp: () -> Void = {}
    var onQuitAnchor: (NSView?) -> Void = { _ in }
    var onDrag: (SidebarWindowID, String, NSView, NSEvent) -> Void = { _, _, _, _ in }
    var onPlacement: (CyclePanelItem.ID, SidebarSnapTarget) -> Void = { _, _ in }

    private let headerPadding: Double = 12
    
    var body: some View {
        VStack(spacing: 0) {
            if state.showsHeader {
                Text(state.applicationTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.vertical, headerPadding)

                Divider()
            }
            
            // Always allow scrolling, including on small displays where five rows may not fit.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: state.showsHeader ? 4 : 0) {
                        ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                            .background(CyclePanelRowAnchor(
                                onAnchor: { onAnchor(item.id, $0) }
                            ))
                            .id(item.id)
                            .transaction { transaction in
                                // Pointer selection should paint immediately, without an inherited animation.
                                if !state.showsHeader { transaction.animation = nil }
                            }

                            if !state.showsHeader, index < state.items.count - 1 {
                                Divider()
                                    .frame(height: 1)
                                    .padding(.horizontal, 6)
                            }
                        }
                    }
                    .padding(state.showsHeader ? 8 : SidebarLayout.menuPadding)
                }
                .onAppear {
                    if let id = state.currentItem?.id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: state.selectedIndex) {
                    guard state.shouldScrollToSelection, let id = state.currentItem?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            if state.showsSidebarActions {
                Divider()
                HStack(spacing: 0) {
                    Button(action: onToggleAppVisibility) {
                        Text(state.sidebarAppVisibilityTitle)
                            .frame(maxWidth: .infinity)
                            .frame(height: SidebarLayout.menuActionHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarActionButtonStyle(isHovered: state.sidebarPointerTarget == .hideApp))
                    .focusEffectDisabled()
                    .help(state.sidebarAppIsHidden ? "Show \(state.applicationTitle) and focus the selected window"
                          : "Hide all windows of \(state.applicationTitle)")
                    .accessibilityLabel("\(state.sidebarAppIsHidden ? "Show" : "Hide") \(state.applicationTitle)")
                    .background(CyclePanelRowAnchor(onAnchor: onHideAnchor))

                    Divider().frame(height: SidebarLayout.menuActionHeight - 12)

                    Button(action: onQuitApp) {
                        Text("Quit")
                            .frame(maxWidth: .infinity)
                            .frame(height: SidebarLayout.menuActionHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarActionButtonStyle(isHovered: state.sidebarPointerTarget == .quitApp))
                    .focusEffectDisabled()
                    .help("Quit \(state.applicationTitle)")
                    .accessibilityLabel("Quit \(state.applicationTitle)")
                    .background(CyclePanelRowAnchor(onAnchor: onQuitAnchor))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }

    @ViewBuilder private func row(_ item: CyclePanelItem, index: Int) -> some View {
        if state.showsSidebarActions, case .window(let window) = item {
            let prefix = window.cgWindowID.flatMap { state.sidebarWindowStates[$0]?.desktopLabel } ?? ""
            let title = prefix + item.title
            let dragTarget = window.application.pid.flatMap { pid in
                window.cgWindowID.map { SidebarWindowID(pid: pid, windowID: $0) }
            }
            HStack(spacing: 0) {
                // Track press/drag on the title only; keep the action button independent.
                CyclePanelRow(title: title, isSelected: index == state.selectedIndex,
                              isCompact: true, showsSelectionBackground: false)
                .overlay {
                    SidebarPointerRegion(onClick: { onActivate(item.id) }, onAnchor: { _ in },
                                         onDrag: { source, event in
                        if let dragTarget { onDrag(dragTarget, item.title, source, event) }
                    })
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onActivate(item.id) }
                .accessibilityLabel("Focus \(title)")
                .accessibilityValue(index == state.selectedIndex ? "Selected" : "")
                .accessibilityActions {
                    ForEach(SidebarSnapTarget.allCases, id: \.self) { target in
                        Button(target.title) { onPlacement(item.id, target) }
                    }
                }
                if let id = window.cgWindowID, let status = state.sidebarWindowStates[id] {
                    let restore = state.sidebarAppIsHidden || status.isMinimized
                    let focus = !restore && !status.isOnScreen
                    let enabled = status.canMinimize || focus || (state.sidebarAppIsHidden && !status.isMinimized)
                    let actionTitle = restore ? "Restore" : focus ? "Focus" : "Minimise"
                    Button { onWindowAction(item.id) } label: {
                        Image(systemName: restore || focus ? "arrow.up.right.square" : "minus")
                            .frame(width: SidebarLayout.menuWindowActionWidth, height: SidebarLayout.menuRowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarActionButtonStyle(isHovered: state.sidebarPointerTarget == .windowAction(item.id)))
                    .focusEffectDisabled()
                    .disabled(!enabled)
                    .help(enabled ? (state.sidebarAppIsHidden ? "Show app and focus window"
                                     : "\(actionTitle) window")
                          : "This window cannot be minimised or restored")
                    .accessibilityLabel("\(actionTitle) \(item.title)")
                }
            }
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(index == state.selectedIndex ? Color.accentColor.opacity(0.3) : Color.clear))
        } else {
            CyclePanelRow(title: item.title, isSelected: index == state.selectedIndex,
                          isCompact: !state.showsHeader)
                .onTapGesture { onActivate(item.id) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onActivate(item.id) }
                .accessibilityValue(index == state.selectedIndex ? "Selected" : "")
        }
    }
}

private struct SidebarActionButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, isHovered: isHovered)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let isHovered: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.18 : isHovered ? 0.1 : 0) : 0)))
                .transaction { $0.animation = nil }
        }
    }
}

// Provides the visible row's native coordinates, including scrolling and clipping.
// These views provide geometry only. A single panel-level pointer path selects rows
// and highlights buttons, so overlapping controls cannot swallow or replay hover events.
struct CyclePanelRowAnchor: NSViewRepresentable {
    var onAnchor: (NSView?) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onAnchor = onAnchor
        onAnchor(view)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.onAnchor = onAnchor
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.onAnchor?(nil)
    }

    final class AnchorView: NSView {
        var onAnchor: ((NSView?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct CyclePanelRow: View {
    let title: String
    let isSelected: Bool
    let isCompact: Bool
    var showsSelectionBackground = true
    
    var body: some View {
        HStack(spacing: 12) {
            if !isCompact {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
            }
            
            Text(title)
                .font(.system(size: 13, weight: isCompact && isSelected ? .medium : .regular))
                .foregroundStyle(isCompact ? Color.primary : (isSelected ? .white : .primary))
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.horizontal, isCompact ? 10 : 16)
        .frame(height: isCompact ? SidebarLayout.menuRowHeight : 44)
        .contentShape(Rectangle())
        .help(title)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected && showsSelectionBackground ? Color.accentColor.opacity(0.3) : Color.clear)
            
        )
    }
}
