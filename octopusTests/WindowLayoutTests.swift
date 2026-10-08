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
            scope: scope ?? self.scope, frame: frame ?? area, minimum: minimum, canMove: true, canResize: resizable,
            hidden: hidden, minimized: minimized, blocked: blocked, recency: recency, stackOrder: stack)
    }

    private func target(_ snap: SidebarSnapTarget) -> CGRect {
        switch snap {
        case .left: return CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .right: return CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .top: return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case .bottom: return CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        case .maximize: return area
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
                       selection: WindowLayoutSelection = .mostRecent) throws -> WindowLayoutPlan {
        let anchor = window(1, frame: target(snap), recency: 99)
        let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor] + (peers ?? [window(2)])),
            anchorID: anchor.id.window, request: request(snap), selection: selection)
        guard case .ready(let plan) = result else { Issue.record("Fixture should produce a ready plan"); throw FixtureError.notReady }
        return plan
    }

    private enum FixtureError: Error { case notReady }

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
        #expect(recent.frames.count == 1)
        let all = try ready(peers: peers, selection: .allNormal)
        #expect(all.peers.map(\.id.window.windowID) == [3, 2])
        #expect(all.frames.count == 2)
        #expect(all.frames[peers[0].id]!.height == area.height / 2)
        #expect(all.frames[peers[0].id]!.union(all.frames[peers[1].id]!) == WindowLayoutPlanner.oppositeHalf(.left, in: area))
        #expect(!WindowLayoutPlanner.overlaps(all.frames[peers[0].id]!, all.frames[peers[1].id]!))
    }

    @Test func topSnapArrangesAllPeersSideBySideOnTheBottom() throws {
        let all = try ready(.top, peers: [window(2), window(3)], selection: .allNormal)
        #expect(all.frames.values.allSatisfy { $0.minY == area.midY && $0.width == area.width / 2 })
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
        for peer in [window(2, resizable: false), window(2, minimum: CGSize(width: 900, height: 400)), window(2, frame: .null)] {
            let result = WindowLayoutPlanner.plan(snapshot: snapshot([anchor, peer]), anchorID: anchor.id.window, request: request(.left))
            guard case .rejected = result else { Issue.record("Ineligible or oversized peer must reject"); continue }
        }
        let crowded = WindowLayoutPlanner.plan(snapshot: snapshot([anchor] + (2...7).map { window(UInt32($0)) }),
            anchorID: anchor.id.window, request: request(.left), selection: .allNormal)
        guard case .rejected = crowded else { Issue.record("Readability shortage must reject"); return }
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
        window(original.id.window.windowID, frame: frame, recency: original.recency, scope: original.scope,
               generation: generation ?? original.id.generation)
    }

    @Test func successfulBatchWritesOnlyPeersAndConfirmsFinalFrames() throws {
        let plan = try ready(peers: [window(2), window(3)], selection: .allNormal)
        var live = Dictionary(uniqueKeysWithValues: ([plan.anchor] + plan.peers).map { ($0.id, $0) })
        var writes: [WindowLayoutIdentity] = []
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true }, read: { live[$0] },
            write: { id, frame, _ in
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

    @Test func adjustedResultRecoversPeerWithoutMovingTheAnchor() throws {
        let plan = try ready()
        let peer = plan.peers[0]
        var current = peer
        var writes: [CGRect] = []
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true },
            read: { $0 == plan.anchor.id ? plan.anchor : current },
            write: { id, frame, _ in
                #expect(id == peer.id)
                writes.append(frame)
                if writes.count == 1 {
                    let clamped = CGRect(x: frame.minX, y: frame.minY, width: frame.width + 50, height: frame.height)
                    current = moved(peer, to: clamped)
                    return .placed(clamped, adjusted: true)
                }
                current = moved(peer, to: frame)
                return .placed(frame, adjusted: false)
            }, clock: { 0 })
        guard case .stopped = result else { Issue.record("Clamp is not success"); return }
        #expect(writes.count == 2 && writes.last == peer.frame)
        #expect(current.frame == peer.frame)
    }

    @Test func userInterruptionPreventsRecoveryOverTheUsersMove() throws {
        let plan = try ready()
        var current = plan.peers[0]
        var currentToken = true
        var writes = 0
        let userFrame = CGRect(x: -900, y: 240, width: 500, height: 400)
        let result = WindowLayoutExecutor.apply(plan, canContinue: { currentToken },
            read: { $0 == plan.anchor.id ? plan.anchor : current },
            write: { _, _, _ in
                writes += 1
                current = moved(current, to: userFrame)
                currentToken = false
                return .cancelled
            }, clock: { 0 })
        guard case .stopped = result else { Issue.record("Interrupted batch must stop"); return }
        #expect(writes == 1 && current.frame == userFrame)
    }

    @Test func aLateClampedFrameCannotPassTheFinalReadbackGate() throws {
        let plan = try ready()
        var current = plan.peers[0]
        var reads = 0
        let result = WindowLayoutExecutor.apply(plan, canContinue: { true },
            read: { id in
                if id == plan.anchor.id { return plan.anchor }
                reads += 1
                if reads >= 4 { return moved(current, to: area) }
                return current
            }, write: { _, frame, _ in current = moved(current, to: frame); return .placed(frame, adjusted: false) }, clock: { 0 })
        guard case .stopped = result else { Issue.record("Late mismatch must fail"); return }
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
                return window(candidate.window.windowID, recency: candidate.recency)
            })
        #expect(reads == 1 && result.windows.count == 2 && result.complete)
        #expect(result.windows.last?.id.window.windowID == 101)
    }

    @Test func candidateReadFailureRemainsUnknownAndHiddenWindowsAreSkipped() {
        let anchor = window(1, frame: target(.left))
        let candidates = [WindowLayoutCandidate(window: window(2).id.window, recency: 4, stackOrder: 0),
                          WindowLayoutCandidate(window: window(3).id.window, recency: 3, stackOrder: 1)]
        let unknown = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates, displays: snapshot([]).displays,
            desktop: 0, selection: .mostRecent, read: { _ in nil })
        #expect(!unknown.complete)
        let skipped = WindowLayoutPlanner.snapshot(anchor: anchor, candidates: candidates, displays: snapshot([]).displays,
            desktop: 0, selection: .mostRecent, read: { candidate in
                window(candidate.window.windowID, hidden: candidate.window.windowID == 2)
            })
        #expect(skipped.complete && skipped.windows.last?.id.window.windowID == 3)
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
            repeatSizeAfterMove: false, acceptStableMismatch: false, wait: {})
        #expect(result == .placed(desired, adjusted: false))
        #expect(sizes == 1 && positions == 1 && reads == 4)
    }
}
