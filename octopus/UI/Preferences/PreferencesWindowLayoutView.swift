import SwiftUI

struct PreferencesWindowLayoutView: View {
    @AppStorage(WindowLayoutSettings.enabledKey) private var enabled = true
    @AppStorage(WindowLayoutSettings.selectionKey) private var selection = WindowLayoutSelection.mostRecent.rawValue
    @EnvironmentObject private var controller: WindowLayoutController

    var body: some View {
        Form {
            Section {
                Toggle("Adjust other windows when snapping", isOn: $enabled)
                    .help("After an Octopus snap, place the selected other normal windows in the opposite half of that display and Desktop.")
                Picker("Adjust", selection: $selection) {
                    ForEach(WindowLayoutSelection.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .pickerStyle(.menu)
                .disabled(!enabled)
                Text("Snap a window left, right, top or bottom. The selected other windows share the opposite half on the destination display and Desktop.")
                    .foregroundStyle(.secondary)
            }
            Section("Snap areas") {
                Text("Left and right edges use half the display. The top edge uses the top half, and the bottom edge uses the bottom half. Corners allow free movement.")
                Text("Dragging from another display adjusts a window on the destination Desktop. Other displays stay unchanged.")
                    .foregroundStyle(.secondary)
                Text("Drag one visible app icon onto another. Choose a side of the outlined icon to pair just those two windows. This explicit gesture also works when automatic adjustment is off.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Undo last adjustment") { controller.undoAdjustment() }
                    .disabled(!controller.canUndo)
                    .help("Undo a pair restores both unchanged windows on their original visible Desktops. Undo an edge adjustment restores only its companions.")
                if !controller.status.isEmpty { Text(controller.status).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
