import AppKit

// Launch Services can open Apple's launcher, but only the AX observation proves
// the requested transition. Submitted launches cannot be cancelled by our task.
@MainActor
final class MissionControlSystemLauncher {
    enum Result: Equatable {
        case alreadySatisfied, changed, unavailable, launchFailed, timedOut, cancelled, disabled, busy

        var succeeded: Bool { self == .alreadySatisfied || self == .changed }
    }

    @MainActor struct Environment {
        var reading: () async -> MissionControlReading
        var isCurrent: () -> Bool
        var requestLaunch: (@escaping @MainActor (Bool) -> Void) -> Bool = MissionControlSystemLauncher.openApplication
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var pause: () async -> Void = { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private final class Receipt {
        var accepted = true
        var succeeded: Bool?
    }

    private(set) var automaticLaunchesDisabled = false
    private var pending = false

    func ensureVisible(environment: Environment) async -> Result {
        await ensure(.visible, environment: environment)
    }

    func ensureHidden(environment: Environment) async -> Result {
        await ensure(.hidden, environment: environment)
    }

    private func ensure(_ desired: MissionControlReading, environment env: Environment) async -> Result {
        func current() -> Bool { !Task.isCancelled && env.isCurrent() }
        guard current() else { return .cancelled }
        guard !pending else { return .busy }
        pending = true
        defer { pending = false }
        let deadline = env.now() + 2
        let initial = await env.reading()
        guard current() else { return .cancelled }
        if initial == desired { return .alreadySatisfied }
        guard initial != .unavailable else { return .unavailable }
        guard !automaticLaunchesDisabled else { return .disabled }
        guard env.now() < deadline else { return .timedOut }

        let receipt = Receipt()
        defer { receipt.accepted = false }
        // A late callback records nothing and can never issue another request.
        guard env.requestLaunch({ success in
            guard receipt.accepted, env.isCurrent(), env.now() < deadline else { return }
            receipt.succeeded = success
        }) else {
            automaticLaunchesDisabled = true
            return .launchFailed
        }
        while current(), env.now() < deadline {
            if receipt.succeeded == false {
                automaticLaunchesDisabled = true
                return .launchFailed
            }
            let observed = await env.reading()
            guard current(), env.now() < deadline else { break }
            if receipt.succeeded == true, observed == desired { return .changed }
            if observed == .unavailable {
                automaticLaunchesDisabled = true
                return .unavailable
            }
            await env.pause()
        }
        // Even cancellation can leave a submitted launch in flight. Never retry
        // automatically in this session, since a late launch could reverse it.
        automaticLaunchesDisabled = true
        return current() ? .timedOut : .cancelled
    }

    private static func openApplication(completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app", isDirectory: true)
        guard Bundle(url: url)?.bundleIdentifier == "com.apple.exposelauncher" else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            let succeeded = application != nil && error == nil
            Task { @MainActor in completion(succeeded) }
        }
        return true
    }
}
