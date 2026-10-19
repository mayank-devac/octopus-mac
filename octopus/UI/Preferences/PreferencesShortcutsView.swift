//
//  PreferencesShortcutsView.swift
//  octopus
//
//  Created  on 26-01-2026.
//

import SwiftUI
import AppKit
import KeyboardShortcuts
import Carbon.HIToolbox

struct PreferencesShortcutsView: View {
    private static let maximumFormHeight: CGFloat = 520
    @StateObject private var modifierManager: ModifierManager = {
        if let manager = AppDelegate.modifierManager {
            return manager
        }
        return ModifierManager()
    }()
    @State private var showingResetConfirmation = false
    @StateObject private var mouseShortcuts = MouseShortcutStore.shared
    @State private var recordingMouseAction: MouseShortcutAction?
    @State private var mouseShortcutError: String?
    @State private var formHeight: CGFloat?
    @State private var monitorShortcutError: String?
    @State private var monitorShortcutConflict = false
    @StateObject private var radialSettings = RadialWindowSettings.shared
    @State private var radialError: String?
    private struct ShortcutAssignment {
        let name: KeyboardShortcuts.Name
        let shortcut: KeyboardShortcuts.Shortcut
    }
    @State private var pendingAssignment: ShortcutAssignment?

    private func saveShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name, allowingSystemConflict: Bool = false) -> String? {
        if name == .showRadialWindows {
            if let error = RadialWindowSettings.keyboardError(shortcut) { return error }
        } else if WindowMonitorShortcuts.conflict(for: shortcut, excluding: name) {
            return "This shortcut is assigned to another Octopus action. Choose another."
        }
        if !allowingSystemConflict, let shortcut,
           shortcut != KeyboardShortcuts.getShortcut(for: name), systemUsesShortcut(shortcut) {
            pendingAssignment = ShortcutAssignment(name: name, shortcut: shortcut)
            return nil
        }
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        return nil
    }

    private func systemUsesShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        var symbolicKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&symbolicKeys) == noErr,
              let keys = symbolicKeys?.takeRetainedValue() as? [[String: Any]] else { return false }
        return keys.contains {
            guard ($0[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let key = $0[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = $0[kHISymbolicHotKeyModifiers] as? Int else { return false }
            return shortcut == KeyboardShortcuts.Shortcut(carbonKeyCode: key, carbonModifiers: modifiers)
        }
    }

    private func refreshMonitorShortcutConflict() {
        monitorShortcutConflict = WindowMonitorShortcuts.conflict(
            for: KeyboardShortcuts.getShortcut(for: .moveWindowLeftMonitor), excluding: .moveWindowLeftMonitor)
            || WindowMonitorShortcuts.conflict(
                for: KeyboardShortcuts.getShortcut(for: .moveWindowRightMonitor), excluding: .moveWindowRightMonitor)
    }

    private func monitorShortcutRow(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            KeyboardShortcutRecorder(name: name, onRecord: { saveShortcut($0, for: name) },
                                     onError: { monitorShortcutError = $0 })
                .frame(width: 135, height: 26)
                .accessibilityLabel(title)
            Button("Disable") {
                monitorShortcutError = saveShortcut(nil, for: name)
            }
            .help("Remove this shortcut and return the key combination to other apps")
            .accessibilityLabel("Disable \(title.lowercased()) shortcut")
        }
    }

    private func positionModifier(_ flag: NSEvent.ModifierFlags, symbol: String, name: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { mouseShortcuts.positionScrollModifiers.contains(flag) },
            set: { enabled in
                var modifiers = mouseShortcuts.positionScrollModifiers
                if enabled { modifiers.insert(flag) } else { modifiers.remove(flag) }
                mouseShortcuts.setPositionScrollModifiers(modifiers)
            }
        ))
        .toggleStyle(.checkbox)
        .help(name)
        .accessibilityLabel("Use \(name) to move the sidebar with the scroll wheel")
    }

    private func cornerModifier(_ flag: NSEvent.ModifierFlags, symbol: String, name: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { mouseShortcuts.cornerSnapModifiers.contains(flag) },
            set: { enabled in
                var modifiers = mouseShortcuts.cornerSnapModifiers
                if enabled { modifiers.insert(flag) } else { modifiers.remove(flag) }
                mouseShortcuts.setCornerSnapModifiers(modifiers)
            }
        ))
        .toggleStyle(.checkbox)
        .help(name)
        .accessibilityLabel("Use \(name) to snap to corners while dragging")
    }

    private var disabledCapabilityNote: String? {
        var disabledCapabilities: [String] = []
        if !modifierManager.activateEnabled {
            disabledCapabilities.append("app switching")
        }
        if !modifierManager.bindEnabled {
            disabledCapabilities.append("binding")
        }
        if !modifierManager.profileEnabled {
            disabledCapabilities.append("workspace opening")
        }

        guard !disabledCapabilities.isEmpty else {
            return nil
        }

        let capabilityList: String
        switch disabledCapabilities.count {
        case 1:
            capabilityList = disabledCapabilities[0]
        case 2:
            capabilityList = "\(disabledCapabilities[0]) and \(disabledCapabilities[1])"
        default:
            let prefix = disabledCapabilities.dropLast().joined(separator: ", ")
            capabilityList = "\(prefix), and \(disabledCapabilities.last!)"
        }

        let verb = disabledCapabilities.count == 1 ? "is" : "are"
        return "Note: Keyboard \(capabilityList) \(verb) disabled"
    }
    
    var body: some View {
        Form {
            Section {
                Button("Reset keyboard modifiers") {
                    showingResetConfirmation = true
                }
                .buttonStyle(.bordered)
            }

            Section {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                    GridRow {
                        Text(verbatim: "Modifier keys")
                            .fontWeight(.medium)
                            .frame(minWidth: 150, alignment: .leading)
                        Text("⌃").fontWeight(.medium)
                        Text("⌥").fontWeight(.medium)
                        Text("⇧").fontWeight(.medium)
                        Text("⌘").fontWeight(.medium)
                    }

                    Divider()

                    GridRow {
                        Text(verbatim: "Switch app")
                            .frame(minWidth: 150, alignment: .leading)
                        Toggle("", isOn: $modifierManager.activateControl).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.activateOption).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.activateShift).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.activateCommand).toggleStyle(.checkbox)
                    }

                    GridRow {
                        Text(verbatim: "Open workspace")
                            .frame(minWidth: 150, alignment: .leading)
                        Toggle("", isOn: $modifierManager.profileControl).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.profileOption).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.profileShift).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.profileCommand).toggleStyle(.checkbox)
                    }

                    GridRow {
                        Text(verbatim: "Bind app")
                            .frame(minWidth: 150, alignment: .leading)
                        Toggle("", isOn: $modifierManager.bindControl).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.bindOption).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.bindShift).toggleStyle(.checkbox)
                        Toggle("", isOn: $modifierManager.bindCommand).toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 8)

                if let disabledCapabilityNote {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.secondary)
                            .font(.caption)

                        Text(disabledCapabilityNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            Section {
                Toggle("Use numpad digits for shortcuts", isOn: $modifierManager.numpadShortcutsEnabled)
                    .toggleStyle(.checkbox)
            }

            Section {
                Button("Reset monitor shortcuts") {
                    let names: [KeyboardShortcuts.Name] = [.moveWindowLeftMonitor, .moveWindowRightMonitor]
                    let previous = names.map { KeyboardShortcuts.getShortcut(for: $0) }
                    // Reset together so swapped shortcuts do not conflict with each other.
                    KeyboardShortcuts.reset(names)
                    monitorShortcutError = nil
                    for (name, previousShortcut) in zip(names, previous) {
                        if let error = saveShortcut(KeyboardShortcuts.getShortcut(for: name), for: name) {
                            KeyboardShortcuts.setShortcut(previousShortcut, for: name)
                            monitorShortcutError = error
                        }
                    }
                }
                monitorShortcutRow("Move window to left monitor", name: .moveWindowLeftMonitor)
                monitorShortcutRow("Move window to right monitor", name: .moveWindowRightMonitor)
                if monitorShortcutConflict {
                    Text("A monitor shortcut conflicts with another Octopus action and will not move windows. Choose another shortcut.")
                        .font(.caption).foregroundStyle(.red)
                } else if let monitorShortcutError {
                    Text(monitorShortcutError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Move focused window between monitors")
            }

            Section {
                Toggle("Use middle mouse button", isOn: Binding(
                    get: { radialSettings.middleClickEnabled },
                    set: { radialError = radialSettings.setMiddleClick($0) }
                ))
                Text("Hold middle click, point to a window, then release. Enabling this reserves ordinary middle click for Octopus.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Select windows").frame(maxWidth: .infinity, alignment: .leading)
                    KeyboardShortcutRecorder(name: .showRadialWindows, onRecord: { saveShortcut($0, for: .showRadialWindows) },
                                             onError: { radialError = $0 })
                        .frame(width: 135, height: 26)
                        .accessibilityLabel("Radial window selector shortcut")
                    Button("Disable") {
                        radialError = saveShortcut(nil, for: .showRadialWindows)
                    }
                }
                Text("Hold modifiers to browse all windows, hover More for extras, release a modifier to select, or press Escape to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = radialError ?? radialSettings.status {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Radial window selector") }

            Section {
                Button("Reset all mouse shortcuts") {
                    recordingMouseAction = nil
                    mouseShortcutError = nil
                    mouseShortcuts.resetAll()
                }
                ForEach(MouseShortcutAction.allCases, id: \.rawValue) { action in
                    HStack {
                        Text(action.title).frame(width: 155, alignment: .leading)
                        let shortcut = mouseShortcuts.bindings[action]
                        Text(shortcut.map { $0.title + (action == .place ? " + drag" : "") } ?? "Not assigned")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MouseShortcutRecorder(isRecording: recordingMouseAction == action,
                            onBegin: { mouseShortcutError = nil; recordingMouseAction = action },
                            onRecord: { shortcut in
                                mouseShortcutError = mouseShortcuts.assign(shortcut, to: action)
                                recordingMouseAction = nil
                            }, onCancel: { recordingMouseAction = nil })
                            .frame(width: 135, height: 26)
                        Button("Reset") {
                            if recordingMouseAction == action { recordingMouseAction = nil }
                            mouseShortcutError = mouseShortcuts.reset(action)
                        }
                        .help("Restore \(action.defaultShortcut.title)\(action == .place ? " + drag" : "")")
                        .accessibilityLabel("Reset \(action.title.lowercased()) mouse shortcut")
                        Button {
                            if recordingMouseAction == action { recordingMouseAction = nil }
                            mouseShortcutError = mouseShortcuts.assign(nil, to: action)
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .disabled(shortcut == nil)
                            .help("Remove this mouse shortcut")
                            .accessibilityLabel("Remove \(action.title.lowercased()) mouse shortcut")
                    }
                }
                if let mouseShortcutError {
                    Text(mouseShortcutError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Snap to corners while dragging").frame(width: 155, alignment: .leading)
                    cornerModifier(.control, symbol: "⌃", name: "Control")
                    cornerModifier(.option, symbol: "⌥", name: "Option (Alt)")
                    cornerModifier(.shift, symbol: "⇧", name: "Shift")
                    cornerModifier(.command, symbol: "⌘", name: "Command")
                    Spacer(minLength: 8)
                    Button("Reset") { mouseShortcuts.resetCornerSnapModifiers() }
                        .help("Restore Control + Option + Shift")
                        .accessibilityLabel("Reset corner snap shortcut")
                    Button("Disable") { mouseShortcuts.setCornerSnapModifiers([]) }
                        .disabled(mouseShortcuts.cornerSnapModifiers.isEmpty)
                        .accessibilityLabel("Disable corner snap shortcut")
                }
                .help("Hold these modifiers before or during your configured drag to select a corner quarter. Clearing all modifiers disables the gesture.")
                HStack {
                    Text("Move sidebar vertically").frame(width: 155, alignment: .leading)
                    positionModifier(.control, symbol: "⌃", name: "Control")
                    positionModifier(.option, symbol: "⌥", name: "Option (Alt)")
                    positionModifier(.shift, symbol: "⇧", name: "Shift")
                    positionModifier(.command, symbol: "⌘", name: "Command")
                    Spacer(minLength: 8)
                    Text("+ Scroll wheel").foregroundStyle(.secondary)
                    Button("Reset") { mouseShortcuts.resetPositionScrollModifiers() }
                        .help("Restore Control + scroll wheel")
                        .accessibilityLabel("Reset sidebar movement shortcut")
                    Button { mouseShortcuts.setPositionScrollModifiers([]) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(mouseShortcuts.positionScrollModifiers.isEmpty)
                    .help("Disable the sidebar movement shortcut")
                    .accessibilityLabel("Disable sidebar movement shortcut")
                }
                .help("Start scrolling over the sidebar, then keep holding the selected modifiers to continue moving it anywhere. Release a selected modifier to finish. If macOS Accessibility Zoom uses the same gesture, choose a different modifier.")
                .background {
                    PreferencesFormSizeReader { height in
                        if formHeight == nil || abs((formHeight ?? 0) - height) > 0.5 { formHeight = height }
                    }
                }
            } header: {
                Text("Mouse shortcuts")
            }

        }
        .formStyle(.grouped)
        .onDisappear { recordingMouseAction = nil; pendingAssignment = nil; radialSettings.editingShortcuts = false }
        .onAppear { refreshMonitorShortcutConflict(); radialSettings.editingShortcuts = true }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            refreshMonitorShortcutConflict()
        }
        .frame(height: min(formHeight ?? Self.maximumFormHeight, Self.maximumFormHeight))
        .alert("macOS also uses this shortcut", isPresented: Binding(
            get: { pendingAssignment != nil },
            set: { if !$0 { pendingAssignment = nil } }
        ), presenting: pendingAssignment) { assignment in
            Button("Cancel", role: .cancel) {}
            Button("Use Anyway") {
                let error = saveShortcut(assignment.shortcut, for: assignment.name, allowingSystemConflict: true)
                if assignment.name == .showRadialWindows { radialError = error }
                else { monitorShortcutError = error }
            }
        } message: { assignment in
            Text("Use \(assignment.shortcut) for Octopus anyway? If macOS still opens its own action, change that shortcut in System Settings → Keyboard → Keyboard Shortcuts.")
        }
        .alert("Reset keyboard modifiers?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                modifierManager.resetToDefaults()
            }
        } message: {
            Text(verbatim: """
            Modifiers will be reset to

            Activate:\t\t⌃
            Profile:\t\t⌃ + ⌥
            Bind:\t\t⌃ + ⌥ + ⇧
            """)
            .font(.system(.body, design: .monospaced))
        }
    }
}

#Preview {
    PreferencesShortcutsView()
}
