import AppKit
import Testing
@testable import octopus

struct SidebarDragTests {
    private let screen = CGRect(x: -1440, y: 120, width: 1440, height: 900)
    private let area = CGRect(x: -1440, y: 160, width: 1440, height: 830)

    @Test func screenEdgesAndCornersChooseTheExpectedLayouts() {
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1430, y: 1010), screen: screen) == .topLeft)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -10, y: 1010), screen: screen) == .topRight)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1430, y: 130), screen: screen) == .bottomLeft)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -10, y: 130), screen: screen) == .bottomRight)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1420, y: 600), screen: screen) == .left)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -20, y: 600), screen: screen) == .right)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -700, y: 1000), screen: screen) == .maximize)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -700, y: 140), screen: screen) == .bottom)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -700, y: 600), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: 5, y: 600), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1400, y: 980), screen: screen) == .topLeft)
    }

    @Test func layoutsReserveTheDockAndMenuBar() {
        let left = SidebarPlacementGeometry.frame(for: .left, in: area)
        let right = SidebarPlacementGeometry.frame(for: .right, in: area)
        #expect(left.maxX == right.minX)
        #expect(left.union(right) == area)
        #expect(SidebarPlacementGeometry.frame(for: .maximize, in: area) == area)
        for target in SidebarSnapTarget.allCases {
            #expect(area.contains(SidebarPlacementGeometry.frame(for: target, in: area)))
        }
        #expect(SidebarPlacementGeometry.frame(for: .topLeft, in: area).maxY == area.maxY)
        #expect(SidebarPlacementGeometry.frame(for: .bottomRight, in: area).minY == area.minY)
    }

    @Test func snappingStartsBeforeThePointerReachesTheBorderAndClearsWhenLeaving() {
        let points: [(CGPoint, SidebarSnapTarget)] = [
            (CGPoint(x: screen.minX + 120, y: screen.midY), .left),
            (CGPoint(x: screen.maxX - 120, y: screen.midY), .right),
            (CGPoint(x: screen.midX, y: screen.maxY - 120), .maximize),
            (CGPoint(x: screen.midX, y: screen.minY + 120), .bottom),
            (CGPoint(x: screen.minX + 100, y: screen.maxY - 100), .topLeft),
            (CGPoint(x: screen.maxX - 100, y: screen.maxY - 100), .topRight),
            (CGPoint(x: screen.minX + 100, y: screen.minY + 100), .bottomLeft),
            (CGPoint(x: screen.maxX - 100, y: screen.minY + 100), .bottomRight)]
        for (point, target) in points {
            #expect(SidebarPlacementGeometry.snap(at: point, screen: screen, distance: 120) == target)
        }
        for point in [CGPoint(x: screen.minX + 121, y: screen.midY),
                      CGPoint(x: screen.maxX - 121, y: screen.midY),
                      CGPoint(x: screen.midX, y: screen.maxY - 121),
                      CGPoint(x: screen.midX, y: screen.minY + 121)] {
            #expect(SidebarPlacementGeometry.snap(at: point, screen: screen, distance: 120) == nil)
        }
    }

    @Test func smallDisplaysKeepAFreeMovementAreaBetweenSnapZones() {
        let compact = CGRect(x: 50, y: -100, width: 240, height: 200)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: compact.midX, y: compact.midY), screen: compact) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: compact.minX + 60, y: compact.midY), screen: compact) == .left)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: compact.minX + 61, y: compact.midY), screen: compact) == nil)
    }

    @Test func chosenDistanceChangesWhenTheSnapPreviewStarts() {
        let point = CGPoint(x: screen.minX + 100, y: screen.midY)
        #expect(SidebarPlacementGeometry.snap(at: point, screen: screen, distance: 24) == nil)
        #expect(SidebarPlacementGeometry.snap(at: point, screen: screen, distance: 120) == .left)
        #expect(SidebarPlacementGeometry.snap(at: point, screen: screen, distance: 300) == .left)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: screen.midX, y: screen.midY), screen: screen, distance: 300) == nil)
    }

    @Test func snapDistanceRejectsInvalidValuesAndStaysWithinTheSliderRange() {
        #expect(SidebarSettings.normalizedSnapDistance(0) == SidebarSettings.minimumSnapDistance)
        #expect(SidebarSettings.normalizedSnapDistance(SidebarSettings.maximumSnapDistance + 50) == SidebarSettings.maximumSnapDistance)
        #expect(SidebarSettings.normalizedSnapDistance(180) == 180)
        #expect(SidebarSettings.normalizedSnapDistance(.nan) == SidebarSettings.defaultSnapDistance)
        #expect(SidebarSettings.normalizedSnapDistance(.infinity) == SidebarSettings.defaultSnapDistance)
    }

    @Test func snapDistanceUsesTheDefaultAndPersistsTheUsersChoice() throws {
        let name = "SidebarDragTests.snapDistance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SidebarSettings.snapDistance(in: defaults) == SidebarSettings.defaultSnapDistance)
        defaults.set(192.0, forKey: "sidebarSnapDistance")
        #expect(SidebarSettings.snapDistance(in: try #require(UserDefaults(suiteName: name))) == 192)
        defaults.set(900.0, forKey: "sidebarSnapDistance")
        #expect(SidebarSettings.snapDistance(in: defaults) == SidebarSettings.maximumSnapDistance)
    }

    @Test func coordinatesUseThePrimaryDisplayForEveryMonitor() {
        let frame = CGRect(x: -1300, y: 1200, width: 800, height: 600)
        let ax = SidebarPlacementGeometry.flip(frame, primaryTop: 900)
        #expect(ax == CGRect(x: -1300, y: -900, width: 800, height: 600))
        #expect(SidebarPlacementGeometry.flip(ax, primaryTop: 900) == frame)
    }

    @Test func freeMovementPreservesSizeAndKeepsOversizedTitleBarsReachable() {
        let normal = SidebarPlacementGeometry.freeFrame(at: CGPoint(x: -20, y: 1000), size: CGSize(width: 700, height: 500), in: area)
        #expect(normal.size == CGSize(width: 700, height: 500))
        #expect(area.contains(normal))
        let large = SidebarPlacementGeometry.freeFrame(at: CGPoint(x: -700, y: 500), size: CGSize(width: 1800, height: 1200), in: area)
        #expect(large.width == 1800 && large.height == 1200)
        #expect(large.maxY == area.maxY && large.minX == area.minX)
    }

    @Test func desktopMetadataNeverTreatsFullscreenOrMissingDataAsAnOrdinaryDesktop() {
        let metadata: [[String: Any]] = [
            ["Current Space": ["ManagedSpaceID": 8, "type": 0]],
            ["Current Space": ["id64": 9, "type": 4]],
            ["Spaces": [["id64": 10, "type": 0]]],
            ["Current Space": ["id64": 0, "type": 0]]]
        #expect(SidebarSpaceReader.visibleDesktopIDs(from: metadata) == [8])
        #expect(SidebarSpaceReader.visibleDesktopIDs(from: []) == [])
    }

    @Test func placementRejectsUnsupportedAndOffDesktopWindows() {
        func allows(fullScreen: Bool = false, modal: Bool = false, sheets: Bool = false,
                    canMove: Bool = true, membership: Set<UInt64> = [8], visible: Set<UInt64> = [8]) -> Bool {
            SidebarPlacementEligibility.allows(fullScreen: fullScreen, modal: modal, hasSheets: sheets,
                                               canMove: canMove, windowDesktops: membership, visibleDesktops: visible)
        }
        #expect(allows())
        #expect(!allows(fullScreen: true))
        #expect(!allows(modal: true))
        #expect(!allows(sheets: true))
        #expect(!allows(canMove: false))
        #expect(!allows(membership: [9]))
        #expect(!allows(membership: []))
        #expect(!allows(visible: []))
        #expect(allows(membership: [7, 8], visible: [8, 9]))
    }

    @MainActor @Test func appIconsChooseTheShownWindowEvenWhenSeveralWindowsExist() {
        let app = Application(NSRunningApplication.current)
        let pid = NSRunningApplication.current.processIdentifier
        let first = Window(AXUIElementCreateApplication(pid), app)
        first.cgWindowID = 11
        let second = Window(AXUIElementCreateApplication(pid), app)
        second.cgWindowID = 22
        let firstID = SidebarWindowID(pid: pid, windowID: 11)
        let secondID = SidebarWindowID(pid: pid, windowID: 22)
        let single = SidebarEntry(pid: pid, application: app, windows: [first], preferredID: firstID)
        let multiple = SidebarEntry(pid: pid, application: app, windows: [first, second], preferredID: secondID, focusedID: firstID)
        let otherDesktop = SidebarEntry(pid: pid, application: app, windows: [first], preferredID: firstID, hasOtherWindows: true)
        #expect(SidebarIconDragPolicy.target(for: single) == firstID)
        #expect(SidebarIconDragPolicy.target(for: multiple) == secondID)
        #expect(SidebarIconDragPolicy.target(for: otherDesktop) == firstID)
        #expect(SidebarIconDragPolicy.target(for: SidebarEntry(pid: pid, application: app, windows: [], preferredID: nil)) == nil)
        let stale = SidebarEntry(pid: pid, application: app, windows: [first],
                                 preferredID: SidebarWindowID(pid: pid, windowID: 33))
        #expect(SidebarIconDragPolicy.target(for: stale) == nil)
        #expect(SidebarIconDragPolicy.target(for: SidebarEntry(pid: pid, application: app, windows: [first], preferredID: nil)) == nil)
    }

    @MainActor @Test func nativePressDoesNotClickAndDragsKeepTheOriginalCallback() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var clicks = 0
        var target = ""
        view.onClick = { clicks += 1 }
        view.onDrag = { _, _ in target = "original window" }
        view.mouseDown(with: try mouse(.leftMouseDown, point: CGPoint(x: 10, y: 10)))
        #expect(clicks == 0)
        view.onDrag = { _, _ in target = "replacement window" }
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: CGPoint(x: 16, y: 10)))
        #expect(target.isEmpty)
        view.mouseDragged(with: try mouse(.leftMouseDragged, point: CGPoint(x: 17, y: 10)))
        #expect(target == "original window")
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 17, y: 10)))
        #expect(clicks == 0)
    }

    @MainActor @Test func clicksCommitOnReleaseAndEscapeOrOutsideReleaseCancel() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var clicks = 0
        view.onClick = { clicks += 1 }
        view.mouseDown(with: try mouse(.leftMouseDown))
        view.mouseUp(with: try mouse(.leftMouseUp))
        #expect(clicks == 1)
        view.mouseDown(with: try mouse(.leftMouseDown, time: 2))
        view.cancelOperation(nil)
        view.mouseUp(with: try mouse(.leftMouseUp, time: 2))
        #expect(clicks == 1)
        view.mouseDown(with: try mouse(.leftMouseDown, time: 3))
        view.mouseUp(with: try mouse(.leftMouseUp, point: CGPoint(x: 200, y: 10), time: 3))
        #expect(clicks == 1)
    }

    @Test func placementUsesSizePositionSizeAndReadsTheActualResult() {
        let request = request()
        var operations: [String] = []
        let result = SidebarPlacementWriter.apply(request, canContinue: { true },
            readFrame: { operations.append("read"); return request.frame },
            writePosition: { _ in operations.append("position"); return true },
            writeSize: { _ in operations.append("size"); return true })
        #expect(operations == ["size", "position", "size", "read"])
        #expect(result == .placed(request.frame, adjusted: false))
    }

    @Test func appMinimumSizeIsReportedAndTheResultIsKeptReachable() {
        let request = request()
        var frame = CGRect(x: 700, y: 20, width: 600, height: 500)
        let result = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { frame },
            writePosition: { position in frame.origin = position; return true }, writeSize: { _ in false })
        #expect(frame.maxX <= request.workArea.maxX)
        #expect(result == .placed(frame, adjusted: true))
        #expect(result.message != nil)
    }

    @Test func fixedSizeMovementNeverWritesSize() {
        let request = request(resize: false)
        var sizes = 0
        let result = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { request.frame },
            writePosition: { _ in true }, writeSize: { _ in sizes += 1; return true })
        #expect(sizes == 0)
        #expect(result == .placed(request.frame, adjusted: false))
    }

    @Test func cancellationAndPartialFailureDoNotContinueWriting() {
        let request = request()
        var writes = 0
        let cancelled = SidebarPlacementWriter.apply(request, canContinue: { writes == 0 }, readFrame: { request.frame },
            writePosition: { _ in writes += 1; return true }, writeSize: { _ in writes += 1; return true })
        #expect(cancelled == .cancelled && writes == 1)
        writes = 0
        let failed = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { request.frame },
            writePosition: { _ in writes += 1; return false }, writeSize: { _ in writes += 1; return true })
        #expect(writes == 2)
        #expect(failed.message != nil)
    }

    @Test func invalidPlacementNeverTouchesTheWindow() {
        let request = SidebarPlacementRequest(frame: .null, workArea: area, resize: true, desktopGeneration: 1)
        var writes = 0
        let result = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { .zero },
            writePosition: { _ in writes += 1; return true }, writeSize: { _ in writes += 1; return true })
        #expect(writes == 0 && result.message != nil)
    }

    private func request(resize: Bool = true) -> SidebarPlacementRequest {
        SidebarPlacementRequest(frame: CGRect(x: 500, y: 20, width: 500, height: 700),
                                workArea: CGRect(x: 0, y: 20, width: 1000, height: 700),
                                resize: resize, desktopGeneration: 1)
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, point: CGPoint = CGPoint(x: 10, y: 10),
                                  time: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                       windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
