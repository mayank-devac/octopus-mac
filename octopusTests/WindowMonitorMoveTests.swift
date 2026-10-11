import AppKit
import Testing
import KeyboardShortcuts
@testable import octopus

struct WindowMonitorMoveTests {
    @MainActor @Test func oldOptionDefaultsMigrateToControlShift() throws {
        let suite = "WindowMonitorMoveTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let left = KeyboardShortcuts.Name.moveWindowLeftMonitor
        let right = KeyboardShortcuts.Name.moveWindowRightMonitor
        var saved: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [
            left: .init(.leftArrow, modifiers: .option), right: .init(.rightArrow, modifiers: .option)
        ]
        WindowMonitorShortcuts.migrateDefaults(in: defaults, read: { saved[$0] }, write: { saved[$1] = $0 })
        #expect(saved[left] == .init(.leftArrow, modifiers: [.control, .shift]))
        #expect(saved[right] == .init(.rightArrow, modifiers: [.control, .shift]))
        // Choosing Option deliberately after migration must survive a later launch.
        saved[left] = .init(.leftArrow, modifiers: .option)
        WindowMonitorShortcuts.migrateDefaults(in: defaults, read: { saved[$0] }, write: { saved[$1] = $0 })
        #expect(saved[left] == .init(.leftArrow, modifiers: .option))
    }

    @MainActor @Test func defaultMigrationPreservesCustomAndDisabledShortcuts() throws {
        let suite = "WindowMonitorMoveTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let left = KeyboardShortcuts.Name.moveWindowLeftMonitor
        let right = KeyboardShortcuts.Name.moveWindowRightMonitor
        let custom = KeyboardShortcuts.Shortcut(.rightArrow, modifiers: [.control, .command])
        var saved = [right: custom] // Missing left entry represents an explicitly cleared shortcut.
        WindowMonitorShortcuts.migrateDefaults(in: defaults, read: { saved[$0] }, write: { saved[$1] = $0 })
        #expect(saved[left] == nil)
        #expect(saved[right] == custom)
    }

    private let sourceArea = CGRect(x: 0, y: 25, width: 1000, height: 750)
    private let destinationArea = CGRect(x: 1200, y: -175, width: 1400, height: 950)

    private func display(_ id: String, x: CGFloat, y: CGFloat = 0) -> WindowLayoutDisplay {
        let frame = CGRect(x: x, y: y, width: 1000, height: 800)
        return WindowLayoutDisplay(id: id, frame: frame, workArea: frame, scale: 1, name: id)
    }

    private func window(frame: CGRect = CGRect(x: 350, y: 300, width: 300, height: 200),
                        scope: WindowLayoutScope = WindowLayoutScope(displayID: "source", spaceID: 2),
                        canResize: Bool = true, hidden: Bool = false, minimized: Bool = false,
                        blocked: Bool = false, canMove: Bool = true, generation: UInt64 = 1) -> WindowLayoutWindow {
        WindowLayoutWindow(id: WindowLayoutIdentity(window: SidebarWindowID(pid: 100, windowID: 1), generation: generation),
            scope: scope, frame: frame, minimum: .zero, minimumReported: false,
            canMove: canMove, canResize: canResize, hidden: hidden, minimized: minimized,
            blocked: blocked, recency: 0, stackOrder: 0)
    }

    private func plan(canResize: Bool = true, moveSize: VisibleDisplayMoveSize = .original) throws -> WindowMonitorMovePlan {
        let destination = WindowLayoutDisplay(id: "destination", frame: destinationArea,
            workArea: destinationArea, scale: 2, name: "Destination")
        return try #require(WindowMonitorMovePolicy.plan(window: window(canResize: canResize), sourceArea: sourceArea,
            destination: destination, scope: WindowLayoutScope(displayID: destination.id, spaceID: 5), moveSize: moveSize))
    }

    @Test func monitorOrderUsesPhysicalPositionAndWrapsAtBothEnds() {
        let screens = [display("right", x: 1200), display("left", x: -1000), display("middle", x: 0)]
        #expect(WindowMonitorMovePolicy.destination(from: "left", direction: .right, displays: screens)?.id == "middle")
        #expect(WindowMonitorMovePolicy.destination(from: "middle", direction: .right, displays: screens)?.id == "right")
        #expect(WindowMonitorMovePolicy.destination(from: "right", direction: .right, displays: screens)?.id == "left")
        #expect(WindowMonitorMovePolicy.destination(from: "left", direction: .left, displays: screens)?.id == "right")
        #expect(WindowMonitorMovePolicy.destination(from: "middle", direction: .left, displays: screens)?.id == "left")
    }

    @Test func stackedMonitorsHaveStableTopToBottomOrder() {
        let screens = [display("bottom", x: 0, y: 800), display("top", x: 0, y: -800), display("middle", x: 0)]
        #expect(WindowMonitorMovePolicy.destination(from: "top", direction: .right, displays: screens)?.id == "middle")
        #expect(WindowMonitorMovePolicy.destination(from: "middle", direction: .right, displays: screens)?.id == "bottom")
        #expect(WindowMonitorMovePolicy.destination(from: "top", direction: .left, displays: screens)?.id == "bottom")
    }

    @Test func oneMonitorAndUnidentifiedSourcesCannotSelectAnArbitraryDestination() {
        let screen = display("only", x: 0)
        #expect(WindowMonitorMovePolicy.destination(from: "only", direction: .right, displays: [screen]) == nil)
        #expect(WindowMonitorMovePolicy.destination(from: "missing", direction: .right,
            displays: [screen, display("other", x: 1000)]) == nil)
        #expect(WindowMonitorMovePolicy.destination(from: "only", direction: .right, displays: [screen, screen]) == nil)
    }

    @Test func originalSizeKeepsRelativePositionAcrossDifferentMonitorSizes() throws {
        let request = try plan()
        // The source is centred in its usable area, so it stays centred on the destination.
        #expect(request.frame == CGRect(x: 1750, y: 200, width: 300, height: 200))
        #expect(request.resize)
        #expect(request.destination.spaceID == 5)
    }

    @Test func fillMonitorUsesUsableAreaAndFixedSizeWindowsOnlyMove() throws {
        let fill = try plan(moveSize: .fullScreen)
        #expect(fill.frame == destinationArea)
        #expect(fill.resize)
        let fixed = try plan(canResize: false, moveSize: .fullScreen)
        #expect(fixed.frame.size == fixed.source.frame.size)
        #expect(!fixed.resize)
        #expect(fixed.source.movable && !fixed.source.eligible)
    }

    @Test func unsupportedWindowStatesAreRejectedBeforeAnyMove() {
        let destination = display("destination", x: 1200)
        for source in [window(hidden: true), window(minimized: true), window(blocked: true), window(canMove: false)] {
            #expect(WindowMonitorMovePolicy.plan(window: source, sourceArea: sourceArea, destination: destination,
                scope: WindowLayoutScope(displayID: destination.id, spaceID: 5), moveSize: .original) == nil)
        }
    }

    @Test func oversizedFixedWindowKeepsItsSizeAndTitleBarReachable() throws {
        let destination = display("small", x: -1000)
        let source = window(frame: CGRect(x: 0, y: 25, width: 1500, height: 1000), canResize: false)
        let request = try #require(WindowMonitorMovePolicy.plan(window: source, sourceArea: sourceArea,
            destination: destination, scope: WindowLayoutScope(displayID: destination.id, spaceID: 5), moveSize: .original))
        #expect(request.frame.size == source.frame.size)
        #expect(request.frame.origin == destination.workArea.origin)
        #expect(!request.resize)
    }

    @Test func changedWindowOrIdentityStopsBeforeTheFirstWrite() throws {
        let request = try plan()
        let changes = [window(frame: CGRect(x: 50, y: 30, width: 300, height: 200)),
            window(scope: WindowLayoutScope(displayID: "source", spaceID: 9)), window(generation: 2),
            window(blocked: true), window(canResize: false)]
        for changed in changes {
            var writes = 0
            let result = WindowMonitorMovePolicy.execute(request, canContinue: { true }, read: { _ in changed },
                write: { _ in writes += 1; return .placed(request.frame, adjusted: false) })
            guard case .failed = result else { Issue.record("A changed source must be rejected"); continue }
            #expect(writes == 0)
        }
    }

    @Test func fixedSizeMoveUsesTheExistingWriterWithoutAnySizeSetters() throws {
        let request = try plan(canResize: false)
        var actual = request.source
        var sizeWrites = 0
        let result = WindowMonitorMovePolicy.execute(request, canContinue: { true }, read: { _ in actual }, write: { plan in
            SidebarPlacementWriter.apply(SidebarPlacementRequest(frame: plan.frame, workArea: plan.workArea,
                resize: plan.resize, desktopGeneration: 0, crossesDisplay: true), canContinue: { true },
                readFrame: { actual.frame }, writePosition: { point in
                    actual = window(frame: CGRect(origin: point, size: actual.frame.size),
                                    scope: plan.destination, canResize: false)
                    return true
                }, writeSize: { _ in sizeWrites += 1; return false }, wait: {})
        })
        guard case .moved(let moved, let adjusted) = result else { Issue.record("Fixed-size move should finish"); return }
        #expect(moved.scope == request.destination)
        #expect(moved.frame == request.frame)
        #expect(!adjusted && sizeWrites == 0)
    }

    @Test func acceptedSetterWithoutDestinationReadbackIsNotReportedAsSuccessOrRetried() throws {
        let request = try plan()
        var writes = 0
        let result = WindowMonitorMovePolicy.execute(request, canContinue: { true }, read: { _ in request.source },
            write: { _ in writes += 1; return .placed(request.frame, adjusted: false) }, wait: {})
        guard case .failed = result else { Issue.record("Destination membership must be verified"); return }
        #expect(writes == 1)
    }

    @Test func delayedDesktopMembershipIsObservedWithoutResubmittingTheMove() throws {
        let request = try plan()
        var writes = 0, waits = 0
        var actual = request.source
        let result = WindowMonitorMovePolicy.execute(request, canContinue: { true }, read: { _ in actual },
            write: { _ in writes += 1; return .placed(request.frame, adjusted: false) }, wait: {
                waits += 1
                if waits == 2 { actual = window(frame: request.frame, scope: request.destination) }
            })
        guard case .moved = result else { Issue.record("Delayed membership should settle"); return }
        #expect(writes == 1 && waits == 2)
    }

    @Test func adjustedPlacementReportsTheVerifiedAppLimit() throws {
        let request = try plan(moveSize: .fullScreen)
        let achieved = CGRect(x: destinationArea.minX, y: destinationArea.minY, width: 1200, height: 850)
        var actual = request.source
        let result = WindowMonitorMovePolicy.execute(request, canContinue: { true }, read: { _ in actual }, write: { _ in
            actual = window(frame: achieved, scope: request.destination)
            return .placed(achieved, adjusted: true)
        })
        guard case .moved(let moved, let adjusted) = result else { Issue.record("Verified adjusted move should finish"); return }
        #expect(moved.frame == achieved && adjusted)
    }

    @Test func cancellationDoesNotWriteOrReadAnotherWindow() throws {
        let request = try plan()
        var reads = 0, writes = 0
        let before = WindowMonitorMovePolicy.execute(request, canContinue: { false }, read: { _ in reads += 1; return nil },
            write: { _ in writes += 1; return .cancelled })
        guard case .cancelled = before else { Issue.record("Cancelled request must stop"); return }
        #expect(reads == 0 && writes == 0)
        var allowed = true
        let during = WindowMonitorMovePolicy.execute(request, canContinue: { allowed }, read: { _ in reads += 1; return request.source },
            write: { _ in writes += 1; allowed = false; return .placed(request.frame, adjusted: false) })
        guard case .cancelled = during else { Issue.record("Cancellation after a setter must stop confirmation"); return }
        #expect(reads == 1 && writes == 1)
    }

    @Test func destinationSelectsOnlyThatMonitorsCurrentNormalDesktop() {
        func displayRecord(_ displayID: String, current: UInt64, type: Int = 0) -> [String: Any] {
            let active: [String: Any] = ["ManagedSpaceID": NSNumber(value: current), "type": NSNumber(value: type)]
            return ["Display Identifier": displayID, "Current Space": active,
                    "Spaces": [["ManagedSpaceID": NSNumber(value: 10), "type": NSNumber(value: 0)], active]]
        }
        let raw = [displayRecord("source", current: 2), displayRecord("destination", current: 5)]
        #expect(SidebarSpaceReader.visibleDesktop(on: "destination", from: raw)?.id == 5)
        #expect(SidebarSpaceReader.visibleDesktop(on: "missing", from: raw) == nil)
        #expect(SidebarSpaceReader.visibleDesktop(on: "destination", from:
            [displayRecord("source", current: 2), displayRecord("destination", current: 5, type: 4)]) == nil)
        #expect(SidebarSpaceReader.visibleDesktop(on: "destination", from: [displayRecord("Main", current: 2)])?.id == 2)
        #expect(SidebarSpaceReader.visibleDesktop(on: "destination", from:
            [displayRecord("destination", current: 5, type: 4), displayRecord("Main", current: 2)]) == nil)
    }
}
