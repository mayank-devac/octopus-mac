import SwiftUI

struct PreferencesWindowLayoutView: View {
    @AppStorage(WindowLayoutSettings.enabledKey) private var enabled = true
    @AppStorage(WindowLayoutSettings.selectionKey) private var selection = WindowLayoutSelection.mostRecent.rawValue
    @AppStorage(WindowLayoutSettings.moveSizeKey) private var moveSize = VisibleDisplayMoveSize.fullScreen.rawValue
    @EnvironmentObject private var controller: WindowLayoutController

    var body: some View {
        Form {
            Section {
                Toggle("Adjust other windows when snapping", isOn: $enabled)
                    .help("Arrange the selected normal windows beside the snapped window. The split may shift to fit app size limits.")
                Picker("Adjust", selection: $selection) {
                    ForEach(WindowLayoutSelection.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .pickerStyle(.menu)
                .disabled(!enabled)
                Text("The selected windows share the remaining area; Octopus can move the split so an app fits its minimum size. Corner snaps adjust companions only when at least two are selected.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Move to another display", selection: $moveSize) {
                    ForEach(VisibleDisplayMoveSize.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .pickerStyle(.menu)
                Text("Applies to free drops on another monitor’s visible Desktop. Full screen fills the area below the menu bar and above the Dock. Edge snaps and icon pairs use their chosen layout. Moving to an inactive Desktop always keeps the current size.")
                    .foregroundStyle(.secondary)
            }
            Section("Snap areas") {
                Text("Edges initially snap to a half. Hold the corner shortcut while dragging to snap to a quarter; configure it in Shortcuts. Without the shortcut, corners allow free movement. Adjustment keeps the chosen corner anchored while fitting app size limits.")
                Text("Dragging from another display adjusts a window on the destination Desktop. Other displays stay unchanged.")
                    .foregroundStyle(.secondary)
                Text("Drag one visible app icon onto another. Choose a side of the outlined icon to pair just those two windows. This explicit gesture also works when automatic adjustment is off.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Undo last adjustment") { controller.undoAdjustment() }
                    .disabled(!controller.canUndo)
                    .help("Undo a pair restores both unchanged windows on their original visible Desktops. Undo an edge layout restores the snapped window and companions if they have not changed.")
                if !controller.status.isEmpty { Text(controller.status).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
