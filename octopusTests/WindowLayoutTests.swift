import AppKit
import Testing
@testable import octopus

struct WindowLayoutTests {
    // Pair fixtures deliberately start on different visible displays; neither is a third-party companion.
    private func pairFixture(direction: PairDropDirection = .left) throws -> WindowPairSnapPlan {
        let destination = WindowLayoutDisplay(id: scope.displayID, frame: area, workArea: area, scale: 1, name: "Target")
        let source = window(1, frame: CGRect(x: 200, y: 160, width: 700, height: 600),
            scope: WindowLayoutScope(displayID: "source", spaceID: 1))
        let target = window(2)
        return try #require(WindowLayoutPlanner.pair(source: source, target: target, direction: direction, display: destination))
    }

    private func pairMoved(_ window: WindowLayoutWindow, frame: CGRect, scope: WindowLayoutScope) -> WindowLayoutWindow {
        WindowLayoutWindow(id: window.id, scope: scope, frame: frame, minimum: window.minimum,
            minimumReported: window.minimumReported,
            canMove: window.canMove, canResize: window.canResize, hidden: window.hidden, minimized: window.minimized,
            blocked: window.blocked, recency: window.recency, stackOrder: window.stackOrder)
    }

    @Test(arguments: PairDropDirection.allCases)
    func explicitPairUsesComplementaryHalvesOfTheTargetDisplay(_ direction: PairDropDirection) throws {
        let pair = try pairFixture(direction: direction)
        #expect(pair.destination == pair.target.scope)
        #expect(pair.source.scope != pair.destination)
        #expect(pair.sourceFrame.union(pair.targetFrame) == area)
        #expect(!WindowLayoutPlanner.overlaps(pair.sourceFrame, pair.targetFrame))
        if direction == .top { #expect(pair.sourceFrame.minY == area.minY) }
        if direction == .bottom { #expect(pair.sourceFrame.minY == area.midY) }
    }

    @Test func pairRejectsEitherWindowsKnownMinimumBeforeCreatingAWritePlan() {
        let display = WindowLayoutDisplay(id: scope.displayID, frame: area, workArea: area, scale: 1, name: "Target")
        let tooWide = CGSize(width: area.width / 2 + 1, height: 200)
        #expect(WindowLayoutPlanner.pair(source: window(1, minimum: tooWide), target: window(2),
            direction: .left, display: display) == nil)
        #expect(WindowLayoutPlanner.pair(source: window(1), target: window(2, minimum: tooWide),
            direction: .left, display: display) == nil)
    }

    @Test func explicitPairWritesOnlyBothSelectedWindowsAndDoesNotSelectThirdWindows() throws {
        let pair = try pairFixture()
        var windows = [pair.source.id: pair.source, pair.target.id: pair.target]
        var writes: [WindowLayoutIdentity] = []
        let result = WindowPairSnapService.execute(pair, canContinue: { true }, read: { windows[$0.id] },
            write: { window, frame, scope in
                writes.append(window.id)
                windows[window.id] = pairMoved(window, frame: frame, scope: scope)
                return .placed(frame, adjusted: false)
            })
        guard case .applied(let a, let b) = result else { Issue.record("Valid pair should complete"); return }
        #expect(writes == [pair.target.id, pair.source.id])
        #expect(a.scope == pair.destination && b.scope == pair.destination)
        #expect(a.frame == pair.sourceFrame && b.frame == pair.targetFrame)
    }

    @Test func pairPartialFailureDoesNotInventAutomaticRollbackOwnership() throws {
        let pair = try pairFixture()
        var windows = [pair.source.id: pair.source, pair.target.id: pair.target]
        var writes = 0
        let result = WindowPairSnapService.execute(pair, canContinue: { true }, read: { windows[$0.id] },
            write: { window, frame, scope in
                writes += 1
                if writes == 1 {
                    windows[window.id] = pairMoved(window, frame: frame, scope: scope)
                    return .placed(frame, adjusted: false)
                }
                // A different actor changes the target while source placement fails, without cancellation.
                windows[pair.target.id] = pairMoved(pair.target,
                    frame: CGRect(x: -1000, y: 220, width: 400, height: 400), scope: pair.destination)
                return .failed("App rejected the source resize")
            })
        guard case .stopped = result else { Issue.record("Partial pair must not report success"); return }
        #expect(writes == 2)
        #expect(windows[pair.target.id]?.frame.width == 400)
    }

    @Test func pairCancellationAndStaleFramesRejectBeforeWrites() throws {
        let pair = try pairFixture()
        var writes = 0
        let result = WindowPairSnapService.execute(pair, canContinue: { false }, read: { $0 },
            write: { _, frame, _ in writes += 1; return .placed(frame, adjusted: false) })
        guard case .stopped = result else { Issue.record("Cancelled pair must stop"); return }
        #expect(writes == 0)
        let stale = WindowPairSnapService.execute(pair, canContinue: { true },
            read: { pairMoved($0, frame: .zero, scope: $0.scope) },
            write: { _, frame, _ in writes += 1; return .placed(frame, adjusted: false) })
        guard case .stopped = stale else { Issue.record("Changed frames must stop"); return }
        #expect(writes == 0)
    }

    @Test func pairUndoRequiresIntactPostFramesAndVisibleOriginalScopes() throws {
        let pair = try pairFixture()
        let a = pairMoved(pair.source, frame: pair.sourceFrame, scope: pair.destination)
        let b = pairMoved(pair.target, frame: pair.targetFrame, scope: pair.destination)
        let undo = WindowPairUndoRecord(plan: pair, sourceAfter: a, targetAfter: b)
        var windows = [a.id: a, b.id: b]
        var writes = 0
        let result = WindowPairSnapService.undo(undo, canContinue: { true }, scopeVisible: { _ in true },
            read: { windows[$0.id] }, write: { current, frame, scope in
                writes += 1
                windows[current.id] = pairMoved(current, frame: frame, scope: scope)
                return .placed(frame, adjusted: false)
            })
        guard case .applied = result else { Issue.record("Intact pair should undo"); return }
        #expect(writes == 2 && windows[a.id]?.scope == pair.source.scope && windows[b.id]?.frame == pair.target.frame)
        writes = 0
        let unavailable = WindowPairSnapService.undo(undo, canContinue: { true }, scopeVisible: { _ in false },
            read: { $0 }, write: { _, frame, _ in writes += 1; return .placed(frame, adjusted: false) })
        guard case .stopped = unavailable else { Issue.record("Inactive original scopes forbid Undo"); return }
        #expect(writes == 0)
        let changed = WindowPairSnapService.undo(undo, canContinue: { true }, scopeVisible: { _ in true },
            read: { pairMoved($0, frame: .zero, scope: $0.scope) },
            write: { _, frame, _ in writes += 1; return .placed(frame, adjusted: false) })
        guard case .stopped = changed else { Issue.record("A user move after pairing forbids Undo"); return }
        #expect(writes == 0)
    }

    @Test func optionalAXNullAndUnsupportedAreAbsenceButTimeoutIsNot() throws {
        #expect(WindowAXAttributeValue(NSNull()).optionalBool == false)
        var unsupported = AXError.attributeUnsupported
        let missing = try #require(AXValueCreate(.axError, &unsupported))
        #expect(WindowAXAttributeValue(missing).optionalAbsence)
        var timeout = AXError.cannotComplete
        let failed = try #require(AXValueCreate(.axError, &timeout))
        #expect(!WindowAXAttributeValue(failed).optionalAbsence)
        #expect(WindowAXAttributeValue(failed).optionalBool == nil)
        #expect(!WindowAXAttributeValue(failed).needsIndividualFallback)
    }

    private let area = CGRect(x: -1440, y: 160, width: 1440, height: 900)
    private let scope = WindowLayoutScope(displayID: "destination", spaceID: 22)

    private func window(_ number: UInt32, frame: CGRect? = nil, recency: UInt64 = 1,
                        scope: WindowLayoutScope? = nil, hidden: Bool = false, minimized: Bool = false,
                        blocked: Bool = false, resizable: Bool = true, minimum: CGSize = .zero,
                        generation: UInt64 = 1, stack: Int = 5) -> WindowLayoutWindow {
        WindowLayoutWindow(id: WindowLayoutIdentity(window: SidebarWindowID(pid: 42, windowID: number), generation: generation),
            scope: scope ?? self.scope, frame: frame ?? area, minimum: minimum, minimumReported: minimum != .zero,
            canMove: true, canResize: resizable,
            hidden: hidden, minimized: minimized, blocked: blocked, recency: recency, stackOrder: stack)
    }

    private func target(_ snap: SidebarSnapTarget) -> CGRect {
        switch snap {
        case .left: return CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .right: return CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .top: return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case .bottom: return CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        case .maximize: return area
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return SidebarPlacementGeometry.cornerFrame(snap,
                size: CGSize(width: area.width / 2, height: area.height / 2), inAX: area)
        }
    }

    private func request(_ snap: SidebarSnapTarget) -> SidebarPlacementRequest {
        SidebarPlacementRequest(frame: target(snap), workArea: area, resize: true, desktopGeneration: 0, snap: snap)
    }

    private func snapshot(_ windows: [WindowLayoutWindow], complete: Bool = true) -> WindowLayoutSnapshot {
        WindowLayoutSnapshot(windows: windows,
            displays: [WindowLayoutDisplay(id: scope.displayID, frame: area, workArea: area, scale: 2, name: "Destination")],
            complete: complete, desktopGeneration: 0)
    }

    private func ready(_ snap: SidebarSnapTarget = .left, peers: [WindowLayoutWindow]? = nil,
                       selection: WindowLayoutSelection = .mostRecent,
                       maximumWindows: Int = WindowLayoutSettings.defaultMaximumWindows) throws -> WindowLayoutPlan {
        let anchor = window(1, frame: target(snap), recency: 99)
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor] + (peers ?? [window(2)])),
            anchorID: anchor.id.window, request: request(snap), selection: selection, maximumWindows: maximumWindows)
        guard case .ready(let plan) = result else { Issue.record("Fixture should produce a ready plan"); throw FixtureError.notReady }
        return plan
    }

    private func prepared(peers: [WindowLayoutWindow]? = nil, snap: SidebarSnapTarget = .left,
                          enabled: Bool = true, selection: WindowLayoutSelection = .allNormal) throws
                          -> (plan: WindowLayoutPlan, fallbackReason: String?) {
        let anchor = window(1, frame: area, recency: 99)
        let state = snapshot([anchor] + (peers ?? [window(2)]))
        return try #require(WindowLayoutPlanner.preparedPlan(snapshot: state, anchor: anchor,
            request: request(snap), destination: scope, display: state.displays[0],
            settings: WindowSnapSettings(enabled: enabled, selection: selection, maximumWindows: 4), generation: 0))
    }

    @Test func preSnapPlanningKeepsTheSourceFrameAndUsesDestinationCompanions() throws {
        let sourceScope = WindowLayoutScope(displayID: "source", spaceID: 1)
        let source = window(1, frame: CGRect(x: 100, y: 50, width: 900, height: 700), scope: sourceScope)
        let peers = [window(2, recency: 10), window(3, recency: 5), window(4, recency: 2), window(5, recency: 1)]
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([source] + peers), anchorID: source.id.window,
            request: request(.left), selection: .allNormal, maximumWindows: 4,
            preferredCompanion: peers[1].id.window, preparingFor: scope)
        guard case .ready(let plan) = result else { Issue.record("Pre-snap source scope must be supported"); return }
        #expect(plan.anchor.frame == source.frame && plan.anchor.scope == sourceScope)
        #expect(plan.scope == scope && plan.peers.map(\.id) == [peers[1].id, peers[0].id, peers[2].id])
        #expect(plan.frames.count == 4 && plan.frames[peers[3].id] == nil)
        #expect(plan.frames[source.id] != source.frame)
    }

    @Test func infeasibleCompanionsProduceASingleWindowPreviewAndCommit() throws {
        let bad = window(2, minimum: CGSize(width: 2000, height: 200))
        let selected = try prepared(peers: [bad])
        #expect(selected.plan.peers.isEmpty && selected.fallbackReason != nil)
        var live = [selected.plan.anchor.id: selected.plan.anchor, bad.id: bad]
        var writes: [WindowLayoutIdentity] = []
        let outcome = WindowLayoutExecutor.applyPrepared(selected.plan, canContinue: { true }, read: { live[$0.id] },
            write: { window, frame in
                writes.append(window.id)
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: false)
            })
        #expect(outcome.reason == nil && writes == [selected.plan.anchor.id])
        #expect(live[bad.id]?.frame == bad.frame)
    }

    @Test func disabledAdjustmentNoCompanionsAndRecentCornersStillPrepareThePrimarySnap() throws {
        let disabled = try prepared(enabled: false)
        let empty = try prepared(peers: [])
        let corner = try prepared(snap: .topRight, selection: .mostRecent)
        for selected in [disabled, empty, corner] {
            #expect(selected.plan.peers.isEmpty && selected.plan.frames.count == 1)
            #expect(selected.fallbackReason == nil)
        }
        let recent = try prepared(peers: [window(2), window(3)], selection: .mostRecent)
        #expect(recent.plan.peers.count == 1)
        let anchor = window(1)
        let timedOut = try #require(WindowLayoutPlanner.preparedPlan(snapshot: nil, anchor: anchor, request: request(.left),
            destination: scope, display: snapshot([anchor]).displays[0],
            settings: WindowSnapSettings(enabled: true, selection: .allNormal, maximumWindows: 4), generation: 0))
        #expect(timedOut.plan.peers.isEmpty && timedOut.fallbackReason != nil)
    }

    @Test func preSnapPreviewIgnoresBoundsInferredFromAnOlderAcceptedSize() {
        let anchor = window(1)
        let peer = window(2)
        let oldSample = WindowLayoutSizeConstraint(minimum: CGSize(width: 2000, height: 200), maximum: area.size)
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor, peer]), anchorID: anchor.id.window,
            request: request(.left), learned: [peer.id: oldSample], preparingFor: scope)
        guard case .ready(let plan) = result else { Issue.record("Old observations must not block a preview"); return }
        #expect(plan.constraints[peer.id]?.minimum.width == WindowLayoutSettings.readabilityMinimum.width)
        #expect(!anchor.minimumReported && !peer.minimumReported)
    }

    @Test func preparedCommitUsesExactlyPreviewedFramesAndCountsNativeSizeSetters() throws {
        let plan = try prepared(peers: [window(2), window(3)]).plan
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var sizes: [WindowLayoutIdentity: Int] = [:]
        var order: [WindowLayoutIdentity] = []
        let outcome = WindowLayoutExecutor.applyPrepared(plan, canContinue: { true }, read: { live[$0.id] },
            write: { window, frame in
                order.append(window.id)
                let request = SidebarPlacementRequest(frame: frame, workArea: area, resize: true,
                    desktopGeneration: 0, snap: window.id == plan.anchor.id ? plan.snap : nil)
                return SidebarPlacementWriter.apply(request, canContinue: { true }, readFrame: { live[window.id]?.frame },
                    writePosition: { origin in
                        guard var current = live[window.id]?.frame else { return false }
                        current.origin = origin
                        live[window.id] = moved(window, to: current)
                        return true
                    }, writeSize: { size in
                        guard var current = live[window.id]?.frame else { return false }
                        sizes[window.id, default: 0] += 1
                        current.size = size
                        live[window.id] = moved(window, to: current)
                        return true
                    }, singleAttempt: true, wait: {})
            })
        #expect(outcome.reason == nil && order == plan.windows.map(\.id))
        for window in plan.windows {
            #expect(sizes[window.id] == 1)
            #expect(outcome.achieved[window.id]?.frame == plan.frames[window.id])
        }
    }

    @Test func preparedCommitStopsOnFirstCompanionClampWithoutRewritingTheAnchor() throws {
        let plan = try prepared(peers: [window(2), window(3), window(4)]).plan
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        let outcome = WindowLayoutExecutor.applyPrepared(plan, canContinue: { true }, read: { live[$0.id] },
            write: { window, target in
                writes.append(window.id)
                var frame = target
                if window.id == plan.peers[0].id { frame.size.width += 40 }
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: frame != target)
            })
        #expect(outcome.reason != nil && writes == [plan.anchor.id, plan.peers[0].id])
        #expect(outcome.achieved.count == 2 && live[plan.anchor.id]?.frame == plan.frames[plan.anchor.id])
        #expect(live[plan.peers[1].id]?.frame == plan.peers[1].frame)
        #expect(live[plan.peers[2].id]?.frame == plan.peers[2].frame)
    }

    @Test func preparedCommitRejectsAnyStaleParticipantBeforeTheFirstWrite() throws {
        let plan = try prepared().plan
        var writes = 0
        let peer = plan.peers[0]
        let outcome = WindowLayoutExecutor.applyPrepared(plan, canContinue: { true }, read: {
            $0.id == peer.id ? moved($0, to: $0.frame.offsetBy(dx: 30, dy: 0)) : $0
        }, write: { _, frame in writes += 1; return .placed(frame, adjusted: false) })
        #expect(outcome.reason != nil && outcome.achieved.isEmpty && writes == 0)
    }

    @Test func preparedCrossDisplayCommitChecksOriginalScopeThenConfirmsDestination() throws {
        let anchor = window(1, frame: CGRect(x: 100, y: 50, width: 900, height: 700),
                            scope: WindowLayoutScope(displayID: "source", spaceID: 1))
        let state = snapshot([anchor, window(2)])
        let plan = try #require(WindowLayoutPlanner.preparedPlan(snapshot: state, anchor: anchor, request: request(.left),
            destination: scope, display: state.displays[0],
            settings: WindowSnapSettings(enabled: true, selection: .mostRecent, maximumWindows: 4), generation: 0)).plan
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        let outcome = WindowLayoutExecutor.applyPrepared(plan, canContinue: { true }, read: { live[$0.id] },
            write: { window, target in
                live[window.id] = pairMoved(window, frame: target, scope: plan.scope)
                return .placed(target, adjusted: false)
            })
        #expect(outcome.reason == nil && outcome.achieved[anchor.id]?.scope == scope)
        #expect(plan.anchor.scope != scope)
    }

    @Test func preparedPreviewRejectsNewGesturesSettingsFocusAndDisplayChanges() throws {
        let plan = try prepared().plan
        let displays = snapshot(plan.windows).displays
        let settings = WindowSnapSettings(enabled: true, selection: .allNormal, maximumWindows: 4)
        let preview = WindowLayoutPreparedSnap(plan: plan, request: request(.left), displays: displays,
            settings: settings, generation: 7, frontmostPID: 42, frontmostWindow: plan.anchor.id.window, fallbackReason: nil)
        #expect(preview.isCurrent(generation: 7, settings: settings, displays: displays, frontmostPID: 42))
        #expect(!preview.isCurrent(generation: 8, settings: settings, displays: displays, frontmostPID: 42))
        #expect(!preview.isCurrent(generation: 7, settings: settings, displays: displays, frontmostPID: 43))
        let changed = WindowSnapSettings(enabled: false, selection: .allNormal, maximumWindows: 4)
        #expect(!preview.isCurrent(generation: 7, settings: changed, displays: displays, frontmostPID: 42))
        let changedMode = WindowSnapSettings(enabled: true, selection: .allNormal, maximumWindows: 4, mode: .current)
        #expect(!preview.isCurrent(generation: 7, settings: changedMode, displays: displays, frontmostPID: 42))
        let screen = displays[0]
        let resized = WindowLayoutDisplay(id: screen.id, frame: screen.frame, workArea: screen.workArea.insetBy(dx: 20, dy: 0),
            scale: screen.scale, name: screen.name)
        #expect(!preview.isCurrent(generation: 7, settings: settings, displays: [resized], frontmostPID: 42))
    }

    @Test func partialCompanionUndoNeverTouchesTheAnchorOrAnExternalChange() throws {
        let plan = try prepared(peers: [window(2), window(3)]).plan
        let peer = plan.peers[0]
        let achieved = try #require(plan.frames[peer.id])
        var live = [peer.id: moved(peer, to: achieved)]
        var writes: [WindowLayoutIdentity] = []
        let result = WindowLayoutExecutor.restore(plan, achieved: [peer.id: achieved], canContinue: { true },
            read: { live[$0] }, write: { window, frame, _ in
                writes.append(window.id)
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: false)
            }, participants: [peer.id])
        guard case .applied = result else { Issue.record("Verified partial companion Undo should work"); return }
        #expect(writes == [peer.id] && live[peer.id]?.frame == peer.frame)
        live[peer.id] = moved(peer, to: achieved.offsetBy(dx: 50, dy: 0))
        writes.removeAll()
        let stale = WindowLayoutExecutor.restore(plan, achieved: [peer.id: achieved], canContinue: { true },
            read: { live[$0] }, write: { window, frame, _ in
                writes.append(window.id); return .placed(frame, adjusted: false)
            }, participants: [peer.id])
        guard case .stopped = stale else { Issue.record("An external move must prevent Undo"); return }
        #expect(writes.isEmpty)
    }

    private enum FixtureError: Error { case notReady }

    @Test func pairedWindowFocusRaisesCompanionThenLeavesDraggedWindowActive() throws {
        let plan = try ready(.left)
        let companion = plan.peers[0]
        var requests: [WindowLayoutWindow] = []
        var completions: [() -> Void] = []
        var finished = false
        WindowPairSnapService.focusAfterPair(companion: companion, dragged: plan.anchor,
            focus: { window, completion in requests.append(window); completions.append(completion) },
            completion: { finished = true })
        #expect(requests.map(\.id) == [companion.id])
        #expect(!finished)
        let first = try #require(completions.first)
        first()
        #expect(requests.map(\.id) == [companion.id, plan.anchor.id])
        #expect(!finished)
        let last = try #require(completions.last)
        last()
        #expect(finished)
    }

    @Test(arguments: [SidebarSnapTarget.topLeft, .topRight, .bottomLeft, .bottomRight])
    func cornerSnapMirrorsTwoCompanionRegionsAndPreservesMRU(_ corner: SidebarSnapTarget) throws {
        let plan = try ready(corner, peers: [window(2, recency: 9), window(3, recency: 4)], selection: .allNormal)
        #expect(plan.frames[plan.anchor.id] == target(corner))
        let first = try #require(plan.frames[plan.peers[0].id])
        let second = try #require(plan.frames[plan.peers[1].id])
        #expect(first.width == area.width / 2 && first.height == area.height)
        #expect(first.minX == (corner.isRightCorner ? area.minX : area.midX))
        #expect(second.width == area.width / 2 && second.height == area.height / 2)
        #expect(second.minY == (corner.isBottomCorner ? area.minY : area.midY))
        #expect(second.minX == target(corner).minX)
        #expect(!WindowLayoutPlanner.overlaps(first, second))
        #expect(!WindowLayoutPlanner.overlaps(first, target(corner)))
        #expect(!WindowLayoutPlanner.overlaps(second, target(corner)))
        #expect(first.width * first.height + second.width * second.height + target(corner).width * target(corner).height == area.width * area.height)
    }

    @Test func cornerSnapsLeaveZeroOrOneSelectedCompanionUntouched() {
        for selection in [WindowLayoutSelection.mostRecent, .allNormal] {
            for peers in [[], [window(2)]] {
                let anchor = window(1, frame: target(.topRight))
                let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor] + peers),
                    anchorID: anchor.id.window, request: request(.topRight), selection: selection)
                guard case .noPeer = result else { Issue.record("Corner needs two selected companions"); continue }
            }
        }
        let anchor = window(1, frame: target(.topRight))
        let recent = WindowLayoutPlanner.plan(snapshot: snapshot([anchor, window(2), window(3)]),
            anchorID: anchor.id.window, request: request(.topRight), selection: .mostRecent)
        guard case .noPeer = recent else { Issue.record("Recent mode must never arrange a corner"); return }
    }

    @Test func cornerLimitsMoveBothDividingLinesWithoutLosingTheChosenCorner() throws {
        let requested = request(.bottomRight)
        let achieved = SidebarPlacementGeometry.cornerFrame(.bottomRight, size: CGSize(width: 800, height: 550), inAX: area)
        let anchor = window(1, frame: achieved)
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor, window(2), window(3)]),
            anchorID: anchor.id.window, request: requested, selection: .allNormal, achievedFrame: achieved)
        guard case .ready(let plan) = result else { Issue.record("Verified clamp should replan"); return }
        let frame = try #require(plan.frames[anchor.id])
        #expect(frame.width == 800 && frame.height == 550)
        #expect(frame.maxX == area.maxX && frame.maxY == area.maxY)
        #expect(plan.frames[window(2).id]?.width == area.width - 800)
        #expect(plan.frames[window(3).id]?.height == area.height - 550)
    }

    @Test func largerCornerGroupsFillAreaAndTryNearbyPopulationsForLimits() throws {
        let peers = (2...7).map { window(UInt32($0), recency: UInt64(10 - $0), minimum: CGSize(width: 320, height: 240)) }
        let plan = try ready(.topRight, peers: peers, selection: .allNormal, maximumWindows: 8)
        let frames = plan.windows.map { plan.frames[$0.id]! }
        #expect(frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height } == area.width * area.height)
        for (index, frame) in frames.enumerated() {
            #expect(area.contains(frame))
            #expect(!frames.dropFirst(index + 1).contains { WindowLayoutPlanner.overlaps(frame, $0) })
        }
        // Two preferred band windows cannot fit as a stack or adjacent columns.
        // A nearby count puts the wide MRU window in the band and stacks the others in the quarter.
        let constrained = try ready(.topRight,
            peers: [window(2, recency: 9, minimum: CGSize(width: 900, height: 550)),
                    window(3, recency: 8, minimum: CGSize(width: 320, height: 450)),
                    window(4, recency: 7)], selection: .allNormal)
        #expect(constrained.frames[window(2).id]?.height == 900)
        #expect((constrained.frames[window(3).id]?.height ?? 0) >= 450)
    }

    @Test func impossibleCornerLimitsRejectBeforeAnyWrite() {
        let anchor = window(1, frame: target(.topRight))
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor,
            window(2, minimum: CGSize(width: 1400, height: 800)),
            window(3, minimum: CGSize(width: 1400, height: 800))]),
            anchorID: anchor.id.window, request: request(.topRight), selection: .allNormal)
        guard case .rejected = result else { Issue.record("Impossible corner must be rejected before execution"); return }
    }

    @Test func hiddenCornerCompanionLimitReflowsAndUndoRestoresAllThreeWindows() throws {
        let plan = try ready(.bottomRight, peers: [window(2, recency: 9), window(3, recency: 8)], selection: .allNormal)
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var clamped = false
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { current, frame, _ in
                if current.id == plan.peers[1].id && !clamped {
                    clamped = true
                    let achieved = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 550)
                    live[current.id] = moved(current, to: achieved)
                    return .placed(achieved, adjusted: true)
                }
                live[current.id] = moved(current, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 })
        guard case .applied(let achieved) = result else { Issue.record("Feasible hidden limit should reflow"); return }
        #expect(achieved[plan.anchor.id]?.maxY == area.maxY)
        #expect(achieved[plan.anchor.id]?.height == 350)
        let restored = WindowLayoutExecutor.restore(plan, achieved: achieved, canContinue: { true }, read: { live[$0] },
            write: { current, frame, _ in live[current.id] = moved(current, to: frame); return .placed(frame, adjusted: false) }, clock: { 0 })
        guard case .applied = restored else { Issue.record("Corner Undo should restore all participants"); return }
        #expect(plan.windows.allSatisfy { live[$0.id]?.frame == $0.frame })
    }

    @Test func partiallyAppliedCornerKeepsVerifiedUndoAndDoesNotLearnSetterFailure() throws {
        let plan = try ready(.topRight, peers: [window(2, recency: 9), window(3, recency: 8)], selection: .allNormal)
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var writes = 0, learned = 0
        var progress: [WindowLayoutIdentity: CGRect]?
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { current, frame, _ in
                writes += 1
                if writes == 2 { return .failed("Refused") }
                live[current.id] = moved(current, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 }, onLearn: { _, _ in learned += 1 }, onProgress: { progress = $0 })
        guard case .stopped = result else { Issue.record("Setter failure must stop the layout"); return }
        #expect(writes == 2 && learned == 0)
        let achieved = try #require(progress)
        #expect(achieved[plan.peers[0].id] == live[plan.peers[0].id]?.frame)
        let restored = WindowLayoutExecutor.restore(plan, achieved: achieved, canContinue: { true }, read: { live[$0] },
            write: { current, frame, _ in live[current.id] = moved(current, to: frame); return .placed(frame, adjusted: false) }, clock: { 0 })
        guard case .applied = restored else { Issue.record("Verified partial corner should offer guarded Undo"); return }
    }

    @Test(arguments: [SidebarSnapTarget.left, .right, .top, .bottom])
    func complementaryHalvesUseDestinationAXCoordinates(_ snap: SidebarSnapTarget) throws {
        let plan = try ready(snap)
        let frame = try #require(plan.frames[plan.peers[0].id])
        #expect(plan.anchor.frame.union(frame) == area)
        #expect(!WindowLayoutPlanner.overlaps(plan.anchor.frame, frame))
        #expect(frame.minX >= area.minX && frame.maxX <= area.maxX)
        #expect(frame.minY >= area.minY && frame.maxY <= area.maxY)
        if snap == .top { #expect(frame.minY == area.midY) }
        if snap == .bottom { #expect(frame.minY == area.minY) }
    }

    @Test func mostRecentModeMovesOnePeerAndAllModePartitionsTheRemainder() throws {
        let peers = [window(2, recency: 3), window(3, recency: 7)]
        let recent = try ready(peers: peers)
        #expect(recent.peers.map(\.id.window.windowID) == [3])
        #expect(recent.frames.count == 2) // The snapped window can share a changed split.
        let all = try ready(peers: peers, selection: .allNormal)
        #expect(all.peers.map(\.id.window.windowID) == [3, 2])
        #expect(all.frames.count == 3)
        #expect(all.frames[peers[0].id]!.height == area.height / 2)
        #expect(all.frames[peers[0].id]!.union(all.frames[peers[1].id]!) == WindowLayoutPlanner.oppositeHalf(.left, in: area))
        #expect(!WindowLayoutPlanner.overlaps(all.frames[peers[0].id]!, all.frames[peers[1].id]!))
    }

    @Test func topSnapArrangesAllPeersSideBySideOnTheBottom() throws {
        let all = try ready(.top, peers: [window(2), window(3)], selection: .allNormal)
        #expect(all.peers.allSatisfy { all.frames[$0.id]?.minY == area.midY
            && all.frames[$0.id]?.width == area.width / 2 })
        #expect(all.frames[all.anchor.id] == all.anchor.frame)
    }

    @Test func reportedMinimumShrinksTheSnappedHalfOnlyAsMuchAsNeeded() throws {
        let peer = window(2, minimum: CGSize(width: 320, height: 600))
        let plan = try ready(.top, peers: [peer])
        #expect(plan.frames[plan.anchor.id]?.height == area.height - 600)
        #expect(plan.frames[peer.id]?.height == 600)
        #expect(plan.frames[plan.anchor.id]!.union(plan.frames[peer.id]!) == area)
    }

    @Test func gridFallbackKeepsPeersInTheRemainingRegion() throws {
        let peers = [window(2, minimum: CGSize(width: 900, height: 200)),
                     window(3, minimum: CGSize(width: 900, height: 200))]
        let plan = try ready(.top, peers: peers, selection: .allNormal)
        #expect(peers.allSatisfy { plan.frames[$0.id]?.width == area.width })
        #expect(peers.allSatisfy { plan.frames[$0.id]?.height == area.height / 4 })
        #expect(!WindowLayoutPlanner.overlaps(plan.frames[peers[0].id]!, plan.frames[peers[1].id]!))
    }

    @Test func unequalShelfGroupsFitOneTallWindowBesideThreeShortWindows() throws {
        let peers = [window(2, minimum: CGSize(width: 400, height: 800)),
                     window(3, minimum: CGSize(width: 400, height: 200)),
                     window(4, minimum: CGSize(width: 400, height: 200)),
                     window(5, minimum: CGSize(width: 400, height: 200))]
        let plan = try ready(.left, peers: peers, selection: .allNormal, maximumWindows: 8)
        let tall = try #require(plan.frames[peers[0].id])
        #expect(tall.height == area.height)
        #expect(peers.dropFirst().allSatisfy { plan.frames[$0.id]?.minX == tall.maxX })
        #expect(plan.frames.values.reduce(CGFloat(0)) { $0 + $1.width * $1.height } == area.width * area.height)
    }

    @Test func allocatorRejectsMalformedAndDuplicateInputsWithoutConvertingThemToPixels() {
        let anchor = window(1).id, peer = window(2).id
        let invalid = WindowLayoutSizeConstraint(minimum: CGSize(width: CGFloat.nan, height: 200), maximum: area.size)
        let valid = WindowLayoutSizeConstraint(minimum: CGSize(width: 320, height: 200), maximum: area.size)
        #expect(WindowLayoutAllocator.allocate(workArea: area, snap: .left, scale: 2,
            anchor: anchor, peers: [peer], constraints: [anchor: valid, peer: invalid]) == nil)
        #expect(WindowLayoutAllocator.allocate(workArea: area, snap: .left, scale: 2,
            anchor: anchor, peers: [peer, peer], constraints: [anchor: valid, peer: valid]) == nil)
        #expect(WindowLayoutAllocator.allocate(workArea: area, snap: .left, scale: CGFloat.greatestFiniteMagnitude,
            anchor: anchor, peers: [peer], constraints: [anchor: valid, peer: valid]) == nil)
    }

    @Test func onlyDestinationDesktopNormalVisibleWindowsParticipate() throws {
        let source = WindowLayoutScope(displayID: "source", spaceID: 22)
        let otherSpace = WindowLayoutScope(displayID: "destination", spaceID: 23)
        let plan = try ready(peers: [window(2, recency: 2), window(3, recency: 20, scope: source),
            window(4, recency: 30, scope: otherSpace), window(5, recency: 40, hidden: true),
            window(6, recency: 50, minimized: true), window(7, recency: 60, blocked: true)])
        #expect(plan.peers.map(\.id.window.windowID) == [2])
    }

    @Test func unobservedHistoryUsesSurfaceOrderRatherThanEnumeration() throws {
        let plan = try ready(peers: [window(2, recency: 0, stack: 7), window(3, recency: 0, stack: 1)])
        #expect(plan.peers.map(\.id.window.windowID) == [3])
    }

    @Test func fixedAndMinimumRestrictedWindowsRejectBeforeMutation() {
        let anchor = window(1, frame: target(.left))
        for peer in [window(2, resizable: false), window(2, minimum: CGSize(width: area.width - 200, height: 400)), window(2, frame: .null)] {
            let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor, peer]), anchorID: anchor.id.window, request: request(.left))
            guard case .rejected = result else { Issue.record("Ineligible or oversized peer must reject"); continue }
        }
        let impossible = WindowLayoutPlanner.plan(snapshot: snapshot([
            window(1, frame: target(.top), minimum: CGSize(width: 320, height: 500)),
            window(2, minimum: CGSize(width: 320, height: 600))]),
            anchorID: anchor.id.window, request: request(.top))
        guard case .rejected = impossible else { Issue.record("Two minima cannot exceed the display"); return }
    }

    @Test func unknownSnapshotDuplicateIdentityAndWrongAnchorCannotLaunchAdjustment() {
        let anchor = window(1, frame: target(.left))
        let fixtures = [snapshot([anchor, window(2)], complete: false), snapshot([anchor, window(2), window(2)]),
                        snapshot([window(1), window(2)])]
        for fixture in fixtures {
            let result = WindowLayoutPlanner.plan(snapshot: fixture, anchorID: anchor.id.window, request: request(.left))
            guard case .rejected = result else { Issue.record("Unknown/stale snapshot must reject"); continue }
        }
    }

    @Test func noCompanionDoesNotTurnIntoAnAppWideFallback() {
        let anchor = window(1, frame: target(.top))
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor]), anchorID: anchor.id.window, request: request(.top))
        guard case .noPeer = result else { Issue.record("A lone anchor needs no adjustment"); return }
    }

    private func moved(_ original: WindowLayoutWindow, to frame: CGRect, generation: UInt64? = nil) -> WindowLayoutWindow {
        WindowLayoutWindow(id: WindowLayoutIdentity(window: original.id.window,
            generation: generation ?? original.id.generation), scope: original.scope, frame: frame,
            minimum: original.minimum, minimumReported: original.minimumReported,
            canMove: original.canMove, canResize: original.canResize, hidden: original.hidden,
            minimized: original.minimized, blocked: original.blocked,
            recency: original.recency, stackOrder: original.stackOrder)
    }

    @Test func successfulBatchWritesOnlyPeersAndConfirmsFinalFrames() throws {
        let plan = try ready(peers: [window(2), window(3)], selection: .allNormal)
        var live = Dictionary(uniqueKeysWithValues: ([plan.anchor] + plan.peers).map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { window, frame, _ in
                let id = window.id
                writes.append(id)
                live[id] = moved(live[id]!, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 })
        guard case .applied(let frames) = result else { Issue.record("Batch must complete"); return }
        #expect(Set(writes) == Set(plan.peers.map(\.id)))
        #expect(!writes.contains(plan.anchor.id))
        #expect(frames == plan.frames)
        #expect(live[plan.anchor.id]!.frame == plan.anchor.frame)
    }

    @Test func staleGenerationOrCancellationRejectsWithZeroWrites() throws {
        let plan = try ready()
        for cancelled in [false, true] {
            var writes = 0
            let result = WindowLayoutExecutor.apply(plan, canContinue: { !cancelled },
                read: { id in id == plan.anchor.id ? plan.anchor : moved(plan.peers[0], to: plan.peers[0].frame, generation: 9) },
                write: { _, frame, _ in writes += 1; return .placed(frame, adjusted: false) }, clock: { 0 })
            guard case .stopped = result else { Issue.record("Stale batch must stop"); continue }
            #expect(writes == 0)
        }
    }

    @Test func hiddenMinimumReflowsAnchorAndCompanionWithoutRollback() throws {
        let plan = try ready()
        let peer = plan.peers[0]
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        var learned: WindowLayoutSizeConstraint?
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true },
            read: { live[$0] },
            write: { window, frame, _ in
                let id = window.id
                writes.append(id)
                if id == peer.id && writes.count == 1 {
                    let clamped = CGRect(x: area.maxX - frame.width - 50, y: frame.minY,
                        width: frame.width + 50, height: frame.height)
                    live[id] = moved(peer, to: clamped)
                    return .placed(clamped, adjusted: true)
                }
                live[id] = moved(live[id]!, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 }, onLearn: { id, value in if id == peer.id { learned = value } })
        guard case .applied(let achieved) = result else { Issue.record("A feasible clamp should reflow"); return }
        #expect(writes == [peer.id, plan.anchor.id])
        #expect(learned?.minimum.width == plan.frames[peer.id]!.width + 50)
        #expect(achieved[plan.anchor.id]!.width == area.width / 2 - 50)
        #expect(achieved[peer.id]!.union(achieved[plan.anchor.id]!) == area)
    }

    @Test func unreportedHeightLimitIsLearnedAndUndoRestoresBothFrames() throws {
        let plan = try ready(.top)
        let peer = plan.peers[0]
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        var learned: WindowLayoutSizeConstraint?
        let outcome = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { window, frame, _ in
                let id = window.id
                writes.append(id)
                if id == peer.id && writes.count == 1 {
                    let clamped = CGRect(x: area.minX, y: area.minY + area.height - 600,
                        width: area.width, height: 600)
                    live[id] = moved(peer, to: clamped)
                    return .placed(clamped, adjusted: true)
                }
                live[id] = moved(live[id]!, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 }, onLearn: { _, value in learned = value })
        guard case .applied(let achieved) = outcome else { Issue.record("Feasible limit should reflow"); return }
        #expect(writes == [peer.id, plan.anchor.id])
        #expect(learned?.minimum.height == 600)
        #expect(achieved[plan.anchor.id]?.height == area.height - 600)
        #expect(achieved[peer.id]?.height == 600)
        let remembered = try #require(learned)
        let next = WindowLayoutPlanner.plan(snapshot: snapshot(plan.windows), anchorID: plan.anchor.id.window,
            request: request(.top), learned: [peer.id: remembered])
        guard case .ready(let nextPlan) = next else { Issue.record("Known limit should plan directly"); return }
        #expect(nextPlan.frames[peer.id]?.height == 600)
        #expect(nextPlan.frames[plan.anchor.id]?.height == area.height - 600)
        let restored = WindowLayoutExecutor.restore(plan, achieved: achieved, canContinue: { true },
            read: { live[$0] }, write: { window, frame, _ in
                let id = window.id
                live[id] = moved(live[id]!, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 })
        guard case .applied = restored else { Issue.record("Undo should restore both frames"); return }
        #expect(live[plan.anchor.id]?.frame == plan.anchor.frame)
        #expect(live[peer.id]?.frame == peer.frame)
    }

    @Test func undoRejectsAChangedParticipantBeforeAnyWrite() throws {
        let plan = try ready(.top)
        let achieved = plan.frames
        var writes = 0
        let changedAnchor = moved(plan.anchor, to: .zero)
        let result = WindowLayoutExecutor.restore(plan, achieved: achieved, canContinue: { true },
            read: { $0 == plan.anchor.id ? changedAnchor : moved(plan.peers[0], to: achieved[plan.peers[0].id]!) },
            write: { _, frame, _ in writes += 1; return .placed(frame, adjusted: false) }, clock: { 0 })
        guard case .stopped = result else { Issue.record("Changed anchor must block Undo"); return }
        #expect(writes == 0)
    }

    @Test func wholeOperationDeadlineStopsBeforeAnotherResize() throws {
        let plan = try ready()
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var time: TimeInterval = 0
        var writes = 0
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { window, frame, _ in
                let id = window.id
                writes += 1
                live[id] = moved(live[id]!, to: frame)
                time = 2
                return .placed(frame, adjusted: false)
            }, clock: { time }, deadline: 1)
        guard case .stopped = result else { Issue.record("Expired batch must stop"); return }
        #expect(writes == 1)
    }

    @Test func failedWriteNeverRollsBackAnExternalFrameChange() throws {
        let plan = try ready()
        var current = plan.peers[0]
        var writes = 0
        var learned = false
        let userFrame = CGRect(x: -900, y: 240, width: 500, height: 400)
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true },
            read: { $0 == plan.anchor.id ? plan.anchor : current },
            write: { _, _, _ in
                writes += 1
                current = moved(current, to: userFrame)
                return .failed("The frame changed outside Octopus")
            }, clock: { 0 }, onLearn: { _, _ in learned = true })
        guard case .stopped = result else { Issue.record("Failed batch must stop"); return }
        #expect(writes == 1 && current.frame == userFrame)
        #expect(!learned)
    }

    @Test func writerReceivesTheVerifiedStartingFrameRatherThanAReplacementRead() throws {
        let plan = try ready()
        let peer = plan.peers[0]
        var current = peer
        let external = CGRect(x: -900, y: 240, width: 500, height: 400)
        var captured: CGRect?
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true },
            read: { $0 == plan.anchor.id ? plan.anchor : current },
            write: { expected, _, _ in
                captured = expected.frame
                current = moved(peer, to: external)
                // The native boundary compares current state with the executor's supplied frame.
                return SidebarPlacementGeometry.matches(current.frame, expected.frame) ? .placed(external, adjusted: false) : .cancelled
            }, clock: { 0 })
        guard case .stopped = result else { Issue.record("An intervening move must stop the write"); return }
        #expect(captured == peer.frame && current.frame == external)
    }

    @Test func cancellationDuringTheLastReadCannotReportSuccess() throws {
        let plan = try ready()
        var current = plan.peers[0]
        var peerReads = 0
        var cancelled = false
        let result = WindowLayoutExecutor.apply(plan, canContinue: { !cancelled },
            read: { id in
                if id == plan.anchor.id { return plan.anchor }
                peerReads += 1
                if peerReads == 4 { cancelled = true }
                return current
            }, write: { _, frame, _ in current = moved(current, to: frame); return .placed(frame, adjusted: false) }, clock: { 0 })
        guard case .stopped = result else { Issue.record("Final cancellation must not be success"); return }
    }

    @Test func aLateClampedFrameCannotPassTheFinalReadbackGate() throws {
        let plan = try ready()
        var current = plan.peers[0]
        var reads = 0
        var learned = false
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true },
            read: { id in
                if id == plan.anchor.id { return plan.anchor }
                reads += 1
                if reads >= 4 { return moved(current, to: area) }
                return current
            }, write: { _, frame, _ in current = moved(current, to: frame); return .placed(frame, adjusted: false) },
            clock: { 0 }, onLearn: { _, _ in learned = true })
        guard case .stopped = result else { Issue.record("Late mismatch must fail"); return }
        #expect(!learned)
    }

    @Test func alreadyArrangedPeerRequiresNoAXWrites() throws {
        let original = try ready()
        let peer = moved(original.peers[0], to: original.frames[original.peers[0].id]!)
        let plan = try ready(peers: [peer])
        var writes = 0
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true },
            read: { $0 == plan.anchor.id ? plan.anchor : peer },
            write: { _, frame, _ in writes += 1; return .placed(frame, adjusted: false) }, clock: { 0 })
        guard case .applied = result else { Issue.record("Intact layout should succeed"); return }
        #expect(writes == 0)
    }

    @Test func settingsDefaultToEnabledAndMostRecentAndPreserveOptOut() throws {
        let suite = "WindowLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WindowLayoutSettings.enabled(in: defaults))
        #expect(WindowLayoutSettings.selection(in: defaults) == .mostRecent)
        defaults.set(false, forKey: WindowLayoutSettings.enabledKey)
        defaults.set("corrupt", forKey: WindowLayoutSettings.selectionKey)
        #expect(!WindowLayoutSettings.enabled(in: defaults))
        #expect(WindowLayoutSettings.selection(in: defaults) == .mostRecent)
        defaults.set(WindowLayoutSelection.allNormal.rawValue, forKey: WindowLayoutSettings.selectionKey)
        #expect(WindowLayoutSettings.selection(in: defaults) == .allNormal)
    }

    @Test func allWindowCapSelectsThreeRecentCompanionsWithoutReadingOlderWindows() throws {
        let anchor = window(1, frame: target(.left))
        let candidates = (2...101).map { number in
            WindowLayoutCandidate(window: window(UInt32(number)).id.window, recency: UInt64(number), stackOrder: number)
        }
        var reads = 0
        let result = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates,
            displays: snapshot([]).displays, desktop: 0, selection: .allNormal, read: { candidate in
                reads += 1
                return .window(window(candidate.window.windowID, recency: candidate.recency))
            })
        #expect(reads == 3)
        #expect(result.complete && result.failureReason == nil)
        #expect(result.windows.map(\.id.window.windowID) == [1, 101, 100, 99])
        guard case .ready(let plan) = WindowLayoutPlanner.plan(snapshot: result, anchorID: anchor.id.window,
            request: request(.left), selection: .allNormal) else {
            Issue.record("A busy Desktop should produce a capped layout"); return
        }
        #expect(plan.peers.map(\.id.window.windowID) == [101, 100, 99])
        let old = window(2)
        var live = Dictionary(uniqueKeysWithValues: (plan.windows + [old]).map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        let applied = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { window, frame, _ in
                writes.append(window.id)
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 })
        guard case .applied = applied else { Issue.record("Capped layout should complete"); return }
        #expect(!writes.contains(old.id) && live[old.id]?.frame == old.frame)
        let direct = WindowLayoutPlanner.plan(snapshot: snapshot([anchor, window(2, recency: 2),
            window(3, recency: 3), window(4, recency: 4), window(5, recency: 5)]),
            anchorID: anchor.id.window, request: request(.left), selection: .allNormal)
        guard case .ready(let capped) = direct else {
            Issue.record("Direct snapshots must also enforce the cap"); return
        }
        #expect(capped.peers.map(\.id.window.windowID) == [5, 4, 3])
    }

    @Test func previousFrontmostWindowPrecedesTwoRecentExtrasEvenWithOlderHistory() throws {
        let anchor = window(1, frame: target(.left))
        let previous = window(2, recency: 1)
        let windows = [previous, window(3, recency: 30), window(4, recency: 40), window(5, recency: 50)]
        let candidates = windows.map { WindowLayoutCandidate(window: $0.id.window, recency: $0.recency, stackOrder: 0) }
        var reads: [UInt32] = []
        let selected = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates,
            displays: snapshot([]).displays, desktop: 0, selection: .allNormal,
            preferredCompanion: previous.id.window, read: { candidate in
                reads.append(candidate.window.windowID)
                return .window(windows.first { $0.id.window == candidate.window }!)
            })
        #expect(reads == [2, 5, 4])
        let result = WindowLayoutPlanner.plan(snapshot: selected, anchorID: anchor.id.window,
            request: request(.left), selection: .allNormal, preferredCompanion: previous.id.window)
        guard case .ready(let plan) = result else { Issue.record("Previous window should be selected"); return }
        #expect(plan.peers.map(\.id.window.windowID) == [2, 5, 4])
    }

    @Test func unavailableOrFixedPreviousWindowFallsBackToEligibleRecentWindows() {
        let anchor = window(1, frame: target(.left))
        let previous = window(2, recency: 1, resizable: false)
        let windows = [previous, window(3, recency: 30), window(4, recency: 40), window(5, recency: 50)]
        let candidates = windows.map { WindowLayoutCandidate(window: $0.id.window, recency: $0.recency, stackOrder: 0) }
        let selected = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates,
            displays: snapshot([]).displays, desktop: 0, selection: .allNormal,
            preferredCompanion: previous.id.window, read: { candidate in
                .window(windows.first { $0.id.window == candidate.window }!)
            })
        #expect(selected.complete && selected.windows.map(\.id.window.windowID) == [1, 5, 4, 3])
        let absent = WindowLayoutPlanner.plan(snapshot: snapshot([anchor] + Array(windows.dropFirst())),
            anchorID: anchor.id.window, request: request(.left), selection: .allNormal,
            preferredCompanion: previous.id.window)
        guard case .ready(let plan) = absent else { Issue.record("Missing preferred window should not block snapping"); return }
        #expect(plan.peers.map(\.id.window.windowID) == [5, 4, 3])
    }

    @Test func windowCapPersistsAndClampsInvalidSavedValues() throws {
        let suite = "WindowLayoutCapTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WindowLayoutSettings.maximumWindows(in: defaults) == 4)
        defaults.set(6, forKey: WindowLayoutSettings.maximumWindowsKey)
        #expect(WindowLayoutSettings.maximumWindows(in: defaults) == 6)
        defaults.set(-10, forKey: WindowLayoutSettings.maximumWindowsKey)
        #expect(WindowLayoutSettings.maximumWindows(in: defaults) == 2)
        defaults.set(100, forKey: WindowLayoutSettings.maximumWindowsKey)
        #expect(WindowLayoutSettings.maximumWindows(in: defaults) == 8)
    }

    @Test func snapModeDefaultsToLegacyAndPersistsTheCurrentChoice() throws {
        let suite = "WindowSnapModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WindowLayoutSettings.mode(in: defaults) == .legacy)
        defaults.set(WindowSnapMode.current.rawValue, forKey: WindowLayoutSettings.modeKey)
        #expect(WindowLayoutSettings.mode(in: defaults) == .current)
        defaults.set("unknown", forKey: WindowLayoutSettings.modeKey)
        #expect(WindowLayoutSettings.mode(in: defaults) == .legacy)
        defaults.set(WindowSnapMode.legacy.rawValue, forKey: WindowLayoutSettings.modeKey)
        #expect(WindowLayoutSettings.mode(in: defaults) == .legacy)
    }

    @Test(arguments: [SidebarSnapTarget.left, .right, .top, .bottom])
    func reportedMinimumExpandsEitherPreviewAreaBeforeTheSingleResize(_ snap: SidebarSnapTarget) throws {
        let horizontal = snap == .left || snap == .right
        let needed = horizontal ? CGSize(width: area.width / 2 + 40, height: 200)
                                : CGSize(width: 320, height: area.height / 2 + 40)
        for constrainedAnchor in [true, false] {
            let anchor = window(1, minimum: constrainedAnchor ? needed : .zero)
            let peer = window(2, minimum: constrainedAnchor ? .zero : needed)
            let state = snapshot([anchor, peer])
            let selected = try #require(WindowLayoutPlanner.preparedPlan(snapshot: state, anchor: anchor,
                request: request(snap), destination: scope, display: state.displays[0],
                settings: WindowSnapSettings(enabled: true, selection: .mostRecent, maximumWindows: 4, mode: .current),
                generation: 0))
            let plan = selected.plan
            #expect(selected.fallbackReason == nil && plan.peers.count == 1)
            let a = try #require(plan.frames[anchor.id]), b = try #require(plan.frames[peer.id])
            let expanded = constrainedAnchor ? a : b
            #expect(horizontal ? expanded.width >= needed.width : expanded.height >= needed.height)
            #expect(a.union(b) == area && !WindowLayoutPlanner.overlaps(a, b))
            #expect(constrainedAnchor ? (horizontal ? b.width < area.width / 2 : b.height < area.height / 2)
                                     : (horizontal ? a.width < area.width / 2 : a.height < area.height / 2))
            var live = [anchor.id: anchor, peer.id: peer]
            var sizes: [WindowLayoutIdentity: Int] = [:]
            let outcome = WindowLayoutExecutor.applyPrepared(plan, canContinue: { true }, read: { live[$0.id] },
                write: { window, frame in
                    let placement = SidebarPlacementRequest(frame: frame, workArea: area, resize: true, desktopGeneration: 0)
                    return SidebarPlacementWriter.apply(placement, canContinue: { true }, readFrame: { live[window.id]?.frame },
                        writePosition: { origin in
                            guard var rect = live[window.id]?.frame else { return false }
                            rect.origin = origin; live[window.id] = moved(window, to: rect); return true
                        }, writeSize: { size in
                            guard var rect = live[window.id]?.frame else { return false }
                            sizes[window.id, default: 0] += 1
                            rect.size = size; live[window.id] = moved(window, to: rect); return true
                        }, singleAttempt: true, wait: {})
                })
            #expect(outcome.reason == nil && sizes[anchor.id] == 1 && sizes[peer.id] == 1)
            #expect(outcome.achieved[anchor.id]?.frame == a && outcome.achieved[peer.id]?.frame == b)
        }
    }

    @Test(arguments: [SidebarSnapTarget.left, .right, .top, .bottom])
    func acceptedSideSizeMovesTheSharedSplitWithoutRetryingTheDefault(_ snap: SidebarSnapTarget) throws {
        let horizontal = snap == .left || snap == .right
        let size = horizontal ? CGSize(width: 900, height: area.height) : CGSize(width: area.width, height: 600)
        let achieved = SidebarPlacementGeometry.snapFrame(snap, size: size, inAX: area)
        let anchor = window(1, frame: achieved) // AX minimum absent; only verified achieved size reveals it.
        let peer = window(2)
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor, peer]), anchorID: anchor.id.window,
            request: request(snap), achievedFrame: achieved)
        guard case .ready(let plan) = result else { Issue.record("Accepted side snap should be planned"); return }
        let a = try #require(plan.frames[anchor.id]), b = try #require(plan.frames[peer.id])
        #expect(a == achieved)
        #expect(a.union(b) == area && !WindowLayoutPlanner.overlaps(a, b))
        var live = Dictionary(uniqueKeysWithValues: plan.windows.map { ($0.id, $0) })
        var anchorWrites = 0
        let applied = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { window, frame, _ in
                if window.id == anchor.id { anchorWrites += 1 }
                live[window.id] = moved(window, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 })
        guard case .applied = applied else { Issue.record("Accepted side layout should complete"); return }
        #expect(anchorWrites == 0)
    }

    @Test func lateCompletionCannotOverrideANewerUserAction() {
        let old = WindowLayoutCompletedSnap(window: window(1).id.window, request: request(.top), startedAt: 10)
        #expect(old.isCurrent(after: 10))
        #expect(!old.isCurrent(after: 11))
    }

    @Test func recentModeReadsOneCandidateEvenWithOneHundredOtherWindows() {
        let anchor = window(1, frame: target(.left))
        let candidates = (2...101).map { number in
            WindowLayoutCandidate(window: window(UInt32(number)).id.window, recency: UInt64(number), stackOrder: number)
        }
        var reads = 0
        let result = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates, displays: snapshot([]).displays,
            desktop: 0, selection: .mostRecent, read: { candidate in
                reads += 1
                return .window(window(candidate.window.windowID, recency: candidate.recency))
            })
        #expect(reads == 1 && result.windows.count == 2 && result.complete)
        #expect(result.windows.last?.id.window.windowID == 101)
    }

    @Test func candidateReadFailureRemainsUnknownAndHiddenWindowsAreSkipped() {
        let anchor = window(1, frame: target(.left))
        let candidates = [WindowLayoutCandidate(window: window(2).id.window, recency: 4, stackOrder: 0),
                          WindowLayoutCandidate(window: window(3).id.window, recency: 3, stackOrder: 1)]
        let unknown = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates, displays: snapshot([]).displays,
            desktop: 0, selection: .mostRecent, read: { _ in .unavailable })
        #expect(!unknown.complete)
        let skipped = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates, displays: snapshot([]).displays,
            desktop: 0, selection: .mostRecent, read: { candidate in
                .window(window(candidate.window.windowID, hidden: candidate.window.windowID == 2))
            })
        #expect(skipped.complete && skipped.windows.last?.id.window.windowID == 3)
        let excluded = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates, displays: snapshot([]).displays,
            desktop: 0, selection: .mostRecent, read: { candidate in
                candidate.window.windowID == 2 ? .excluded : .window(window(3))
            })
        #expect(excluded.complete && excluded.windows.last?.id.window.windowID == 3)
    }

    @Test func batchedFrameDecoderRejectsMalformedAndErrorValues() throws {
        var position = CGPoint(x: -100, y: 30)
        var size = CGSize(width: 800, height: 500)
        let pointValue = try #require(AXValueCreate(.cgPoint, &position))
        let sizeValue = try #require(AXValueCreate(.cgSize, &size))
        #expect(AXUIElement.decodeWindowFrame(position: pointValue, size: sizeValue) == CGRect(origin: position, size: size))
        #expect(AXUIElement.decodeWindowFrame(position: sizeValue, size: pointValue) == nil)
        #expect(AXUIElement.decodeWindowFrame(position: NSNumber(value: 4), size: sizeValue) == nil)
        var error = AXError.cannotComplete
        let errorValue = try #require(AXValueCreate(.axError, &error))
        #expect(AXUIElement.decodeWindowFrame(position: errorValue, size: sizeValue) == nil)
    }

    @Test func companionWriterResizesOnceAndWaitsForDelayedReachableFrames() {
        let desired = CGRect(x: 0, y: 20, width: 1000, height: 350)
        let workArea = CGRect(x: 0, y: 20, width: 1000, height: 700)
        let request = SidebarPlacementRequest(frame: desired, workArea: workArea, resize: true, desktopGeneration: 0)
        var frame = workArea
        var reads = 0, sizes = 0, positions = 0
        var pendingSize: CGSize?
        let result = SidebarPlacementWriter.apply(request, canContinue: { true },
            readFrame: {
                reads += 1
                if reads >= 4, let pendingSize { frame.size = pendingSize }
                return frame
            }, writePosition: { point in positions += 1; frame.origin = point; return true },
            writeSize: { size in sizes += 1; pendingSize = size; return true },
            acceptStableMismatch: false, wait: {})
        #expect(result == .placed(desired, adjusted: false))
        #expect(sizes == 1 && positions == 1 && reads == 4)
    }
}
