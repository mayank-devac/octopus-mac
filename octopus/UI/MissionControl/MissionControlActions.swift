import AppKit

struct MissionControlSelection: Equatable {
    let screenID: String
    let desktopID: UInt64
    var windowID: SidebarWindowID? = nil
}

// Main-thread UI state is separate from native AX work so pointer and failure
// behaviour can be checked without changing the user's real desktops.
struct MissionControlSelectionState {
    private(set) var pressed = false
    private(set) var pending = false
    private(set) var suppressMissionControl = false

    mutating func begin() -> Bool {
        guard !pending else { return false }
        pending = true
        suppressMissionControl = true
        return true
    }

    mutating func press(_ pressed: Bool) { self.pressed = pressed }
    mutating func dismiss() {
        pressed = false
        suppressMissionControl = true
    }
    mutating func finish() { pending = false }
    mutating func observeMissionControl(_ visible: Bool) {
        if !pending && !visible { suppressMissionControl = false }
    }
    mutating func reset() { self = Self() }
}

struct MissionControlHoverLifetime {
    private enum Phase {
        case loading(until: TimeInterval)
        case tracking(departure: TimeInterval?)
    }
    private var phase = Phase.tracking(departure: nil)

    mutating func beginLoading(now: TimeInterval) { phase = .loading(until: now + 2) }

    mutating func didPresent() {
        if case .loading = phase { reset() }
    }

    mutating func update(inTrigger: Bool, inMap: Bool, pressed: Bool, now: TimeInterval) -> Bool {
        if case .loading(let deadline) = phase {
            if now < deadline { return false }
            reset()
        }
        if inTrigger || inMap || pressed { reset(); return false }
        guard case .tracking(let departure) = phase else { return false }
        guard let departure else {
            phase = .tracking(departure: now)
            return false
        }
        return now - departure >= 0.3
    }
    mutating func reset() { phase = .tracking(departure: nil) }
}

@MainActor
final class MissionControlActions {
    enum DesktopPress { case notReady, submitted, rejected }

    struct Environment {
        var isCurrent: () -> Bool
        var catalog: () async -> SidebarSpaceReader.Catalog?
        var reading: () async -> MissionControlReading
        var validateWindow: () async -> Bool
        var pressDesktop: () async -> DesktopPress
        var ensureVisible: () async -> MissionControlSystemLauncher.Result
        var ensureHidden: () async -> MissionControlSystemLauncher.Result
        var focusWindow: () async -> Bool
        var pause: () async -> Void = { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // Poll only for a bounded transition. A successful native request is not proof.
    static func perform(_ selection: MissionControlSelection, environment env: Environment) async -> Bool {
        func current() -> Bool { !Task.isCancelled && env.isCurrent() }
        func valid() async -> Bool {
            guard current(), let catalog = await env.catalog(),
                  catalog.desktops(on: selection.screenID).contains(where: { $0.id == selection.desktopID }),
                  current() else { return false }
            if selection.windowID == nil { return true }
            let valid = await env.validateWindow()
            return valid && current()
        }
        func wait(_ predicate: () async -> Bool) async -> Bool {
            for _ in 0..<24 {
                guard current() else { return false }
                if await predicate() { return current() }
                await env.pause()
            }
            return false
        }
        guard await valid() else { return false }
        let initial = await env.reading()
        guard current(), initial != .unavailable else { return false }
        var opened = false
        var succeeded = false
        guard let initialCatalog = await env.catalog(), current() else { return false }
        let active = initialCatalog.activeIDs.contains(selection.desktopID)
        if active {
            if initial == .hidden {
                succeeded = true
            } else if (await env.ensureHidden()).succeeded {
                succeeded = await wait {
                    guard let catalog = await env.catalog(), catalog.activeIDs.contains(selection.desktopID) else { return false }
                    return await env.reading() == .hidden
                }
            }
        } else {
            if initial == .hidden {
                let transition = await env.ensureVisible()
                opened = transition == .changed
                guard transition.succeeded, current() else { return false }
            }
            if await wait({ await env.reading() == .visible }), await valid() {
                // Resolve the target's current native control only after MC opens.
                var press = DesktopPress.notReady
                _ = await wait {
                    guard await valid(), current() else { press = .rejected; return true }
                    press = await env.pressDesktop()
                    return press != .notReady
                }
                if press == .submitted {
                    succeeded = await wait {
                        guard let catalog = await env.catalog(), catalog.activeIDs.contains(selection.desktopID) else { return false }
                        return await env.reading() == .hidden
                    }
                }
            }
        }
        if succeeded, await valid(), current(),
           await env.catalog()?.activeIDs.contains(selection.desktopID) == true, current() {
            if selection.windowID == nil { return true }
            if await env.focusWindow(), await valid(), current(),
               await env.catalog()?.activeIDs.contains(selection.desktopID) == true { return true }
        }
        // On failure, only clean up a Mission Control session we opened ourselves.
        // Do not dismiss UI after cancellation or after the user changed desktops.
        if opened, current(), let catalog = await env.catalog(),
           catalog.activeIDs == initialCatalog.activeIDs, catalog.desktops == initialCatalog.desktops,
           await env.reading() == .visible, current() {
            _ = await env.ensureHidden()
        }
        return false
    }

    private let native = MissionControlNativeActions()
    private let launcher = MissionControlSystemLauncher()
    private var task: Task<Void, Never>?
    var isPending: Bool { task != nil }
    private var cancellation: SidebarPendingAction?
    private var focusToken: SidebarPendingAction?

    func cancel() {
        task?.cancel()
        cancellation?.cancel()
        focusToken?.cancel()
    }

    func select(_ selection: MissionControlSelection, snapshot: MissionControlSnapshot,
                displayID: CGDirectDisplayID,
                isCurrent: @escaping () -> Bool,
                completion: @escaping (Bool) -> Void) {
        guard task == nil else { return }
        let token = SidebarPendingAction(frontmostPID: nil)
        cancellation = token
        let requirement = selection.windowID.flatMap { snapshot.focusRequirements[$0] }
        let window = snapshot.windows.first { $0.id == selection.windowID }
        let transition = MissionControlSystemLauncher.Environment(
            reading: { [native] in await native.read { MissionControlAXProbe.reading(deadline: native.deadline) } },
            isCurrent: { !token.isCancelled && isCurrent() && AXIsProcessTrusted() })
        let env = Environment(isCurrent: isCurrent,
            catalog: { [native] in await native.read { native.spaces.readCatalog() } },
            reading: { [native] in await native.read { MissionControlAXProbe.reading(deadline: native.deadline) } },
            validateWindow: { [native] in
                await native.read { native.validate(selection, window: window, requirement: requirement,
                                                     screens: snapshot.screens, token: token) }
            },
            pressDesktop: { [native] in
                await native.read {
                    guard !token.isCancelled, AXIsProcessTrusted(), CGDisplayIsOnline(displayID) != 0,
                          SidebarSettings.monitorID(displayID) == selection.screenID,
                          CGDisplayBounds(displayID) == snapshot.screens.first(where: { $0.id == selection.screenID })?.bounds,
                          let catalog = native.spaces.readCatalog() else { return .rejected }
                    guard let buttons = MissionControlAXProbe.selectionButtons(displayID: displayID, deadline: native.deadline) else { return .notReady }
                    guard let index = catalog.selectionIndex(screenID: selection.screenID, desktopID: selection.desktopID,
                                                             controlCount: buttons.count),
                          let fresh = native.spaces.readCatalog(),
                          fresh.desktops(on: selection.screenID) == catalog.desktops(on: selection.screenID),
                          !token.isCancelled, AXIsProcessTrusted() else { return .rejected }
                    if selection.windowID != nil,
                       !native.validate(selection, window: window, requirement: requirement,
                                        screens: snapshot.screens, token: token) { return .rejected }
                    guard !token.isCancelled, AXIsProcessTrusted(),
                          native.spaces.readCatalog()?.desktops(on: selection.screenID) == fresh.desktops(on: selection.screenID) else { return .rejected }
                    return AXUIElementPerformAction(buttons[index], kAXPressAction as CFString) == .success ? .submitted : .rejected
                }
            },
            ensureVisible: { [launcher] in await launcher.ensureVisible(environment: transition) },
            ensureHidden: { [launcher] in await launcher.ensureHidden(environment: transition) },
            focusWindow: { [weak self] in
                guard let self, let id = selection.windowID, let requirement, !token.isCancelled else { return false }
                let focus = SidebarPendingAction(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                focusTarget: id, focusRequirement: requirement)
                self.focusToken = focus
                defer { self.focusToken = nil }
                return await WindowPresentation.bringForward(id, requirement: requirement, token: focus,
                    queue: self.native.queue, canContinue: { !token.isCancelled && isCurrent() },
                    validate: {
                        self.native.validate(selection, window: window, requirement: requirement,
                                             screens: snapshot.screens, token: token)
                    })
            })
        task = Task { [weak self] in
            let success = await Self.perform(selection, environment: env)
            guard let self else { return }
            self.task = nil
            self.cancellation = nil
            completion(success)
        }
    }
}

private final class MissionControlNativeActions {
    let spaces = SidebarSpaceReader()
    let queue = DispatchQueue(label: "com.octopus.mission-control.actions", qos: .userInitiated)
    var deadline: TimeInterval { ProcessInfo.processInfo.systemUptime + 0.16 }

    func read<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    func validate(_ selection: MissionControlSelection, window: MissionControlSnapshot.Window?,
                  requirement: SidebarFocusRequirement?, screens: [MissionControlScreen], token: SidebarPendingAction) -> Bool {
        guard !token.isCancelled, AXIsProcessTrusted(), let id = selection.windowID, let window, let requirement,
              let launchDate = requirement.launchDate,
              let app = NSRunningApplication(processIdentifier: id.pid), app.activationPolicy == .regular,
              !app.isTerminated, app.launchDate == launchDate,
              id.pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let element = requirement.element
        AXUIElementSetMessagingTimeout(element, 0.04)
        var pid: pid_t = 0
        let minimized: Bool? = element.getAttributeValue(.minimized)
        guard AXUIElementGetPid(element, &pid) == .success, pid == id.pid,
              element.getWindowID() == id.windowID, minimized != nil,
              SidebarWindowPolicy.isTopLevelWindow(role: element.getAttributeValue(.role), subrole: element.getAttributeValue(.subrole)),
              let bounds = element.getWindowFrame(), MissionControlSnapshot.validBounds(bounds),
              let catalog = spaces.readCatalog(),
              let membership = spaces.read(windowIDs: [id.windowID], catalog: catalog.desktops)[id.windowID],
              Set(membership.map(\.id)) == window.desktopIDs,
              membership.contains(where: { $0.id == selection.desktopID }),
              SidebarWindowPolicy.displayIdentifier(desktops: membership, bounds: bounds,
                  displayFrames: Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.bounds) })) == selection.screenID,
              !token.isCancelled, AXIsProcessTrusted() else { return false }
        return true
    }
}
