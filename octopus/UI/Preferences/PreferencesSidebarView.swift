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

    private var displayChoices: [(id: String, name: String)] {
        let connected = screens.enumerated().compactMap { index, screen -> (id: String, name: String)? in
            guard let id = SidebarSettings.monitorID(screen) else { return nil }
            let duplicate = screens.filter { $0.localizedName == screen.localizedName }.count > 1
            let name = duplicate ? "\(screen.localizedName) (Display \(index + 1))" : screen.localizedName
            return (id, name)
        }
        let ids = Set(connected.map(\.id))
        let disconnected = savedDisplays.filter { !ids.contains($0.key) }.sorted { $0.key < $1.key }
            .map { entry in
                let duplicate = savedDisplays.values.filter { $0.name == entry.value.name }.count > 1
                let suffix = duplicate ? "disconnected · \(entry.key.prefix(8))" : "disconnected"
                return (id: entry.key, name: "\(entry.value.name) (\(suffix))")
            }
        return connected + disconnected
    }

    private var editingEnabled: Bool {
        enabled && (!multiDisplay || (!selectedDisplayID.isEmpty && configuration.enabled))
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
            } else if screens.count > 1 || monitor != "primary" {
                HStack {
                    Picker("Display", selection: $monitor) {
                        Text("Primary display").tag("primary")
                        ForEach(displayChoices.filter { choice in
                            screens.contains { SidebarSettings.monitorID($0) == choice.id }
                        }, id: \.id) { display in
                            Text(display.name).tag(display.id)
                        }
                        if monitor != "primary", !screens.contains(where: { SidebarSettings.monitorID($0) == monitor }) {
                            Text("Disconnected display (using primary)").tag(monitor)
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
                     + "In full screen, the sidebar stays at the screen edge; Auto-hide applies across all desktops.")

            }
            .disabled(!enabled)

            Section("Sidebar UI") {
                Picker("Visibility", selection: setting(\.idleBehavior)) {
                    ForEach(SidebarIdleBehavior.allCases, id: \.rawValue) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .disabled(!editingEnabled)
                .help("Fade makes the idle sidebar more transparent so you can see through the icons. Auto-Hide shows it only when the pointer reaches the screen edge. Always visible keeps it fully opaque.")
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
                HStack {
                    Text("Vertical position")
                    Text("Top").font(.caption).foregroundStyle(.secondary)
                    Slider(value: setting(\.position), in: 0...1)
                        .accessibilityLabel("Sidebar vertical position")
                    Text("Bottom").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Gap between apps")
                    Slider(value: setting(\.appSpacing), in: 0...SidebarSettings.maximumAppSpacing, step: 1)
                        .accessibilityLabel("Vertical gap between apps")
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
            }
            .disabled(!editingEnabled || (multiDisplay && selectedDisplayID.isEmpty))
        }
        .formStyle(.grouped)
        // Leave room for the settings toolbar and keep the form usable on smaller screens.
        .frame(height: min(660, max(360, (NSScreen.main?.visibleFrame.height ?? 760) - 100)))
        .onAppear {
            screens = NSScreen.screens
            reload()
        }
        .onChange(of: selectedDisplayID) { _, _ in reload() }
        .onChange(of: multiDisplay) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
            reload()
        }
    }
}
