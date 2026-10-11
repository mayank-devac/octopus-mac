import SwiftUI
import AppKit

struct PreferencesSidebarView: View {
    @AppStorage("sidebarEnabled") private var enabled = true
    @AppStorage(SidebarSettings.multiDisplayKey) private var multiDisplay = false
    @AppStorage("sidebarMonitor") private var monitor = "primary"
    @State private var screens = NSScreen.screens
    @State private var selectedDisplayID = ""
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

    private func reload() {
        screens = NSScreen.screens
        savedDisplays = SidebarSettings.displayPreferences()
        if !displayChoices.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displayChoices.first(where: { $0.id == monitor })?.id
                ?? displayChoices.first?.id ?? ""
        }
        configuration = SidebarSettings.configuration(for: multiDisplay ? selectedDisplayID : nil)
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
            if multiDisplay {
                HStack {
                    Picker("Display", selection: $selectedDisplayID) {
                        ForEach(displayChoices, id: \.id) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
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
                    .pickerStyle(.menu)
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
                Toggle("Show menu for apps with one window", isOn: setting(\.showSingleWindowMenu))
                    .disabled(!editingEnabled)
            } footer: {
                Text("Groups windows by desktop with separators. Each menu shows only that desktop’s windows. Finder appears only when open. "
                     + (configuration.displayScope == .currentDisplay
                        ? "Current display lists windows belonging to this sidebar’s display; apps without windows are omitted. "
                        : "Apps without windows appear last. ")
                     + "In full screen, the sidebar stays at the screen edge. Compact keeps its number strip visible. Mac Notch opens a horizontal app bar below a real or virtual top-centre notch.")

            }
            .disabled(!enabled)

            Section("Sidebar UI") {
                Picker("Visibility", selection: setting(\.idleBehavior)) {
                    ForEach(SidebarIdleBehavior.allCases, id: \.rawValue) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .disabled(!editingEnabled)
                .help("Fade makes the idle sidebar more transparent. Auto-Hide shows it at the screen edge. Always visible keeps it fully opaque. Compact keeps a numbered strip visible. Mac Notch opens a horizontal app bar below a real or virtual notch; each app’s windows remain in one vertical list.")
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
                HStack {
                    Text("Snap distance")
                    Slider(value: Binding(
                        get: { configuration.snapDistance },
                        set: { setting(\.snapDistance).wrappedValue = $0 }
                    ), in: SidebarSettings.minimumSnapDistance...SidebarSettings.maximumSnapDistance, step: 20)
                        .accessibilityLabel("Window snap distance from screen sides")
                        .accessibilityValue("\(Int(configuration.snapDistance)) points")
                    Text("\(Int(configuration.snapDistance)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .disabled(!editingEnabled)
                .help("Larger distances show snap previews sooner. On smaller displays the distance is limited so the centre stays available for moving windows.")
                Picker("Side", selection: setting(\.side)) {
                    Text("Left").tag(SidebarSide.left)
                    Text("Right").tag(SidebarSide.right)
                }
                .disabled(configuration.idleBehavior == .notch)
                .help(configuration.idleBehavior == .notch
                    ? "Mac Notch centres the sidebar below the notch."
                    : "Choose the screen edge for the sidebar.")
                HStack {
                    Text("Vertical position")
                    Text("Top").font(.caption).foregroundStyle(.secondary)
                    Slider(value: setting(\.position), in: 0...1)
                        .accessibilityLabel("Sidebar vertical position")
                    Text("Bottom").font(.caption).foregroundStyle(.secondary)
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
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)) { _ in reload() }
    }
}
