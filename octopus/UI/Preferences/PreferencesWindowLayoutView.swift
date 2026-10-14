import SwiftUI

struct PreferencesWindowLayoutView: View {
    @AppStorage(WindowLayoutSettings.modeKey) private var mode = WindowSnapMode.legacy.rawValue
    @AppStorage(WindowLayoutSettings.enabledKey) private var enabled = true
    @AppStorage(WindowLayoutSettings.selectionKey) private var selection = WindowLayoutSelection.mostRecent.rawValue
    @AppStorage(WindowLayoutSettings.maximumWindowsKey) private var maximumWindows = WindowLayoutSettings.defaultMaximumWindows
    @AppStorage(WindowLayoutSettings.moveSizeKey) private var moveSize = VisibleDisplayMoveSize.fullScreen.rawValue
    @EnvironmentObject private var controller: WindowLayoutController

    var body: some View {
        Form {
            Section {
                Picker("Snap behaviour", selection: $mode) {
                    ForEach(WindowSnapMode.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .pickerStyle(.menu)
                Text(mode == WindowSnapMode.current.rawValue
                    ? "Current shows the selected layout before release and requests each window size once. If an app refuses, its accepted size stays and further adjustment stops."
                    : "Legacy shows the dragged window’s target, then adjusts the other windows after release. It can retry resizing and shift the layout to fit app limits.")
                    .foregroundStyle(.secondary)
                Toggle("Adjust windows when snapping", isOn: $enabled)
                    .help("Arrange the selected normal windows beside the snapped window. The split may shift to fit app size limits.")
                Picker("Adjust", selection: $selection) {
                    ForEach(WindowLayoutSelection.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .pickerStyle(.menu)
                .disabled(!enabled)
                if selection == WindowLayoutSelection.allNormal.rawValue {
                    Stepper("Maximum windows per snap: \(WindowLayoutSettings.normalizedMaximumWindows(maximumWindows))",
                            value: $maximumWindows, in: WindowLayoutSettings.maximumWindowsRange)
                        .disabled(!enabled)
                    Text("Includes the snapped window, the window you were using before the snap, then other recently used windows on this display and Desktop. Older windows stay in place and may be covered by the selected layout.")
                        .foregroundStyle(.secondary)
                }
                Text("Dragging shows a preview; windows resize after you release. The selected windows share the remaining area; Octopus can move the split so an app fits its minimum size. Corner snaps adjust companions only when at least two are selected.")
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
                    .help(mode == WindowSnapMode.current.rawValue
                        ? "Undo restores verified companions and keeps the dragged window snapped. Undo a pair restores both unchanged windows on their original visible Desktops."
                        : "Undo an edge layout restores the snapped window and companions if they have not changed. Undo a pair restores both unchanged windows on their original visible Desktops.")
                if !controller.status.isEmpty { Text(controller.status).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
