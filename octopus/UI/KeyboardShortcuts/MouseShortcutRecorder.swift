import AppKit
import SwiftUI

// Capture only on this control, so recording never intercepts another app's clicks.
struct MouseShortcutRecorder: NSViewRepresentable {
    var isRecording: Bool
    var onBegin: () -> Void
    var onRecord: (MouseShortcut) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.beginRecording)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.isRecording = isRecording
        button.title = isRecording ? "Click a mouse button" : "Record"
        button.onBegin = onBegin
        button.onRecord = onRecord
        button.onCancel = onCancel
        button.toolTip = "Click Record, then click this button with the mouse button you want. You can hold modifier keys. Escape cancels."
        button.setAccessibilityLabel(isRecording ? "Click a mouse button to record. Escape cancels." : "Record mouse shortcut")
        if isRecording { button.window?.makeFirstResponder(button) }
    }

    final class RecorderButton: NSButton {
        var isRecording = false
        var onBegin: (() -> Void)?
        var onRecord: ((MouseShortcut) -> Void)?
        var onCancel: (() -> Void)?

        @objc func beginRecording() {
            isRecording = true
            window?.makeFirstResponder(self)
            onBegin?()
        }
        private func record(_ event: NSEvent) {
            let shortcut = MouseShortcut(button: event.buttonNumber, modifiers: event.modifierFlags)
            if shortcut.isValid {
                isRecording = false
                onRecord?(shortcut)
            }
        }
        override func mouseDown(with event: NSEvent) {
            if isRecording { record(event) } else { super.mouseDown(with: event) }
        }
        override func rightMouseDown(with event: NSEvent) {
            if isRecording { record(event) } else { super.rightMouseDown(with: event) }
        }
        override func otherMouseDown(with event: NSEvent) {
            if isRecording { record(event) } else { super.otherMouseDown(with: event) }
        }
        override func keyDown(with event: NSEvent) {
            if isRecording && event.keyCode == 53 { isRecording = false; onCancel?() }
            else { super.keyDown(with: event) }
        }
        override func resignFirstResponder() -> Bool {
            if isRecording { isRecording = false; onCancel?() }
            return super.resignFirstResponder()
        }
    }
}
