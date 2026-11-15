import AppKit

////////////////////
//// Fade a menu panel out, then order it out
/// A new presentation during the fade cancels it, so a quick reopen never loses
// the panel. The panel ignores clicks while it fades.

@MainActor
final class MenuPanelFader {
    private var generation = 0
    private(set) var isFading = false

    func fadeOut(_ panel: NSPanel, completion: @escaping () -> Void) {
        generation += 1
        let current = generation
        isFading = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MenuMotion.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.isFading = false
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.ignoresMouseEvents = false
                completion()
            }
        }
    }

    /// Call before showing the panel again.
    func cancel(_ panel: NSPanel) {
        generation += 1
        isFading = false
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
    }
}

//////////////////
