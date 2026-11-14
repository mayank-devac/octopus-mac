//
//  AccessibilityPermissionGuide.swift
//  octopus
//
//  Opens System Settings → Accessibility and docks a small panel next to its window
//  with a draggable Octopus icon, so the user can drop the app into the list.
//

import AppKit
import SwiftUI
import ApplicationServices

@MainActor
final class AccessibilityPermissionGuide {
    static let shared = AccessibilityPermissionGuide()

    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    private static let settingsBundleID = "com.apple.systempreferences"
    private static let pollInterval: TimeInterval = 0.25
    private static let launchGrace: TimeInterval = 5

    private var panel: NSPanel?
    private var timer: Timer?
    private var openedAt = Date.distantPast

    private init() {}

    ////////////////////
    //// Open the guide
    /// Opens the Accessibility pane and runs the drag panel until access is granted.
    // Already trusted: just open the pane so the user can still review it.
    // Safe to call repeatedly: a second call only reopens the pane and restarts the launch grace.

    func open() {
        guard let url = Self.settingsURL else { return }
        NSWorkspace.shared.open(url)
        guard !AXIsProcessTrusted() else { return }

        openedAt = Date()
        if panel == nil { panel = makePanel() }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        tick()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    //// The guide lives only while System Settings is running and access is missing.
    //////////////////

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: AccessibilityPermissionGuideView(onClose: { [weak self] in self?.close() }))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        return panel
    }

    ////////////////////
    //// Poll state
    /// Ends on grant or when System Settings is gone; otherwise shows the panel only while
    /// Settings is the frontmost app with a window on screen, and follows that window.
    // The launch grace covers the moment between asking Settings to open and it actually running.
    // Which pane is showing cannot be detected: window titles need Screen Recording permission.

    private func tick() {
        if AXIsProcessTrusted() { close(); return }

        let settingsApps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID)
        if settingsApps.isEmpty {
            if Date().timeIntervalSince(openedAt) > Self.launchGrace { close() } else { panel?.orderOut(nil) }
            return
        }

        guard let panel else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID,
              let window = settingsWindowFrame(pids: Set(settingsApps.map(\.processIdentifier))),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(window) }) ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }

        let origin = AccessibilityGuidePlacement.origin(panelSize: panel.frame.size, settingsWindow: window,
                                                        visibleFrame: screen.visibleFrame)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    //// Polling avoids AX observers, which need the very permission being requested.
    //////////////////

    /// Largest normal-layer System Settings window, in AppKit (bottom-left) coordinates.
    /// Window bounds and owner PID are readable without Screen Recording permission.
    // CG window bounds are top-left based on the primary display, hence the flip.
    private func settingsWindowFrame(pids: Set<pid_t>) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }

        let frames = info.compactMap { entry -> CGRect? in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }
}
