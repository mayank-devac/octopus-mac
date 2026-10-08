//
//  octopusApp.swift
//  octopus
//
//  Created  on 12-09-2025.
//

import SwiftUI
import KeyboardShortcuts
import ServiceManagement

@main
struct octopusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var profileManager: ProfileManager
    @StateObject private var sparkleConnector = SparkleConnector()
    @AppStorage("launchOnLogin") private var launchOnLogin = true

    init() {
        SidebarSettings.registerDefaults()
        let profileManager = ProfileManager()
        _profileManager = StateObject(wrappedValue: profileManager)
        AppDelegate.profileManager = profileManager
        
        // Sync launch at login state with system
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            _launchOnLogin = AppStorage(wrappedValue: status == .enabled, "launchOnLogin")
        }
    }

    var body: some Scene {
        Settings {
            PreferencesView()
                .environmentObject(profileManager)
                .environmentObject(sparkleConnector)
                .environmentObject(appDelegate.windowLayoutController)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(profileManager)
                .environmentObject(sparkleConnector)
        } label: {
            MenuBarLabel(profileManager: profileManager)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var instance: AppDelegate!
    static var profileManager: ProfileManager!
    static private(set) var modifierManager: ModifierManager!
    
    private var cycleController: CyclePanelController!
    private var shortcutManager: ShortcutController!
    private var windowManager: PreferencesController!
    private var sidebarController: SidebarController!
    let windowLayoutController = WindowLayoutController()
    private var appearanceObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAppearance() }
        }
        AppDelegate.modifierManager = ModifierManager()
        
        cycleController = CyclePanelController(modifierManager: AppDelegate.modifierManager)
        shortcutManager = ShortcutController(cycleController, AppDelegate.profileManager)
        windowManager = PreferencesController()
        
        NSApp.setActivationPolicy(.accessory)
        windowLayoutController.start()
        sidebarController = SidebarController(cycleController: cycleController)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        appearanceObserver = nil
        sidebarController?.stop()
        windowLayoutController.stop()
        AppDelegate.profileManager.saveNow()
    }

    private func applyAppearance() {
        let appearance: NSAppearance?
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil
        }
        // Nil follows macOS; avoid refreshing the app for unrelated preference changes.
        if NSApp.appearance?.name != appearance?.name {
            NSApp.appearance = appearance
        }
    }
}
