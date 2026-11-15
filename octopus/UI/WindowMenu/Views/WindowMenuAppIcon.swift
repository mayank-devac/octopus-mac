import SwiftUI

/// App icon for running and not-running apps, with a generic fallback.
struct WindowMenuAppIcon: View {
    let pid: pid_t?
    let bundleURL: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = AppIconCache.icon(pid: pid, bundleURL: bundleURL) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.fill").resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
