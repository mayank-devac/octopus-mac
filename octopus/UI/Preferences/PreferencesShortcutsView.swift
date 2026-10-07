//
//  PreferencesShortcutsView.swift
//  octopus
//
//  Created  on 26-01-2026.
//

import SwiftUI

struct PreferencesShortcutsView: View {
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

    private var disabledCapabilityNote: String? {
        var disabledCapabilities: [String] = []
        if !modifierManager.activateEnabled {
            disabledCapabilities.append("app switching")
        }
        if !modifierManager.bindEnabled {
            disabledCapabilities.append("binding")
        }
        if !modifierManager.profileEnabled {
            disabledCapabilities.append("profile switching")
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
                VStack(alignment: .leading, spacing: 16) {
                    Text("Use the selection boxes below to customize modifier keys for switching and binding apps, and profile switching.\n\nTo disable an action, deselect all modifier checkboxes in that row.")
                        .font(.body)
                        .foregroundColor(.secondary)

                    Button("Reset keyboard modifiers") {
                        showingResetConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
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
                        Text(verbatim: "Switch profile")
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
            } footer: {
                Text("⌃ Control  •  ⌥ Option  •  ⇧ Shift  •  ⌘ Command")
            }

            Section {
                Toggle("Use numpad digits for shortcuts", isOn: $modifierManager.numpadShortcutsEnabled)
                    .toggleStyle(.checkbox)
            } footer: {
                Text("Also use numpad 0–9 for app and profile shortcuts. These combinations may conflict with other apps.")
            }

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
            } header: {
                Text("Mouse shortcuts")
            } footer: {
                Text("On sidebar app icons only. Inactive apps focus first. Click Record, then click that button with your chosen mouse button; modifier keys are optional. Escape cancels. Hide and minimise must use different shortcuts.")
            }

        }
        .formStyle(.grouped)
        .onDisappear { recordingMouseAction = nil }
        .frame(height: !modifierManager.activateEnabled || !modifierManager.bindEnabled || !modifierManager.profileEnabled ? 495 : 460)
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
