import AppKit
import SwiftUI

@MainActor
final class SidebarViewState: ObservableObject {
    @Published var highlightedEntryID: SidebarEntryID?
    @Published var side: SidebarSide = .right
    @Published var dragSections: [SidebarDesktopSection]?
    @Published var dropDesktopID: UInt64?
    // Pair feedback is icon-specific, separate from a whole Desktop section's transfer highlight.
    @Published var pairDropEntryID: SidebarEntryID?
    @Published var pairDropDirection: PairDropDirection?
    @Published var monitors: [SidebarMonitor] = []
    @Published var configuration = SidebarConfiguration()
    @Published var isExpanded = false
    @Published var isTopCentered = false
    @Published var topContentWidth: CGFloat?
    var dragDesktops: [SidebarDesktop]?
}

struct SidebarView: View {
    @ObservedObject var inventory: SidebarWindowInventory
    @ObservedObject var state: SidebarViewState
    @ObservedObject private var mouseShortcuts = MouseShortcutStore.shared
    private var appSpacing: Double { state.configuration.appSpacing }
    private var labelFontSize: Double { state.configuration.fontSize }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var onClick: (SidebarEntryID) -> Void
    var onAnchor: (SidebarEntryID, NSView?) -> Void
    var onIconAnchor: (SidebarEntryID, NSView?) -> Void = { _, _ in }
    var pairTargetsProvider: () -> [SidebarIconPairTarget] = { [] }
    var onPairCommand: (SidebarWindowID, SidebarWindowID, PairDropDirection) -> Void = { _, _, _ in }
    var onDrag: (SidebarEntryID, SidebarWindowID?, String, NSView, NSEvent) -> Void = { _, _, _, _, _ in }
    var onPlacement: (SidebarWindowID, SidebarSnapTarget) -> Void = { _, _ in }
    var onMouseAction: (SidebarEntryID, MouseShortcutAction, SidebarWindowID?) -> Void = { _, _, _ in }
    var onDesktopAnchor: (UInt64, NSView?) -> Void = { _, _ in }
    var onDesktopTransfer: (SidebarWindowID, SidebarDesktop) -> Void = { _, _ in }
    var onMonitorAnchor: (String, NSView?) -> Void = { _, _ in }
    var onReveal: () -> Void = {}

    private var isCompact: Bool { state.configuration.idleBehavior == .compact }
    private var showsMainSidebar: Bool { !isCompact || state.isExpanded }
    private var contentWidth: CGFloat? {
        state.isTopCentered ? state.topContentWidth
            : (showsMainSidebar ? SidebarLayout.width : 0) + (isCompact ? SidebarLayout.compactWidth : 0)
    }
    private var sidebarAlignment: Alignment {
        state.isTopCentered ? .center : state.side == .left ? .leading : .trailing
    }

    private var sections: [SidebarDesktopSection] {
        state.dragSections ?? SidebarDesktopSection.make(entries: inventory.entries,
            desktops: inventory.desktops, scope: inventory.desktopScope)
    }

    private var displayedEntries: [SidebarEntry] { groups.flatMap(\.sections).flatMap(\.entries) }
    private var groups: [SidebarMonitorGroup] {
        SidebarMonitorGroup.make(sections: sections, desktops: state.dragDesktops ?? inventory.desktops,
            monitors: state.monitors, scope: inventory.desktopScope)
    }

    var body: some View {
        let indices = Dictionary(uniqueKeysWithValues: displayedEntries.enumerated().map { ($0.element.id, $0.offset) })
        return Group {
            if !inventory.hasPermission {
                sidebarRow {
                    Button(action: openAccessibilitySettings) {
                        VStack(spacing: 6) {
                            Image(systemName: "hand.raised.fill").font(.title2)
                            Text("Allow access").font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76)
                    }
                    .buttonStyle(.plain)
                    .help("Allow octopus in System Settings → Privacy & Security → Accessibility")
                } compact: {
                    Button(action: openAccessibilitySettings) { Image(systemName: "hand.raised") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Allow Accessibility access")
                        .frame(width: SidebarLayout.compactWidth, height: 76)
                }
            } else if groups.isEmpty || (inventory.desktopScope == .visibleDesktops && inventory.entries.isEmpty) {
                sidebarRow {
                    Text("No windows")
                        .font(.caption)
                        .frame(maxWidth: .infinity, minHeight: 76)
                } compact: {
                    Text("–").frame(width: SidebarLayout.compactWidth, height: 76)
                        .accessibilityLabel("No windows")
                }
            } else if isCompact && !showsMainSidebar {
                compactEntries(indices: indices)
            } else if state.isTopCentered {
                notchEntries(indices: indices)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: CGFloat(appSpacing)) {
                        ForEach(groups) { group in
                            VStack(spacing: 0) {
                                if let monitor = group.monitor {
                                    sidebarRow {
                                        Text(monitor.title)
                                            .font(.system(size: max(CGFloat(labelFontSize) - 1, 8), weight: .medium))
                                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                            .multilineTextAlignment(.center).lineLimit(3)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background { SidebarFrostBackground(shadowOpacity: state.configuration.shadowOpacity) }
                                            .frame(maxWidth: .infinity).frame(height: SidebarMonitor.headerHeight)
                                            .overlay {
                                                SidebarGeometryAnchor(id: monitor.id, onAnchor: onMonitorAnchor)
                                                    .allowsHitTesting(false)
                                            }
                                            .help(monitor.title)
                                    } compact: {
                                        Color.clear.frame(width: SidebarLayout.compactWidth, height: SidebarMonitor.headerHeight)
                                    }
                                    if group.sections.allSatisfy({ $0.entries.isEmpty }) {
                                        sidebarRow {
                                            Text("Empty")
                                                .font(.system(size: max(CGFloat(labelFontSize) - 1, 8), weight: .medium))
                                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background { SidebarFrostBackground(shadowOpacity: state.configuration.shadowOpacity) }
                                                .frame(maxWidth: .infinity).frame(height: SidebarMonitor.emptyHeight)
                                        } compact: {
                                            Color.clear.frame(width: SidebarLayout.compactWidth, height: SidebarMonitor.emptyHeight)
                                        }
                                    }
                                }
                                ForEach(Array(group.sections.enumerated()), id: \.element.id) { index, section in
                                    if index > 0 {
                                        sidebarRow {
                                            SidebarDesktopSeparator(title: section.desktop?.title ?? "Other apps",
                                                                    shadowOpacity: state.configuration.shadowOpacity)
                                        } compact: {
                                            Color.clear.frame(width: SidebarLayout.compactWidth, height: SidebarLayout.desktopSeparatorHeight)
                                        }
                                        .padding(.vertical, CGFloat(appSpacing) / 2)
                                    }
                                    desktopSection(section, indices: indices)
                                }
                            }
                        }
                    }
                    .padding(.vertical, SidebarLayout.verticalPadding)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
        .frame(width: contentWidth)
        .frame(maxHeight: .infinity)
        .background(alignment: sidebarAlignment) {
            if isCompact {
                UnevenRoundedRectangle(
                    topLeadingRadius: state.side == .right ? 12 : 0,
                    bottomLeadingRadius: state.side == .right ? 12 : 0,
                    bottomTrailingRadius: state.side == .left ? 12 : 0,
                    topTrailingRadius: state.side == .left ? 12 : 0
                )
                .fill((colorScheme == .dark ? Color.black : Color.white).opacity(0.45))
                .frame(width: SidebarLayout.compactWidth)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: sidebarAlignment)
        .accessibilityAction(named: Text("Expand sidebar"), onReveal)
    }

    // Both columns live in the same scroll view, so numbers cannot drift from their app rows.
    private func sidebarRow<Main: View, Compact: View>(@ViewBuilder main: () -> Main,
                                                      @ViewBuilder compact: () -> Compact) -> some View {
        HStack(spacing: 0) {
            if isCompact && state.side == .left { compact() }
            if showsMainSidebar { main().frame(width: SidebarLayout.width) }
            if isCompact && state.side == .right { compact() }
        }
    }

    private func desktopSection(_ section: SidebarDesktopSection, indices: [SidebarEntryID: Int]) -> some View {
        VStack(spacing: CGFloat(appSpacing)) {
            ForEach(section.entries) { entry in
                let index = indices[entry.id] ?? 0
                sidebarRow {
                    item(entry, index: index)
                } compact: {
                    compactNumber(entry, index: index)
                }
            }
        }
        .background {
            if let desktop = section.desktop, state.dropDesktopID == desktop.id {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.22))
            }
        }
        .overlay {
            if let desktop = section.desktop {
                SidebarGeometryAnchor(id: desktop.id, onAnchor: onDesktopAnchor).allowsHitTesting(false)
            }
        }
    }

    private func compactEntries(indices: [SidebarEntryID: Int]) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: SidebarLayout.labelHeight + CGFloat(appSpacing)) {
                ForEach(displayedEntries) { entry in
                    compactNumber(entry, index: indices[entry.id] ?? 0, reservesLabelSpace: false)
                }
            }
            .padding(.vertical, SidebarLayout.verticalPadding)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func notchEntries(indices: [SidebarEntryID: Int]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: CGFloat(appSpacing)) {
                ForEach(groups) { group in
                    notchGroup(group, indices: indices)
                }
            }
            .padding(SidebarLayout.notchBarPadding)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func notchGroup(_ group: SidebarMonitorGroup, indices: [SidebarEntryID: Int]) -> some View {
        HStack(spacing: 0) {
            if let monitor = group.monitor {
                notchMonitorLabel(monitor)
                    .padding(.trailing, CGFloat(appSpacing))
                if group.sections.allSatisfy({ $0.entries.isEmpty }) {
                    Text("Empty").font(.caption).foregroundStyle(.secondary)
                        .frame(width: SidebarLayout.notchEmptyWidth, height: SidebarLayout.rowHeight)
                }
            }
            ForEach(Array(group.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.45))
                        .frame(width: 1, height: SidebarLayout.rowHeight - 8)
                        .frame(width: SidebarLayout.notchSeparatorWidth)
                        .padding(.horizontal, CGFloat(appSpacing) / 2)
                        .accessibilityLabel(section.desktop?.title ?? "Other apps")
                }
                notchSection(section, indices: indices)
            }
        }
    }

    private func notchMonitorLabel(_ monitor: SidebarMonitor) -> some View {
        let number = (state.monitors.firstIndex { $0.id == monitor.id } ?? (monitor.isPrimary ? 0 : 1)) + 1
        let title = "\(number) · \(monitor.name.isEmpty ? "Monitor" : monitor.name)"
        return Text(title)
            .font(.system(size: CGFloat(labelFontSize), weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.65)
            .frame(width: SidebarLayout.rowHeight - 8, height: SidebarLayout.notchMonitorWidth)
            .rotationEffect(.degrees(-90))
            .frame(width: SidebarLayout.notchMonitorWidth, height: SidebarLayout.rowHeight)
            .contentShape(Rectangle())
            .overlay {
                SidebarGeometryAnchor(id: monitor.id, onAnchor: onMonitorAnchor).allowsHitTesting(false)
            }
            .help(title).accessibilityLabel(title)
    }

    private func notchSection(_ section: SidebarDesktopSection, indices: [SidebarEntryID: Int]) -> some View {
        HStack(spacing: CGFloat(appSpacing)) {
            ForEach(section.entries) { entry in
                item(entry, index: indices[entry.id] ?? 0).frame(width: SidebarLayout.width)
            }
        }
        .background {
            if let desktop = section.desktop, state.dropDesktopID == desktop.id {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.22))
            }
        }
        .overlay {
            if let desktop = section.desktop {
                SidebarGeometryAnchor(id: desktop.id, onAnchor: onDesktopAnchor).allowsHitTesting(false)
            }
        }
    }

    private func compactNumber(_ entry: SidebarEntry, index: Int, reservesLabelSpace: Bool = true) -> some View {
        let number = index + 1
        let isOpen = entry.hasOpenWindows
        let numberColor: Color = colorScheme == .dark ? .white : .black
        let numberOpacity: Double = isOpen ? 1 : 0.35
        let stateDescription = isOpen ? "open" : "hidden or no open windows"
        let accessibilityDescription = "\(number), \(entry.application.title), \(stateDescription)"
        return Text(String(number))
            .font(.system(size: CGFloat(labelFontSize) + 3, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(numberColor.opacity(numberOpacity))
            .frame(width: SidebarLayout.compactWidth, height: SidebarLayout.iconSlotHeight)
            .frame(height: reservesLabelSpace ? SidebarLayout.rowHeight : SidebarLayout.iconSlotHeight,
                   alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture(perform: onReveal)
            .accessibilityLabel(Text(accessibilityDescription))
            .accessibilityAction { onReveal() }
            .help(entry.application.title)
    }

    private func item(_ entry: SidebarEntry, index: Int) -> some View {
        let title = entry.preferredWindow?.title ?? entry.application.title
        let dragTarget = SidebarIconDragPolicy.target(for: entry)
        let mouseBindings = mouseShortcuts.bindings
        let maximumLabelScale: CGFloat = reduceMotion ? 1 : 1 + SidebarLayout.magnificationGrowth
        // Reserve width for the largest zoom so labels keep the same wrapping during hover.
        let labelPadding: CGFloat = 4
        let labelWidth = (SidebarLayout.width - 6) / maximumLabelScale - labelPadding * 2
        return VStack(alignment: .center, spacing: 0) {
            Group {
                if let icon = entry.application.runningApplication?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.fill").resizable()
                }
            }
            .frame(width: SidebarLayout.iconSize, height: SidebarLayout.iconSize)
            .overlay {
                // Measure the actual icon, rather than using its larger row/title hit area.
                SidebarGeometryAnchor(id: entry.id, onAnchor: onIconAnchor).allowsHitTesting(false)
            }
            .overlay {
                if state.pairDropEntryID == entry.id {
                    SidebarPairBorder(direction: state.pairDropDirection)
                        .padding(-3).allowsHitTesting(false)
                }
            }
            .scaleEffect(scale(for: index))
            .frame(height: SidebarLayout.iconSlotHeight)

            Text(title)
                .font(.system(size: CGFloat(labelFontSize), weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .lineLimit(2)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, labelPadding)
                .padding(.vertical, 2)
                .background {
                    SidebarFrostBackground(shadowOpacity: state.configuration.shadowOpacity)
                }
                .scaleEffect(scale(for: index), anchor: .top)
                .frame(width: labelWidth + labelPadding * 2)
                .frame(height: SidebarLayout.labelHeight, alignment: .top)
                .padding(.horizontal, 3)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: SidebarLayout.rowHeight)
        .opacity(entry.visibleIDs.isEmpty ? 0.65 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: scale(for: index))
        .overlay {
            SidebarPointerRegion(
                onClick: { onClick(entry.id) },
                onAnchor: { onAnchor(entry.id, $0) },
                onDrag: { onDrag(entry.id, dragTarget, title, $0, $1) },
                dragShortcut: mouseBindings.place,
                onMouseClick: { shortcut in
                    if let action = mouseBindings.clickAction(for: shortcut) { onMouseAction(entry.id, action, dragTarget) }
                    else if shortcut == .left { onClick(entry.id) }
                },
                onDoubleClick: { if let id = dragTarget { onPlacement(id, .maximize) } },
                doubleClickTarget: dragTarget
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.application.title): \(title), \(entry.desktop?.title ?? "Other apps")")
        .accessibilityHint(entry.preferredID == nil ? "Activate app"
            : entry.isHidden || entry.preferredID.flatMap { entry.windowStates[$0.windowID]?.isMinimized } == true
                ? "Restore window" : "Focus window")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onClick(entry.id) }
        .accessibilityActions {
            Button("Hide app") { onMouseAction(entry.id, .hide, dragTarget) }
            if dragTarget != nil {
                Button("Minimise or restore window") { onMouseAction(entry.id, .minimize, dragTarget) }
            }
            if let id = dragTarget {
                // Screen-reader users can invoke the same explicit pair command without a pointer drag.
                if entry.visibleIDs.contains(id) {
                    ForEach(accessiblePairTargets(excluding: id), id: \.window) { destination in
                        ForEach(PairDropDirection.allCases, id: \.rawValue) { direction in
                            Button("Pair \(direction.rawValue) of \(destination.title)") {
                                onPairCommand(id, destination.window, direction)
                            }
                        }
                    }
                }
                ForEach(SidebarSnapTarget.allCases, id: \.self) { target in
                    Button(target.title) { onPlacement(id, target) }
                }
                if inventory.canTransferDesktops, !entry.isHidden,
                   entry.windowStates[id.windowID]?.isMinimized == false, let source = entry.desktop {
                    ForEach(inventory.desktops.filter {
                        SidebarDesktopTransferPolicy.allows(source: source, destination: $0)
                    }, id: \.id) { desktop in
                        Button("Move to \(desktop.title)") { onDesktopTransfer(id, desktop) }
                    }
                }
            }
        }
    }

    private func accessiblePairTargets(excluding source: SidebarWindowID) -> [SidebarIconPairTarget] {
        var seen = Set<SidebarWindowID>()
        return pairTargetsProvider().filter { $0.isVisible && $0.window != source && seen.insert($0.window).inserted }
    }

    private func scale(for index: Int) -> CGFloat {
        guard state.dragSections == nil, !reduceMotion,
              let highlighted = displayedEntries.firstIndex(where: { $0.id == state.highlightedEntryID }) else { return 1 }
        switch abs(index - highlighted) {
        case 0: return 1 + SidebarLayout.magnificationGrowth
        case 1: return 1.1
        default: return 1
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct SidebarNotchTriggerView: View {
    var body: some View {
        SidebarNotchShape()
            .fill(Color.black.opacity(0.94))
            .accessibilityHidden(true)
    }
}

struct SidebarNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(16, min(rect.height / 2, rect.width / 4))
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                              control: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 2 * r, y: rect.maxY),
                              control: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + 2 * r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                              control: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: rect.minX + r, y: rect.minY))
            path.closeSubpath()
        }
    }
}

// A quiet neutral outline identifies B; the thick segment shows where dragged A will land.
private struct SidebarPairBorder: View {
    let direction: PairDropDirection?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.32 : 0.22), lineWidth: 1.5)
            GeometryReader { geometry in
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    switch direction {
                    case .left: path.move(to: CGPoint(x: 0, y: 5)); path.addLine(to: CGPoint(x: 0, y: h - 5))
                    case .right: path.move(to: CGPoint(x: w, y: 5)); path.addLine(to: CGPoint(x: w, y: h - 5))
                    case .top: path.move(to: CGPoint(x: 5, y: 0)); path.addLine(to: CGPoint(x: w - 5, y: 0))
                    case .bottom: path.move(to: CGPoint(x: 5, y: h)); path.addLine(to: CGPoint(x: w - 5, y: h))
                    case nil: break
                    }
                }.stroke(.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SidebarDesktopSeparator: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let shadowOpacity: Double

    var body: some View {
        let lineColor: Color = colorScheme == .dark ? .white : .black
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: lineColor.opacity(0.65), location: 0.2),
            .init(color: lineColor.opacity(0.65), location: 0.8), .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
        .frame(height: 1)
        .padding(.horizontal, 4)
        .frame(height: SidebarLayout.desktopSeparatorHeight)
        .background {
            SidebarFrostBackground(shadowOpacity: shadowOpacity)
                .opacity(0.55)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .allowsHitTesting(false)
    }
}

private struct SidebarGeometryAnchor<ID: Hashable>: NSViewRepresentable {
    let id: ID
    let onAnchor: (ID, NSView?) -> Void

    final class AnchorView: NSView {
        var onRemoval: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onRemoval = { onAnchor(id, nil) }
        onAnchor(id, view)
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {}
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.onRemoval?() }
}

private struct SidebarFrostBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var shadowOpacity: Double

    var body: some View {
        let isDarkFrost = colorScheme == .dark
        let blurRadius: CGFloat = isDarkFrost ? 4 : 3.5
        let surfacePadding: CGFloat = isDarkFrost ? 1 : 0
        let fadeMargin = blurRadius * 3
        // Leave three blur radii inside the canvas so the fade reaches
        // transparency before the native effect's rectangular bounds.
        Group {
            if isDarkFrost {
                // A neutral tint keeps the shadow consistent regardless of the wallpaper colour.
                Color(white: 0.06).opacity(min(0.5 * shadowOpacity, 1))
            } else {
                // Flat light tint, not the blurred material, so black text stays readable on very dark wallpapers.
                Color(white: 0.94).opacity(min(0.5 * shadowOpacity, 1))
            }
        }
            .mask {
                ZStack {
                    // The setting is applied once, to the fill above; scaling the mask too would square it.
                    Capsule(style: .continuous)
                        .fill(.white)
                        .padding(fadeMargin)
                        .blur(radius: blurRadius)
                        .opacity(isDarkFrost ? 0.25 : 0.65)

                    // Keep contrast near the letters without tinting the whole halo.
                    Capsule(style: .continuous)
                        .fill(.white)
                        .padding(fadeMargin + 1)
                        .blur(radius: 4)
                        .opacity(0.90)
                }
            }
            .padding(-(fadeMargin + surfacePadding))
            .allowsHitTesting(false)
    }
}

private struct SidebarLabelBackground: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Contrast the black text in Dark Mode and white text in Light Mode.
        let material: NSVisualEffectView.Material = colorScheme == .dark ? .popover : .hudWindow
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .aqua : .darkAqua
        if nsView.material != material { nsView.material = material }
        if nsView.appearance?.name != appearanceName {
            nsView.appearance = NSAppearance(named: appearanceName)
        }
    }
}

// Keep the click area fixed while the controller tracks the pointer independently.
struct SidebarPointerRegion: NSViewRepresentable {
    var onClick: () -> Void
    var onAnchor: (NSView?) -> Void
    var onDrag: ((NSView, NSEvent) -> Void)? = nil
    var dragShortcut: MouseShortcut? = .left
    var onMouseClick: ((MouseShortcut) -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var doubleClickTarget: SidebarWindowID? = nil

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        updateNSView(view, context: context)
        onAnchor(view)
        return view
    }

    func updateNSView(_ view: PointerView, context: Context) {
        view.onClick = onClick
        view.onAnchor = onAnchor
        view.onDrag = onDrag
        view.dragShortcut = dragShortcut
        view.onMouseClick = onMouseClick
        view.onDoubleClick = onDoubleClick
        view.doubleClickTarget = doubleClickTarget
    }

    static func dismantleNSView(_ view: PointerView, coordinator: ()) {
        view.cancelOperation(nil)
        view.onAnchor?(nil)
    }

    final class PointerView: NSView {
        var onClick: (() -> Void)?
        var onAnchor: ((NSView?) -> Void)?
        var onDrag: ((NSView, NSEvent) -> Void)?
        var dragShortcut: MouseShortcut? = .left
        var cornerModifiersProvider: () -> NSEvent.ModifierFlags = { MouseShortcutStore.shared.cornerSnapModifiers }
        var onMouseClick: ((MouseShortcut) -> Void)?
        var onDoubleClick: (() -> Void)?
        var doubleClickTarget: SidebarWindowID? {
            didSet { if oldValue != doubleClickTarget { cancelPendingClick() } }
        }
        private var clickGate = SidebarClickGate()
        private struct Press {
            let point: CGPoint
            let button: Int
            let event: NSEvent
            let click: (() -> Void)?
            let drag: ((NSView, NSEvent) -> Void)?
            let primaryTarget: SidebarWindowID?
            let doubleAction: (() -> Void)?
        }
        private struct PendingClick {
            let id: UUID
            let target: SidebarWindowID
            let timestamp: TimeInterval
            let action: (() -> Void)?
            let work: DispatchWorkItem
        }
        private var press: Press?
        private var pendingClick: PendingClick?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            startPress(event)
        }
        override func rightMouseDown(with event: NSEvent) { startPress(event) }
        override func otherMouseDown(with event: NSEvent) { startPress(event) }
        // Capture actions and identity at mouse down. Plain-left app clicks arbitrate single versus double;
        // other buttons and modifier bindings retain the existing immediate click policy.
        private func startPress(_ event: NSEvent) {
            press = nil
            let shortcut = MouseShortcut(button: event.buttonNumber, modifiers: event.modifierFlags)
            let primary = shortcut == .left && onDoubleClick != nil ? doubleClickTarget : nil
            var primaryTarget = primary
            var double: (() -> Void)?
            if let primary {
                guard event.timestamp.isFinite else { return }
                // macOS can keep numbering clicks at the same pointer location after our
                // action finishes. Only a matching second click is a double; later clicks
                // start a fresh action and the per-app busy guard handles overlap.
                if let pending = pendingClick, pending.target == primary, event.clickCount == 2,
                   event.timestamp >= pending.timestamp,
                   event.timestamp - pending.timestamp <= SidebarClickGate.interval {
                    cancelPendingClick()
                    double = onDoubleClick
                } else {
                    commitPendingClick()
                    // AppKit may still call this a double within its longer system interval.
                    // Outside Octopus's 230 ms window, let this release act as a single click.
                    if event.clickCount > 1 { primaryTarget = nil }
                }
            } else {
                commitPendingClick()
                guard clickGate.accepts(timestamp: event.timestamp, clickCount: event.clickCount) else { return }
            }
            let click: (() -> Void)?
            if let onMouseClick { click = { onMouseClick(shortcut) } }
            else { click = shortcut == .left ? onClick : nil }
            press = Press(point: event.locationInWindow, button: event.buttonNumber, event: event,
                click: click, drag: SidebarCornerSnapShortcut.allowsDrag(shortcut, binding: dragShortcut,
                    cornerModifiers: cornerModifiersProvider()) ? onDrag : nil,
                primaryTarget: primaryTarget, doubleAction: double)
        }
        override func mouseDragged(with event: NSEvent) {
            continuePress(event)
        }
        override func rightMouseDragged(with event: NSEvent) { continuePress(event) }
        override func otherMouseDragged(with event: NSEvent) { continuePress(event) }
        private func continuePress(_ event: NSEvent) {
            guard let press, event.buttonNumber == press.button,
                  Self.hasStartedDrag(from: press.point, to: event.locationInWindow) else { return }
            self.press = nil
            cancelPendingClick()
            press.drag?(self, press.event)
        }
        override func mouseUp(with event: NSEvent) {
            endPress(event)
        }
        override func rightMouseUp(with event: NSEvent) { endPress(event) }
        override func otherMouseUp(with event: NSEvent) { endPress(event) }
        // Commit a double only on an in-bounds release still classified by macOS as a click.
        private func endPress(_ event: NSEvent) {
            guard let completed = press, event.buttonNumber == completed.button else { return }
            press = nil
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if let double = completed.doubleAction {
                if event.clickCount == 2 { double() }
                return
            }
            guard let target = completed.primaryTarget else { completed.click?(); return }
            let id = UUID()
            let work = DispatchWorkItem { [weak self] in self?.commitPendingClick(expectedID: id) }
            pendingClick = PendingClick(id: id, target: target, timestamp: completed.event.timestamp,
                action: completed.click, work: work)
            let delay = max(0, SidebarClickGate.interval - max(0, event.timestamp - completed.event.timestamp))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        override func cancelOperation(_ sender: Any?) { press = nil; cancelPendingClick() }

        // Delay the single primary action so a double cannot first minimise or hide its window.
        // The nonce prevents a cancelled timer from committing a newer pending click.
        func commitPendingClick(expectedID: UUID? = nil) {
            guard let pending = pendingClick, expectedID == nil || expectedID == pending.id else { return }
            cancelPendingClick()
            guard pending.target == doubleClickTarget else { return }
            pending.action?()
        }

        private func cancelPendingClick() {
            pendingClick?.work.cancel()
            pendingClick = nil
        }

        static func hasStartedDrag(from start: CGPoint, to end: CGPoint) -> Bool {
            hypot(end.x - start.x, end.y - start.y) > 6
        }
    }
}
