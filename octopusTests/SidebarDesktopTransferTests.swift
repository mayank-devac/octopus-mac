import AppKit
import Testing
@testable import octopus

struct SidebarDesktopTransferTests {
    @MainActor @Test func notchWidthIncludesMonitorHeadersDesktopSeparatorsAndEmptyDisplays() {
        let app = Application(NSRunningApplication.current)
        let first = desktop(10), second = desktop(20)
        let third = desktop(30, display: "monitor-b")
        let entries = [SidebarEntry(pid: 1, application: app, windows: [], preferredID: nil, desktop: first),
                       SidebarEntry(pid: 2, application: app, windows: [], preferredID: nil, desktop: second)]
        let sections = SidebarDesktopSection.make(entries: entries, desktops: [first, second, third], scope: .allDesktops)
        let groups = SidebarMonitorGroup.make(sections: sections, desktops: [first, second, third],
            monitors: [SidebarMonitor(id: "monitor-a", name: "A", isPrimary: true),
                       SidebarMonitor(id: "monitor-b", name: "B", isPrimary: false)], scope: .allDesktops)
        let expected = SidebarLayout.notchItemWidth * 2 + SidebarLayout.notchSeparatorWidth
            + SidebarLayout.notchMonitorWidth * 2 + SidebarLayout.notchEmptyWidth + 4 * 4
        #expect(SidebarMonitorGroup.notchContentWidth(groups, spacing: 4) == expected)
        #expect(groups[1].desktops == [third]) // Empty display still exposes destinations through its header.
    }

    @Test func notchDesktopPopupBridgeConnectsHeadingWithoutCapturingNeighbouringApps() {
        let anchor = CGRect(x: 500, y: 704, width: 28, height: 86)
        let menu = CGRect(x: 514, y: 400, width: 280, height: 300)
        let regions = SidebarDesktopMenuGeometry.interactionFrames(menu: menu, anchor: anchor)
        #expect(regions.contains { $0.contains(CGPoint(x: 520, y: 702)) })
        #expect(!regions.contains { $0.contains(CGPoint(x: 560, y: 720)) })
        #expect(regions.contains { $0.contains(CGPoint(x: 600, y: 550)) })
    }

    private func desktop(_ id: UInt64, display: String? = "monitor-a", number: Int? = 1) -> SidebarDesktop {
        SidebarDesktop(id: id, order: Int(id), number: number, displayIdentifier: display)
    }

    @Test func nativeBridgeNeverSubmitsAnInvalidWindowOrDesktop() {
        // Safe on every OS; zero IDs return before constructing a move operation.
        #expect(!SidebarSpaceTransferSubmit(0, 20))
        #expect(!SidebarSpaceTransferSubmit(10, 0))
    }

    @Test func desktopCatalogIncludesInactiveSpacesAndTheirDisplayOwnership() {
        let catalog = SidebarSpaceReader.desktops(from: [
            ["Display Identifier": "monitor-a", "Current Space": ["id64": 10, "type": 0],
             "Spaces": [["id64": 10, "type": 0], ["id64": 20, "type": 0], ["id64": 30, "type": 4]]],
            ["Display Identifier": "monitor-b", "Spaces": [["id64": 40, "type": 0]]]])
        #expect(catalog.map(\.id) == [10, 20, 30, 40])
        #expect(catalog.map(\.displayIdentifier) == ["monitor-a", "monitor-a", "monitor-a", "monitor-b"])
        #expect(catalog.map(\.number) == [1, 2, nil, 3])
    }

    @Test func transferEligibilityDoesNotRequireTheSourceDesktopToBeOnScreen() {
        let inactive = desktop(20)
        #expect(SidebarDesktopTransferPolicy.source(desktops: [inactive], hidden: false,
            minimized: false, fullScreen: false, modal: false, hasSheets: false, canMove: true) == inactive)
        #expect(SidebarDesktopTransferPolicy.allows(source: inactive, destination: desktop(10)))
        #expect(SidebarDesktopTransferPolicy.allows(source: inactive, destination: desktop(30)))
    }

    @Test func transferRejectsHiddenMinimizedModalFullscreenAndAmbiguousWindows() {
        func source(hidden: Bool = false, minimized: Bool = false, fullScreen: Bool = false,
                    modal: Bool = false, sheets: Bool = false, canMove: Bool = true,
                    spaces: [SidebarDesktop]? = nil) -> SidebarDesktop? {
            SidebarDesktopTransferPolicy.source(desktops: spaces ?? [desktop(10)], hidden: hidden,
                minimized: minimized, fullScreen: fullScreen, modal: modal, hasSheets: sheets, canMove: canMove)
        }
        #expect(source() != nil)
        #expect(source(hidden: true) == nil)
        #expect(source(minimized: true) == nil)
        #expect(source(fullScreen: true) == nil)
        #expect(source(modal: true) == nil)
        #expect(source(sheets: true) == nil)
        #expect(source(canMove: false) == nil)
        #expect(source(spaces: []) == nil)
        #expect(source(spaces: [desktop(10), desktop(20)]) == nil)
        #expect(source(spaces: [desktop(10, display: nil)]) == nil)
        #expect(source(spaces: [desktop(10, number: nil)]) == nil)
    }

    @Test func destinationsRejectSameDesktopOtherMonitorsAndFullscreenSpaces() {
        let source = desktop(10)
        #expect(!SidebarDesktopTransferPolicy.allows(source: source, destination: source))
        #expect(!SidebarDesktopTransferPolicy.allows(source: source, destination: desktop(20, display: "monitor-b")))
        #expect(!SidebarDesktopTransferPolicy.allows(source: source, destination: desktop(20, display: nil)))
        #expect(!SidebarDesktopTransferPolicy.allows(source: source, destination: desktop(20, number: nil)))
        #expect(!SidebarDesktopTransferPolicy.allows(source: desktop(10, display: ""), destination: desktop(20, display: "")))
    }

    @MainActor @Test func emptyDesktopsStayOutOfSidebarButRemainInMonitorDestinations() {
        let app = Application(NSRunningApplication.current)
        let first = desktop(10), empty = desktop(20), third = desktop(30)
        let entry = SidebarEntry(pid: 1, application: app, windows: [], preferredID: nil, desktop: first)
        let unknown = SidebarEntry(pid: 2, application: app, windows: [], preferredID: nil)
        let sections = SidebarDesktopSection.make(entries: [entry, unknown],
            desktops: [first, empty, third, desktop(40, number: nil)], scope: .allDesktops)
        #expect(sections.map(\.id) == [10, nil])
        #expect(sections.flatMap(\.entries).map(\.pid) == [1, 2])
        let groups = SidebarMonitorGroup.make(sections: sections, desktops: [first, empty, third],
            monitors: [SidebarMonitor(id: "monitor-a", name: "Studio Display", isPrimary: true)], scope: .allDesktops)
        #expect(groups[0].desktops.map(\.id) == [10, 20, 30])
        #expect(groups[0].sections.count == 1)
        #expect(groups[0].monitor?.title == "Desktops")
        let visible = SidebarDesktopSection.make(entries: [entry], desktops: [first, empty], scope: .visibleDesktops)
        #expect(visible.count == 1 && visible[0].desktop == nil)
        #expect(visible[0].entries.count == 1)
    }

    @Test func monitorsKeepTheirNamesAndEmptyMonitorsStillHaveAHeading() {
        let desktops = [desktop(10, display: "monitor-b"), desktop(20)]
        let monitors = [SidebarMonitor(id: "monitor-a", name: "Built-in Retina Display", isPrimary: true),
                        SidebarMonitor(id: "monitor-b", name: "DELL U2723QE", isPrimary: false)]
        let groups = SidebarMonitorGroup.make(sections: [], desktops: desktops, monitors: monitors, scope: .allDesktops)
        #expect(groups.map(\.id) == ["monitor-a", "monitor-b"])
        #expect(groups[1].monitor?.title == "2 · DELL U2723QE")
        #expect(groups.allSatisfy { $0.sections.isEmpty && !$0.desktops.isEmpty })
        #expect(SidebarMonitorGroup.contentHeight(groups, spacing: 6) == (SidebarMonitor.headerHeight + SidebarMonitor.emptyHeight) * 2 + 6 + SidebarLayout.verticalPadding * 2)
    }

    @Test func threeMonitorsUseDistinctNumbersAndFilteredDisplaysKeepTheirNumber() {
        let monitors = [SidebarMonitor(id: "monitor-a", name: "A", isPrimary: true, number: 1),
                        SidebarMonitor(id: "monitor-b", name: "B", isPrimary: false, number: 2),
                        SidebarMonitor(id: "monitor-c", name: "C", isPrimary: false, number: 3)]
        let desktops = [desktop(30, display: "monitor-c"), desktop(10), desktop(20, display: "monitor-b")]
        let groups = SidebarMonitorGroup.make(sections: [], desktops: desktops,
            monitors: monitors, scope: .allDesktops)
        #expect(groups.compactMap { $0.monitor?.title } == ["1 · A", "2 · B", "3 · C"])
        let filtered = SidebarMonitorGroup.make(sections: [], desktops: [desktops[0]],
            monitors: [monitors[2]], scope: .allDesktops)
        #expect(filtered[0].monitor?.numberedTitle == "3 · C")
        #expect(filtered[0].monitor?.title == "Desktops")
        let primaryAlias = SidebarMonitorGroup.make(sections: [], desktops: [desktop(10, display: "Main")],
            monitors: monitors, scope: .allDesktops)
        #expect(primaryAlias[0].monitor?.numberedTitle == "1 · A")
    }

    @Test func displayNamesAppearOnlyWhenSeveralDisplaysAreConnected() {
        let desktops = [desktop(10, display: "monitor-a")]
        let single = [SidebarMonitor(id: "monitor-a", name: "Studio Display", isPrimary: true)]
        let one = SidebarMonitorGroup.make(sections: [], desktops: desktops, monitors: single, scope: .allDesktops)
        #expect(one[0].monitor?.title == "Desktops")
        let both = single + [SidebarMonitor(id: "monitor-b", name: "DELL U2723QE", isPrimary: false)]
        let two = SidebarMonitorGroup.make(sections: [], desktops: desktops, monitors: both, scope: .allDesktops)
        #expect(two[0].monitor?.title == "1 · Studio Display")
    }

    @Test func popupAllowsCrossingTheGapWithoutCapturingAdjacentAppIcons() {
        for menu in [CGRect(x: 600, y: 100, width: 280, height: 400),
                     CGRect(x: 986, y: 100, width: 280, height: 400)] {
            let anchor = CGRect(x: 890, y: 440, width: 86, height: 40)
            let regions = SidebarDesktopMenuGeometry.interactionFrames(menu: menu, anchor: anchor)
            let gapX: CGFloat = menu.minX < anchor.minX ? 885 : 981
            #expect(regions.contains { $0.contains(CGPoint(x: gapX, y: 460)) })
            #expect(!regions.contains { $0.contains(CGPoint(x: 930, y: 300)) })
            #expect(regions.contains { $0.contains(CGPoint(x: menu.midX, y: 300)) })
        }
    }

    @Test func desktopTargetsNeverCapturePopupPaddingOrAnEmptyGap() {
        let sidebar = CGRect(x: 900, y: 100, width: 86, height: 300)
        let targets = [SidebarDesktopDropTarget(desktop: desktop(10), frame: CGRect(x: 900, y: 300, width: 86, height: 100)),
                       SidebarDesktopDropTarget(desktop: desktop(20), frame: CGRect(x: 900, y: 100, width: 86, height: 100))]
        func resolve(_ point: CGPoint, excluded: [CGRect] = []) -> UInt64? {
            SidebarDesktopDropTarget.resolve(at: point, targets: targets, sidebar: sidebar, excluded: excluded)?.desktop.id
        }
        #expect(resolve(CGPoint(x: 940, y: 350)) == 10)
        #expect(resolve(CGPoint(x: 940, y: 150)) == 20)
        #expect(resolve(CGPoint(x: 940, y: 250)) == nil)
        #expect(resolve(CGPoint(x: 880, y: 150)) == nil)
        #expect(resolve(CGPoint(x: 940, y: 150), excluded: [targets[1].frame]) == nil)
    }

    @MainActor @Test func desktopHitTestingBoundsOversizedNativeVisibleRects() {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 86, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 86, height: 300))
        window.contentView = root
        let view = OversizedVisibleView(frame: CGRect(x: 0, y: 100, width: 86, height: 80))
        root.addSubview(view)
        let ownFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let sidebar = window.convertToScreen(root.bounds)
        #expect(SidebarDesktopDropTarget.visibleFrame(of: view, within: sidebar) == ownFrame)
        let clipped = CGRect(x: sidebar.minX, y: ownFrame.minY + 40, width: 86, height: 40)
        #expect(SidebarDesktopDropTarget.visibleFrame(of: view, within: clipped) == clipped)
    }

    @Test func asynchronousVerificationRequiresTheActualDestination() {
        #expect(SidebarDesktopTransferPolicy.verify(membership: [10], destinationID: 20, expired: false) == .pending)
        #expect(SidebarDesktopTransferPolicy.verify(membership: [], destinationID: 20, expired: false) == .pending)
        #expect(SidebarDesktopTransferPolicy.verify(membership: [10, 20], destinationID: 20, expired: false) == .pending)
        #expect(SidebarDesktopTransferPolicy.verify(membership: [20], destinationID: 20, expired: false) == .moved)
        #expect(SidebarDesktopTransferPolicy.verify(membership: [10], destinationID: 20, expired: true) == .unconfirmed)
        #expect(SidebarDesktopTransferPolicy.verify(membership: [20], destinationID: 20, expired: true) == .moved)
    }

    @MainActor private final class OversizedVisibleView: NSView {
        override var visibleRect: NSRect { CGRect(x: -1000, y: -1000, width: 3000, height: 3000) }
    }
}
