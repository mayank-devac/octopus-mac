import SwiftUI
import AppKit

struct PreferencesSidebarView: View {
    @AppStorage("sidebarEnabled") private var enabled = true
    @AppStorage(SidebarSettings.multiDisplayKey) private var multiDisplay = false
    @AppStorage(SidebarNumberShortcuts.enabledKey) private var numberShortcuts = false
    @AppStorage(SidebarNumberShortcuts.modifiersKey) private var numberShortcutModifierMask = Int(SidebarNumberShortcuts.defaultModifiers.rawValue)
    @AppStorage("sidebarMonitor") private var monitor = "primary"
    @AppStorage(PreferenceKeys.sidebarWindowMenuStyle) private var windowMenuStyle = SidebarWindowMenuStyle.defaultStyle
    @AppStorage(PreferenceKeys.sidebarWindowMenuShowsOpenApps) private var windowMenuShowsOpenApps = false
    @State private var screens = NSScreen.screens
    @AppStorage(SidebarSettings.settingsSelectedDisplayKey) private var selectedDisplayID = ""
    @State private var configuration = SidebarConfiguration()
    @State private var savedDisplays: [String: SidebarDisplayPreference] = [:]
    @State private var formHeight: CGFloat?

    private var displayChoices: [(id: String, name: String)] {
        screens.enumerated().compactMap { index, screen -> (id: String, name: String)? in
            guard let id = SidebarSettings.monitorID(screen) else { return nil }
            let detectedName = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let duplicate = screens.filter { $0.localizedName == screen.localizedName }.count > 1
            let name = detectedName.isEmpty ? "Display \(index + 1)"
                : duplicate ? "\(detectedName) (Display \(index + 1))" : detectedName
            let role = index == 0 ? "Primary" : "Secondary"
            return (id, "\(name) (\(role))")
        }
    }

    private var singleDisplaySelection: Binding<String> {
        Binding(get: {
            displayChoices.contains { $0.id == monitor } ? monitor : "primary"
        }, set: { monitor = $0 })
    }

    private var editingEnabled: Bool {
        enabled && (!multiDisplay || (!selectedDisplayID.isEmpty && configuration.enabled))
    }

    private var usesVirtualNotch: Bool {
        guard configuration.idleBehavior == .notch else { return false }
        let screen = multiDisplay
            ? screens.first { SidebarSettings.monitorID($0) == selectedDisplayID }
            : SidebarSettings.selectedScreen()
        guard let screen else { return false }
        return SidebarLayout.hardwareNotchFrame(screenFrame: screen.frame, safeTopInset: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea) == nil
    }

    private var showWindows: Binding<String> {
        Binding(get: {
            multiDisplay && !configuration.enabled ? "off" : configuration.desktopScope.rawValue
        }, set: { value in
            var next = configuration
            if value == "off", multiDisplay { next.enabled = false }
            else {
                next.enabled = true
                next.desktopScope = .saved(value)
            }
            save(next)
        })
    }

    private func setting<Value>(_ path: WritableKeyPath<SidebarConfiguration, Value>) -> Binding<Value> {
        Binding(get: { configuration[keyPath: path] }, set: { value in
            var next = configuration
            next[keyPath: path] = value
            save(next)
        })
    }

    ////////////////////
    //// Delay opening
    /// Fade and Compact can step aside; all three supported modes can hide until the pointer reaches the edge.
    // Step aside fades a sidebar the pointer rests on unused; Hide until edge hides it until the pointer rests at the edge.

    @ViewBuilder private var delayedOpeningControls: some View {
        Picker("Delay opening", selection: delayedOpeningSelection.animation()) {
            ForEach(configuration.idleBehavior.delayedOpeningChoices, id: \.rawValue) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .disabled(!editingEnabled)
        .help("Step aside is available for Fade and Compact; it fades the unused sidebar and lets clicks through. Hide until edge hides the sidebar until the pointer rests at the screen edge.")
        // Step aside waits before closing the sidebar; Hide until edge waits before opening it.
        if let delay = configuration.activeDelayedOpening.delayCopy {
            LabeledContent(delay.title) {
                HStack(spacing: 6) {
                    Text("Short").font(.caption).foregroundStyle(.secondary)
                    Slider(value: selectedDelayBinding, in: SidebarSettings.openingDelayRange, step: 0.1)
                        .accessibilityLabel("Sidebar " + delay.title.lowercased())
                        .accessibilityValue(Text(selectedDelayText))
                    Text("Long").font(.caption).foregroundStyle(.secondary)
                    Text(selectedDelayText)
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .disabled(!editingEnabled)
            .help(delay.help)
        }
    }

    private var delayedOpeningSelection: Binding<SidebarDelayedOpening> {
        Binding(get: { configuration.activeDelayedOpening }, set: { value in
            setting(\.delayedOpening).wrappedValue = value
        })
    }

    private var selectedDelayBinding: Binding<Double> {
        configuration.activeDelayedOpening == .stepAside ? setting(\.closingDelay) : setting(\.openingDelay)
    }

    private var selectedDelayText: String {
        let delay = configuration.activeDelayedOpening == .stepAside
            ? configuration.closingDelay
            : configuration.openingDelay
        return delay.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    //// Rows appear only for the modes that offer Delay opening.
    //////////////////

    ////////////////////
    //// Edge mark color
    /// Picking a color stores it as hex; the reset button clears it so the mark follows the macOS accent color.
    // Until a color is picked, the well shows the accent color, matching the automatic mark.

    @ViewBuilder private var edgeMarkColorControls: some View {
        if configuration.autoHideEdgeMarkColor != nil {
            Button { setting(\.autoHideEdgeMarkColor).wrappedValue = nil } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Use the automatic color: the macOS accent color.")
        }
        ColorPicker("Edge mark color", selection: Binding(
            get: { Color(nsColor: SidebarEdgeMark.color(hex: configuration.autoHideEdgeMarkColor) ?? .controlAccentColor) },
            // A color that cannot be read as RGB (e.g. an image pattern) keeps the current one rather than resetting it.
            set: { if let hex = SidebarEdgeMark.hex(NSColor($0)) { setting(\.autoHideEdgeMarkColor).wrappedValue = hex } }
        ), supportsOpacity: false)
        .labelsHidden()
        .help("Color of the line on the screen edge where the hidden sidebar appears.")
    }

    //// Sits in the edge mark row, beside its switch, while the mark is on.
    //////////////////

    private func save(_ value: SidebarConfiguration) {
        var next = value
        next.normalize()
        configuration = next
        if multiDisplay {
            guard !selectedDisplayID.isEmpty else { return }
            let name = screens.first { SidebarSettings.monitorID($0) == selectedDisplayID }?.localizedName
                ?? savedDisplays[selectedDisplayID]?.name ?? "Display"
            SidebarSettings.save(next, for: selectedDisplayID, name: name)
        } else {
            next.saveSingleSidebar()
        }
    }

    // Each save writes many defaults keys and every write triggers a reload, so only assign state that
    // actually changed; redundant assignments re-render controls mid-animation (e.g. the Style picker slide).
    private func reload() {
        let latestScreens = NSScreen.screens
        if latestScreens != screens { screens = latestScreens }
        let latestDisplays = SidebarSettings.displayPreferences()
        if latestDisplays != savedDisplays { savedDisplays = latestDisplays }
        if !displayChoices.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displayChoices.first(where: { $0.id == monitor })?.id
                ?? displayChoices.first?.id ?? ""
        }
        let latestConfiguration = SidebarSettings.configuration(for: multiDisplay ? selectedDisplayID : nil)
        if latestConfiguration != configuration { configuration = latestConfiguration }
    }

    private func enableCompactIconsForConnectedDisplays() {
        let connectedDisplays = screens.compactMap { screen -> (id: String, name: String)? in
            guard let id = SidebarSettings.monitorID(screen) else { return nil }
            return (id, screen.localizedName)
        }
        SidebarSettings.enableCompactIconsForConnectedDisplays(connectedDisplays)
        reload()
    }

    private var resetButton: some View {
        Button("Reset") {
            var next = SidebarConfiguration.factoryDefaults
            if !multiDisplay { next.enabled = enabled }
            save(next)
        }
        .buttonStyle(.bordered)
        .disabled(multiDisplay && selectedDisplayID.isEmpty)
        .help("Restore this display’s sidebar settings to their default values.")
        .accessibilityLabel("Reset selected display’s sidebar settings")
    }

    var body: some View {
        Form {
            Toggle("Show window sidebar", isOn: $enabled)
            Toggle("Multi-display sidebar", isOn: $multiDisplay)
                .help("Show a sidebar on each enabled display. Each display remembers its own settings.")
            Toggle("Number shortcuts for sidebar apps", isOn: $numberShortcuts)
                .disabled(!enabled)
                .help("Open sidebar apps from top to bottom with 1–9 or 0; choose the modifier keys in Shortcuts settings.")
            if numberShortcuts {
                Text(SidebarNumberShortcuts.hint(for: NSEvent.ModifierFlags(rawValue: UInt(clamping: numberShortcutModifierMask))))
                    .font(.caption).foregroundStyle(.secondary)
                if let note = SidebarNumberShortcuts.availabilityNote {
                    Text(note)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if multiDisplay {
                HStack {
                    Picker("Display", selection: $selectedDisplayID) {
                        ForEach(displayChoices, id: \.id) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Display")
                    Spacer()
                    resetButton
                }
            } else {
                HStack {
                    Picker("Display", selection: singleDisplaySelection) {
                        Text("Primary display").tag("primary")
                        ForEach(displayChoices, id: \.id) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Display")
                    Spacer()
                    resetButton
                }
            }
            Section {
                Picker("Show windows", selection: showWindows) {
                    ForEach(SidebarDesktopScope.allCases, id: \.rawValue) { scope in
                        Text(scope.title).tag(scope.rawValue)
                    }
                    if multiDisplay { Text("Off").tag("off") }
                }
                .disabled(!enabled || (multiDisplay && selectedDisplayID.isEmpty))
                .help(multiDisplay ? "Off hides only this display’s sidebar and keeps its saved settings."
                      : "Choose whether to list windows from visible desktops or all desktops.")
                Picker("Displays", selection: setting(\.displayScope)) {
                    ForEach(SidebarDisplayScope.allCases, id: \.rawValue) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .disabled(!editingEnabled)
                .help("Current display shows only windows belonging to the display where this sidebar appears. Show windows still controls which desktops are included.")
                Picker(WindowMenuStrings.styleTitle, selection: $windowMenuStyle) {
                    ForEach(SidebarWindowMenuStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .help(WindowMenuStrings.styleHelp)
                Toggle(WindowMenuStrings.showsOpenAppsTitle, isOn: $windowMenuShowsOpenApps)
                    .disabled(windowMenuStyle != .modern)
                    .help(WindowMenuStrings.showsOpenAppsHelp)
                Toggle("Show menu for apps with one window", isOn: setting(\.showSingleWindowMenu))
                    .disabled(!editingEnabled)
                    .help("Off opens the window menu only for apps with more than one window.")
            }
            .disabled(!enabled)

            Section("Sidebar UI") {
                // Animate the switch so rows that depend on the style (e.g. Font size) change smoothly with the segment slide.
                Picker("Style", selection: setting(\.selectedStyle).animation()) {
                    Text("Dock").tag(SidebarStyle.dock)
                    Text("Floating").tag(SidebarStyle.floating)
                }
                .pickerStyle(.segmented)
                .disabled(!editingEnabled)
                .help(configuration.idleBehavior == .notch
                    ? "Dock grows a black bar out of the notch. Floating shows icons floating below the notch."
                    : "Dock shows app icons in a rounded bar. Floating shows icons floating over the desktop.")
                Toggle("Show window titles", isOn: setting(\.showsWindowTitles).animation())
                    .disabled(!editingEnabled)
                    .help("Show each window’s title under its icon; when off, display names shrink to their numbers. Choosing a style resets this: on for Dock, off for Floating.")
                Picker("Visibility", selection: setting(\.idleBehavior)) {
                    ForEach(SidebarIdleBehavior.allCases, id: \.rawValue) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .disabled(!editingEnabled)
                .help("Fade makes the idle sidebar more transparent. Auto-Hide shows it at the screen edge. Always visible keeps it fully opaque. Compact keeps a strip of numbers or app icons visible. Fade, Always visible and Compact can delay opening so buttons under the sidebar stay clickable. Mac Notch opens a horizontal app bar below a real or virtual notch; each app’s windows remain in one vertical list.")
                if configuration.idleBehavior == .compact {
                    Toggle("Show app icons instead of numbers", isOn: setting(\.compactShowsIcons))
                        .disabled(!editingEnabled)
                }
                if configuration.idleBehavior.supportsDelayedOpening { delayedOpeningControls }
                if configuration.idleBehavior == .hide {
                    LabeledContent("Show edge mark") {
                        HStack {
                            if configuration.autoHideShowsEdgeMark { edgeMarkColorControls }
                            Toggle("Show edge mark", isOn: setting(\.autoHideShowsEdgeMark)).labelsHidden()
                        }
                    }
                    .disabled(!editingEnabled)
                    .help("Show a thin line on the screen edge where the hidden sidebar appears.")
                }
                if usesVirtualNotch {
                    HStack {
                        Text("Notch width")
                        Slider(value: setting(\.virtualNotchWidth), in: SidebarSettings.virtualNotchWidthRange, step: 10)
                            .accessibilityLabel("Virtual notch width")
                        Text("\(Int(configuration.virtualNotchWidth)) pt")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .help("Resize the virtual notch on this display. A physical camera housing keeps its actual width.")
                }
                Picker("Side", selection: setting(\.side)) {
                    Text("Left").tag(SidebarSide.left)
                    Text("Right").tag(SidebarSide.right)
                }
                .disabled(configuration.idleBehavior == .notch)
                .help(configuration.idleBehavior == .notch
                    ? "Mac Notch centres the sidebar below the notch."
                    : "Choose the screen edge for the sidebar.")
                LabeledContent("Vertical position") {
                    HStack(spacing: 6) {
                        Text("Top").font(.caption).foregroundStyle(.secondary)
                        Slider(value: setting(\.position), in: 0...1)
                            .accessibilityLabel("Sidebar vertical position")
                        Text("Bottom").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(configuration.idleBehavior == .notch)
                .help(configuration.idleBehavior == .notch
                    ? "Mac Notch uses a fixed top-centre position."
                    : "Move the sidebar vertically along its screen edge.")
                HStack {
                    Text("Gap between apps")
                    Slider(value: setting(\.appSpacing), in: 0...SidebarSettings.maximumAppSpacing, step: 1)
                        .accessibilityLabel("Gap between apps")
                    Text("\(Int(configuration.appSpacing)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                HStack {
                    Text("Font size")
                    Slider(value: setting(\.fontSize), in: SidebarSettings.minimumFontSize...SidebarSettings.maximumFontSize, step: 1)
                        .accessibilityLabel("Sidebar label font size")
                    Text("\(Int(configuration.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                // Vertical Dock without titles draws no text; Floating headings and the notch bar still do.
                .disabled(configuration.style == .dock && configuration.idleBehavior != .notch
                          && !configuration.showsWindowTitles)
                // The vertical Dock's titles sit on its glass, so it offers the panel's opacity instead.
                // Group gives the branches one view for the size reader below to attach to.
                Group {
                    if configuration.style == .dock && configuration.idleBehavior != .notch {
                        HStack {
                            Text("Dock opacity")
                            Slider(value: Binding(
                                get: { configuration.dockOpacity },
                                set: { setting(\.dockOpacity).wrappedValue = ($0 * 20).rounded() / 20 }
                            ), in: 0...1)
                                .accessibilityLabel("Dock background opacity")
                            Text("\(Int((configuration.dockOpacity * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                        .help("Make the Dock’s frosted panel more transparent.")
                    } else {
                        HStack {
                            Text("Shadow opacity")
                            Slider(value: Binding(
                                get: { configuration.shadowOpacity },
                                set: { setting(\.shadowOpacity).wrappedValue = ($0 * 20).rounded() / 20 }
                            ), in: 0...SidebarSettings.maximumShadowOpacity)
                                .accessibilityLabel("Sidebar text shadow opacity")
                            Text("\(Int((configuration.shadowOpacity * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }
                .background {
                    PreferencesFormSizeReader { height in
                        if formHeight == nil || abs((formHeight ?? 0) - height) > 0.5 {
                            formHeight = height
                        }
                    }
                }
            }
            .disabled(!editingEnabled || (multiDisplay && selectedDisplayID.isEmpty))
        }
        .formStyle(.grouped)
        .frame(height: formHeight)
        .onAppear { reload() }
        .onChange(of: selectedDisplayID) { _, _ in reload() }
        .onChange(of: multiDisplay) { _, _ in reload() }
        .onChange(of: numberShortcuts) { wasEnabled, isEnabled in
            if isEnabled && !wasEnabled { enableCompactIconsForConnectedDisplays() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)) { _ in reload() }
    }
}
