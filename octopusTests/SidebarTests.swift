import AppKit
import Combine
import class SwiftUI.NSHostingView
import struct SwiftUI.Form
import struct SwiftUI.Section
import struct SwiftUI.ForEach
import struct SwiftUI.Text
import struct SwiftUI.Group
import struct SwiftUI.ScrollView
import struct SwiftUI.HStack
import struct SwiftUI.VStack
import struct SwiftUI.ObservedObject
import protocol SwiftUI.View
import Testing
@testable import octopus

struct SidebarTests {
    @Test func presentationPreservesVisibilityAndFullScreenRules() {
        let cases: [(SidebarIdleBehavior, Bool, Bool, SidebarPresentation.Mode, Bool)] = [
            (.fade, false, false, .edge, false), (.fade, false, true, .edge, true),
            (.hide, false, false, .edge, true), (.stayVisible, false, false, .edge, false),
            (.stayVisible, false, true, .edge, true), (.compact, false, false, .compact, false),
            (.compact, false, true, .compact, false), (.notch, true, false, .notch, false),
            (.notch, true, true, .notch, false), (.notch, false, false, .edge, true)
        ]
        for (behavior, trigger, fullScreen, mode, autoHides) in cases {
            let policy = SidebarPresentation(behavior: behavior, hasNotchTrigger: trigger, fullScreen: fullScreen)
            #expect(policy.mode == mode && policy.autoHides == autoHides)
            #expect(policy.restoresMainSidebar(expanded: true, menuVisible: true))
            #expect(policy.restoresMainSidebar(expanded: false, menuVisible: false) == (!autoHides && mode != .notch))
            #expect(policy.closesWhenOutside(expanded: true) == (autoHides || mode != .edge))
            #expect(policy.closeDelay == (mode == .notch ? SidebarLayout.notchCloseDelay : 0))
        }
    }

    @MainActor @Test func presentationKeepsDrawingPaddingOutsideNotchHitTargets() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: -820, y: 870, width: 200, height: 30)
        var config = SidebarConfiguration.factoryDefaults
        config.idleBehavior = .notch
        let policy = SidebarPresentation(behavior: .notch, hasNotchTrigger: true, fullScreen: false)
        let frames = policy.layout(configuration: config, notch: notch, available: screen,
            screen: screen, groups: [], entryCount: 0, expanded: true)
        #expect(frames.sidebar.maxY == notch.minY)
        #expect(frames.drawing.maxY == frames.sidebar.maxY)
        #expect(frames.sidebar.minY - frames.drawing.minY == SidebarLayout.drawingPadding)
        let shadowPoint = CGPoint(x: frames.sidebar.midX, y: frames.sidebar.minY - 1)
        #expect(frames.drawing.contains(shadowPoint))
        #expect(!policy.pointerFrame(sidebar: frames.sidebar, compact: frames.compact, expanded: true).contains(shadowPoint))
        #expect(frames.edgeTrigger.isEmpty)
        #expect(screen.contains(frames.drawing))
        for side in SidebarSide.allCases {
            config.side = side
            for behavior in [SidebarIdleBehavior.stayVisible, .compact] {
                config.idleBehavior = behavior
                let edgePolicy = SidebarPresentation(behavior: behavior, hasNotchTrigger: false, fullScreen: false)
                let edge = edgePolicy.layout(configuration: config, notch: .zero, available: screen,
                    screen: screen, groups: [], entryCount: 0, expanded: true)
                #expect(edge.topContentWidth == nil)
                #expect(edge.drawing.minY == edge.sidebar.minY)
                #expect(!edge.edgeTrigger.isEmpty)
                #expect(edgePolicy.pointerFrame(sidebar: edge.sidebar, compact: edge.compact, expanded: false)
                    == (behavior == .compact ? edge.compact : edge.sidebar))
            }
        }
    }

    @MainActor @Test func visibilitySwitchesKeepTheReplacementNativeAnchors() async throws {
        let mode = AnchorSwitchMode()
        let registry = AnchorSwitchRegistry()
        let host = NSHostingView(rootView: AnchorSwitchView(mode: mode, registry: registry))
        host.sizingOptions = []
        let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        panel.orderFront(nil)
        for next in [SidebarIdleBehavior.stayVisible, .notch, .stayVisible, .compact, .notch, .compact, .stayVisible] {
            mode.behavior = next
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            if next == .compact {
                #expect(registry.rows.isEmpty && registry.geometry.isEmpty)
            } else {
                #expect(registry.rows.count == 3 && registry.geometry.count == 3,
                    "\(next.rawValue): rows \(registry.rows.count), geometry \(registry.geometry.count), events \(registry.events)")
                for id in 1...3 {
                    let row = try #require(registry.rows[id])
                    let geometry = try #require(registry.geometry[id])
                    #expect(row.window === panel && geometry.window === panel)
                    let frame = panel.convertToScreen(row.convert(row.bounds, to: nil))
                    let hit = SidebarDesktopDropTarget.visibleFrame(of: row, within: panel.frame)
                    #expect(hit?.contains(CGPoint(x: frame.midX, y: frame.midY)) == true)
                }
            }
        }
    }

    @Test func emptyNotchBarKeepsNoWindowAndPermissionControlsReachable() {
        for count in [0, 1] {
            let size = SidebarLayout.notchBarSize(count: count, appSpacing: 4,
                availableFrame: CGRect(x: 0, y: 0, width: 1200, height: 800), groupedWidth: 0)
            #expect(size.width == SidebarLayout.width + SidebarLayout.notchBarPadding * 2)
            #expect(size.height >= 76)
        }
    }

    @MainActor @Test func notchTriggerExposesAWorkingAccessibilityPress() async throws {
        // Ask only this test application to materialise its accessibility tree, as VoiceOver does.
        // This does not enable VoiceOver or change the user's system accessibility settings.
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI) ?? false
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        var opened = false
        let host = NSHostingView(rootView: SidebarNotchTriggerView(onReveal: { opened = true }))
        host.sizingOptions = []
        let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        panel.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        var tree: [String] = []
        func findTrigger(_ object: Any) -> AnyObject? {
            // SwiftUI's accessibility nodes implement the ObjC selectors without formally
            // conforming to NSAccessibilityProtocol, so use optional selector dispatch.
            let element = object as AnyObject
            let label: String? = element.accessibilityLabel?() ?? nil
            let children: [Any] = element.accessibilityChildren?() ?? []
            tree.append("\(type(of: object)): \(label ?? "nil"), children \(children.count)")
            if label == "Open app bar" { return element }
            for child in children {
                if let found = findTrigger(child) { return found }
            }
            return nil
        }
        let found = findTrigger(host)
        let trigger = try #require(found, "AX tree: \(tree)")
        #expect(trigger.accessibilityRole?() == .button)
        #expect(trigger.accessibilityPerformPress?() == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened)
    }

    @Test func virtualNotchWidthPersistsPerDisplayAndOlderProfilesKeepTheirDefaults() throws {
        let suite = "NotchWidth-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = SidebarConfiguration.factoryDefaults
        configuration.virtualNotchWidth = 320
        configuration.saveSingleSidebar(in: defaults)
        #expect(SidebarConfiguration(defaults: defaults).virtualNotchWidth == 320)
        SidebarSettings.save(configuration, for: "A", name: "A", in: defaults)
        configuration.virtualNotchWidth = 150
        SidebarSettings.save(configuration, for: "B", name: "B", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults).virtualNotchWidth == 320)
        #expect(SidebarSettings.configuration(for: "B", in: defaults).virtualNotchWidth == 150)
        let oldProfile = Data("{\"idleBehavior\":\"notch\",\"appSpacing\":8}".utf8)
        let restored = try JSONDecoder().decode(SidebarConfiguration.self, from: oldProfile)
        #expect(restored.virtualNotchWidth == SidebarSettings.defaultVirtualNotchWidth)
        #expect(restored.appSpacing == 8)
        configuration.virtualNotchWidth = .nan
        configuration.normalize()
        #expect(configuration.virtualNotchWidth == SidebarSettings.defaultVirtualNotchWidth)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let resized = try #require(SidebarLayout.notchTriggerFrame(screenFrame: screen,
            safeTopInset: 0, leftArea: nil, rightArea: nil, virtualWidth: 320))
        #expect(resized.width == 320 && resized.midX == screen.midX)
        let hardware = try #require(SidebarLayout.notchTriggerFrame(screenFrame: screen, safeTopInset: 32,
            leftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            rightArea: CGRect(x: 856, y: 950, width: 656, height: 32), virtualWidth: 320))
        #expect(hardware.width == 200)
    }

    @Test func notchPopupsStayCentredBelowIconsAndWithinScreen() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let bar = CGRect(x: -1000, y: 760, width: 600, height: 94)
        let icon = CGRect(x: -900, y: 790, width: 40, height: 40)
        let menu = SidebarLayout.notchMenuFrame(size: CGSize(width: 280, height: 300),
            icon: icon, bar: bar, screen: screen)
        #expect(menu.midX == icon.midX)
        #expect(menu.maxY == bar.minY)
        #expect(menu.intersection(bar).isEmpty)
        #expect(screen.contains(menu))
        let row = CGRect(x: icon.midX - 43, y: bar.minY + 4, width: 86, height: 86)
        let bridge = SidebarLayout.notchMenuBridge(menu: menu, anchor: row)
        #expect(bridge.contains(CGPoint(x: icon.midX + 4, y: bar.minY + 2)))
        #expect(!bridge.contains(CGPoint(x: row.maxX + 4, y: bar.minY + 2)))
        let rightIcon = CGRect(x: -60, y: 790, width: 40, height: 40)
        let clamped = SidebarLayout.notchMenuFrame(size: CGSize(width: 280, height: 2000),
            icon: rightIcon, bar: bar, screen: screen)
        #expect(clamped.maxX == screen.maxX)
        #expect(clamped.minY == screen.minY)
        #expect(clamped.maxY == bar.minY)
        let windowMenu = SidebarLayout.notchMenuFrame(size: CGSize(width: 280, height: 300),
            icon: icon, bar: bar, screen: screen, belowIcon: true)
        #expect(windowMenu.midX == icon.midX + SidebarLayout.notchWindowMenuOffset)
        #expect(windowMenu.maxY == icon.minY)
        #expect(windowMenu.intersection(icon).isEmpty)
        #expect(screen.contains(windowMenu))
        let shiftedAtEdge = SidebarLayout.notchMenuFrame(size: CGSize(width: 280, height: 300),
            icon: rightIcon, bar: bar, screen: screen, belowIcon: true)
        #expect(shiftedAtEdge.maxX == screen.maxX)
        #expect(shiftedAtEdge.maxY == rightIcon.minY)
    }

    @Test func notchDragScrollingUsesHorizontalEdgesAndLeavesTheMiddleStill() {
        let bar = CGRect(x: 100, y: 600, width: 500, height: 94)
        #expect(SidebarLayout.dragScrollDelta(at: CGPoint(x: 105, y: 650), frame: bar,
            horizontal: true, flipped: true) == CGPoint(x: -10, y: 0))
        #expect(SidebarLayout.dragScrollDelta(at: CGPoint(x: 595, y: 650), frame: bar,
            horizontal: true, flipped: true) == CGPoint(x: 10, y: 0))
        #expect(SidebarLayout.dragScrollDelta(at: CGPoint(x: 350, y: 605), frame: bar,
            horizontal: true, flipped: true) == .zero)
        #expect(SidebarLayout.dragScrollDelta(at: CGPoint(x: 90, y: 650), frame: bar,
            horizontal: true, flipped: true) == .zero)
    }

    @MainActor @Test func windowPopupBackdropHasTransparentRoundedCorners() throws {
        let panel = CyclePanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 120))
        defer { panel.close() }
        let effect = try #require(panel.contentView as? NSVisualEffectView)
        let mask = try #require(effect.maskImage)
        let pixels = try #require(mask.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        #expect(try #require(pixels.colorAt(x: 0, y: 0)).alphaComponent == 0)
        #expect(try #require(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)).alphaComponent == 1)
        #expect(mask.resizingMode == .stretch)
        #expect(mask.capInsets.top == 12 && mask.capInsets.right == 12)
        #expect(!panel.isOpaque && panel.backgroundColor == .clear)
    }

    @MainActor @Test func notchPopupNativeRowsStayInOneColumnBelowTheIcon() async throws {
        let app = Application(NSRunningApplication.current)
        let windows = [10, 20].map { id -> Window in
            let window = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Window \(id)")
            window.cgWindowID = CGWindowID(id)
            return window
        }
        let state = CyclePanelState()
        state.setWindows(windows, applicationTitle: "Example", selectedID: 10,
            sidebarWindowStates: [10: SidebarWindowState(isMinimized: false, canMinimize: true),
                                  20: SidebarWindowState(isMinimized: true, canMinimize: true)])
        var anchors: [CyclePanelItem.ID: NSView] = [:]
        let bar = CGRect(x: 100, y: 700, width: 600, height: 94)
        let frame = SidebarLayout.notchMenuFrame(size: CGSize(width: SidebarLayout.notchWindowMenuWidth, height: 120),
            icon: CGRect(x: 250, y: 740, width: 40, height: 40), bar: bar,
            screen: CGRect(x: 0, y: 0, width: 1000, height: 900), belowIcon: true)
        let panel = CyclePanel(contentRect: frame)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = NSHostingView(rootView: CyclePanelView(state: state, onAnchor: { anchors[$0] = $1 }))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = try #require(panel.contentView)
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        container.layoutSubtreeIfNeeded()
        let first = try #require(anchors[.window(10)])
        let second = try #require(anchors[.window(20)])
        let firstFrame = panel.convertToScreen(first.convert(first.bounds, to: nil))
        let secondFrame = panel.convertToScreen(second.convert(second.bounds, to: nil))
        #expect(firstFrame.minX == secondFrame.minX && firstFrame.width == secondFrame.width)
        #expect(panel.frame.maxY == 740) // The icon bottom, above the app label.
        #expect(firstFrame.maxY <= 740 && secondFrame.maxY <= 740)
        #expect(firstFrame.minY > secondFrame.minY)
        let point = CGPoint(x: secondFrame.midX, y: secondFrame.midY)
        #expect(CyclePanelController.sidebarPointerTarget(at: point, items: state.items,
            anchors: anchors, hideAnchor: nil) == .row(.window(20)))
    }

    @Test func compactVisibilitySurvivesSingleAndDisplayPreferenceReloads() throws {
        let suite = "SidebarCompact-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = SidebarConfiguration.factoryDefaults
        configuration.idleBehavior = .compact
        configuration.side = .left
        configuration.saveSingleSidebar(in: defaults)
        #expect(SidebarConfiguration(defaults: defaults) == configuration)
        SidebarSettings.rememberDisplay(id: "A", name: "Display A", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == configuration)
        var other = configuration
        other.idleBehavior = .hide
        SidebarSettings.save(other, for: "B", name: "Display B", in: defaults)
        let restarted = try #require(UserDefaults(suiteName: suite))
        #expect(SidebarSettings.configuration(for: "A", in: restarted) == configuration)
        #expect(SidebarSettings.configuration(for: "B", in: restarted) == other)
        #expect(SidebarIdleBehavior.saved("compact") == .compact)
        #expect(SidebarIdleBehavior.saved("notch") == .notch)
        #expect(SidebarConfiguration.factoryDefaults.idleBehavior == .fade)
    }

    @Test func notchTriggerUsesHardwareGeometryOrProportionalVirtualNotch() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 950, width: 656, height: 32)
        let right = CGRect(x: 856, y: 950, width: 656, height: 32)
        let frame = try #require(SidebarLayout.notchTriggerFrame(
            screenFrame: screen, safeTopInset: 32, leftArea: left, rightArea: right))
        #expect(frame == CGRect(x: 656, y: 940, width: 200, height: SidebarLayout.notchTriggerHeight))
        let virtual = try #require(SidebarLayout.notchTriggerFrame(
            screenFrame: screen, safeTopInset: 0, leftArea: nil, rightArea: nil))
        #expect(virtual.midX == screen.midX && virtual.maxY == screen.maxY)
        #expect(SidebarLayout.virtualNotchWidthRange.contains(virtual.width))
        #expect(SidebarLayout.virtualNotchHeightRange.contains(virtual.height))
        #expect(abs(virtual.width - screen.width * SidebarLayout.virtualNotchWidthRatio) < 0.001)
        #expect(abs(virtual.height - screen.height * SidebarLayout.virtualNotchHeightRatio) < 0.001)
        let invalidHardware = try #require(SidebarLayout.notchTriggerFrame(
            screenFrame: screen, safeTopInset: 32, leftArea: right, rightArea: left))
        #expect(invalidHardware == virtual)
        let large = try #require(SidebarLayout.notchTriggerFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 4000, height: 2000),
            safeTopInset: 0, leftArea: nil, rightArea: nil))
        #expect(large.width == SidebarLayout.virtualNotchWidthRange.upperBound)
        #expect(large.height == SidebarLayout.virtualNotchHeightRange.upperBound)
        #expect(SidebarLayout.notchTriggerFrame(
            screenFrame: .zero, safeTopInset: 0, leftArea: nil, rightArea: nil) == nil)

        let available = CGRect(x: 0, y: 0, width: screen.width, height: screen.height - 24)
        let oneApp = SidebarLayout.notchBarSize(count: 1, appSpacing: 4, availableFrame: available)
        #expect(oneApp == CGSize(width: SidebarLayout.width + SidebarLayout.notchBarPadding * 2,
                                height: SidebarLayout.rowHeight + SidebarLayout.notchBarPadding * 2))
        let twoApps = SidebarLayout.notchBarSize(count: 2, appSpacing: 4, availableFrame: available)
        #expect(twoApps.width == SidebarLayout.width * 2 + 4 + SidebarLayout.notchBarPadding * 2)
        let manyApps = SidebarLayout.notchBarSize(count: 100, appSpacing: 4, availableFrame: available)
        #expect(manyApps.width == available.width * SidebarLayout.notchBarMaximumScreenFraction)

        let sidebar = SidebarLayout.notchSidebarFrames(
            contentSize: twoApps, below: virtual, availableFrame: available)
        #expect(sidebar.content.midX == virtual.midX)
        #expect(sidebar.content.maxY == virtual.minY)
        #expect(sidebar.panel.midX == sidebar.content.midX)
        #expect(sidebar.panel.width == twoApps.width + SidebarLayout.drawingPadding * 2)
        #expect(sidebar.panel.maxY == sidebar.content.maxY)
        #expect(sidebar.panel.minY == sidebar.content.minY - SidebarLayout.drawingPadding)

        let clipped = SidebarLayout.notchSidebarFrames(
            contentSize: CGSize(width: SidebarLayout.width, height: 2000), below: virtual,
            availableFrame: screen)
        #expect(clipped.content.minY == screen.minY)
        #expect(clipped.content.maxY == virtual.minY)
        #expect(clipped.panel.minY == screen.minY)
    }

    @Test func notchVisibilitySurvivesSingleAndDisplayPreferenceReloads() throws {
        let suite = "SidebarNotch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = SidebarConfiguration.factoryDefaults
        configuration.idleBehavior = .notch
        configuration.saveSingleSidebar(in: defaults)
        #expect(SidebarConfiguration(defaults: defaults).idleBehavior == .notch)
        SidebarSettings.save(configuration, for: "Notched", name: "Built-in Display", in: defaults)
        let restarted = try #require(UserDefaults(suiteName: suite))
        #expect(SidebarSettings.configuration(for: "Notched", in: restarted).idleBehavior == .notch)
    }

    @Test func compactStripStaysAtEitherEdgeWithTheSameHeightWhenExpanded() {
        let screen = CGRect(x: -1440, y: 120, width: 1440, height: 900)
        for side in SidebarSide.allCases {
            for count in [1, 6, 100] {
                let frame = SidebarLayout.sidebarFrame(in: screen, count: count, side: side, position: 0.25)
                let closed = SidebarLayout.compactFrames(beside: frame, side: side, expanded: false)
                let open = SidebarLayout.compactFrames(beside: frame, side: side, expanded: true)
                #expect(closed.compact == open.compact)
                #expect(closed.main == open.main)
                #expect(closed.panel == closed.compact)
                #expect(open.panel.contains(open.compact) && open.panel.contains(open.main))
                #expect(open.compact.height == frame.height && open.panel.height == frame.height)
                #expect(open.compact.minY == frame.minY)
                #expect(open.compact.width < open.main.width)
                if side == .left {
                    #expect(open.compact.minX == screen.minX)
                    #expect(open.main.minX == open.compact.maxX)
                } else {
                    #expect(open.compact.maxX == screen.maxX)
                    #expect(open.main.maxX == open.compact.minX)
                }
            }
        }
    }

    @Test func collapsedCompactHeightContainsOnlyNumberRows() {
        #expect(SidebarLayout.compactContentHeight(count: 0, appSpacing: 4) == SidebarLayout.rowHeight)
        #expect(SidebarLayout.compactContentHeight(count: 1, appSpacing: 4)
            == SidebarLayout.iconSlotHeight + SidebarLayout.verticalPadding * 2)
        #expect(SidebarLayout.compactContentHeight(count: 2, appSpacing: 4)
            == SidebarLayout.iconSlotHeight * 2 + SidebarLayout.labelHeight + 4
                + SidebarLayout.verticalPadding * 2)

        let count = 3
        let height = SidebarLayout.compactContentHeight(count: count, appSpacing: 4)
        let firstCentre = SidebarLayout.verticalPadding + SidebarLayout.iconSlotHeight / 2
        let lastCentre = firstCentre + CGFloat(count - 1) * (SidebarLayout.rowHeight + 4)
        #expect(firstCentre == height - lastCentre)

        let frame = SidebarLayout.sidebarFrame(in: CGRect(x: 0, y: 0, width: 1000, height: 800),
            count: count, side: .left, position: 0.5, appSpacing: 4,
            contentHeight: height, minimumHeight: 0)
        #expect(frame.height == height)
    }

    @MainActor @Test func compactNumbersDimHiddenMinimisedAndWindowlessApps() {
        let running = NSRunningApplication.current
        let app = Application(running)
        let window = Window(AXUIElementCreateApplication(running.processIdentifier), app, cachedTitle: "Window")
        window.cgWindowID = 10
        var entry = SidebarEntry(pid: running.processIdentifier, application: app, windows: [window],
            preferredID: nil, windowStates: [10: SidebarWindowState(isMinimized: false, canMinimize: true)])
        #expect(entry.hasOpenWindows)
        // A window on another desktop remains open even though it is not on screen.
        entry.windowStates[10]?.isOnScreen = false
        #expect(entry.hasOpenWindows)
        entry.isHidden = true
        #expect(!entry.hasOpenWindows)
        entry.isHidden = false
        entry.windowStates[10] = SidebarWindowState(isMinimized: true, canMinimize: true)
        #expect(!entry.hasOpenWindows)
        let windowless = SidebarEntry(pid: running.processIdentifier, application: app, windows: [], preferredID: nil)
        #expect(!windowless.hasOpenWindows)
    }

    @Test func sidebarLevelsStayAboveAppPalettesAndBelowModalDialogs() {
        #expect(NSWindow.Level.floating.rawValue < SidebarWindowLevels.sidebar.rawValue)
        #expect(SidebarWindowLevels.sidebar.rawValue < SidebarWindowLevels.menu.rawValue)
        #expect(SidebarWindowLevels.menu.rawValue < SidebarWindowLevels.dragPreview.rawValue)
        #expect(SidebarWindowLevels.dragPreview.rawValue < SidebarWindowLevels.dragIcon.rawValue)
        #expect(SidebarWindowLevels.dragIcon.rawValue < NSWindow.Level.modalPanel.rawValue)
        #expect(SidebarWindowLevels.notch == NSWindow.Level.statusBar)
        #expect(SidebarWindowLevels.notch.rawValue < NSWindow.Level.popUpMenu.rawValue)
    }

    @Test func wheelPositionRespectsPhysicalDirectionUnitsAndScreenEdges() {
        #expect(SidebarLayout.scrolledPosition(0.5, deltaY: 3, precise: false, inverted: false, availableTravel: 480) == 0.45)
        #expect(SidebarLayout.scrolledPosition(0.5, deltaY: -3, precise: false, inverted: true, availableTravel: 480) == 0.45)
        #expect(SidebarLayout.scrolledPosition(0.5, deltaY: -3, precise: false, inverted: false, availableTravel: 480) == 0.55)
        #expect(SidebarLayout.scrolledPosition(0.5, deltaY: 24, precise: true, inverted: false, availableTravel: 480) == 0.45)
        #expect(SidebarLayout.scrolledPosition(0.02, deltaY: 10, precise: false, inverted: false, availableTravel: 480) == 0)
        #expect(SidebarLayout.scrolledPosition(0.98, deltaY: -10, precise: false, inverted: false, availableTravel: 480) == 1)
        #expect(SidebarLayout.scrolledPosition(0.5, deltaY: 3, precise: false, inverted: false, availableTravel: 0) == nil)
        #expect(SidebarLayout.scrolledPosition(0.5, deltaY: .nan, precise: false, inverted: false, availableTravel: 480) == nil)
    }

    @Test func changingOneSidebarPositionPreservesOtherDisplaysAndGlobalSettings() throws {
        let suite = "SidebarScrollPosition-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "sidebarEnabled")
        defaults.set(0.33, forKey: "sidebarPosition")
        var first = SidebarConfiguration.factoryDefaults
        first.enabled = false
        first.side = .left
        first.snapDistance = 460
        first.position = 0.2
        var second = SidebarConfiguration.factoryDefaults
        second.position = 0.7
        SidebarSettings.save(first, for: "A", name: "A", in: defaults)
        SidebarSettings.save(second, for: "B", name: "B", in: defaults)
        SidebarSettings.savePosition(0.8, for: "A", in: defaults)
        first.position = 0.8
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == first)
        #expect(SidebarSettings.configuration(for: "B", in: defaults) == second)
        #expect(defaults.double(forKey: "sidebarPosition") == 0.33)
        SidebarSettings.savePosition(0.4, for: nil, in: defaults)
        #expect(defaults.double(forKey: "sidebarPosition") == 0.4)
        #expect(!defaults.bool(forKey: "sidebarEnabled"))
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == first)
        #expect(SidebarSettings.configuration(for: "B", in: defaults) == second)
    }

    @Test func settingsHeightFitsContentAndTheActualWindowsScreen() {
        #expect(PreferencesFormSizing.height(contentHeight: 610, screenHeight: 1000,
                                             windowHeight: 750, viewportHeight: 660) == 610)
        #expect(PreferencesFormSizing.height(contentHeight: 610, screenHeight: 600,
                                             windowHeight: 750, viewportHeight: 660) == 510)
        #expect(PreferencesFormSizing.height(contentHeight: 610, screenHeight: 1000,
                                             windowHeight: 600, viewportHeight: 510) == 610)
        #expect(PreferencesFormSizing.height(contentHeight: 630, screenHeight: 1000,
                                             windowHeight: 750, viewportHeight: 660) == 630)
        #expect(PreferencesFormSizing.height(contentHeight: .nan, screenHeight: 1000,
                                             windowHeight: 750, viewportHeight: 660) == nil)
        #expect(PreferencesFormSizing.height(contentHeight: 610, screenHeight: 600.5,
                                             windowHeight: 750, viewportHeight: 660) == 510)
    }

    @MainActor @Test func groupedFormMeasuresItsLastRowBeyondTheVisibleViewport() async throws {
        var measured: CGFloat?
        let form = Form {
            Section("Settings") {
                ForEach(0..<18) { index in
                    Text("Setting \(index)")
                }
                Text("Last setting").background {
                    PreferencesFormSizeReader { measured = $0 }
                }
            }
        }
        .formStyle(.grouped)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 650, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: form)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let height = try #require(measured)
        let screen = try #require(window.screen)
        #expect(height > 300)
        #expect(height <= screen.visibleFrame.height)
        // A larger viewport must not inflate the measured content height.
        measured = nil
        window.setContentSize(CGSize(width: 650, height: height + 40))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let resizedHeight = try #require(measured)
        #expect(abs(resizedHeight - height) <= 1)
    }

    @MainActor @Test func currentDisplayFiltersMenusAndTargetsWithoutChangingDesktopScope() throws {
        let running = NSRunningApplication.current
        let app = Application(running)
        let pid = running.processIdentifier
        let first = SidebarDesktop(id: 101, order: 0, number: 1, displayIdentifier: "A")
        let second = SidebarDesktop(id: 102, order: 1, number: 2, displayIdentifier: "A")
        let other = SidebarDesktop(id: 201, order: 2, number: 3, displayIdentifier: "B")
        func window(_ id: CGWindowID) -> Window {
            let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Window \(id)")
            window.cgWindowID = id
            return window
        }
        let outside = SidebarWindowID(pid: pid, windowID: 20)
        let entry = SidebarEntry(pid: pid, application: app, windows: [window(10), window(11), window(20), window(30)],
            preferredID: outside, focusedID: outside, windowStates: [
                10: SidebarWindowState(isMinimized: false, canMinimize: true, desktops: [first], displayIdentifier: "A"),
                11: SidebarWindowState(isMinimized: true, canMinimize: true, isOnScreen: false,
                                       desktops: [second], displayIdentifier: "A"),
                20: SidebarWindowState(isMinimized: false, canMinimize: true, desktops: [other], displayIdentifier: "B"),
                30: SidebarWindowState(isMinimized: false, canMinimize: true)
            ])
        for scope in SidebarDesktopScope.allCases {
            let filtered = SidebarWindowInventory.entries(for: [running], windowEntries: [entry],
                                                         scope: scope, displayIdentifier: "A")
            #expect(filtered.flatMap(\.windows).compactMap(\.cgWindowID).sorted() == [10, 11])
            #expect(filtered.allSatisfy { $0.focusedID == nil && $0.preferredID != outside })
            #expect(filtered.allSatisfy { $0.windowStates[20] == nil && $0.windowStates[30] == nil })
            #expect(filtered.contains { $0.windowStates[11]?.isMinimized == true })
            #expect(filtered.count == (scope == .allDesktops ? 2 : 1))
        }
        let all = SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: .allDesktops)
        #expect(all.flatMap(\.windows).compactMap(\.cgWindowID).sorted() == [10, 11, 20, 30])
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .allDesktops,
                                              displayIdentifier: "A").isEmpty)
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: .allDesktops,
                                              displayIdentifier: "disconnected").isEmpty)
        let selected = try #require(SidebarWindowInventory.entries(for: [running], windowEntries: [entry],
            scope: .allDesktops, displayIdentifier: "B").first)
        #expect(selected.windows.compactMap(\.cgWindowID) == [20])
        #expect(!selected.hasOtherWindows)
        var multipleMemberships = entry
        multipleMemberships.windowStates[20]?.desktops = [first, other]
        let onB = SidebarWindowInventory.entries(for: [running], windowEntries: [multipleMemberships],
                                                scope: .allDesktops, displayIdentifier: "B")
        #expect(onB.count == 1 && onB.first?.desktop == other)
    }

    @Test func displayMembershipHandlesStaleBoundsSharedSpacesAndSpanningWindows() {
        let frames = ["A": CGRect(x: 0, y: 0, width: 1000, height: 800),
                      "B": CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        let desktop = SidebarDesktop(id: 101, order: 0, number: 1, displayIdentifier: "A")
        let onB = CGRect(x: 1200, y: 30, width: 400, height: 300)
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [desktop], bounds: onB, displayFrames: frames) == "A")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [desktop], bounds: nil, displayFrames: frames) == "A")
        let shared = SidebarDesktop(id: 101, order: 0, number: 1, displayIdentifier: "Main")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [shared], bounds: onB, displayFrames: frames) == "B")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [], bounds: onB, displayFrames: frames) == "B")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [],
            bounds: CGRect(x: 900, y: 30, width: 500, height: 300), displayFrames: frames) == "B")
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [],
            bounds: CGRect(x: -500, y: -500, width: 100, height: 100), displayFrames: frames) == nil)
        #expect(SidebarWindowPolicy.displayIdentifier(desktops: [], bounds: nil, displayFrames: frames) == nil)
    }

    @Test func displayFilterLoadsOlderProfilesWithoutResettingTheirPreferences() throws {
        let suite = "SidebarDisplayScopeMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = SidebarConfiguration.factoryDefaults
        original.enabled = false
        original.side = .left
        original.position = 0.25
        original.desktopScope = .visibleDesktops
        original.displayScope = .currentDisplay
        original.snapDistance = 460
        SidebarSettings.save(original, for: "A", name: "A", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == original)
        let encoded = try JSONEncoder().encode(SidebarDisplayPreference(name: "A", configuration: original))
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var configuration = try #require(json["configuration"] as? [String: Any])
        configuration.removeValue(forKey: "displayScope")
        json["configuration"] = configuration
        defaults.set(["A": try JSONSerialization.data(withJSONObject: json)], forKey: SidebarSettings.displayPreferencesKey)
        original.displayScope = .allDisplays
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == original)
        #expect(SidebarDisplayScope.saved("unknown") == .allDisplays)
        #expect(SidebarConfiguration.factoryDefaults.displayScope == .allDisplays)
    }

    @Test func displayPreferencesInheritOnceAndRemainIndependentAcrossRestarts() throws {
        let suite = "SidebarDisplays-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("left", forKey: "sidebarSide")
        defaults.set(0.25, forKey: "sidebarPosition")
        defaults.set("hide", forKey: SidebarSettings.idleBehaviorKey)
        defaults.set(false, forKey: "sidebarShowSingleWindowMenu")
        defaults.set(12.0, forKey: "sidebarAppSpacing")
        defaults.set(14.0, forKey: "sidebarFontSize")
        defaults.set(2.0, forKey: "sidebarShadowOpacity")
        defaults.set(400.0, forKey: "sidebarSnapDistance")
        let original = SidebarConfiguration(defaults: defaults)
        #expect(!defaults.bool(forKey: SidebarSettings.multiDisplayKey))
        SidebarSettings.rememberDisplay(id: "A", name: "Same name", in: defaults)
        SidebarSettings.rememberDisplay(id: "B", name: "Same name", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == original)
        #expect(SidebarSettings.configuration(for: "B", in: defaults) == original)

        var changed = original
        changed.enabled = false
        changed.desktopScope = .visibleDesktops
        changed.side = .right
        changed.position = 0.75
        changed.idleBehavior = .stayVisible
        changed.showSingleWindowMenu = true
        changed.appSpacing = 1
        changed.fontSize = 9
        changed.shadowOpacity = 0
        changed.snapDistance = 20
        SidebarSettings.save(changed, for: "A", name: "Same name", in: defaults)
        let restarted = try #require(UserDefaults(suiteName: suite))
        SidebarSettings.rememberDisplay(id: "A", name: "Renamed display", in: restarted)
        #expect(SidebarSettings.configuration(for: "A", in: restarted) == changed)
        #expect(SidebarSettings.configuration(for: "B", in: restarted) == original)
        #expect(SidebarSettings.configuration(for: nil, in: restarted) == original)
        #expect(SidebarSettings.displayPreferences(in: restarted)["A"]?.name == "Renamed display")
        // An unchanged reconnect should not rewrite preferences and trigger another refresh.
        let saved = restarted.dictionary(forKey: SidebarSettings.displayPreferencesKey)?["A"] as? Data
        SidebarSettings.rememberDisplay(id: "A", name: "Renamed display", in: restarted)
        #expect(restarted.dictionary(forKey: SidebarSettings.displayPreferencesKey)?["A"] as? Data == saved)

        // Reset uses factory defaults, not the customized single-sidebar settings.
        let factory = SidebarConfiguration.factoryDefaults
        #expect(factory.enabled && factory.desktopScope == .allDesktops && factory.side == .right)
        #expect(factory.position == 0.5 && factory.idleBehavior == .fade && factory.showSingleWindowMenu)
        #expect(factory.appSpacing == SidebarSettings.defaultAppSpacing)
        #expect(factory.fontSize == SidebarSettings.defaultFontSize)
        #expect(factory.shadowOpacity == SidebarSettings.defaultShadowOpacity)
        #expect(factory.snapDistance == SidebarSettings.defaultSnapDistance)
        SidebarSettings.save(factory, for: "A", name: "Renamed display", in: restarted)
        #expect(SidebarSettings.configuration(for: "A", in: restarted) == factory)
        #expect(SidebarSettings.configuration(for: "B", in: restarted) == original)
        #expect(SidebarSettings.configuration(for: nil, in: restarted) == original)
    }

    @Test func sidebarTargetsRespectOffDisconnectReconnectAndModeSwitches() throws {
        let suite = "SidebarTargets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.single])
        #expect(SidebarSettings.targets(connectedDisplayIDs: [], in: defaults).isEmpty)
        defaults.set(true, forKey: SidebarSettings.multiDisplayKey)
        SidebarSettings.rememberDisplay(id: "A", name: "A", in: defaults)
        SidebarSettings.rememberDisplay(id: "B", name: "B", in: defaults)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B", "A"], in: defaults)
            == [.display("A"), .display("B")])
        var off = SidebarSettings.configuration(for: "B", in: defaults)
        off.enabled = false
        SidebarSettings.save(off, for: "B", name: "B", in: defaults)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.display("A")])
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["B"], in: defaults).isEmpty)
        // Reordering displays does not alter their preferences or re-enable an Off display.
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["B", "A"], in: defaults) == [.display("A")])
        defaults.set(false, forKey: "sidebarEnabled")
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults).isEmpty)
        SidebarSettings.rememberDisplay(id: "C", name: "C", in: defaults)
        #expect(SidebarSettings.configuration(for: "C", in: defaults).enabled)
        defaults.set(true, forKey: "sidebarEnabled")
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.display("A")])
        defaults.set(false, forKey: SidebarSettings.multiDisplayKey)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.single])
        defaults.set(true, forKey: SidebarSettings.multiDisplayKey)
        #expect(SidebarSettings.targets(connectedDisplayIDs: ["A", "B"], in: defaults) == [.display("A")])
    }

    @Test func damagedDisplayPreferencesDoNotLoseOtherDisplaysAndValuesAreBounded() throws {
        let suite = "SidebarDisplayRecovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = SidebarConfiguration(defaults: defaults)
        configuration.position = .nan
        configuration.appSpacing = -10
        configuration.fontSize = 100
        configuration.shadowOpacity = .infinity
        configuration.snapDistance = 900
        SidebarSettings.save(configuration, for: "A", name: "A", in: defaults)
        var saved = defaults.dictionary(forKey: SidebarSettings.displayPreferencesKey) ?? [:]
        saved["broken"] = Data("invalid".utf8)
        defaults.set(saved, forKey: SidebarSettings.displayPreferencesKey)
        let loaded = SidebarSettings.configuration(for: "A", in: defaults)
        #expect(loaded.position == 0.5)
        #expect(loaded.appSpacing == 0)
        #expect(loaded.fontSize == SidebarSettings.maximumFontSize)
        #expect(loaded.shadowOpacity == SidebarSettings.defaultShadowOpacity)
        #expect(loaded.snapDistance == SidebarSettings.maximumSnapDistance)
        SidebarSettings.rememberDisplay(id: "broken", name: "Recovered", in: defaults)
        #expect(SidebarSettings.configuration(for: "A", in: defaults) == loaded)
        #expect(SidebarSettings.displayPreferences(in: defaults)["broken"]?.name == "Recovered")
    }

    @MainActor @Test func appVisibilityButtonHidesOrShowsTheSelectedWindowOfAMultiWindowApp() {
        let app = Application(NSRunningApplication.current)
        let first = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "First")
        first.cgWindowID = 10
        let second = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Second")
        second.cgWindowID = 20
        let state = CyclePanelState()
        let target = SidebarWindowID(pid: getpid(), windowID: 20)
        let normal = SidebarWindowState(isMinimized: false, canMinimize: true)
        let states = [CGWindowID(10): normal, CGWindowID(20): normal]
        state.setWindows([first, second], applicationTitle: "Example", selectedID: 20,
                         sidebarWindowStates: states, sidebarAppIsHidden: true)
        #expect(state.sidebarAppVisibilityTitle == "Show app")
        let show = state.sidebarAppVisibilityAction(pid: getpid())
        #expect(show == .focus(target))
        state.reset()
        #expect(show == .focus(target))
        #expect(state.sidebarAppVisibilityAction(pid: getpid()) == nil)
        state.setWindows([first, second], applicationTitle: "Example", selectedID: 20,
                         sidebarWindowStates: states, sidebarAppIsHidden: false)
        #expect(state.sidebarAppVisibilityTitle == "Hide app")
        #expect(state.sidebarAppVisibilityAction(pid: getpid()) == .hide(target))
    }

    @Test func browserMenusKeepTheSameRealWindowsWhenOpenAndMinimised() {
        let frame = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let realTitles = ["New Tab - Brave - Personal", "Google - Brave - ü"]
        for minimized in [false, true] {
            for title in realTitles {
                #expect(!SidebarWindowPolicy.isBrowserHelper(title: title, applicationTitle: "Brave Browser",
                    subrole: kAXStandardWindowSubrole as String, hasCloseButton: true, parentIsWindow: false,
                    bounds: frame, minimized: minimized))
            }
        }
        // During minimise/restore, controls or CG geometry can briefly disappear.
        #expect(!SidebarWindowPolicy.isBrowserHelper(title: realTitles[0], applicationTitle: "Brave Browser",
            subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
            bounds: CGRect(x: 0, y: 30, width: 1, height: 1), minimized: true))
        #expect(!SidebarWindowPolicy.isBrowserHelper(title: realTitles[0], applicationTitle: "Brave Browser",
            subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
            bounds: CGRect(x: 0, y: 30, width: 1, height: 1), minimized: false))
        for title in ["Brave Browser", ""] {
            #expect(SidebarWindowPolicy.isBrowserHelper(title: title, applicationTitle: "Brave Browser",
                subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
                bounds: frame, minimized: false))
            // An untitled real browser window must not be removed by its name.
            #expect(!SidebarWindowPolicy.isBrowserHelper(title: title, applicationTitle: "Brave Browser",
                subrole: kAXStandardWindowSubrole as String, hasCloseButton: true, parentIsWindow: false,
                bounds: frame, minimized: false))
        }
        #expect(SidebarWindowPolicy.isBrowserHelper(title: "Restore pages?", applicationTitle: "Brave Browser",
            subrole: "AXUnknown", hasCloseButton: false, parentIsWindow: true, bounds: frame, minimized: false))
        #expect(SidebarWindowPolicy.isBrowserHelper(title: nil, applicationTitle: "Google Chrome",
            subrole: kAXStandardWindowSubrole as String, hasCloseButton: false, parentIsWindow: false,
            bounds: CGRect(x: 0, y: 30, width: 1, height: 1), minimized: false))
        // A temporary AX failure is not proof that a normal window has no controls.
        #expect(!SidebarWindowPolicy.isBrowserHelper(title: nil, applicationTitle: "Brave Browser",
            subrole: nil, hasCloseButton: nil, parentIsWindow: false, bounds: frame, minimized: false))
        #expect(!SidebarWindowPolicy.needsBrowserHelperCheck(bundleIdentifier: "com.apple.finder"))
    }

    @Test func remoteDiscoveryRejectsBrowserTabsAndRestoreSurfaces() {
        #expect(SidebarWindowDiscovery.isEligibleRemoteWindow(
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String
        ))
        for subrole in [nil, "", "AXUnknown", kAXDialogSubrole as String] as [String?] {
            #expect(!SidebarWindowDiscovery.isEligibleRemoteWindow(
                role: kAXWindowRole as String, subrole: subrole
            ))
        }
        #expect(!SidebarWindowDiscovery.isEligibleRemoteWindow(
            role: kAXButtonRole as String, subrole: kAXStandardWindowSubrole as String
        ))
    }

    @Test func spaceNumbersFollowOrderWithoutCountingFullScreenOrDuplicateSpaces() {
        let spaces: [[String: Any]] = [["Spaces": [
            ["id64": 10, "type": 0], ["ManagedSpaceID": 11, "type": 4],
            ["id64": 12, "type": 0], ["id64": 99, "type": 2]
        ]], ["Spaces": [["id64": 10, "type": 0], ["id64": 13, "type": 0]]]]
        let result = SidebarSpaceReader.desktops(from: spaces)
        #expect(result.map(\.id) == [10, 11, 12, 13])
        #expect(result.map(\.number) == [1, nil, 2, 3])
        #expect(result[2].windowPrefix == "2. ")
    }

    @Test func legacyAutoHideMigratesToIdleBehaviorWithoutOverridingANewChoice() throws {
        let suite = "SidebarIdleMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sidebarAutoHide")
        SidebarSettings.migrateLegacyAutoHide(in: defaults)
        #expect(defaults.string(forKey: SidebarSettings.idleBehaviorKey) == "hide")
        #expect(defaults.object(forKey: "sidebarAutoHide") == nil)

        defaults.set(false, forKey: "sidebarAutoHide")
        SidebarSettings.migrateLegacyAutoHide(in: defaults)
        #expect(defaults.string(forKey: SidebarSettings.idleBehaviorKey) == "hide")

        defaults.removeObject(forKey: SidebarSettings.idleBehaviorKey)
        defaults.set(false, forKey: "sidebarAutoHide")
        SidebarSettings.migrateLegacyAutoHide(in: defaults)
        #expect(defaults.string(forKey: SidebarSettings.idleBehaviorKey) == "stayVisible")

        #expect(SidebarIdleBehavior.saved(nil) == .fade)
        #expect(SidebarIdleBehavior.saved("bogus") == .fade)
    }

    @Test func windowOnEveryDesktopOfADisplayCollapsesToTheVisibleDesktop() {
        let a1 = SidebarDesktop(id: 5, order: 0, number: 1, displayIdentifier: "a")
        let a2 = SidebarDesktop(id: 6, order: 1, number: 2, displayIdentifier: "a")
        let a3 = SidebarDesktop(id: 7, order: 2, number: 3, displayIdentifier: "a")
        let b1 = SidebarDesktop(id: 8, order: 3, number: 4, displayIdentifier: "b")
        let b2 = SidebarDesktop(id: 9, order: 4, number: 5, displayIdentifier: "b")
        let catalog = [a1, a2, a3, b1, b2]
        func collapse(_ membership: [SidebarDesktop], visible: Set<UInt64>) -> [SidebarDesktop] {
            SidebarSpaceReader.collapsingAllDesktopsMembership(membership, catalog: catalog, visible: visible)
        }
        // Sticky on display b only: one row, on b's visible desktop.
        #expect(collapse([b1, b2], visible: [5, 9]) == [b2])
        // No visible desktop known: deterministic fallback to the first.
        #expect(collapse([b1, b2], visible: []) == [b1])
        // Sticky on both displays: one row per display.
        #expect(collapse([a1, a2, a3, b1, b2], visible: [6, 8]) == [a2, b1])
        // Partial membership and single-desktop windows are real placements.
        #expect(collapse([a1, a2], visible: [5]) == [a1, a2])
        #expect(collapse([a1], visible: [5]) == [a1])
        #expect(collapse([], visible: []).isEmpty)
    }

    @MainActor @Test func repeatedAppIconsHaveDistinctIdentitiesAndOnlyTheirDesktopsWindows() throws {
        let running = NSRunningApplication.current
        let pid = running.processIdentifier
        let app = Application(running)
        let desktop1 = SidebarDesktop(id: 100, order: 0, number: 1)
        let desktop2 = SidebarDesktop(id: 200, order: 1, number: 2)
        func window(_ id: CGWindowID) -> Window {
            let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Window \(id)")
            window.cgWindowID = id
            return window
        }
        let remote = SidebarWindowID(pid: pid, windowID: 30)
        let entry = SidebarEntry(pid: pid, application: app, windows: [window(10), window(20), window(30)],
            preferredID: remote, focusedID: remote, windowStates: [
                10: SidebarWindowState(isMinimized: false, canMinimize: true, isOnScreen: true, desktops: [desktop1]),
                20: SidebarWindowState(isMinimized: true, canMinimize: true, isOnScreen: false, desktops: [desktop1]),
                30: SidebarWindowState(isMinimized: false, canMinimize: true, isOnScreen: false, desktops: [desktop2])
            ])
        let groups = SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: .allDesktops)
        #expect(groups.count == 2)
        let first = try #require(groups.first)
        let second = try #require(groups.last)
        #expect(first.id != second.id)
        #expect(first.pid == second.pid)
        #expect(first.windows.map(\.cgWindowID) == [10, 20])
        #expect(second.windows.map(\.cgWindowID) == [30])
        #expect(second.hasOtherWindows) // A multi-window app still gets a menu for its one-window group.
        #expect(first.windowStates[10]?.desktopLabel == "1. ")
        #expect(second.windowStates[30]?.desktopLabel == "2. ")
        #expect(second.focusedID == remote)
        #expect(first.focusedID == nil)
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: second, frontmostPID: pid, setting: setting) == .focus(remote))
        }
        #expect(SidebarWindowInventory.separatorIndices(entries: groups, scope: .allDesktops) == [1])
        #expect(SidebarWindowInventory.separatorIndices(entries: groups, scope: .visibleDesktops).isEmpty)
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let plain = SidebarLayout.sidebarFrame(in: frame, count: 2, side: .right, position: 0.5, appSpacing: 4)
        let separated = SidebarLayout.sidebarFrame(in: frame, count: 2, side: .right, position: 0.5,
                                                   appSpacing: 4, separatorCount: 1)
        #expect(separated.height - plain.height == SidebarLayout.desktopSeparatorHeight + 4)
    }

    @Test func desktopScopeDefaultsToAllDesktops() {
        #expect(SidebarDesktopScope.saved(nil) == .allDesktops)
        #expect(SidebarDesktopScope.saved("invalid") == .allDesktops)
        for scope in SidebarDesktopScope.allCases {
            #expect(SidebarDesktopScope.saved(scope.rawValue) == scope)
        }
    }

    @MainActor @Test func allDesktopsKeepsRunningAppsWhenMacOSReturnsNoWindows() throws {
        let running = NSRunningApplication.current
        // Feed the production inventory assembler a real running app and an empty AX result.
        let entries = SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .allDesktops)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.pid == running.processIdentifier)
        #expect(entry.windows.isEmpty)
        #expect(entry.preferredID == nil)
        #expect(entry.preferredWindow == nil)
        for setting in SidebarActiveAppClickAction.allCases {
            for frontmost in [nil, Optional(running.processIdentifier)] {
                let action = SidebarIconClickPolicy.action(for: entry, frontmostPID: frontmost, setting: setting)
                #expect(action == .activateApp(running.processIdentifier))
                #expect(action?.target == nil)
            }
        }
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .visibleDesktops).isEmpty)
    }

    @MainActor @Test func allDesktopsMergesWindowListsWithoutDuplicatingApps() throws {
        let running = NSRunningApplication.current
        let app = Application(running)
        let id = SidebarWindowID(pid: running.processIdentifier, windowID: 10)
        let window = Window(AXUIElementCreateApplication(id.pid), app, cachedTitle: "Readable window")
        window.cgWindowID = id.windowID
        let original = SidebarEntry(pid: id.pid, application: app, windows: [window], preferredID: id)
        let entries = SidebarWindowInventory.entries(for: [running], windowEntries: [original], scope: .allDesktops)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.preferredID == id)
        #expect(entry.windows.map(\.cgWindowID) == [10])
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: nil, setting: .minimize) == .focus(id))
    }

    @MainActor @Test func finderNeedsAWindowButMinimisedWindowsKeepItListed() throws {
        let running = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        #expect(SidebarWindowInventory.entries(for: [running], windowEntries: [], scope: .allDesktops).isEmpty)
        let app = Application(running)
        let id = SidebarWindowID(pid: running.processIdentifier, windowID: 10)
        let window = Window(AXUIElementCreateApplication(id.pid), app, cachedTitle: "Downloads")
        window.cgWindowID = id.windowID
        let entry = SidebarEntry(pid: id.pid, application: app, windows: [window], preferredID: id,
            windowStates: [10: SidebarWindowState(isMinimized: true, canMinimize: true, isOnScreen: false)])
        for scope in SidebarDesktopScope.allCases {
            let entries = SidebarWindowInventory.entries(for: [running], windowEntries: [entry], scope: scope)
            #expect(entries.count == 1)
            #expect(entries.first?.windows.map(\.cgWindowID) == [10])
        }
    }

    @Test func activeAppClickDefaultsAndInvalidValuesUseMinimise() {
        #expect(SidebarActiveAppClickAction.saved(nil) == .minimize)
        #expect(SidebarActiveAppClickAction.saved("invalid") == .minimize)
        for value in SidebarActiveAppClickAction.allCases {
            #expect(SidebarActiveAppClickAction.saved(value.rawValue) == value)
        }
    }

    @MainActor @Test func iconClicksRespectFocusAndRestoreBeforeToggling() {
        let app = Application(NSRunningApplication.current)
        let pid = getpid()
        let first = SidebarWindowID(pid: pid, windowID: 10)
        let second = SidebarWindowID(pid: pid, windowID: 20)
        func window(_ id: CGWindowID) -> Window {
            let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Window")
            window.cgWindowID = id
            return window
        }
        var entry = SidebarEntry(pid: pid, application: app, windows: [window(10), window(20)], preferredID: first,
                                 focusedID: second)
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: nil, setting: setting) == .focus(first))
        }
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .none) == .focus(first))
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .hide) == .hide(first))
        // Minimise the focused window, even when a different cached window is preferred.
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .minimize)
                == .minimize(second, requireFocused: true))
        entry.focusedID = nil // A modal/nonstandard window must not minimise a substitute.
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .minimize) == nil)
        entry.windowStates = [10: SidebarWindowState(isMinimized: true, canMinimize: true),
                              20: SidebarWindowState(isMinimized: true, canMinimize: true)]
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: setting) == .focus(first))
        }
        entry.windowStates = [:]
        entry.isHidden = true
        #expect(entry.visibleIDs.isEmpty)
        #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: .hide) == .focus(first))
    }

    @Test func minimiseRejectsUnsupportedFullScreenAndModalWindows() {
        #expect(SidebarWindowPolicy.canMinimize(standardWindow: true, fullScreen: false, modal: false,
                                              hasSheets: false, settable: true))
        for state in [(false, false, false, false, true), (true, true, false, false, true),
                      (true, false, true, false, true), (true, false, false, true, true),
                      (true, false, false, false, false)] {
            #expect(!SidebarWindowPolicy.canMinimize(standardWindow: state.0, fullScreen: state.1,
                modal: state.2, hasSheets: state.3, settable: state.4))
        }
    }

    @Test func queuedActionsCanBeCancelledRepeatedly() {
        let action = SidebarPendingAction(frontmostPID: nil)
        #expect(!action.isCancelled)
        #expect(!action.hasStartedFocus)
        #expect(action.beginFocus())
        #expect(action.hasStartedFocus)
        action.cancel()
        action.cancel()
        #expect(action.isCancelled)
        #expect(!action.isCurrent)
        #expect(!action.beginFocus())
    }

    @MainActor @Test func anActiveAppOnAnotherDesktopIsFocusedInsteadOfHiddenOrMinimised() {
        let pid = getpid()
        let app = Application(NSRunningApplication.current)
        let id = SidebarWindowID(pid: pid, windowID: 10)
        let window = Window(AXUIElementCreateApplication(pid), app, cachedTitle: "Other desktop")
        window.cgWindowID = id.windowID
        let entry = SidebarEntry(pid: pid, application: app, windows: [window], preferredID: id, focusedID: id,
            windowStates: [10: SidebarWindowState(isMinimized: false, canMinimize: false, isOnScreen: false)])
        #expect(entry.visibleIDs.isEmpty)
        for setting in SidebarActiveAppClickAction.allCases {
            #expect(SidebarIconClickPolicy.action(for: entry, frontmostPID: pid, setting: setting) == .focus(id))
        }
    }

    @MainActor @Test func rapidRepeatsAreBlockedButLaterGroupedClicksAreAccepted() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var clicks = 0
        view.onClick = { clicks += 1 }
        // Grouped clicks less than 230 ms after the last accepted click are suppressed.
        // Use 240 ms for accepted repeats to stay clear of the floating-point boundary.
        let events: [(TimeInterval, Int, Int)] = [(1, 1, 1), (1.05, 2, 1), (1.1, 3, 1),
                                                (1.24, 4, 2), (1.3, 5, 2), (1.48, 6, 3),
                                                (1.49, 1, 4)]
        for (timestamp, count, expectedClicks) in events {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                modifierFlags: [], timestamp: timestamp, windowNumber: 0, context: nil,
                eventNumber: count, clickCount: count, pressure: 1))
            view.mouseDown(with: event)
            let release = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                modifierFlags: [], timestamp: timestamp + 0.01, windowNumber: 0, context: nil,
                eventNumber: count, clickCount: count, pressure: 0))
            view.mouseUp(with: release)
            #expect(clicks == expectedClicks)
        }
    }

    @MainActor private func primaryClick(_ view: SidebarPointerRegion.PointerView, count: Int,
                                         time: TimeInterval, modifiers: NSEvent.ModifierFlags = []) throws {
        let point = CGPoint(x: 10, y: 10)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: modifiers, timestamp: time, windowNumber: 0, context: nil,
            eventNumber: count, clickCount: count, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: modifiers, timestamp: time + 0.001, windowNumber: 0, context: nil,
            eventNumber: count, clickCount: count, pressure: 0))
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    @MainActor @Test func doubleClickMaximisesOnceWithoutFiringTheMappedSingleAction() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var singles = 0, maximises = 0
        view.doubleClickTarget = SidebarWindowID(pid: 42, windowID: 1)
        view.onMouseClick = { _ in singles += 1 }
        view.onDoubleClick = { maximises += 1 }
        try primaryClick(view, count: 1, time: 1)
        #expect(singles == 0 && maximises == 0)
        try primaryClick(view, count: 2, time: 1 + SidebarClickGate.interval / 2)
        view.commitPendingClick()
        #expect(singles == 0 && maximises == 1)
    }

    @MainActor @Test func groupedClicksWorkAgainWhenActionFinishesWithoutMovingTheMouse() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        view.doubleClickTarget = SidebarWindowID(pid: 42, windowID: 1)
        var busy = false
        var singles = 0, maximises = 0
        view.onMouseClick = { _ in if !busy { singles += 1 } }
        view.onDoubleClick = { maximises += 1; busy = true }
        try primaryClick(view, count: 1, time: 1)
        try primaryClick(view, count: 2, time: 1 + SidebarClickGate.interval / 2)
        #expect(maximises == 1 && singles == 0)
        try primaryClick(view, count: 3, time: 1 + SidebarClickGate.interval * 0.75)
        #expect(singles == 0) // The inventory ignores clicks while its action is busy.
        busy = false
        try primaryClick(view, count: 4, time: 1 + SidebarClickGate.interval * 0.9)
        #expect(singles == 1 && maximises == 1)
    }

    @MainActor @Test func secondClickAfter230MillisecondsRunsAsASingleClick() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var singles = 0, maximises = 0
        view.doubleClickTarget = SidebarWindowID(pid: 42, windowID: 1)
        view.onMouseClick = { _ in singles += 1 }
        view.onDoubleClick = { maximises += 1 }
        try primaryClick(view, count: 1, time: 1)
        try primaryClick(view, count: 2, time: 1 + SidebarClickGate.interval + 0.05)
        #expect(singles == 2 && maximises == 0)
    }

    @MainActor @Test func singleClickFallbackAndModifierClicksKeepTheirMappedAction() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var singles = 0, maximises = 0
        view.doubleClickTarget = SidebarWindowID(pid: 42, windowID: 1)
        view.onMouseClick = { _ in singles += 1 }
        view.onDoubleClick = { maximises += 1 }
        try primaryClick(view, count: 1, time: 1)
        view.commitPendingClick()
        #expect(singles == 1)
        try primaryClick(view, count: 1, time: 2, modifiers: .shift)
        #expect(singles == 2 && maximises == 0)
        try primaryClick(view, count: 1, time: 3)
        view.doubleClickTarget = SidebarWindowID(pid: 42, windowID: 2)
        view.commitPendingClick()
        #expect(singles == 2 && maximises == 0)
    }

    @MainActor @Test func draggingAndEscapeCancelDeferredClickActions() throws {
        let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
        var singles = 0, maximises = 0, drags = 0
        view.doubleClickTarget = SidebarWindowID(pid: 42, windowID: 1)
        view.onClick = { singles += 1 }
        view.onDoubleClick = { maximises += 1 }
        view.onDrag = { _, _ in drags += 1 }
        try primaryClick(view, count: 1, time: 1)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 1 + SidebarClickGate.interval / 2, windowNumber: 0,
            context: nil, eventNumber: 2, clickCount: 2, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: CGPoint(x: 30, y: 10),
            modifierFlags: [], timestamp: down.timestamp + 0.01, windowNumber: 0,
            context: nil, eventNumber: 2, clickCount: 2, pressure: 1))
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.commitPendingClick()
        #expect(drags == 1 && singles == 0 && maximises == 0)
        try primaryClick(view, count: 1, time: 3)
        view.cancelOperation(nil)
        view.commitPendingClick()
        #expect(singles == 0 && maximises == 0)
    }

    @MainActor @Test func aDoubleClickRequiresAnInBoundsClickRelease() throws {
        for (point, releaseCount) in [(CGPoint(x: 100, y: 10), 2), (CGPoint(x: 10, y: 10), 0)] {
            let view = SidebarPointerRegion.PointerView(frame: CGRect(x: 0, y: 0, width: 86, height: 86))
            var actions = 0
            view.doubleClickTarget = SidebarWindowID(pid: 42, windowID: 1)
            view.onClick = { actions += 1 }
            view.onDoubleClick = { actions += 1 }
            try primaryClick(view, count: 1, time: 1)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: 1 + SidebarClickGate.interval / 2,
                windowNumber: 0, context: nil, eventNumber: 2, clickCount: 2, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: down.timestamp + 0.001, windowNumber: 0,
                context: nil, eventNumber: 2, clickCount: releaseCount, pressure: 0))
            view.mouseDown(with: down)
            view.mouseUp(with: up)
            view.commitPendingClick()
            #expect(actions == 0)
        }
    }

    @MainActor @Test func menuStateRefreshesWindowControlsAndClearsThemForKeyboardMode() {
        let app = Application(NSRunningApplication.current)
        let window = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Example")
        window.cgWindowID = 10
        let state = CyclePanelState()
        let normal = SidebarWindowState(isMinimized: false, canMinimize: true)
        let minimized = SidebarWindowState(isMinimized: true, canMinimize: true)
        state.setWindows([window], applicationTitle: "Example", selectedID: 10, sidebarWindowStates: [10: normal])
        #expect(state.showsSidebarActions)
        state.selectFromPointer(0)
        state.setWindows([window], applicationTitle: "Example", selectedID: 10,
                         preserveInteraction: true, sidebarWindowStates: [10: minimized])
        #expect(state.sidebarWindowStates[10] == minimized)
        #expect(!state.shouldScrollToSelection)
        #expect(state.currentWindow?.cgWindowID == 10)
        state.setWindows([window], applicationTitle: "Example", selectedID: 10,
                         preserveInteraction: true, sidebarWindowStates: [10: normal], sidebarAppIsHidden: true)
        #expect(state.sidebarAppIsHidden)
        #expect(!state.sidebarWindowStates[10]!.isMinimized)
        state.setApplication(app)
        #expect(!state.showsSidebarActions)
        #expect(state.sidebarWindowStates.isEmpty)
        #expect(state.showsHeader)
        #expect(!state.sidebarAppIsHidden)
        state.reset()
        #expect(!state.showsSidebarActions)
    }

    @Test func ordinaryVisibleHiddenAndMinimisedWindowsAreEligible() {
        #expect(SidebarWindowPolicy.isEligible(onScreen: true, normalLevel: true, standardWindow: true,
                                              minimized: false, hidden: false, ownProcess: false))
        // Startup discovery must also include windows that were never on screen this session.
        for state in [(false, true, false), (false, false, true), (false, true, true)] {
            #expect(SidebarWindowPolicy.isEligible(onScreen: state.0, normalLevel: true,
                standardWindow: true, minimized: state.1, hidden: state.2, ownProcess: false))
        }
        // Inactive-desktop visible windows and nonstandard/own-process windows stay excluded.
        let excluded = [
            (false, true, true, false, false, false), // inactive desktop
            (true, false, true, false, false, false), // utility panel
            (true, true, false, false, false, false), // non-standard window
            (true, true, true, false, false, true)    // octopus itself
        ]
        for value in excluded {
            #expect(!SidebarWindowPolicy.isEligible(onScreen: value.0, normalLevel: value.1,
                                                   standardWindow: value.2, minimized: value.3,
                                                   hidden: value.4, ownProcess: value.5))
        }
    }

    @Test func dockTransitionsKeepAnExistingAppInTheSameSidebarSlot() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let original = SidebarLayout.sidebarFrame(in: screen, count: 3, side: .right, position: 0.5)
        // CG can report off-screen before AX reports minimised, and during restore the
        // reverse happens. The AX window still exists throughout these snapshots.
        for (onScreen, minimized) in [(true, false), (false, false), (false, true),
                                      (false, false), (true, false)] {
            let staysListed = SidebarWindowPolicy.isEligible(onScreen: onScreen, normalLevel: true,
                standardWindow: true, minimized: minimized, hidden: false, ownProcess: false,
                previouslyListed: true)
            #expect(staysListed)
            let frame = SidebarLayout.sidebarFrame(in: screen, count: staysListed ? 3 : 2,
                                                   side: .right, position: 0.5)
            #expect(frame == original)
        }
        // Clearing desktop history must not admit an ordinary window on another desktop.
        #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: true,
            minimized: false, hidden: false, ownProcess: false, previouslyListed: false))
        #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: false,
            minimized: false, hidden: false, ownProcess: false, previouslyListed: true))
    }

    @Test func allDesktopsIncludesOffScreenWindowsButStillExcludesPanelsAndoctopus() {
        #expect(SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: true,
            minimized: false, hidden: false, ownProcess: false, scope: .allDesktops))
        #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: true, standardWindow: true,
            minimized: false, hidden: false, ownProcess: false, scope: .visibleDesktops))
        for value in [(false, true, false), (true, false, false), (true, true, true)] {
            #expect(!SidebarWindowPolicy.isEligible(onScreen: false, normalLevel: value.0,
                standardWindow: value.1, minimized: false, hidden: false,
                ownProcess: value.2, scope: .allDesktops))
        }
    }

    @Test func popupOwnsInputWhereItOverlapsTheSidebar() {
        let sidebar = CGRect(x: 1000, y: 200, width: SidebarLayout.width, height: 300)
        let screen = CGRect(x: 0, y: 0, width: 1100, height: 900)
        let iconSize = SidebarLayout.iconSize * (1 + SidebarLayout.magnificationGrowth)
        let icon = CGRect(x: sidebar.midX - iconSize / 2, y: sidebar.midY - iconSize / 2,
                          width: iconSize, height: iconSize)
        let menu = SidebarLayout.menuFrame(size: CGSize(width: 280, height: 120), icon: icon,
                                           screen: screen, side: .right)
        let overlap = sidebar.intersection(menu)
        #expect(!overlap.isEmpty)
        let point = CGPoint(x: overlap.midX, y: overlap.midY)
        #expect(!SidebarLayout.acceptsSidebarPointer(at: point, sidebar: sidebar, menu: menu))
        #expect(SidebarLayout.acceptsSidebarPointer(at: point, sidebar: sidebar, menu: nil))
        #expect(SidebarLayout.acceptsSidebarPointer(at: CGPoint(x: sidebar.maxX - 5, y: sidebar.midY),
                                                    sidebar: sidebar, menu: menu))
        #expect(!SidebarLayout.acceptsSidebarPointer(at: .zero, sidebar: sidebar, menu: menu))
    }

    @Test func topLevelWindowsAreAcceptedWhenSubroleIsMissing() {
        #expect(SidebarWindowPolicy.isTopLevelWindow(role: kAXWindowRole as String, subrole: nil))
        #expect(SidebarWindowPolicy.isTopLevelWindow(role: kAXWindowRole as String, subrole: "AXUnknown"))
        #expect(SidebarWindowPolicy.isTopLevelWindow(
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String
        ))
        #expect(!SidebarWindowPolicy.isTopLevelWindow(role: kAXButtonRole as String, subrole: nil))
        #expect(!SidebarWindowPolicy.isTopLevelWindow(role: kAXWindowRole as String, subrole: "AXCloseButton"))
    }

    @Test func windowTitlesAreMatchedWithoutCaseOrOuterWhitespace() {
        #expect(SidebarWindowPolicy.normalizedWindowTitle("  New Tab - Google Chrome  ") == "new tab - google chrome")
        #expect(SidebarWindowPolicy.normalizedWindowTitle("Safari") != "safari window")
    }

    @Test func selectionUsesEligibleHistoryThenFocusThenFirstWindow() {
        let first = SidebarWindowID(pid: 1, windowID: 10)
        let second = SidebarWindowID(pid: 1, windowID: 20)
        let stale = SidebarWindowID(pid: 2, windowID: 10)
        #expect(first != stale)
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [first: 1, second: 2, stale: 3], focused: first) == second)
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [stale: 3], focused: second) == second)
        #expect(SidebarWindowPolicy.preferredID([first], recency: [:], focused: second) == first)
        #expect(SidebarWindowPolicy.preferredID([], recency: [first: 1], focused: first) == nil)

        let states: [CGWindowID: SidebarWindowState] = [
            10: SidebarWindowState(isMinimized: false, canMinimize: true, isOnScreen: true),
            20: SidebarWindowState(isMinimized: false, canMinimize: false, isOnScreen: false)
        ]
        // A newer off-desktop window must not take an icon click away from a visible one.
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [first: 1, second: 2],
            focused: second, states: states) == first)
        #expect(SidebarWindowPolicy.preferredID([second], recency: [:],
            focused: second, states: states) == second)
        #expect(SidebarWindowPolicy.preferredID([first, second], recency: [first: 1, second: 2],
            focused: first, states: states, hidden: true) == second)
    }

    @Test func sidebarPositionUsesSelectedScreenAndClampsOverflow() {
        let screen = CGRect(x: -1440, y: 120, width: 1440, height: 850)
        let top = SidebarLayout.sidebarFrame(in: screen, count: 2, side: .right, position: 0)
        let middle = SidebarLayout.sidebarFrame(in: screen, count: 2, side: .right, position: 0.5)
        let bottom = SidebarLayout.sidebarFrame(in: screen, count: 2, side: .left, position: 1)
        #expect(top.maxX == screen.maxX)
        #expect(top.maxY == screen.maxY)
        #expect(middle.midY == screen.midY)
        #expect(bottom.minX == screen.minX)
        #expect(bottom.minY == screen.minY)
        let overflow = SidebarLayout.sidebarFrame(in: screen, count: 100, side: .right, position: 1.5)
        #expect(overflow.height == screen.height)
        #expect(screen.contains(overflow))
    }

    @Test func menuStaysNearIconAndWithinItsMonitor() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let icon = CGRect(x: -70, y: 200, width: 40, height: 40)
        let right = SidebarLayout.menuFrame(size: CGSize(width: 400, height: 300), icon: icon, screen: screen, side: .right)
        #expect(right.maxX == icon.minX - SidebarLayout.menuGap)
        #expect(right.midY == icon.midY - 18)
        let leftIcon = CGRect(x: screen.minX + 30, y: screen.maxY - 40, width: 40, height: 40)
        let left = SidebarLayout.menuFrame(size: CGSize(width: 400, height: 500), icon: leftIcon, screen: screen, side: .left)
        #expect(left.minX == leftIcon.maxX + SidebarLayout.menuGap)
        #expect(left.maxY == screen.maxY)
        #expect(screen.contains(left))
        let oversized = SidebarLayout.menuFrame(size: CGSize(width: 2000, height: 2000), icon: icon, screen: screen, side: .right)
        #expect(oversized == screen)
        let bottomIcon = CGRect(x: screen.minX + 30, y: screen.minY + 10, width: 40, height: 40)
        let nearBottom = SidebarLayout.menuFrame(size: CGSize(width: 400, height: 300), icon: bottomIcon,
                                                screen: screen, side: .left)
        #expect(nearBottom.minY == screen.minY)
        #expect(screen.contains(nearBottom))
    }

    @Test func releasingModifiersOnlyCommitsKeyboardSessions() {
        let required: NSEvent.ModifierFlags = [.control, .option]
        #expect(!CyclePanelPresentation.sidebar.shouldCommit(required: required, pressed: []))
        #expect(!CyclePanelPresentation.keyboard.shouldCommit(required: required, pressed: required))
        #expect(CyclePanelPresentation.keyboard.shouldCommit(required: required, pressed: [.control]))
        #expect(!CyclePanelPresentation.keyboard.shouldCommit(required: [], pressed: []))
    }

    @MainActor @Test func unchangedRefreshKeepsRowsSelectionAndScrollIntent() {
        let app = Application(NSRunningApplication.current)
        func window(_ id: CGWindowID) -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Window \(id)")
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 20)
        state.selectFromPointer(1)
        var rowUpdates = 0
        let subscription = state.$items.dropFirst().sink { _ in rowUpdates += 1 }
        defer { subscription.cancel() }

        state.setWindows([window(20), window(10)], applicationTitle: "Example", selectedID: 20,
                         preserveInteraction: true)
        #expect(rowUpdates == 0)
        #expect(state.windows.map(\.cgWindowID) == [10, 20])
        #expect(state.currentWindow?.cgWindowID == 20)
        #expect(!state.shouldScrollToSelection)
    }

    @MainActor @Test func changedRefreshUpdatesTitlesAppendsWindowsAndHandlesClosedSelection() {
        let app = Application(NSRunningApplication.current)
        func window(_ id: CGWindowID, title: String = "Window") -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: title)
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 20)
        let selectedRowID = state.currentItem?.id
        state.setWindows([window(30), window(20, title: "Renamed"), window(10), window(20)],
                         applicationTitle: "Example", selectedID: 20, preserveInteraction: true)
        #expect(state.windows.map(\.cgWindowID) == [10, 20, 30])
        #expect(state.currentItem?.id == selectedRowID)
        #expect(state.currentWindow?.title == "Renamed")
        #expect(!state.shouldScrollToSelection)
        state.cycleNext()
        #expect(state.currentWindow?.cgWindowID == 30)
        #expect(state.shouldScrollToSelection)

        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 30,
                         preserveInteraction: true)
        #expect(state.currentWindow?.cgWindowID == 20)
        #expect(!state.items.contains { $0.id == .window(30) })
        #expect(!state.shouldScrollToSelection)
        state.setWindows([], applicationTitle: "Example", selectedID: 20, preserveInteraction: true)
        #expect(state.currentItem == nil)
    }

    @MainActor @Test func nativeMenuGeometryDrivesRowAndButtonHoverWithoutCompetingCallbacks() async throws {
        let app = Application(NSRunningApplication.current)
        func window(_ id: CGWindowID, title: String = "Window") -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: title)
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        let normal = SidebarWindowState(isMinimized: false, canMinimize: true)
        let minimized = SidebarWindowState(isMinimized: true, canMinimize: true)
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 10,
                         sidebarWindowStates: [10: normal, 20: minimized])
        var anchors: [CyclePanelItem.ID: NSView] = [:]
        var hideAnchor: NSView?
        let size = CGSize(width: 280, height: SidebarLayout.menuRowHeight * 2 + 1
                          + SidebarLayout.menuPadding * 2 + SidebarLayout.menuActionHeight + 1)
        // A hidden panel exercises real AppKit/SwiftUI layout without touching another app.
        let panel = CyclePanel(contentRect: CGRect(origin: .zero, size: size))
        #expect(panel.animationBehavior == .none)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let hosting = NSHostingView(rootView: CyclePanelView(state: state,
            onAnchor: { anchors[$0] = $1 }, onHideAnchor: { hideAnchor = $0 }))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = try #require(panel.contentView)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        container.layoutSubtreeIfNeeded()
        let first = try #require(anchors[.window(10)])
        let second = try #require(anchors[.window(20)])
        #expect(first.bounds.width == size.width - SidebarLayout.menuPadding * 2)
        #expect(first.bounds.height == SidebarLayout.menuRowHeight)
        #expect(second.bounds.height == SidebarLayout.menuRowHeight)
        #expect(!first.visibleRect.isEmpty)
        #expect(!second.visibleRect.isEmpty)
        let initialSize = panel.frame.size
        for index in 0..<12 {
            let row = index % 2 == 0 ? first : second
            // Alternate between the title, minimise/restore, and close regions without waiting for a scan.
            let zone = index % 3
            let x = zone == 0 ? row.bounds.midX : row.bounds.maxX - (zone == 1 ? 45 : 15)
            let point = panel.convertPoint(toScreen: row.convert(CGPoint(x: x, y: row.bounds.midY), to: nil))
            let target = CyclePanelController.sidebarPointerTarget(at: point, items: state.items,
                anchors: anchors, hideAnchor: hideAnchor)
            let id = CyclePanelItem.ID.window(index % 2 == 0 ? 10 : 20)
            let expected: SidebarPointerTarget = zone == 0 ? .row(id)
                : zone == 1 ? .windowAction(id) : .windowClose(id)
            #expect(target == expected)
            state.setSidebarPointerTarget(target)
            #expect(state.currentWindow?.cgWindowID == (index % 2 == 0 ? 10 : 20))
            #expect(state.sidebarPointerTarget == target)
            try await Task.sleep(for: .milliseconds(10))
            container.layoutSubtreeIfNeeded()
            #expect(anchors[.window(10)] === first)
            #expect(anchors[.window(20)] === second)
            #expect(first.bounds.height == SidebarLayout.menuRowHeight)
            #expect(second.bounds.height == SidebarLayout.menuRowHeight)
            #expect(panel.frame.size == initialSize)
        }
        // Replayed row events cannot compete with the panel's current pointer position.
        let oldPoint = first.convert(CGPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        let staleEntry = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: oldPoint,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        first.mouseEntered(with: staleEntry)
        let staleMove = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: oldPoint,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        first.mouseMoved(with: staleMove)
        #expect(state.currentWindow?.cgWindowID == 20)
        #expect(state.sidebarPointerTarget == .windowClose(.window(20)))
        let footer = try #require(hideAnchor)
        let footerPoint = panel.convertPoint(toScreen: footer.convert(
            CGPoint(x: footer.bounds.midX, y: footer.bounds.midY), to: nil))
        let footerTarget = CyclePanelController.sidebarPointerTarget(at: footerPoint, items: state.items,
            anchors: anchors, hideAnchor: hideAnchor)
        #expect(footerTarget == .hideApp)
        state.setSidebarPointerTarget(footerTarget)
        #expect(state.sidebarPointerTarget == .hideApp)
        #expect(state.currentWindow?.cgWindowID == 20)
        let outsideTarget = CyclePanelController.sidebarPointerTarget(
            at: CGPoint(x: panel.frame.minX - 10, y: panel.frame.minY - 10), items: state.items,
            anchors: anchors, hideAnchor: hideAnchor)
        #expect(outsideTarget == nil)
        state.setSidebarPointerTarget(outsideTarget)
        #expect(state.sidebarPointerTarget == nil)
        state.setWindows([window(10, title: String(repeating: "Long title ", count: 20)), window(20)],
                         applicationTitle: "Example", selectedID: 20, preserveInteraction: true,
                         sidebarWindowStates: [10: minimized, 20: normal], sidebarAppIsHidden: true)
        try await Task.sleep(for: .milliseconds(50))
        container.layoutSubtreeIfNeeded()
        #expect(panel.frame.size == initialSize)
        #expect(anchors[.window(10)] === first)
        #expect(anchors[.window(20)] === second)
        #expect(first.bounds.height == SidebarLayout.menuRowHeight)
        #expect(second.bounds.height == SidebarLayout.menuRowHeight)
    }

    @MainActor @Test func refreshedMenuPreservesIdentityAndHandlesRemovedSelection() {
        let app = Application(NSRunningApplication.current)
        // Local, inert AX handles: these tests neither inspect nor focus another application's windows.
        func window(_ id: CGWindowID) -> Window {
            let result = Window(AXUIElementCreateApplication(getpid()), app, cachedTitle: "Window \(id)")
            result.cgWindowID = id
            return result
        }
        let state = CyclePanelState()
        state.setWindows([window(10), window(20)], applicationTitle: "Example", selectedID: 20)
        #expect(!state.showsHeader)
        #expect(state.currentWindow?.cgWindowID == 20)
        state.selectFromPointer(0)
        #expect(!state.shouldScrollToSelection)
        state.cycleNext()
        #expect(state.shouldScrollToSelection)
        #expect(state.currentWindow?.cgWindowID == 20)
        state.setWindows([window(20), window(10)], applicationTitle: "Example", selectedID: 20)
        #expect(state.selectedIndex == 0)
        state.cyclePrevious()
        #expect(state.currentWindow?.cgWindowID == 10)
        state.cycleNext()
        #expect(state.currentWindow?.cgWindowID == 20)
        state.setWindows([window(10)], applicationTitle: "Example", selectedID: 20)
        #expect(state.currentWindow?.cgWindowID == 10)
        state.setWindows([], applicationTitle: "Example", selectedID: 10)
        #expect(state.currentItem == nil)
        #expect(!state.showsHeader)
    }
}

@MainActor private final class AnchorSwitchMode: ObservableObject {
    @Published var behavior: SidebarIdleBehavior = .stayVisible
}

@MainActor private final class AnchorSwitchRegistry {
    var rows: [Int: NSView] = [:]
    var geometry: [Int: NSView] = [:]
    var events: [String] = []

    func record(_ change: SidebarAnchorChange, id: Int, geometry: Bool) {
        switch change {
        case .registered(let view): events.append("register \(geometry) \(id) \(ObjectIdentifier(view))")
        case .removed(let view): events.append("remove \(geometry) \(id) \(ObjectIdentifier(view))")
        }
        if geometry { change.apply(to: &self.geometry, id: id) }
        else { change.apply(to: &rows, id: id) }
    }
}

private struct AnchorSwitchView: View {
    @ObservedObject var mode: AnchorSwitchMode
    let registry: AnchorSwitchRegistry

    var body: some View {
        Group {
            if mode.behavior == .notch {
                ScrollView(.horizontal) { HStack { ForEach(1...3, id: \.self) { row($0) } } }
            } else if mode.behavior == .compact {
                Text("Compact")
            } else {
                ScrollView(.vertical) { VStack { ForEach(1...3, id: \.self) { row($0) } } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ id: Int) -> some View {
        Text("App \(id)").frame(width: 86, height: 86)
            .background {
                SidebarGeometryAnchor(id: id, onAnchor: { id, change in
                    registry.record(change, id: id, geometry: true)
                })
            }
            .overlay {
                SidebarPointerRegion(onClick: {}, onAnchor: { change in
                    registry.record(change, id: id, geometry: false)
                })
            }
    }
}
