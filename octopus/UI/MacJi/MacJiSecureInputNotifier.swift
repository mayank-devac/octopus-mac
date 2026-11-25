//
//  MacJiSecureInputNotifier.swift
//  octopus
//
//  Posts a notification when a background app holds Secure Input and so
//  silently blocks MacJi. Checked on app switches; each holder is reported once.
//

import AppKit
import UserNotifications

@MainActor
final class MacJiSecureInputNotifier {
    private var notifiedPID: pid_t?

    ////////////////////
    //// Check after an app switch
    /// The frontmost app holding Secure Input is normal (a password field in use),
    /// so only a holder in the background is reported.

    func check(frontmostPID: pid_t?) {
        guard let holder = MacJiSecureInput.holder() else {
            notifiedPID = nil
            return
        }
        guard holder.pid != frontmostPID, holder.pid != notifiedPID else { return }
        notifiedPID = holder.pid
        post(for: holder)
    }

    //// Clearing the holder re-arms the notification for the next time it happens.
    //////////////////

    private func post(for holder: MacJiSecureInputHolder) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "MacJi is paused"
            content.body = "\(holder.name) is blocking keyboard access. \(MacJiSecureInput.turnOffSteps(for: holder))"
            center.add(UNNotificationRequest(identifier: "macji.secureInput", content: content, trigger: nil))
        }
    }
}
