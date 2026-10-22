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
    private(set) var departure: TimeInterval?
    mutating func update(inTrigger: Bool, inMap: Bool, pressed: Bool, now: TimeInterval) -> Bool {
        if inTrigger || inMap || pressed { departure = nil; return false }
        if departure == nil { departure = now }
        return now - (departure ?? now) >= 0.3
    }
    mutating func reset() { departure = nil }
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
        var toggle: () async -> Bool
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
        let active = await env.catalog()?.activeIDs.contains(selection.desktopID) == true
        guard current() else { return false }
        if active {
            if initial == .hidden {
                succeeded = true
            } else if await env.toggle() {
                succeeded = await wait {
                    guard let catalog = await env.catalog(), catalog.activeIDs.contains(selection.desktopID) else { return false }
                    return await env.reading() == .hidden
                }
            }
        } else {
            if initial == .hidden {
                opened = await env.toggle()
            }
            if (initial == .visible || opened), await wait({ await env.reading() == .visible }), await valid() {
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
        // Native cleanup is allowed after cancellation, but never after permission loss.
        if opened, env.isCurrent(), await env.reading() == .visible { _ = await env.toggle() }
        return false
    }

    private let native = MissionControlNativeActions()
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
                displayID: CGDirectDisplayID, isCurrent: @escaping () -> Bool,
                completion: @escaping (Bool) -> Void) {
        guard task == nil else { return }
        let token = SidebarPendingAction(frontmostPID: nil)
        cancellation = token
        let requirement = selection.windowID.flatMap { snapshot.focusRequirements[$0] }
        let window = snapshot.windows.first { $0.id == selection.windowID }
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
            toggle: { [native] in await native.read { AXIsProcessTrusted() && MissionControlAXProbe.toggle() } },
            focusWindow: { [weak self] in
                guard let self, let id = selection.windowID, let requirement, !token.isCancelled,
                      let app = NSRunningApplication(processIdentifier: id.pid), !app.isTerminated else { return false }
                let focus = SidebarPendingAction(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                focusTarget: id, focusRequirement: requirement)
                self.focusToken = focus
                defer { self.focusToken = nil }
                guard await self.native.read({
                    self.native.validate(selection, window: window, requirement: requirement, screens: snapshot.screens, token: token)
                }), !token.isCancelled, isCurrent() else { return false }
                let activated = await withCheckedContinuation { continuation in
                    let waiter = WindowForegroundActivationWaiter(targetPID: id.pid,
                        initialPID: focus.frontmostPID, center: NSWorkspace.shared.notificationCenter, timeout: 1,
                        canContinue: { !token.isCancelled && !focus.isCancelled && isCurrent() && !app.isTerminated },
                        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
                            continuation.resume(returning: $0)
                        }
                    waiter.start { SidebarFocusActivation.requestForeground(app, target: id, token: focus) }
                }
                guard activated else { return false }
                let expiresAt = ProcessInfo.processInfo.systemUptime + 0.8
                let raised = await self.native.read {
                    guard self.native.validate(selection, window: window, requirement: requirement, screens: snapshot.screens, token: token),
                          SidebarFocusActivation.raise(requirement.element, id: id, token: focus,
                                                       expiresAt: expiresAt) else { return false }
                    return true
                }
                guard raised else { return false }
                // One request and one raise; only read while exact focus settles.
                for _ in 0..<12 {
                    guard !token.isCancelled, isCurrent(), ProcessInfo.processInfo.systemUptime < expiresAt else { return false }
                    let confirmed = await self.native.read {
                        self.native.focused(id, requirement: requirement, app: app, token: token)
                    }
                    if confirmed { return true }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return false
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
    private let queue = DispatchQueue(label: "com.octopus.mission-control.actions", qos: .userInitiated)
    var deadline: TimeInterval { ProcessInfo.processInfo.systemUptime + 0.16 }

    func read<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    func focused(_ id: SidebarWindowID, requirement: SidebarFocusRequirement,
                 app: NSRunningApplication, token: SidebarPendingAction) -> Bool {
        guard !token.isCancelled, AXIsProcessTrusted(), !app.isTerminated, !app.isHidden,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid else { return false }
        let application = AXUIElementCreateApplication(id.pid)
        AXUIElementSetMessagingTimeout(application, 0.04)
        guard let focused: AXUIElement = application.getAttributeValue(.focusedWindow) else { return false }
        AXUIElementSetMessagingTimeout(focused, 0.04)
        return requirement.matches(element: focused, launchDate: app.launchDate) && focused.getWindowID() == id.windowID
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid && !token.isCancelled
    }

    func validate(_ selection: MissionControlSelection, window: MissionControlSnapshot.Window?,
                  requirement: SidebarFocusRequirement?, screens: [MissionControlScreen], token: SidebarPendingAction) -> Bool {
        guard !token.isCancelled, AXIsProcessTrusted(), let id = selection.windowID, let window, let requirement,
              let launchDate = requirement.launchDate,
              let app = NSRunningApplication(processIdentifier: id.pid), app.activationPolicy == .regular,
              !app.isTerminated, !app.isHidden, app.launchDate == launchDate,
              id.pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let element = requirement.element
        AXUIElementSetMessagingTimeout(element, 0.04)
        var pid: pid_t = 0
        let minimized: Bool? = element.getAttributeValue(.minimized)
        guard AXUIElementGetPid(element, &pid) == .success, pid == id.pid,
              element.getWindowID() == id.windowID, minimized == false,
              SidebarWindowPolicy.isTopLevelWindow(role: element.getAttributeValue(.role), subrole: element.getAttributeValue(.subrole)),
              let bounds = element.getWindowFrame(), bounds == window.bounds,
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
