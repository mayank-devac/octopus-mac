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
            Section("Window layout") {
                Picker("Snap behaviour", selection: $mode) {
                    ForEach(WindowSnapMode.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .pickerStyle(.menu)
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
                }
            }
            Section("Display moves") {
                Picker("Move to another display", selection: $moveSize) {
                    ForEach(VisibleDisplayMoveSize.allCases, id: \.rawValue) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .pickerStyle(.menu)
            }
            Section("Undo") {
                Button("Undo last adjustment") { controller.undoAdjustment() }
                    .disabled(!controller.canUndo)
                    .help(mode == WindowSnapMode.current.rawValue
                        ? "Undo restores verified companions and keeps the dragged window snapped. Undo a pair restores both unchanged windows on their original visible Desktops."
                        : "Undo an edge layout restores the snapped window and companions if they have not changed. Undo a pair restores both unchanged windows on their original visible Desktops.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
