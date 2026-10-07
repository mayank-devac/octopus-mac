import AppKit
import Combine

struct SidebarWindowID: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

struct SidebarEntry: Identifiable {
    let pid: pid_t
    let application: Application
    let windows: [Window]
    let preferredID: SidebarWindowID?
    var focusedID: SidebarWindowID? = nil
    var isHidden = false
    var windowStates: [CGWindowID: SidebarWindowState] = [:]
    var desktop: SidebarDesktop? = nil
    var hasOtherWindows = false
    var id: SidebarEntryID { SidebarEntryID(pid: pid, desktopID: desktop?.id) }

    var visibleIDs: Set<SidebarWindowID> {
        guard !isHidden else { return [] }
        return Set(windows.compactMap { window in
            guard let id = window.cgWindowID, windowStates[id]?.isMinimized != true,
                  windowStates[id]?.isOnScreen != false else { return nil }
            return SidebarWindowID(pid: self.pid, windowID: id)
        })
    }

    var preferredWindow: Window? {
        guard let preferredID else { return nil }
        return windows.first { $0.cgWindowID == preferredID.windowID }
    }
}

struct SidebarWindowState: Equatable {
    let isMinimized: Bool
    let canMinimize: Bool
    var isOnScreen = true
    var desktops: [SidebarDesktop] = []
    var desktopLabel: String? = nil
    var displayIdentifier: String? = nil
}

enum SidebarWindowAction: Equatable {
    case activateApp(pid_t)
    case focus(SidebarWindowID)
    case minimize(SidebarWindowID, requireFocused: Bool)
    case hide(SidebarWindowID)
    case place(SidebarWindowID, SidebarPlacementRequest)

    var target: SidebarWindowID? {
        switch self {
        case .activateApp: return nil
        case .focus(let id), .minimize(let id, _), .hide(let id), .place(let id, _): return id
        }
    }

    var processIdentifier: pid_t {
        switch self {
        case .activateApp(let pid): return pid
        case .focus(let id), .minimize(let id, _), .hide(let id), .place(let id, _): return id.pid
        }
    }
}

enum SidebarIconClickPolicy {
    static func action(for entry: SidebarEntry, frontmostPID: pid_t?,
                       setting: SidebarActiveAppClickAction) -> SidebarWindowAction? {
        guard let preferred = entry.preferredID else { return .activateApp(entry.pid) }
        // The app can remain active with every window minimised. Restore before toggling.
        guard !entry.isHidden, !entry.visibleIDs.isEmpty else { return .focus(preferred) }
        guard frontmostPID == entry.pid, setting != .none else { return .focus(preferred) }
        if setting == .hide { return .hide(preferred) }
        guard let focused = entry.focusedID, entry.visibleIDs.contains(focused) else { return nil }
        return .minimize(focused, requireFocused: true)
    }
}

// Main-thread cancellation must be visible even while the AX queue is blocked in another app.
final class SidebarPendingAction: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var focusStarted = false
    let frontmostPID: pid_t?

    init(frontmostPID: pid_t?) { self.frontmostPID = frontmostPID }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // A validated focus can itself trigger a Space change while AX is still returning.
    func beginFocus() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        focusStarted = true
        return true
    }

    var hasStartedFocus: Bool {
        lock.lock()
        defer { lock.unlock() }
        return focusStarted
    }

    var isCurrent: Bool {
        !isCancelled && AXIsProcessTrusted()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID
    }

    func canFinishFocus(on pid: pid_t) -> Bool {
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return !isCancelled && AXIsProcessTrusted() && (currentPID == frontmostPID || currentPID == pid)
    }
}

enum SidebarFocusActivation {
    static func canRequestAfterRaise(_ error: AXError) -> Bool {
        error != .invalidUIElement && error != .apiDisabled
    }

    static func request(canContinue: () -> Bool, yieldActivation: () -> Void, activate: () -> Bool) -> Bool {
        guard canContinue() else { return false }
        yieldActivation()
        guard canContinue() else { return false }
        return activate()
    }

    // Prefer the exact window over app-wide activation. Acceptance alone does not
    // confirm a Space transition or that the requested window became focused.
    static func activate(target: SidebarWindowID?, focusWindow: (SidebarWindowID) -> Bool,
                         activateApp: (NSApplication.ActivationOptions) -> Bool) -> Bool {
        // No target window: macOS chooses the Space either way.
        guard let target else { return activateApp([.activateAllWindows]) }
        return focusWindow(target) || activateApp([])
    }
}

enum SidebarWindowPolicy {
    static func displayIdentifier(desktops: [SidebarDesktop], bounds: CGRect?,
                                  displayFrames: [String: CGRect]) -> String? {
        let members = Set(desktops.compactMap(\.displayIdentifier).filter { displayFrames[$0] != nil })
        // Space membership remains useful when hidden/minimised windows have stale bounds.
        if members.count == 1 { return members.first }
        guard let bounds, !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite else { return nil }
        let candidates = displayFrames.filter { members.isEmpty || members.contains($0.key) }
        var selected: String?
        var largestArea: CGFloat = 0
        for (id, frame) in candidates.sorted(by: { $0.key < $1.key }) {
            let overlap = frame.intersection(bounds)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > largestArea {
                selected = id
                largestArea = area
            }
        }
        return selected
    }

    static func isEligible(onScreen: Bool, normalLevel: Bool, standardWindow: Bool,
                           minimized: Bool, hidden: Bool, ownProcess: Bool,
                           previouslyListed: Bool = false,
                           scope: SidebarDesktopScope = .visibleDesktops) -> Bool {
        // CG visibility and AXMinimized do not change atomically during Dock animations.
        // Visible-desktop mode keeps a live window until it closes or the desktop changes.
        (scope == .allDesktops || onScreen || minimized || hidden || previouslyListed)
            && normalLevel && standardWindow && !ownProcess
    }

    static func isTopLevelWindow(role: String?, subrole: String?) -> Bool {
        guard role == (kAXWindowRole as String) else {
            return false
        }
        // Some applications omit AXSubrole or report AXUnknown for a normal top-level window.
        return subrole == nil || subrole == "" || subrole == "AXUnknown"
            || subrole == (kAXStandardWindowSubrole as String)
    }

    static func canMinimize(standardWindow: Bool, fullScreen: Bool, modal: Bool,
                            hasSheets: Bool, settable: Bool) -> Bool {
        standardWindow && !fullScreen && !modal && !hasSheets && settable
    }

    static func normalizedWindowTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func needsBrowserHelperCheck(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.brave.Browser" || bundleIdentifier == "com.google.Chrome"
    }

    static func isBrowserHelper(title: String?, applicationTitle: String, subrole: String?,
                                hasCloseButton: Bool?, parentIsWindow: Bool,
                                bounds: CGRect?, minimized: Bool) -> Bool {
        // Real browser windows have their own close control. A failed control query
        // is unknown, not evidence of a helper; keep that window until a later scan.
        guard hasCloseButton == false else { return false }
        if parentIsWindow { return true }
        if title == nil, !minimized, let bounds, bounds.width <= 1 || bounds.height <= 1 { return true }
        // An app-name/empty title alone is insufficient: genuine untitled windows
        // with window controls pass above. Toolbar/backing surfaces have neither.
        if let title {
            let name = normalizedWindowTitle(title)
            if name.isEmpty || name == normalizedWindowTitle(applicationTitle) { return true }
        }
        return subrole == nil || subrole == "" || subrole == "AXUnknown"
    }

    static func preferredID(_ ids: [SidebarWindowID], recency: [SidebarWindowID: UInt64],
                            focused: SidebarWindowID?, states: [CGWindowID: SidebarWindowState] = [:],
                            hidden: Bool = false) -> SidebarWindowID? {
        let unminimized = hidden ? [] : ids.filter { states[$0.windowID]?.isMinimized != true }
        let visible = unminimized.filter { states[$0.windowID]?.isOnScreen != false }
        // Prefer this desktop before considering another Space or a minimised window.
        let candidates = !visible.isEmpty ? visible : (unminimized.isEmpty ? ids : unminimized)
        if let recent = candidates.filter({ recency[$0] != nil }).max(by: { recency[$0]! < recency[$1]! }) {
            return recent
        }
        if let focused, candidates.contains(focused) { return focused }
        return candidates.first
    }
}

@MainActor
final class SidebarWindowInventory: ObservableObject {
    @Published private(set) var entries: [SidebarEntry] = []
    @Published private(set) var hasPermission = AXIsProcessTrusted()
    @Published private(set) var fullScreenDisplays: Set<CGDirectDisplayID> = []
    @Published private(set) var desktops: [SidebarDesktop] = []
    @Published private(set) var canTransferDesktops = false
    private(set) var desktopScope = SidebarDesktopScope.allDesktops
    private var displayIdentifier: String?
    var onChange: (() -> Void)?
    var onDesktopChange: (() -> Void)?
    var onPlacementResult: ((SidebarPlacementResult) -> Void)?
    var onDesktopTransferResult: ((String?) -> Void)?

    private lazy var reader = SidebarWindowReader(onChange: { [weak self] in
        DispatchQueue.main.async { self?.refresh() }
    })
    private var notifications: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var presentationObserver: NSKeyValueObservation?
    private var pendingRefresh: DispatchWorkItem?
    private var discoveryRefresh: DispatchWorkItem?
    private var refreshRequested = false
    private var generation = 0
    private var desktopGeneration = 0
    private var running = false
    private var refreshCompletions: [() -> Void] = []
    private var pendingActions: [pid_t: SidebarPendingAction] = [:]
    private var pendingDesktopTransfer: SidebarPendingAction?
    private struct ForegroundFocus {
        let id: SidebarWindowID
        let token: SidebarPendingAction
        let expiresAt: TimeInterval
    }
    private var foregroundFocus: [pid_t: ForegroundFocus] = [:]

    var separatorIndices: Set<Int> {
        Self.separatorIndices(entries: entries, scope: desktopScope)
    }

    static func separatorIndices(entries: [SidebarEntry], scope: SidebarDesktopScope) -> Set<Int> {
        guard scope == .allDesktops else { return [] }
        return Set(entries.indices.dropFirst().filter { entries[$0 - 1].desktop?.id != entries[$0].desktop?.id })
    }

    // AX's window list can be empty when an app's windows are all on other Spaces.
    // App visibility in All desktops must therefore come from the running-app list.
    static func entries(for applications: [NSRunningApplication], windowEntries: [SidebarEntry],
                        scope: SidebarDesktopScope, displayIdentifier: String? = nil) -> [SidebarEntry] {
        let windowEntries = displayIdentifier.map { displayID in
            windowEntries.compactMap { entry -> SidebarEntry? in
                let windows = entry.windows.filter { window in
                    guard let id = window.cgWindowID, let state = entry.windowStates[id] else { return false }
                    return state.displayIdentifier == displayID
                }
                guard !windows.isEmpty else { return nil }
                var filtered = projectedEntry(entry, windows: windows, desktop: entry.desktop,
                                              hasOtherWindows: entry.hasOtherWindows)
                for id in Array(filtered.windowStates.keys) {
                    guard var state = filtered.windowStates[id] else { continue }
                    state.desktops.removeAll {
                        $0.displayIdentifier != displayID && $0.displayIdentifier != "Main" && $0.displayIdentifier != nil
                    }
                    state.desktopLabel = state.desktops.first?.windowPrefix
                    filtered.windowStates[id] = state
                }
                return filtered
            }
        } ?? windowEntries
        let result: [SidebarEntry]
        if scope == .allDesktops {
            let byPID = Dictionary(uniqueKeysWithValues: windowEntries.map { ($0.pid, $0) })
            let apps = applications.filter { !$0.isTerminated }.compactMap { running -> SidebarEntry? in
                if let entry = byPID[running.processIdentifier], !entry.windows.isEmpty { return entry }
                // An app without windows has no display to assign it to.
                guard displayIdentifier == nil else { return nil }
                // Finder stays running to draw the desktop even with no Finder windows.
                // Keep real window entries above, including hidden/minimised ones.
                guard running.bundleIdentifier != "com.apple.finder" else { return nil }
                return SidebarEntry(
                    pid: running.processIdentifier, application: Application(running), windows: [],
                    preferredID: nil, isHidden: running.isHidden)
            }
            result = apps.flatMap { groups(for: $0) }
        } else {
            result = windowEntries.filter { $0.application.runningApplication?.isTerminated != true }
        }
        return result.sorted {
            if scope == .allDesktops {
                let left = $0.desktop?.order ?? Int.max
                let right = $1.desktop?.order ?? Int.max
                if left != right { return left < right }
            }
            let comparison = $0.application.title.localizedCaseInsensitiveCompare($1.application.title)
            return comparison == .orderedSame ? $0.pid < $1.pid : comparison == .orderedAscending
        }
    }

    private static func groups(for entry: SidebarEntry) -> [SidebarEntry] {
        guard !entry.windows.isEmpty else { return [entry] }
        var groups: [SidebarDesktop: [Window]] = [:]
        var unknown: [Window] = []
        for window in entry.windows {
            let desktops = window.cgWindowID.flatMap { entry.windowStates[$0]?.desktops } ?? []
            if desktops.isEmpty { unknown.append(window) }
            for desktop in desktops { groups[desktop, default: []].append(window) }
        }
        var result = groups.map { projectedEntry(entry, windows: $0.value, desktop: $0.key,
                                                hasOtherWindows: entry.windows.count > $0.value.count) }
        if !unknown.isEmpty {
            result.append(projectedEntry(entry, windows: unknown, desktop: nil,
                                         hasOtherWindows: entry.windows.count > unknown.count))
        }
        return result
    }

    private static func projectedEntry(_ entry: SidebarEntry, windows: [Window], desktop: SidebarDesktop?,
                                       hasOtherWindows: Bool) -> SidebarEntry {
        let ids = windows.compactMap { $0.cgWindowID.map { SidebarWindowID(pid: entry.pid, windowID: $0) } }
        let windowIDs = Set(ids.map(\.windowID))
        var states = entry.windowStates.filter { windowIDs.contains($0.key) }
        for id in Array(states.keys) { states[id]?.desktopLabel = desktop?.windowPrefix }
        let history = entry.preferredID.map { [$0: UInt64(1)] } ?? [:]
        let preferred = SidebarWindowPolicy.preferredID(ids, recency: history, focused: entry.focusedID,
                                                        states: states, hidden: entry.isHidden)
        return SidebarEntry(pid: entry.pid, application: entry.application, windows: windows,
            preferredID: preferred, focusedID: ids.contains(where: { $0 == entry.focusedID }) ? entry.focusedID : nil,
            isHidden: entry.isHidden, windowStates: states, desktop: desktop, hasOtherWindows: hasOtherWindows)
    }

    func setDesktopScope(_ scope: SidebarDesktopScope, displayIdentifier: String? = nil) {
        guard desktopScope != scope || self.displayIdentifier != displayIdentifier else { return }
        cancelActions()
        desktopScope = scope
        self.displayIdentifier = displayIdentifier
        desktopGeneration += 1
        entries = []
        refresh()
    }

    func start() {
        guard !running else { return }
        running = true
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self else { return }
                    if note.name == NSWorkspace.activeSpaceDidChangeNotification {
                        self.cancelActions(preservingStartedFocus: self.desktopScope == .allDesktops)
                        self.desktopGeneration += 1
                        if self.desktopScope == .visibleDesktops { self.entries = [] }
                        self.onDesktopChange?()
                    }
                    if note.name == NSWorkspace.didActivateApplicationNotification,
                       let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                        self.finishForegroundFocus(pid)
                    }
                    self.refresh()
                }
            })
        }
        refresh()
    }

    func stop() {
        cancelActions()
        running = false
        generation += 1
        pendingRefresh?.cancel()
        pendingRefresh = nil
        discoveryRefresh?.cancel()
        discoveryRefresh = nil
        refreshRequested = false
        refreshCompletions.removeAll()
        notifications.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notifications.removeAll()
        permissionTimer?.invalidate()
        permissionTimer = nil
        presentationObserver = nil
        reader.queue.async { [reader] in reader.removeObservers() }
        entries = []
        desktops = []
        canTransferDesktops = false
        fullScreenDisplays = []
    }

    func refresh(completion: (() -> Void)? = nil) {
        guard running else { return }
        discoveryRefresh?.cancel()
        discoveryRefresh = nil
        if let completion { refreshCompletions.append(completion) }
        // Let the active scan finish. Any number of new events need only one follow-up.
        guard pendingRefresh == nil else {
            refreshRequested = true
            return
        }
        startRefresh()
    }

    private func startRefresh() {
        generation += 1
        let request = generation
        let desktop = desktopGeneration
        let scope = desktopScope
        let displayIdentifier = self.displayIdentifier
        // Requests made during this scan keep their completions for the next scan.
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let fullScreenPID = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        let work = DispatchWorkItem { [weak self, reader] in
            let snapshot = reader.read(applications, systemFullScreenPID: fullScreenPID,
                                       desktop: desktop, scope: scope)
            DispatchQueue.main.async {
                guard let self, self.running, request == self.generation else { return }
                if desktop == self.desktopGeneration {
                    self.hasPermission = snapshot.hasPermission
                    self.entries = Self.entries(for: applications, windowEntries: snapshot.entries, scope: scope,
                                                displayIdentifier: displayIdentifier)
                    self.fullScreenDisplays = snapshot.fullScreenDisplays
                    self.desktops = snapshot.desktops.filter {
                        displayIdentifier == nil || $0.displayIdentifier == displayIdentifier
                            || $0.displayIdentifier == "Main" || $0.displayIdentifier == nil
                    }
                    self.canTransferDesktops = snapshot.canTransferDesktops
                    self.updatePermissionTimer()
                    if snapshot.needsWindowDiscovery {
                        self.scheduleDiscoveryRefresh()
                    } else {
                        self.discoveryRefresh?.cancel()
                        self.discoveryRefresh = nil
                    }
                    self.onChange?()
                    for completion in completions {
                        guard self.running, request == self.generation else { return }
                        completion()
                    }
                } else {
                    // Never repopulate a newly selected desktop with the old one's windows.
                    self.refreshCompletions.insert(contentsOf: completions, at: 0)
                    self.refreshRequested = true
                }
                guard self.running, request == self.generation else { return }
                self.pendingRefresh = nil
                let refreshAgain = self.refreshRequested
                self.refreshRequested = false
                if refreshAgain { self.startRefresh() }
            }
        }
        pendingRefresh = work
        reader.queue.async(execute: work)
    }

    // Sidebar actions never use Window.focus(), whose keyboard fallback reopens apps.
    func focus(_ id: SidebarWindowID) {
        perform(.focus(id))
    }

    func preparePlacement(_ id: SidebarWindowID, completion: @escaping (SidebarPlacementTarget?) -> Void) {
        guard running, hasPermission, pendingActions[id.pid] == nil else { completion(nil); return }
        let desktop = desktopGeneration
        reader.queue.async { [weak self, reader] in
            let target = reader.placementTarget(id, desktop: desktop)
            DispatchQueue.main.async {
                guard let self, self.running, self.hasPermission, desktop == self.desktopGeneration else {
                    completion(nil); return
                }
                completion(target)
            }
        }
    }

    func prepareDrag(_ id: SidebarWindowID, allowDesktopTransfer: Bool,
                     completion: @escaping (SidebarPlacementTarget?, SidebarDesktopTransferTarget?) -> Void) {
        guard running, hasPermission, pendingActions[id.pid] == nil else { completion(nil, nil); return }
        let desktop = desktopGeneration
        let transferAvailable = allowDesktopTransfer && pendingDesktopTransfer == nil && canTransferDesktops
        reader.queue.async { [weak self, reader] in
            let placement = reader.placementTarget(id, desktop: desktop)
            let transfer = transferAvailable ? reader.desktopTransferTarget(id, desktop: desktop) : nil
            DispatchQueue.main.async {
                guard let self, self.running, self.hasPermission, desktop == self.desktopGeneration else {
                    completion(nil, nil); return
                }
                completion(placement, transfer)
            }
        }
    }

    // This action intentionally has no route into requestForeground or placement.
    func moveToDesktop(_ id: SidebarWindowID, to destination: SidebarDesktop) {
        prepareDrag(id, allowDesktopTransfer: true) { [weak self] _, target in
            guard let self else { return }
            guard let target else {
                self.onDesktopTransferResult?("Desktop transfer is unavailable for this window."); return
            }
            self.moveToDesktop(id, request: SidebarDesktopTransferRequest(sourceDesktop: target.sourceDesktop,
                destinationDesktop: destination, desktopGeneration: target.desktopGeneration))
        }
    }

    func moveToDesktop(_ id: SidebarWindowID, request: SidebarDesktopTransferRequest) {
        guard running, hasPermission, canTransferDesktops, pendingActions[id.pid] == nil,
              pendingDesktopTransfer == nil, request.desktopGeneration == desktopGeneration else {
            onDesktopTransferResult?("Desktop transfer is unavailable or busy."); return
        }
        let token = SidebarPendingAction(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        pendingActions[id.pid] = token
        pendingDesktopTransfer = token
        reader.queue.async { [weak self, reader] in
            let failure = reader.submitDesktopTransfer(id, request: request, token: token)
            DispatchQueue.main.async {
                guard let self, self.running, self.pendingActions[id.pid] === token else { return }
                if let failure {
                    self.finishDesktopTransfer(id, token: token, message: failure)
                } else {
                    self.verifyDesktopTransfer(id, request: request, token: token,
                        deadline: ProcessInfo.processInfo.systemUptime + 2)
                }
            }
        }
    }

    private func verifyDesktopTransfer(_ id: SidebarWindowID, request: SidebarDesktopTransferRequest,
                                       token: SidebarPendingAction, deadline: TimeInterval) {
        guard running, !token.isCancelled, pendingActions[id.pid] === token else { return }
        reader.queue.async { [weak self, reader] in
            let membership = reader.desktopTransferMembership(id)
            DispatchQueue.main.async {
                guard let self, self.running, !token.isCancelled, self.pendingActions[id.pid] === token else { return }
                let result = SidebarDesktopTransferPolicy.verify(membership: membership ?? [],
                    destinationID: request.destinationDesktop.id,
                    expired: membership == nil || ProcessInfo.processInfo.systemUptime >= deadline)
                switch result {
                case .moved: self.finishDesktopTransfer(id, token: token, message: nil)
                case .unconfirmed:
                    self.finishDesktopTransfer(id, token: token, message: "Couldn’t confirm the desktop move. Check the window’s location.")
                case .pending:
                    // Retry observations only. Never submit the move a second time.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        self?.verifyDesktopTransfer(id, request: request, token: token, deadline: deadline)
                    }
                }
            }
        }
    }

    private func finishDesktopTransfer(_ id: SidebarWindowID, token: SidebarPendingAction, message: String?) {
        if pendingDesktopTransfer === token { pendingDesktopTransfer = nil }
        onDesktopTransferResult?(message)
        refreshAndUnlock(id.pid, token: token)
    }

    func perform(_ action: SidebarWindowAction, frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier) {
        let pid = action.processIdentifier
        guard running, hasPermission, pendingActions[pid] == nil else {
            if case .place = action { onPlacementResult?(.failed("Window control is unavailable or busy.")) }
            return
        }
        let token = SidebarPendingAction(frontmostPID: frontmostPID)
        pendingActions[pid] = token
        let application = entries.first(where: { $0.pid == pid })?.application.runningApplication
        let desktop = desktopGeneration
        let systemFullScreenPID = NSApp.currentSystemPresentationOptions.contains(.fullScreen) ? frontmostPID : nil
        reader.queue.async { [weak self, reader] in
            let result = reader.perform(action, desktop: desktop, token: token,
                                        systemFullScreenPID: systemFullScreenPID, application: application)
            DispatchQueue.main.async {
                guard let self, self.running, !token.isCancelled,
                      desktop == self.desktopGeneration
                        || (self.desktopScope == .allDesktops && token.hasStartedFocus) else { return }
                switch result {
                case .activate(let application):
                    if token.canFinishFocus(on: pid), !application.isTerminated {
                        self.requestForeground(application, target: action.target, token: token)
                        return
                    }
                case .placement(let result, let application):
                    self.onPlacementResult?(result)
                    if case .placed = result, let application, token.canFinishFocus(on: pid), !application.isTerminated {
                        self.requestForeground(application, target: action.target, token: token)
                        return
                    }
                // Stale or unsupported requests stay quiet; refresh below reconciles the UI.
                case .rejected, .completed: break
                }
                // Keep the click guard until the new inventory is published, not just until
                // AX returns; a second click must never act on the pre-minimise snapshot.
                self.refreshAndUnlock(pid, token: token)
            }
        }
    }

    private func requestForeground(_ application: NSRunningApplication, target: SidebarWindowID?, token: SidebarPendingAction) {
        let pid = application.processIdentifier
        if let target {
            foregroundFocus[pid] = ForegroundFocus(id: target, token: token,
                                                  expiresAt: ProcessInfo.processInfo.systemUptime + 1)
        }
        let accepted = SidebarFocusActivation.request(
            canContinue: { token.canFinishFocus(on: pid) && !application.isTerminated },
            yieldActivation: { NSApp.yieldActivation(to: application) },
            activate: {
                SidebarFocusActivation.activate(target: target,
                    focusWindow: { SidebarWindowFocusRequest($0.pid, $0.windowID) },
                    activateApp: { application.activate(options: $0) })
            })
        guard accepted, target != nil else {
            foregroundFocus[pid] = nil
            refreshAndUnlock(pid, token: token)
            return
        }
        finishForegroundFocus(pid)
        guard let waiting = foregroundFocus[pid], waiting.token === token else { return }
        // Expiry only cancels stale intent; it never postpones an activation or raise.
        let remaining = max(0, waiting.expiresAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.foregroundFocus[pid]?.token === token else { return }
            self.foregroundFocus[pid] = nil
            token.cancel()
            self.refreshAndUnlock(pid, token: token)
        }
    }

    private func finishForegroundFocus(_ pid: pid_t) {
        guard let request = foregroundFocus[pid], pendingActions[pid] === request.token,
              request.token.canFinishFocus(on: pid),
              ProcessInfo.processInfo.systemUptime < request.expiresAt,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        foregroundFocus[pid] = nil // Claim once, even if activation notifications repeat.
        reader.queue.async { [weak self, reader] in
            reader.raiseForegroundWindow(request.id, token: request.token, expiresAt: request.expiresAt)
            DispatchQueue.main.async { self?.refreshAndUnlock(pid, token: request.token) }
        }
    }

    private func refreshAndUnlock(_ pid: pid_t, token: SidebarPendingAction) {
        guard running, pendingActions[pid] === token else { return }
        refresh { [weak self] in
            guard let self, self.pendingActions[pid] === token else { return }
            self.pendingActions[pid] = nil
        }
    }

    private func cancelActions(preservingStartedFocus: Bool = false) {
        pendingActions = pendingActions.filter { _, token in
            if preservingStartedFocus && token.hasStartedFocus { return true }
            token.cancel()
            return false
        }
        foregroundFocus = foregroundFocus.filter { pid, request in pendingActions[pid] === request.token }
        if pendingDesktopTransfer?.isCancelled == true { pendingDesktopTransfer = nil }
    }

    private func scheduleDiscoveryRefresh() {
        guard discoveryRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        discoveryRefresh = work
        // Only continue a finite, unfinished discovery scan. Never poll after it ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func updatePermissionTimer() {
        if !hasPermission { cancelActions() }
        if hasPermission {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            // Only poll while permission is missing; normal inventory updates are event driven.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    if AXIsProcessTrusted() { self?.refresh() }
                }
            }
        }
    }
}

// AX calls can block on another application. Mutable state is confined to queue;
// the run-loop callback only invokes the immutable, Sendable onChange closure.
private final class SidebarWindowReader: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.octopus.sidebar.windows", qos: .userInitiated)
    private let onChange: @Sendable () -> Void
    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: [pid_t: [AXUIElement]] = [:]
    private var recency: [SidebarWindowID: UInt64] = [:]
    private var lastFocused: [pid_t: SidebarWindowID] = [:]
    private var sequence: UInt64 = 0
    private struct KnownWindow {
        let element: AXUIElement
        let application: NSRunningApplication
    }
    private var knownWindows: [SidebarWindowID: KnownWindow] = [:]
    private var previousEntries: [pid_t: SidebarEntry] = [:]
    private var desktopGeneration: Int?
    private var desktopScope: SidebarDesktopScope?
    private var fullScreenWindows: Set<SidebarWindowID> = []
    private let spaceReader = SidebarSpaceReader()
    private let windowDiscovery = SidebarWindowDiscovery()

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    struct Snapshot {
        var hasPermission: Bool
        var entries: [SidebarEntry] = []
        var fullScreenDisplays: Set<CGDirectDisplayID> = []
        var needsWindowDiscovery = false
        var desktops: [SidebarDesktop] = []
        var canTransferDesktops = false
    }

    private struct ListedWindow {
        let pid: pid_t
        let bounds: CGRect
        let title: String
        let onScreen: Bool
        let normalLevel: Bool
    }

    static func isOnScreen(_ id: SidebarWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.windowID) as? [[String: Any]],
              let info = list.first,
              (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id.windowID,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == id.pid else { return false }
        return (info[kCGWindowIsOnscreen as String] as? Bool) == true
    }

    private func listedWindows() -> [CGWindowID: ListedWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
        var windows: [CGWindowID: ListedWindow] = [:]
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let level = info[kCGWindowLayer as String] as? NSNumber,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width > 0, bounds.height > 0 else { continue }
            windows[id.uint32Value] = ListedWindow(
                pid: pid.int32Value,
                bounds: bounds,
                title: info[kCGWindowName as String] as? String ?? "",
                onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                normalLevel: level.intValue == 0
            )
        }
        return windows
    }

    private func matchingWindow(for axWindow: AXUIElement, pid: pid_t,
                                windowID: CGWindowID?, listed: [CGWindowID: ListedWindow]) -> (CGWindowID, ListedWindow)? {
        let candidates = listed.filter { $0.value.pid == pid && $0.value.normalLevel }
        guard !candidates.isEmpty else { return nil }
        if let id = windowID {
            // An authoritative AX ID must not fall back to a different window's title/frame.
            return candidates[id].map { (id, $0) }
        }

        let axTitle: String = axWindow.getAttributeValue(.title) ?? ""
        let normalizedAXTitle = SidebarWindowPolicy.normalizedWindowTitle(axTitle)
        let titleMatches = candidates.filter {
            !normalizedAXTitle.isEmpty &&
                SidebarWindowPolicy.normalizedWindowTitle($0.value.title) == normalizedAXTitle
        }
        if titleMatches.count == 1, let match = titleMatches.first { return match }

        guard let axFrame = axWindow.getWindowFrame() else {
            return candidates.count == 1 ? candidates.first : nil
        }
        // Accessibility and Core Graphics use the same logical coordinate space here.
        // A small tolerance covers browser chrome changing its title bar metrics.
        let nearest = candidates.min {
            frameDistance(axFrame, $0.value.bounds) < frameDistance(axFrame, $1.value.bounds)
        }
        guard let nearest, frameDistance(axFrame, nearest.value.bounds) <= 32 else { return nil }
        return nearest
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    func read(_ applications: [NSRunningApplication], systemFullScreenPID: pid_t?,
              desktop: Int, scope: SidebarDesktopScope) -> Snapshot {
        dispatchPrecondition(condition: .onQueue(queue))
        if desktopScope != scope || (desktopGeneration != desktop && scope == .visibleDesktops) {
            knownWindows.removeAll()
            previousEntries.removeAll()
        }
        desktopGeneration = desktop
        desktopScope = scope
        fullScreenWindows.removeAll()
        var snapshot = Snapshot(hasPermission: AXIsProcessTrusted())
        guard snapshot.hasPermission else {
            removeObservers()
            return snapshot
        }
        let listed = listedWindows()
        let displayFrames = activeDisplayFrames()
        // Resolve the native capability on the worker queue, never during pointer input.
        snapshot.canTransferDesktops = SidebarSpaceTransferIsAvailable()
        snapshot.desktops = spaceReader.allDesktops()
        let visibleDesktops = spaceReader.visibleDesktopIDs()
        let desktops = spaceReader.read(windowIDs: Set(listed.filter { $0.value.normalLevel }.keys), catalog: snapshot.desktops)
            .mapValues { SidebarSpaceReader.collapsingAllDesktopsMembership($0, catalog: snapshot.desktops, visible: visibleDesktops) }
        let visible = listed.filter { $0.value.onScreen && $0.value.normalLevel }
        // Some games/video windows do not expose AXFullScreen. Only use geometry as a
        // fallback when AppKit independently confirms that their active app is full screen.
        for window in visible.values where window.pid == systemFullScreenPID {
            if let display = displayContaining(window.bounds),
               window.bounds.insetBy(dx: -2, dy: -2).contains(CGDisplayBounds(display)) {
                snapshot.fullScreenDisplays.insert(display)
            }
        }
        let pids = Set(applications.map(\.processIdentifier))
        windowDiscovery.retainApplications(pids)
        var survivingIDs: Set<SidebarWindowID> = []
        for pid in Array(observers.keys) where !pids.contains(pid) { removeObserver(pid) }

        for running in applications where !running.isTerminated {
            let app = Application(running)
            guard let element = app.element else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            // A failed AX query is not an empty window list. Keep the last verified list
            // until a successful scan, a desktop change, or termination resolves it.
            let readableWindows: [AXUIElement]? = element.getAttributeValue(.windows)
            if readableWindows == nil {
                if var previous = previousEntries[running.processIdentifier],
                   previous.application.runningApplication?.isTerminated == false {
                    previous.isHidden = running.isHidden
                    for id in Array(previous.windowStates.keys) {
                        previous.windowStates[id]?.isOnScreen = listed[id].map {
                            $0.pid == running.processIdentifier && $0.onScreen && $0.normalLevel
                        } ?? false
                        previous.windowStates[id]?.desktops = desktops[id] ?? []
                        previous.windowStates[id]?.desktopLabel = desktops[id]?.first?.windowPrefix
                        let bounds = listed[id].flatMap { $0.pid == running.processIdentifier ? $0.bounds : nil }
                        if let display = SidebarWindowPolicy.displayIdentifier(desktops: desktops[id] ?? [],
                            bounds: bounds, displayFrames: displayFrames) {
                            previous.windowStates[id]?.displayIdentifier = display
                        }
                    }
                    snapshot.entries.append(previous)
                    for window in previous.windows {
                        if let id = window.cgWindowID {
                            survivingIDs.insert(SidebarWindowID(pid: running.processIdentifier, windowID: id))
                        }
                    }
                    continue
                }
            }
            var axWindows = readableWindows ?? []
            if scope == .allDesktops {
                // A real cross-Space window must belong to a managed desktop. Browser
                // helper surfaces can be layer 0 but have no Space membership.
                let candidates = Set(listed.filter {
                    $0.value.pid == running.processIdentifier && $0.value.normalLevel
                        && !(desktops[$0.key]?.isEmpty ?? true)
                }.keys)
                let discovered = windowDiscovery.read(pid: running.processIdentifier, current: axWindows, candidates: candidates)
                axWindows = discovered.windows
                snapshot.needsWindowDiscovery = snapshot.needsWindowDiscovery || discovered.needsAnotherPass
            }
            observe(app: element, pid: running.processIdentifier, windows: axWindows)
            var windows: [Window] = []
            var states: [CGWindowID: SidebarWindowState] = [:]
            for axWindow in axWindows {
                AXUIElementSetMessagingTimeout(axWindow, 0.2)
                let axID = axWindow.getWindowID().flatMap { $0 == kCGNullWindowID ? nil : $0 }
                var ownerPID: pid_t = 0
                guard AXUIElementGetPid(axWindow, &ownerPID) == .success,
                      ownerPID == running.processIdentifier else { continue }
                let previousID = knownID(for: axWindow, pid: ownerPID, reportedID: axID)
                let previous = previousEntries[ownerPID]
                guard let role: String = axWindow.getAttributeValue(.role) else {
                    if let id = previousID,
                       let window = previous?.windows.first(where: { $0.cgWindowID == id }),
                       var state = previous?.windowStates[id],
                       survivingIDs.insert(SidebarWindowID(pid: ownerPID, windowID: id)).inserted {
                        state.isOnScreen = listed[id].map { $0.pid == ownerPID && $0.onScreen } ?? false
                        state.desktops = desktops[id] ?? []
                        state.desktopLabel = desktops[id]?.first?.windowPrefix
                        let bounds = listed[id].flatMap { $0.pid == ownerPID ? $0.bounds : nil }
                        state.displayIdentifier = SidebarWindowPolicy.displayIdentifier(desktops: state.desktops,
                            bounds: bounds, displayFrames: displayFrames) ?? state.displayIdentifier
                        windows.append(window)
                        states[id] = state
                    }
                    continue
                }
                let subrole: String? = axWindow.getAttributeValue(.subrole)
                guard SidebarWindowPolicy.isTopLevelWindow(role: role, subrole: subrole) else { continue }
                let minimized: Bool = axWindow.getAttributeValue(.minimized)
                    ?? previousID.flatMap { previous?.windowStates[$0]?.isMinimized } ?? false
                let restorable = running.isHidden || minimized
                let match = matchingWindow(for: axWindow, pid: running.processIdentifier,
                    windowID: axID, listed: scope == .allDesktops || restorable ? listed : visible)
                let rawTitle: String? = axWindow.getAttributeValue(.title)
                if SidebarWindowPolicy.needsBrowserHelperCheck(bundleIdentifier: running.bundleIdentifier),
                   isBrowserHelper(axWindow, applicationTitle: app.title, title: rawTitle,
                                   subrole: subrole, bounds: match?.1.bounds, minimized: minimized) {
                    continue
                }
                // Use the same AX window enumeration as the keyboard list. Hidden/minimised
                // windows do not need to have been visible during this octopus session.
                let normalLevel = axID.flatMap { listed[$0] }.map {
                    $0.pid == running.processIdentifier && $0.normalLevel
                } ?? (match != nil || restorable || previousID != nil)
                guard SidebarWindowPolicy.isEligible(onScreen: match?.1.onScreen == true,
                    normalLevel: normalLevel, standardWindow: true, minimized: minimized,
                    hidden: running.isHidden, ownProcess: false, previouslyListed: previousID != nil,
                    scope: scope),
                    let id = axID ?? match?.0 ?? previousID else { continue }
                let sidebarID = SidebarWindowID(pid: running.processIdentifier, windowID: id)
                guard survivingIDs.insert(sidebarID).inserted else { continue }
                let fullScreen: Bool = axWindow.getAttributeValue(NSAccessibility.Attribute(rawValue: "AXFullScreen")) ?? false
                let geometryFullScreen = match.map {
                    guard $0.1.onScreen, running.processIdentifier == systemFullScreenPID,
                          let display = displayContaining($0.1.bounds) else { return false }
                    return $0.1.bounds.insetBy(dx: -2, dy: -2).contains(CGDisplayBounds(display))
                } ?? false
                if fullScreen || geometryFullScreen { fullScreenWindows.insert(sidebarID) }
                if fullScreen, !running.isHidden, !minimized, let info = match?.1, info.onScreen,
                   let display = displayContaining(info.bounds) {
                    snapshot.fullScreenDisplays.insert(display)
                }
                knownWindows[sidebarID] = KnownWindow(element: axWindow, application: running)
                states[id] = SidebarWindowState(isMinimized: minimized,
                    canMinimize: !fullScreen && !geometryFullScreen
                        && isMinimizedSettable(axWindow),
                    isOnScreen: match?.1.onScreen == true, desktops: desktops[id] ?? [],
                    desktopLabel: desktops[id]?.first?.windowPrefix,
                    displayIdentifier: SidebarWindowPolicy.displayIdentifier(desktops: desktops[id] ?? [],
                        bounds: match?.1.bounds ?? axWindow.getWindowFrame(), displayFrames: displayFrames)
                        ?? previous?.windowStates[id]?.displayIdentifier)
                let title = rawTitle ?? ""
                let window = Window(axWindow, app, cachedTitle: title.isEmpty ? app.title : title)
                window.cgWindowID = id
                windows.append(window)
            }
            guard !windows.isEmpty else { continue }
            let focusedElement: AXUIElement? = element.getAttributeValue(.focusedWindow)
            let focusedID = windows.first { window in
                focusedElement.map { CFEqual($0, window.element) } ?? false
            }.flatMap { window in
                window.cgWindowID.map { SidebarWindowID(pid: running.processIdentifier, windowID: $0) }
            }
            let ids = windows.compactMap { window in
                window.cgWindowID.map { SidebarWindowID(pid: running.processIdentifier, windowID: $0) }
            }
            // AX retains an app's focused window after another app becomes active.
            // Reading every app also catches a quick window switch followed by an app switch.
            if let focusedID, ids.contains(focusedID), focusedID != lastFocused[running.processIdentifier] {
                recordFocus(focusedID)
            }
            if let preferred = SidebarWindowPolicy.preferredID(ids, recency: recency, focused: focusedID,
                                                               states: states, hidden: running.isHidden) {
                snapshot.entries.append(SidebarEntry(pid: running.processIdentifier,
                    application: app, windows: windows, preferredID: preferred,
                    focusedID: focusedID, isHidden: running.isHidden, windowStates: states))
            }
        }
        knownWindows = knownWindows.filter { survivingIDs.contains($0.key) }
        // Bound history without losing recency for windows temporarily on another desktop.
        recency = recency.filter { pids.contains($0.key.pid) }
        lastFocused = lastFocused.filter { pids.contains($0.key) }
        if recency.count > 4096 {
            recency = Dictionary(uniqueKeysWithValues: recency.sorted { $0.value > $1.value }.prefix(2048).map { ($0.key, $0.value) })
        }
        previousEntries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.pid, $0) })
        return snapshot
    }

    private func knownID(for element: AXUIElement, pid: pid_t, reportedID: CGWindowID?) -> CGWindowID? {
        if let id = reportedID {
            guard let known = knownWindows[SidebarWindowID(pid: pid, windowID: id)],
                  !known.application.isTerminated, CFEqual(known.element, element) else { return nil }
            return id
        }
        return knownWindows.first {
            $0.key.pid == pid && !$0.value.application.isTerminated && CFEqual($0.value.element, element)
        }?.key.windowID
    }

    enum ActionResult {
        case activate(NSRunningApplication)
        case completed
        case rejected
        case placement(SidebarPlacementResult, NSRunningApplication?)
    }

    func placementTarget(_ id: SidebarWindowID, desktop: Int) -> SidebarPlacementTarget? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard desktopGeneration == desktop, AXIsProcessTrusted(), let known = validatedWindow(id) else { return nil }
        let element = known.element
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let fullScreen: Bool = placementAttribute(element, "AXFullScreen", unsupported: false),
              let modal: Bool = placementAttribute(element, "AXModal", unsupported: false),
              let sheets: [AXUIElement] = placementAttribute(element, "AXSheets", unsupported: []),
              let minimized: Bool = placementAttribute(element, kAXMinimizedAttribute, unsupported: false),
              let frame = element.getWindowFrame(), SidebarPlacementGeometry.isValid(frame) else { return nil }
        let memberships = Set((spaceReader.read(windowIDs: [id.windowID])[id.windowID] ?? []).map(\.id))
        guard SidebarPlacementEligibility.allows(fullScreen: fullScreen || fullScreenWindows.contains(id),
            modal: modal, hasSheets: !sheets.isEmpty, canMove: isSettable(element, attribute: .position),
            windowDesktops: memberships, visibleDesktops: spaceReader.visibleDesktopIDs()) else { return nil }
        return SidebarPlacementTarget(id: id, frame: frame, canResize: isSettable(element, attribute: .size),
                                      isMinimized: minimized, desktopGeneration: desktop)
    }

    func desktopTransferTarget(_ id: SidebarWindowID, desktop: Int) -> SidebarDesktopTransferTarget? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard desktopGeneration == desktop, AXIsProcessTrusted(), let known = validatedWindow(id),
              known.element.getAttributeValue(.subrole) as String? == kAXStandardWindowSubrole as String,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id.windowID) as? [[String: Any]])?.first,
              (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id.windowID,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == id.pid,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
        let element = known.element
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let fullScreen: Bool = placementAttribute(element, "AXFullScreen", unsupported: false),
              let modal: Bool = placementAttribute(element, "AXModal", unsupported: false),
              let sheets: [AXUIElement] = placementAttribute(element, "AXSheets", unsupported: []),
              let minimized: Bool = placementAttribute(element, kAXMinimizedAttribute, unsupported: false) else { return nil }
        let memberships = spaceReader.read(windowIDs: [id.windowID])[id.windowID] ?? []
        guard let source = SidebarDesktopTransferPolicy.source(desktops: memberships,
            hidden: known.application.isHidden, minimized: minimized,
            fullScreen: fullScreen || fullScreenWindows.contains(id), modal: modal,
            hasSheets: !sheets.isEmpty, canMove: isSettable(element, attribute: .position)) else { return nil }
        return SidebarDesktopTransferTarget(id: id, sourceDesktop: source, desktopGeneration: desktop)
    }

    func submitDesktopTransfer(_ id: SidebarWindowID, request: SidebarDesktopTransferRequest,
                               token: SidebarPendingAction) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard token.isCurrent, let target = desktopTransferTarget(id, desktop: request.desktopGeneration),
              target.sourceDesktop.id == request.sourceDesktop.id,
              let destination = spaceReader.allDesktops().first(where: { $0.id == request.destinationDesktop.id }),
              SidebarDesktopTransferPolicy.allows(source: target.sourceDesktop, destination: destination),
              destination.displayIdentifier == request.destinationDesktop.displayIdentifier,
              token.isCurrent else { return "This window or desktop is no longer available for transfer." }
        return SidebarSpaceTransferSubmit(id.windowID, destination.id)
            ? nil : "Desktop transfer is not supported on this macOS version."
    }

    func desktopTransferMembership(_ id: SidebarWindowID) -> Set<UInt64>? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard AXIsProcessTrusted(), validatedWindow(id) != nil else { return nil }
        return Set((spaceReader.read(windowIDs: [id.windowID])[id.windowID] ?? []).map(\.id))
    }

    private func placementAttribute<T>(_ element: AXUIElement, _ attribute: String, unsupported: T) -> T? {
        var value: AnyObject?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success: return value as? T
        // Some toolkits do not expose these optional attributes. A failed read is different.
        case .attributeUnsupported: return unsupported
        default: return nil
        }
    }

    private func isSettable(_ element: AXUIElement, attribute: NSAccessibility.Attribute) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute.rawValue as CFString, &settable) == .success
            && settable.boolValue
    }

    func perform(_ action: SidebarWindowAction, desktop: Int, token: SidebarPendingAction,
                 systemFullScreenPID: pid_t?, application: NSRunningApplication?) -> ActionResult {
        dispatchPrecondition(condition: .onQueue(queue))
        guard desktopGeneration == desktop, token.isCurrent else { return .rejected }
        if case .activateApp(let pid) = action {
            guard desktopScope == .allDesktops, pid != ProcessInfo.processInfo.processIdentifier,
                  let running = application, running.processIdentifier == pid,
                  running.activationPolicy == .regular, !running.isTerminated,
                  token.isCurrent, token.beginFocus() else { return .rejected }
            if running.isHidden, !running.unhide() { return .rejected }
            guard token.canFinishFocus(on: pid), !running.isTerminated else { return .rejected }
            // Do not launch or reopen an app to manufacture a window for the sidebar.
            return .activate(running)
        }
        guard let id = action.target,
              let known = validatedWindow(id), token.isCurrent else { return .rejected }
        let element = known.element
        AXUIElementSetMessagingTimeout(element, 0.2)
        let running = known.application
        let minimized: Bool = element.getAttributeValue(.minimized) ?? false

        switch action {
        case .activateApp: return .rejected // Handled above, without requiring an AX window.
        case .place(_, let request):
            guard request.desktopGeneration == desktop,
                  let target = placementTarget(id, desktop: desktop),
                  !request.resize || target.canResize else {
                return .placement(.failed("This window cannot be placed on the current desktop."), nil)
            }
            if target.isMinimized {
                guard canChangeMinimized(element, fullScreen: false), token.isCurrent,
                      AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                    return .placement(.failed("This window could not be restored."), nil)
                }
            }
            guard token.canFinishFocus(on: id.pid) else { return .rejected }
            if running.isHidden, !running.unhide() { return .placement(.failed("This app could not be shown."), nil) }
            // Enough for the writer's confirmation passes; still bounded for unresponsive apps.
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            let result = Self.withoutEnhancedUserInterface(pid: id.pid) {
                SidebarPlacementWriter.apply(request,
                    canContinue: { token.canFinishFocus(on: id.pid) && !running.isTerminated && ProcessInfo.processInfo.systemUptime < deadline },
                    readFrame: { element.getWindowFrame() },
                    writePosition: { position in
                        var position = position
                        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
                        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
                    }, writeSize: { size in
                        var size = size
                        guard let value = AXValueCreate(.cgSize, &size) else { return false }
                        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
                    })
            }
            if result == .cancelled, !token.isCancelled, ProcessInfo.processInfo.systemUptime >= deadline {
                return .placement(.failed("This app took too long to finish placement; the window may have moved."), nil)
            }
            guard case .placed = result else { return .placement(result, nil) }
            guard token.canFinishFocus(on: id.pid), validatedWindow(id) != nil, token.beginFocus() else {
                return .placement(.failed("Window placement finished, but the app could not bring it forward."), nil)
            }
            guard prepareWindowForActivation(element) else {
                return .placement(.failed("This window is no longer available to bring forward."), nil)
            }
            return .placement(result, running)
        case .hide:
            guard !running.isHidden, token.isCurrent else { return .rejected }
            return running.hide() ? .completed : .rejected
        case .minimize(_, let requireFocused):
            // A cached visible window may have moved to another Desktop before this
            // queued action runs. Navigate to the exact window instead of minimising it.
            if !Self.isOnScreen(id), !running.isHidden, !minimized {
                return perform(.focus(id), desktop: desktop, token: token,
                               systemFullScreenPID: systemFullScreenPID, application: application)
            }
            guard !running.isHidden, !minimized,
                  desktopScope == .allDesktops || Self.isOnScreen(id),
                  !(requireFocused && systemFullScreenPID == id.pid),
                  canChangeMinimized(element, fullScreen: fullScreenWindows.contains(id)) else { return .rejected }
            if requireFocused {
                let appElement = AXUIElementCreateApplication(id.pid)
                AXUIElementSetMessagingTimeout(appElement, 0.2)
                guard token.frontmostPID == id.pid,
                      let focused: AXUIElement = appElement.getAttributeValue(.focusedWindow),
                      CFEqual(focused, element) else { return .rejected }
            }
            guard token.isCurrent else { return .rejected }
            return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                               kCFBooleanTrue) == .success ? .completed : .rejected
        case .focus:
            // Only previously verified windows can be restored. Never launch or reopen.
            guard desktopScope == .allDesktops || running.isHidden || minimized || Self.isOnScreen(id),
                  token.beginFocus() else { return .rejected }
            if minimized {
                guard canChangeMinimized(element, fullScreen: fullScreenWindows.contains(id)), token.isCurrent,
                      AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                   kCFBooleanFalse) == .success else { return .rejected }
            }
            guard token.canFinishFocus(on: id.pid) else { return .rejected }
            if running.isHidden, !running.unhide() { return .rejected }
            guard token.canFinishFocus(on: id.pid), !running.isTerminated,
                  validatedWindow(id) != nil else { return .rejected }
            // Request the exact window before any main-window or raise operation.
            // Raising here races the subsequent WindowServer focus request across Spaces.
            // requestForeground owns activation and the follow-up raise.
            return .activate(running)
        }
    }

    // With AXEnhancedUserInterface on, apps animate AX frame writes, so the size/position
    // writes overlap and some are dropped. Rectangle suspends it for the same reason
    // (clone/Rectangle/AccessibilityElement.swift `performWindowAdjustment`).
    private static func withoutEnhancedUserInterface<T>(pid: pid_t, _ body: () -> T) -> T {
        let attribute = "AXEnhancedUserInterface" as CFString
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var value: CFTypeRef?
        let wasEnabled = AXUIElementCopyAttributeValue(application, attribute, &value) == .success
            && (value as? Bool) == true
        if wasEnabled { _ = AXUIElementSetAttributeValue(application, attribute, kCFBooleanFalse) }
        defer { if wasEnabled { _ = AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue) } }
        return body()
    }

    private func prepareWindowForActivation(_ element: AXUIElement) -> Bool {
        if isSettable(element, attribute: .main) {
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        // A restore animation may reject this early raise. Still request app activation.
        let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return SidebarFocusActivation.canRequestAfterRaise(result)
    }

    func raiseForegroundWindow(_ id: SidebarWindowID, token: SidebarPendingAction, expiresAt: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard token.canFinishFocus(on: id.pid),
              ProcessInfo.processInfo.systemUptime < expiresAt,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid,
              let known = validatedWindow(id), !known.application.isTerminated else { return }
        AXUIElementSetMessagingTimeout(known.element, 0.2)
        guard token.canFinishFocus(on: id.pid), ProcessInfo.processInfo.systemUptime < expiresAt,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == id.pid else { return }
        if AXUIElementPerformAction(known.element, kAXRaiseAction as CFString) == .success {
            recordFocus(id)
        }
    }

    private func validatedWindow(_ id: SidebarWindowID) -> KnownWindow? {
        guard let known = knownWindows[id], !known.application.isTerminated,
              known.application.processIdentifier == id.pid,
              id.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = Application(known.application)
        if let element = app.element { AXUIElementSetMessagingTimeout(element, 0.2) }
        let reportedID = known.element.getWindowID().flatMap { $0 == kCGNullWindowID ? nil : $0 }
        // Off-Space handles will not appear in kAXWindowsAttribute. Their freshly
        // reported window ID, role and owner PID validate them without that list.
        guard reportedID.map({ $0 == id.windowID })
            ?? app.getAXWindows().contains(where: { CFEqual($0, known.element) }) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(known.element, &pid) == .success, pid == id.pid,
              SidebarWindowPolicy.isTopLevelWindow(role: known.element.getAttributeValue(.role),
                                                   subrole: known.element.getAttributeValue(.subrole)) else { return nil }
        return known
    }

    private func canChangeMinimized(_ element: AXUIElement, fullScreen: Bool) -> Bool {
        let isFullScreen: Bool = element.getAttributeValue(NSAccessibility.Attribute(rawValue: "AXFullScreen")) ?? false
        let modal: Bool = element.getAttributeValue(NSAccessibility.Attribute(rawValue: "AXModal")) ?? false
        let sheets: [AXUIElement] = element.getAttributeValue(NSAccessibility.Attribute(rawValue: "AXSheets")) ?? []
        return SidebarWindowPolicy.canMinimize(
            standardWindow: SidebarWindowPolicy.isTopLevelWindow(role: element.getAttributeValue(.role),
                                                                subrole: element.getAttributeValue(.subrole)),
            fullScreen: fullScreen || isFullScreen, modal: modal, hasSheets: !sheets.isEmpty,
            settable: isMinimizedSettable(element))
    }

    private func isMinimizedSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private func isBrowserHelper(_ element: AXUIElement, applicationTitle: String, title: String?,
                                 subrole: String?, bounds: CGRect?, minimized: Bool) -> Bool {
        var closeButton: CFTypeRef?
        let closeError = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton)
        let hasCloseButton: Bool?
        var closeWindowID: CGWindowID?
        switch closeError {
        case .success:
            if let closeButton, CFGetTypeID(closeButton) == AXUIElementGetTypeID() {
                let button = closeButton as! AXUIElement
                let ownerWindow: AXUIElement? = button.getAttributeValue(
                    NSAccessibility.Attribute(rawValue: kAXWindowAttribute as String))
                closeWindowID = ownerWindow?.getWindowID()
                // A browser overlay can forward the real window's controls. Those
                // controls do not make the overlay a second independent window.
                if let closeWindowID, let id = element.getWindowID() {
                    hasCloseButton = closeWindowID == id
                } else {
                    hasCloseButton = true
                }
            } else {
                hasCloseButton = false
            }
        case .attributeUnsupported, .noValue:
            hasCloseButton = false
        default:
            hasCloseButton = nil
        }
        let parent: AXUIElement? = element.getAttributeValue(.parent)
        let parentRole: String? = parent?.getAttributeValue(.role)
        let rejected = SidebarWindowPolicy.isBrowserHelper(title: title, applicationTitle: applicationTitle,
            subrole: subrole, hasCloseButton: hasCloseButton, parentIsWindow: parentRole == (kAXWindowRole as String),
            bounds: bounds, minimized: minimized)
        #if DEBUG
        if ProcessInfo.processInfo.environment["octopus_BROWSER_WINDOW_DIAGNOSTICS"] == "1" {
            let id = element.getWindowID() ?? 0
            let line = "octopus browser window id=\(id) title=\(String(describing: title)) subrole=\(String(describing: subrole)) ownClose=\(String(describing: hasCloseButton)) closeWindowID=\(String(describing: closeWindowID)) closeError=\(closeError.rawValue) parent=\(String(describing: parentRole)) bounds=\(String(describing: bounds)) minimized=\(minimized) rejected=\(rejected)\n"
            if let data = line.data(using: .utf8) { FileHandle.standardError.write(data) }
        }
        #endif
        return rejected
    }

    private func recordFocus(_ id: SidebarWindowID) {
        sequence += 1
        recency[id] = sequence
        lastFocused[id.pid] = id
    }

    private func activeDisplayFrames() -> [String: CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return [:] }
        return displays.prefix(Int(count)).reduce(into: [:]) { result, display in
            if let id = SidebarSettings.monitorID(display) { result[id] = CGDisplayBounds(display) }
        }
    }

    private func displayContaining(_ bounds: CGRect) -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).max { left, right in
            let a = CGDisplayBounds(left).intersection(bounds)
            let b = CGDisplayBounds(right).intersection(bounds)
            return a.width * a.height < b.width * b.height
        }
    }

    private func observe(app: AXUIElement, pid: pid_t, windows: [AXUIElement]) {
        if observers[pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                Unmanaged<SidebarWindowReader>.fromOpaque(context).takeUnretainedValue().onChange()
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
            observers[pid] = observer
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                         kAXApplicationShownNotification, kAXApplicationHiddenNotification] {
                AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard let observer = observers[pid] else { return }
        let previous = observedWindows[pid] ?? []
        let names = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXMovedNotification, kAXResizedNotification]
        for window in previous where !windows.contains(where: { CFEqual($0, window) }) {
            for name in names { AXObserverRemoveNotification(observer, window, name as CFString) }
        }
        for window in windows where !previous.contains(where: { CFEqual($0, window) }) {
            for name in names {
                AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        observedWindows[pid] = windows
    }

    private func removeObserver(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observedWindows.removeValue(forKey: pid)
    }

    func removeObservers() {
        dispatchPrecondition(condition: .onQueue(queue))
        for pid in Array(observers.keys) { removeObserver(pid) }
        knownWindows.removeAll()
        previousEntries.removeAll()
        fullScreenWindows.removeAll()
        windowDiscovery.reset()
    }
}
