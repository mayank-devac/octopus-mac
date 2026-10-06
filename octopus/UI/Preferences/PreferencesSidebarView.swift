import SwiftUI
import AppKit

struct PreferencesSidebarView: View {
    @AppStorage("sidebarEnabled") private var enabled = true
    @AppStorage("sidebarDesktopScope") private var desktopScope = SidebarDesktopScope.allDesktops.rawValue
    @AppStorage("sidebarSide") private var side = SidebarSide.right.rawValue
    @AppStorage("sidebarPosition") private var position = 0.5
    @AppStorage("sidebarMonitor") private var monitor = "primary"
    @AppStorage("sidebarAutoHide") private var autoHide = false
    @AppStorage("sidebarShowSingleWindowMenu") private var showSingleWindowMenu = false
    @AppStorage("sidebarActiveAppClickAction") private var activeAppClickAction = SidebarActiveAppClickAction.minimize.rawValue
    @AppStorage("sidebarAppSpacing") private var appSpacing = SidebarSettings.defaultAppSpacing
    @State private var screens = NSScreen.screens

    var body: some View {
        Form {
            Toggle("Show window sidebar", isOn: $enabled)
            Section {
                Picker("Apps from", selection: $desktopScope) {
                    ForEach(SidebarDesktopScope.allCases, id: \.rawValue) { scope in
                        Text(scope.title).tag(scope.rawValue)
                    }
                }
                Picker("Side", selection: $side) {
                    Text("Left").tag(SidebarSide.left.rawValue)
                    Text("Right").tag(SidebarSide.right.rawValue)
                }
                Picker("Monitor", selection: $monitor) {
                    Text("Primary monitor").tag("primary")
                    ForEach(screens, id: \.self) { screen in
                        if let id = SidebarSettings.monitorID(screen) {
                            Text(screen.localizedName).tag(id)
                        }
                    }
                    if monitor != "primary", !screens.contains(where: { SidebarSettings.monitorID($0) == monitor }) {
                        Text("Disconnected monitor (using primary)").tag(monitor)
                    }
                }
                HStack {
                    Text("Vertical position")
                    Text("Top").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $position, in: 0...1)
                        .accessibilityLabel("Sidebar vertical position")
                    Text("Bottom").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Automatically hide sidebar", isOn: $autoHide)
                Toggle("Show window menu for apps with one window", isOn: $showSingleWindowMenu)
                Picker("Clicking the active app", selection: $activeAppClickAction) {
                    ForEach(SidebarActiveAppClickAction.allCases, id: \.rawValue) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                HStack {
                    Text("Gap between apps")
                    Slider(value: $appSpacing, in: 0...SidebarSettings.maximumAppSpacing, step: 1)
                        .accessibilityLabel("Vertical gap between apps")
                    Text("\(Int(appSpacing)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            } footer: {
                Text("All desktops groups windows by desktop, with a separator between groups. An app can appear in several groups; each menu shows only that desktop’s windows, prefixed with its desktop number. Finder appears only with a window, including minimised windows. Apps without known windows appear after the desktop groups. Desktop discovery uses private macOS APIs and may fall back to the app list. In full screen, reveal the sidebar at the screen edge. Hide affects the whole app across desktops.")
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .frame(height: 485)
        .onAppear {
            desktopScope = SidebarDesktopScope.saved(desktopScope).rawValue
            activeAppClickAction = SidebarActiveAppClickAction.saved(activeAppClickAction).rawValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }
}
