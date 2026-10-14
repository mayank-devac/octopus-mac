//
//  PreferencesGeneralView.swift
//  octopus
//
//  Created  on 26-01-2026.
//

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import ApplicationServices

struct PreferencesGeneralView: View {
    @AppStorage("launchOnLogin") private var launchOnLogin = true
//    @AppStorage("hideMenubarIcon") private var hideMenubarIcon = false
    @AppStorage("showActiveProfileInMenuBar") private var showActiveProfileInMenuBar = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("defaultNumberOrder") private var defaultNumberOrder = "rightHanded"
    @AppStorage("instantSwitch") private var instantSwitch = "never"
    @AppStorage("windowMenuDisplay") private var windowMenuDisplay =
        UserDefaults.standard.bool(forKey: "showWindowMenuOnPrimaryDisplay") ? "primary" : "automatic"
    
    @State private var hasAccessibilityPermission = AXIsProcessTrusted()
    @State private var screens = NSScreen.screens
    
    // Timer to poll for accessibility permission changes
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Form {
            // Accessibility Permission Warning
            if !hasAccessibilityPermission {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .imageScale(.large)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility Permission Required")
                            .fontWeight(.medium)
                        Text("System Settings → Privacy & Security → Accessibility")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Open Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            Section {
                Toggle("Launch octopus at login", isOn: $launchOnLogin)
                    .onChange(of: launchOnLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }

                Picker("Theme:", selection: $appearance) {
                    Text("Device default").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.menu)
            }

            Section {
//                Toggle("Hide menubar icon", isOn: $hideMenubarIcon)
                Toggle("Show active profile in menu bar", isOn: $showActiveProfileInMenuBar)
                Picker("Window menu display:", selection: $windowMenuDisplay) {
                    Text("Automatic").tag("automatic")
                    Text("Primary display").tag("primary")
                    ForEach(screens.indices, id: \.self) { index in
                        let screen = screens[index]
                        if let id = SidebarSettings.monitorID(screen) {
                            Text("\(screen.localizedName) (Display \(index + 1))").tag(id)
                        }
                    }
                    if windowMenuDisplay != "automatic", windowMenuDisplay != "primary",
                       !screens.contains(where: { SidebarSettings.monitorID($0) == windowMenuDisplay }) {
                        Text("Disconnected display (using primary)").tag(windowMenuDisplay)
                    }
                }
                .pickerStyle(.menu)
                .help("Automatic keeps the current placement. A disconnected display uses the primary display. Applies when the window menu next opens.")

                Picker("Instant switch:", selection: $instantSwitch) {
                    Text("Never").tag("never")
                    Text("When only one window open").tag("whenOnlyOneWindowOpen")
                }
                .pickerStyle(.menu)

                Picker("Default number order:", selection: $defaultNumberOrder) {
                    Text("Right handed (0, 9, ..., 1)").tag("rightHanded")
                    Text("Left handed (1, ..., 9, 0)").tag("leftHanded")
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .frame(height: hasAccessibilityPermission ? 310 : 400)
        .onAppear {
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onReceive(timer) { _ in
            // Poll for permission changes
            hasAccessibilityPermission = AXIsProcessTrusted()
        }
    }
    
    private func openAccessibilitySettings() {
        // Open System Settings to the Privacy & Security > Accessibility pane
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
                // Revert the toggle if it failed
                DispatchQueue.main.async {
                    launchOnLogin = !enabled
                }
            }
        } else {
            // Legacy API for macOS 12 and earlier
            SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! as CFString, enabled)
        }
    }
}

#Preview {
    PreferencesGeneralView()
}
