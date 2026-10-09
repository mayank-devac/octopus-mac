import AppKit
import Testing
@testable import octopus

struct SidebarDragTests {
    private let screen = CGRect(x: -1440, y: 120, width: 1440, height: 900)
    private let area = CGRect(x: -1440, y: 160, width: 1440, height: 830)

    @Test func stationaryCornerPreviewChangesWithModifierPressAndRelease() throws {
        let chord = SidebarCornerSnapShortcut.defaultModifiers
        let points: [(CGPoint, SidebarSnapTarget)] = [
            (CGPoint(x: screen.minX + 10, y: screen.maxY - 10), .topLeft),
            (CGPoint(x: screen.maxX - 10, y: screen.maxY - 10), .topRight),
            (CGPoint(x: screen.minX + 10, y: screen.minY + 10), .bottomLeft),
            (CGPoint(x: screen.maxX - 10, y: screen.minY + 10), .bottomRight)
        ]
        for (point, corner) in points {
            func resolve(_ flags: NSEvent.ModifierFlags) -> SidebarPlacementGeometry.Decision? {
                SidebarPlacementGeometry.resolve(at: point, screen: screen, workArea: area,
                    originalSize: CGSize(width: 500, height: 300), sourceDisplay: screen, canResize: true,
                    distance: 120, modifiers: flags, cornerModifiers: chord, moveSize: .fullScreen)
            }
            let free = try #require(resolve([]))
            let preview = try #require(resolve(chord))
            #expect(preview.snap == corner && preview.resize)
            #expect(preview.frame == SidebarPlacementGeometry.frame(for: corner, in: area))
            #expect(resolve(chord) == preview) // Drop uses the same resolver and geometry.
            #expect(resolve([]) == free && free.snap == nil && !free.resize)
        }
    }

    @Test func visibleDisplayFreeMovesUsePreferenceWhileExplicitSnapsTakePrecedence() throws {
        let original = CGSize(width: 500, height: 300)
        let other = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func resolve(_ point: CGPoint, source: CGRect?, preference: VisibleDisplayMoveSize,
                     canResize: Bool = true) throws -> SidebarPlacementGeometry.Decision {
            try #require(SidebarPlacementGeometry.resolve(at: point, screen: screen, workArea: area,
                originalSize: original, sourceDisplay: source, canResize: canResize, distance: 120,
                modifiers: [], cornerModifiers: [], moveSize: preference))
        }
        let middle = CGPoint(x: screen.midX, y: screen.midY)
        let full = try resolve(middle, source: other, preference: .fullScreen)
        #expect(full.frame == area && full.resize && full.snap == nil)
        let originalMove = try resolve(middle, source: other, preference: .original)
        #expect(originalMove.frame.size == original && originalMove.resize && originalMove.snap == nil)
        for (source, preference, resizable) in [(Optional(screen), VisibleDisplayMoveSize.fullScreen, true), (nil, .fullScreen, true),
                                               (Optional(other), .fullScreen, false)] {
            let move = try resolve(middle, source: source, preference: preference, canResize: resizable)
            #expect(move.frame.size == original && !move.resize)
        }
        let half = try resolve(CGPoint(x: screen.minX + 10, y: screen.midY), source: other, preference: .fullScreen)
        #expect(half.snap == .left && half.frame == SidebarPlacementGeometry.frame(for: .left, in: area))
        #expect(SidebarPlacementGeometry.sourceDisplay(for: CGRect(x: 100, y: 100, width: 600, height: 400),
            displays: [screen, other]) == other)
    }

    @Test func visibleDisplayMovePreferenceDefaultsToFullScreenAndPersists() throws {
        let name = "SidebarDragTests.moveSize.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(WindowLayoutSettings.moveSize(in: defaults) == .fullScreen)
        defaults.set(VisibleDisplayMoveSize.original.rawValue, forKey: WindowLayoutSettings.moveSizeKey)
        #expect(WindowLayoutSettings.moveSize(in: try #require(UserDefaults(suiteName: name))) == .original)
        defaults.set("invalid", forKey: WindowLayoutSettings.moveSizeKey)
        #expect(WindowLayoutSettings.moveSize(in: defaults) == .fullScreen)
    }

    @Test(arguments: [SidebarSnapTarget.topLeft, .topRight, .bottomLeft, .bottomRight])
    func cornerWriterKeepsAppClampsAnchored(_ corner: SidebarSnapTarget) {
        let workArea = CGRect(x: -1400, y: -400, width: 1400, height: 900)
        let quarter = SidebarPlacementGeometry.cornerFrame(corner, size: CGSize(width: 700, height: 450), inAX: workArea)
        let request = SidebarPlacementRequest(frame: quarter, workArea: workArea, resize: true, desktopGeneration: 0, snap: corner)
        var actual = workArea
        let result = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { actual },
            writePosition: { actual.origin = $0; return true },
            writeSize: { actual.size = CGSize(width: max(800, $0.width), height: max(550, $0.height)); return true }, wait: {})
        #expect(result == .placed(actual, adjusted: true))
        #expect(actual == SidebarPlacementGeometry.cornerFrame(corner, size: CGSize(width: 800, height: 550), inAX: workArea))
    }

    @Test func foregroundActivationYieldsBeforeRequestingAndHonoursRejection() {
        #expect(SidebarFocusActivation.canRequestAfterRaise(.cannotComplete))
        #expect(!SidebarFocusActivation.canRequestAfterRaise(.invalidUIElement))
        #expect(!SidebarFocusActivation.canRequestAfterRaise(.apiDisabled))
        var steps: [String] = []
        let accepted = SidebarFocusActivation.request(canContinue: { true },
            yieldActivation: { steps.append("yield") }, activate: { steps.append("activate all windows"); return false })
        #expect(!accepted)
        #expect(steps == ["yield", "activate all windows"])
    }

    @Test func cancelledFocusCannotActivateOrStealFocusAfterYield() {
        var current = true
        var activations = 0
        let accepted = SidebarFocusActivation.request(canContinue: { current },
            yieldActivation: { current = false }, activate: { activations += 1; return true })
        #expect(!accepted && activations == 0)
        #expect(!SidebarFocusActivation.request(canContinue: { false }, yieldActivation: {}, activate: { activations += 1; return true }))
        #expect(activations == 0)
    }

    @Test func windowTargetedFocusUsesWindowRequestBeforeAppFallback() {
        let target = SidebarWindowID(pid: 42, windowID: 7)
        var focused: [SidebarWindowID] = []
        var activations: [NSApplication.ActivationOptions] = []
        #expect(SidebarFocusActivation.activate(target: target,
            focusWindow: { focused.append($0); return true }, activateApp: { activations.append($0); return true }))
        #expect(focused == [target] && activations.isEmpty)

        // When WindowServer rejects the window, fall back without surfacing every app window.
        #expect(SidebarFocusActivation.activate(target: target,
            focusWindow: { _ in false }, activateApp: { activations.append($0); return true }))
        #expect(activations == [[]])
    }

    @Test func appOnlyFocusActivatesAllWindowsWithoutWindowServerFocus() {
        var focused = 0
        var activations: [NSApplication.ActivationOptions] = []
        #expect(!SidebarFocusActivation.activate(target: nil,
            focusWindow: { _ in focused += 1; return true }, activateApp: { activations.append($0); return false }))
        #expect(focused == 0 && activations == [[.activateAllWindows]])
    }

    @Test func windowServerFocusRejectsMissingIdentifiersSoCallersFallBack() {
        #expect(!SidebarWindowFocusRequest(0, 7))
        #expect(!SidebarWindowFocusRequest(ProcessInfo.processInfo.processIdentifier, 0))
    }

    @Test func screenEdgesAndCornersChooseTheExpectedLayouts() {
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1430, y: 1010), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -10, y: 1010), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1430, y: 130), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -10, y: 130), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1420, y: 600), screen: screen) == .left)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -20, y: 600), screen: screen) == .right)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -700, y: 1000), screen: screen) == .top)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -700, y: 140), screen: screen) == .bottom)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -700, y: 600), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: 5, y: 600), screen: screen) == nil)
        #expect(SidebarPlacementGeometry.snap(at: CGPoint(x: -1400, y: 980), screen: screen) == nil)
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
        #expect(SidebarPlacementGeometry.frame(for: .top, in: area).maxY == area.maxY)
        #expect(SidebarPlacementGeometry.frame(for: .bottom, in: area).minY == area.minY)
    }

    @Test func snappingStartsBeforeThePointerReachesTheBorderAndClearsWhenLeaving() {
        let points: [(CGPoint, SidebarSnapTarget)] = [
            (CGPoint(x: screen.minX + 120, y: screen.midY), .left),
            (CGPoint(x: screen.maxX - 120, y: screen.midY), .right),
            (CGPoint(x: screen.midX, y: screen.maxY - 120), .top),
            (CGPoint(x: screen.midX, y: screen.minY + 120), .bottom)
        ]
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

    @Test func maximizeActionOnlySkipsAVisibleWindowAlreadyFillingTheWorkArea() {
        let workArea = CGRect(x: -1440, y: 160, width: 1440, height: 830)
        func target(frame: CGRect, resizable: Bool = true, minimized: Bool = false, hidden: Bool = false) -> SidebarPlacementTarget {
            SidebarPlacementTarget(id: SidebarWindowID(pid: 42, windowID: 1), frame: frame,
                canResize: resizable, isMinimized: minimized, isHidden: hidden, desktopGeneration: 0)
        }
        #expect(SidebarMaximizePolicy.disposition(target: target(frame: workArea), workArea: workArea,
            displayIsFullScreen: false) == .noOp)
        #expect(SidebarMaximizePolicy.disposition(target: target(frame: workArea, minimized: true), workArea: workArea,
            displayIsFullScreen: false) == .place)
        #expect(SidebarMaximizePolicy.disposition(target: target(frame: workArea, hidden: true), workArea: workArea,
            displayIsFullScreen: false) == .place)
        #expect(SidebarMaximizePolicy.disposition(target: target(frame: workArea.insetBy(dx: 10, dy: 10)), workArea: workArea,
            displayIsFullScreen: false) == .place)
        #expect(SidebarMaximizePolicy.disposition(target: target(frame: workArea.insetBy(dx: 10, dy: 10), resizable: false),
            workArea: workArea, displayIsFullScreen: false) == .focus)
        #expect(SidebarMaximizePolicy.disposition(target: nil, workArea: workArea,
            displayIsFullScreen: false) == .focus)
        #expect(SidebarMaximizePolicy.disposition(target: target(frame: workArea), workArea: workArea,
            displayIsFullScreen: true) == .focus)
    }

    @Test func placementSkipsActivationOnlyWhenTheExactWindowIsAlreadyFocused() {
        let target = SidebarWindowID(pid: 42, windowID: 7)
        #expect(SidebarPlacementFocusPolicy.isAlreadyFocused(target, frontmostPID: 42, focusedWindowID: 7))
        #expect(!SidebarPlacementFocusPolicy.isAlreadyFocused(target, frontmostPID: 12, focusedWindowID: 7))
        #expect(!SidebarPlacementFocusPolicy.isAlreadyFocused(target, frontmostPID: 42, focusedWindowID: 8))
        #expect(!SidebarPlacementFocusPolicy.isAlreadyFocused(target, frontmostPID: nil, focusedWindowID: 7))
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

    @Test func sameDisplayPlacementSkipsDisplayProbeAndWritesSizeOnce() {
        let request = request()
        var operations: [String] = []
        let result = SidebarPlacementWriter.apply(request, canContinue: { true },
            readFrame: { operations.append("read"); return request.frame },
            writePosition: { _ in operations.append("position"); return true },
            writeSize: { _ in operations.append("size"); return true })
        #expect(operations == ["size", "position", "read"])
        #expect(result == .placed(request.frame, adjusted: false))
    }

    @Test func sameDisplayMaximizeDoesNotRepeatTheSizeWrite() {
        let base = request()
        let placement = SidebarPlacementRequest(frame: base.frame, workArea: base.workArea,
            resize: true, desktopGeneration: base.desktopGeneration, snap: .maximize)
        var sizeWrites = 0
        let result = SidebarPlacementWriter.apply(placement, canContinue: { true },
            readFrame: { placement.frame }, writePosition: { _ in true },
            writeSize: { _ in sizeWrites += 1; return true },
            repeatSizeAfterMove: placement.crossesDisplay)
        #expect(sizeWrites == 1)
        #expect(result == .placed(placement.frame, adjusted: false))
    }

    @Test func crossDisplayPlacementRepeatsSizeAfterMove() {
        let base = request()
        let request = SidebarPlacementRequest(frame: base.frame, workArea: base.workArea, resize: true,
            desktopGeneration: base.desktopGeneration, crossesDisplay: true)
        var operations: [String] = []
        let result = SidebarPlacementWriter.apply(request, canContinue: { true },
            readFrame: { operations.append("read"); return request.frame },
            writePosition: { _ in operations.append("position"); return true },
            writeSize: { _ in operations.append("size"); return true })
        #expect(operations == ["read", "size", "position", "size", "read"])
        #expect(result == .placed(request.frame, adjusted: false))
    }

    @Test func aWindowOnAnotherDisplayLandsOnTheTargetDisplayBeforeBeingResized() {
        let base = request()
        let request = SidebarPlacementRequest(frame: base.frame, workArea: base.workArea, resize: base.resize,
            desktopGeneration: base.desktopGeneration, crossesDisplay: true)
        var frame = CGRect(x: -1400, y: 20, width: 1000, height: 700)
        var operations: [String] = []
        let result = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { frame },
            writePosition: { position in operations.append("position \(Int(position.x))"); frame.origin = position; return true },
            writeSize: { size in operations.append("size \(Int(size.width))"); frame.size = size; return true }, wait: {})
        // No shrunken intermediate on the source display: move across, then size-position-size.
        #expect(operations == ["position 0", "size 500", "position 500", "size 500"])
        #expect(result == .placed(request.frame, adjusted: false))
    }

    @Test func droppedSizeWritesAreReassertedInsteadOfShiftingTheWindowToTheLeft() {
        let base = request()
        let request = SidebarPlacementRequest(frame: base.frame, workArea: base.workArea, resize: base.resize,
            desktopGeneration: base.desktopGeneration, crossesDisplay: true)
        // The app ignores the first two size writes (the window is still changing display).
        var frame = CGRect(x: 0, y: 20, width: 1000, height: 700)
        var dropped = 2
        var positionWrites: [CGPoint] = []
        let result = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { frame },
            writePosition: { position in positionWrites.append(position); frame.origin = position; return true },
            writeSize: { size in
                if dropped > 0 { dropped -= 1 } else { frame.size = size }
                return true
            }, wait: {})
        // Moving left to "fit" the stale 1000-point width is what made right snaps land left.
        #expect(positionWrites == [request.frame.origin])
        #expect(result == .placed(request.frame, adjusted: false))
    }

    @Test func aSmallWindowCanGrowToTheFullSizeOfALargerTargetDisplay() {
        // Display 1 is 600 wide at x -600...0; the target display is 1000 wide at x 0...1000.
        let maximise = SidebarPlacementRequest(frame: CGRect(x: 0, y: 20, width: 1000, height: 700),
            workArea: CGRect(x: 0, y: 20, width: 1000, height: 700), resize: true,
            desktopGeneration: 1, crossesDisplay: true)
        var frame = CGRect(x: -600, y: 20, width: 300, height: 400)
        let result = SidebarPlacementWriter.apply(maximise, canContinue: { true }, readFrame: { frame },
            writePosition: { frame.origin = $0; return true },
            writeSize: { size in
                // macOS fits a size to the display the window is currently on.
                let onTarget = maximise.workArea.contains(CGPoint(x: frame.midX, y: frame.midY))
                frame.size = onTarget ? size : CGSize(width: min(size.width, 600), height: min(size.height, 700))
                return true
            }, wait: {})
        #expect(result == .placed(maximise.frame, adjusted: false))
    }

    @Test func slowResizeIsNotMistakenForAnOutOfBoundsWindowAndMovedToTheOppositeSide() {
        let request = request()
        // A maximised window whose app applies the size write after a few reads.
        var frame = CGRect(x: 0, y: 20, width: 1000, height: 700)
        var pending: CGSize?
        var reads = 0
        var positionWrites: [CGPoint] = []
        let result = SidebarPlacementWriter.apply(request, canContinue: { true },
            readFrame: { reads += 1; if reads > 3, let pending { frame.size = pending }; return frame },
            writePosition: { position in positionWrites.append(position); frame.origin = position; return true },
            writeSize: { size in pending = size; return true },
            wait: {})
        #expect(positionWrites == [request.frame.origin])
        #expect(result == .placed(request.frame, adjusted: false))
    }

    @Test func nativeSizeFailureIsNotReportedAsAnAppMinimum() {
        let request = request()
        var frame = CGRect(x: 700, y: 20, width: 600, height: 500)
        let result = SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { frame },
            writePosition: { position in frame.origin = position; return true }, writeSize: { _ in false }, wait: {})
        #expect(frame.maxX <= request.workArea.maxX)
        guard case .failed = result else { Issue.record("A refused setter must remain a failure"); return }
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
