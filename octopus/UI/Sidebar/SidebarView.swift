import AppKit
import SwiftUI

@MainActor
final class SidebarViewState: ObservableObject {
    @Published var highlightedEntryID: SidebarEntryID?
    @Published var side: SidebarSide = .right
    @Published var dragSections: [SidebarDesktopSection]?
    @Published var dropDesktopID: UInt64?
    @Published var monitors: [SidebarMonitor] = []
    var dragDesktops: [SidebarDesktop]?
}

struct SidebarView: View {
    @ObservedObject var inventory: SidebarWindowInventory
    @ObservedObject var state: SidebarViewState
    @ObservedObject private var mouseShortcuts = MouseShortcutStore.shared
    @AppStorage("sidebarAppSpacing") private var appSpacing = SidebarSettings.defaultAppSpacing
    @AppStorage("sidebarFontSize") private var labelFontSize = SidebarSettings.defaultFontSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var onClick: (SidebarEntryID) -> Void
    var onAnchor: (SidebarEntryID, NSView?) -> Void
    var onDrag: (SidebarEntryID, SidebarWindowID?, String, NSView, NSEvent) -> Void = { _, _, _, _, _ in }
    var onPlacement: (SidebarWindowID, SidebarSnapTarget) -> Void = { _, _ in }
    var onMouseAction: (SidebarEntryID, MouseShortcutAction, SidebarWindowID?) -> Void = { _, _, _ in }
    var onDesktopAnchor: (UInt64, NSView?) -> Void = { _, _ in }
    var onDesktopTransfer: (SidebarWindowID, SidebarDesktop) -> Void = { _, _ in }
    var onMonitorAnchor: (String, NSView?) -> Void = { _, _ in }

    private var sections: [SidebarDesktopSection] {
        state.dragSections ?? SidebarDesktopSection.make(entries: inventory.entries,
            desktops: inventory.desktops, scope: inventory.desktopScope)
    }

    private var displayedEntries: [SidebarEntry] { sections.flatMap(\.entries) }
    private var groups: [SidebarMonitorGroup] {
        SidebarMonitorGroup.make(sections: sections, desktops: state.dragDesktops ?? inventory.desktops,
            monitors: state.monitors, scope: inventory.desktopScope)
    }

    var body: some View {
        let indices = Dictionary(uniqueKeysWithValues: displayedEntries.enumerated().map { ($0.element.id, $0.offset) })
        return Group {
            if !inventory.hasPermission {
                Button(action: openAccessibilitySettings) {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill").font(.title2)
                        Text("Allow access").font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                }
                .buttonStyle(.plain)
                .help("Allow octopus in System Settings → Privacy & Security → Accessibility")
            } else if groups.isEmpty || (inventory.desktopScope == .visibleDesktops && inventory.entries.isEmpty) {
                Text("No windows")
                    .font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 76)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: CGFloat(appSpacing)) {
                        ForEach(groups) { group in
                            VStack(spacing: 0) {
                                if let monitor = group.monitor {
                                    Text(monitor.title)
                                        .font(.system(size: max(CGFloat(labelFontSize) - 1, 8), weight: .medium))
                                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                                        .multilineTextAlignment(.center).lineLimit(3)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background { SidebarFrostBackground().opacity(0.8) }
                                        .frame(maxWidth: .infinity).frame(height: SidebarMonitor.headerHeight)
                                        .overlay {
                                            SidebarGeometryAnchor(id: monitor.id, onAnchor: onMonitorAnchor)
                                                .allowsHitTesting(false)
                                        }
                                        .help(monitor.title)
                                    if group.sections.allSatisfy({ $0.entries.isEmpty }) {
                                        Text("Empty")
                                            .font(.system(size: max(CGFloat(labelFontSize) - 1, 8), weight: .medium))
                                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background { SidebarFrostBackground().opacity(0.8) }
                                            .frame(maxWidth: .infinity).frame(height: SidebarMonitor.emptyHeight)
                                    }
                                }
                                ForEach(Array(group.sections.enumerated()), id: \.element.id) { index, section in
                                    if index > 0 {
                                        SidebarDesktopSeparator(title: section.desktop?.title ?? "Other apps")
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
        .foregroundStyle(.white)
        .frame(width: SidebarLayout.width)
        .frame(maxHeight: .infinity)
        .background(Color.clear)
        .frame(maxWidth: .infinity, alignment: state.side == .left ? .leading : .trailing)
    }

    private func desktopSection(_ section: SidebarDesktopSection, indices: [SidebarEntryID: Int]) -> some View {
        VStack(spacing: CGFloat(appSpacing)) {
            ForEach(section.entries) { entry in
                item(entry, index: indices[entry.id] ?? 0)
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

    private func item(_ entry: SidebarEntry, index: Int) -> some View {
        let title = entry.preferredWindow?.title ?? entry.application.title
        let dragTarget = SidebarIconDragPolicy.target(for: entry)
        let mouseBindings = mouseShortcuts.bindings
        let maximumLabelScale: CGFloat = reduceMotion ? 1 : 1 + SidebarLayout.magnificationGrowth
        // Reserve width for the largest zoom so labels keep the same wrapping during hover.
        let labelPadding: CGFloat = 4
        let labelWidth = (SidebarLayout.width - 6) / maximumLabelScale - labelPadding * 2
        return VStack(spacing: 0) {
            Group {
                if let icon = entry.application.runningApplication?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.fill").resizable()
                }
            }
            .frame(width: SidebarLayout.iconSize, height: SidebarLayout.iconSize)
            .scaleEffect(scale(for: index))
            .frame(height: SidebarLayout.iconSlotHeight)

            Text(title)
                .font(.system(size: CGFloat(labelFontSize), weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .lineLimit(2)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, labelPadding)
                .padding(.vertical, 2)
                .background {
                    SidebarFrostBackground()
                }
                .scaleEffect(scale(for: index), anchor: .top)
                .frame(width: labelWidth + labelPadding * 2)
                .frame(height: SidebarLayout.labelHeight, alignment: .top)
                .padding(.horizontal, 3)
        }
        .frame(maxWidth: .infinity)
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
                }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.application.title): \(title), \(entry.desktop?.title ?? "Other apps")")
        .accessibilityHint(entry.preferredID == nil ? "Activate app" : entry.visibleIDs.isEmpty ? "Restore window" : "Focus window")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onClick(entry.id) }
        .accessibilityActions {
            Button("Hide app") { onMouseAction(entry.id, .hide, dragTarget) }
            if dragTarget != nil {
                Button("Minimise or restore window") { onMouseAction(entry.id, .minimize, dragTarget) }
            }
            if let id = dragTarget {
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

private struct SidebarDesktopSeparator: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    var body: some View {
        let lineColor: Color = colorScheme == .dark ? .black : .white
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: lineColor.opacity(0.65), location: 0.2),
            .init(color: lineColor.opacity(0.65), location: 0.8), .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
        .frame(height: 1)
        .padding(.horizontal, 4)
        .frame(height: SidebarLayout.desktopSeparatorHeight)
        .background {
            SidebarFrostBackground()
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

    var body: some View {
        let isDarkFrost = colorScheme == .light
        let blurRadius: CGFloat = isDarkFrost ? 4 : 3.5
        let surfacePadding: CGFloat = isDarkFrost ? 1 : 0
        let fadeMargin = blurRadius * 3
        // Leave three blur radii inside the canvas so the fade reaches
        // transparency before the native effect's rectangular bounds.
        Group {
            if isDarkFrost {
                // A neutral tint keeps the shadow consistent regardless of the wallpaper colour.
                Color(white: 0.06).opacity(0.5)
            } else {
                SidebarLabelBackground().opacity(0.38)
            }
        }
            .mask {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.white)
                        .padding(fadeMargin)
                        .blur(radius: blurRadius)
                        .opacity(isDarkFrost ? 0.25 : 0.65)

                    if isDarkFrost {
                        // Keep contrast near the letters without darkening the whole halo.
                        Capsule(style: .continuous)
                            .fill(.white)
                            .padding(fadeMargin + 1)
                            .blur(radius: 4)
                            .opacity(0.90)
                    }
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
    }

    static func dismantleNSView(_ view: PointerView, coordinator: ()) {
        view.onAnchor?(nil)
    }

    final class PointerView: NSView {
        var onClick: (() -> Void)?
        var onAnchor: ((NSView?) -> Void)?
        var onDrag: ((NSView, NSEvent) -> Void)?
        var dragShortcut: MouseShortcut? = .left
        var onMouseClick: ((MouseShortcut) -> Void)?
        private var clickGate = SidebarClickGate()
        private var press: (point: CGPoint, button: Int, event: NSEvent, click: (() -> Void)?, drag: ((NSView, NSEvent) -> Void)?)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            startPress(event)
        }
        override func rightMouseDown(with event: NSEvent) { startPress(event) }
        override func otherMouseDown(with event: NSEvent) { startPress(event) }
        private func startPress(_ event: NSEvent) {
            // Suppress only very fast repeats, even if macOS groups later clicks together.
            press = nil
            guard clickGate.accepts(timestamp: event.timestamp, clickCount: event.clickCount) else { return }
            let shortcut = MouseShortcut(button: event.buttonNumber, modifiers: event.modifierFlags)
            let click: (() -> Void)?
            if let onMouseClick { click = { onMouseClick(shortcut) } }
            else { click = shortcut == .left ? onClick : nil }
            press = (event.locationInWindow, event.buttonNumber, event, click,
                     shortcut == dragShortcut ? onDrag : nil)
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
            press.drag?(self, press.event)
        }
        override func mouseUp(with event: NSEvent) {
            endPress(event)
        }
        override func rightMouseUp(with event: NSEvent) { endPress(event) }
        override func otherMouseUp(with event: NSEvent) { endPress(event) }
        private func endPress(_ event: NSEvent) {
            guard event.buttonNumber == press?.button else { return }
            let click = press?.click
            press = nil
            if bounds.contains(convert(event.locationInWindow, from: nil)) { click?() }
        }
        override func cancelOperation(_ sender: Any?) { press = nil }

        static func hasStartedDrag(from start: CGPoint, to end: CGPoint) -> Bool {
            hypot(end.x - start.x, end.y - start.y) > 6
        }
    }
}
