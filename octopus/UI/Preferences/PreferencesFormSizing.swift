import AppKit
import SwiftUI

enum PreferencesFormSizing {
    static func height(contentHeight: CGFloat, screenHeight: CGFloat,
                       windowHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        guard [contentHeight, screenHeight, windowHeight, viewportHeight].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        let outsideForm = max(0, windowHeight - viewportHeight)
        let available = max(1, screenHeight - outsideForm)
        return min(contentHeight.rounded(.up), max(1, available.rounded(.down)))
    }
}

// Place this behind the final form row. Its position measures the actual rendered
// content even when the scroll document stretches to fill a larger viewport.
struct PreferencesFormSizeReader: NSViewRepresentable {
    var onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> SizingView {
        let view = SizingView()
        view.onHeight = onHeight
        return view
    }

    func updateNSView(_ view: SizingView, context: Context) {
        view.onHeight = onHeight
        view.scheduleMeasurement()
    }

    static func dismantleNSView(_ view: SizingView, coordinator: ()) {
        view.detach()
    }

    final class SizingView: NSView {
        var onHeight: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var measurement: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleMeasurement() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleMeasurement() }
            })
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard window != nil, measurement == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.measurement = nil
                self.measure()
            }
            measurement = work
            DispatchQueue.main.async(execute: work)
        }

        private func measure() {
            guard let window, let screen = window.screen,
                  let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let row = convert(bounds, to: document)
            let bottom = document.isFlipped ? row.maxY - document.bounds.minY : document.bounds.maxY - row.minY
            // A small, intentional margin below the last control includes the group's rounded edge.
            let contentHeight = bottom + scroll.contentInsets.top + scroll.contentInsets.bottom + 16
            guard let height = PreferencesFormSizing.height(
                contentHeight: contentHeight, screenHeight: screen.visibleFrame.height,
                windowHeight: window.frame.height, viewportHeight: scroll.bounds.height
            ) else { return }
            onHeight?(height)
        }

        func detach() {
            measurement?.cancel()
            measurement = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }
    }
}
