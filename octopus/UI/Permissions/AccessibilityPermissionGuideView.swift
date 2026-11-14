//
//  AccessibilityPermissionGuideView.swift
//  octopus
//
//  Compact drag-to-allow panel shown next to System Settings → Accessibility.
//

import SwiftUI
import AppKit

struct AccessibilityPermissionGuideView: View {
    var onClose: () -> Void

    private enum ResetState { case idle, running, done, failed }

    private let appURL = Bundle.main.bundleURL
    private let appName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    @State private var resetState = ResetState.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dragChip

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drag \(appName) into the Accessibility list")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Then switch it on to allow access.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.leading, 6)

            resetRow
                .padding(.leading, 6)
        }
        .padding(14)
        .frame(width: 340, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    ////////////////////
    //// Drag chip
    /// The whole chip is the drag handle, so it reads as one obvious target.
    // Dropping the .app bundle's file URL mirrors a Finder drag, which the Accessibility list accepts.

    private var dragChip: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
                .padding(4)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(appName)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .padding(.trailing, 6)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrag { NSItemProvider(object: appURL as NSURL) }
        .help("Drag \(appName) into the Accessibility list")
    }

    //// Keep the chip visually dominant over the instructions below it.
    //////////////////

    ////////////////////
    //// Reset row
    /// Lets the user clear an old entry that shows as "on" but no longer works.
    // Every state is one short line so the panel keeps the height it was created with.
    // The button is replaced while the reset runs, so it cannot be started twice.

    @ViewBuilder
    private var resetRow: some View {
        Group {
            switch resetState {
            case .idle:
                HStack(spacing: 4) {
                    Text("Already in the list but not working?")
                        .foregroundStyle(.secondary)
                    Button("Reset", action: startReset)
                        .buttonStyle(.link)
                }
            case .running:
                Text("Resetting…")
                    .foregroundStyle(.secondary)
            case .done:
                Text("Reset done. Drag \(appName) in again.")
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Reset failed. Remove it with the − button.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func startReset() {
        resetState = .running
        Task {
            resetState = await AccessibilityGrantReset.reset() ? .done : .failed
        }
    }

    //// The reset only runs from this button, never automatically.
    //////////////////
}
