import Foundation
import Testing
@testable import octopus

////////////////////
//// Delay opening
/// Settings resolution, presentation policy and the Step aside timing.
// Pure checks only; pointer, fade and click-through still need the real app.

struct SidebarDelayedOpeningTests {
    @Test func delayedOpeningAppliesOnlyToModesThatOfferIt() {
        var config = SidebarConfiguration.factoryDefaults
        config.openingDelay = 0.8
        config.closingDelay = 1.4
        for behavior in SidebarIdleBehavior.allCases {
            config.idleBehavior = behavior
            for choice in SidebarDelayedOpening.allCases {
                config.delayedOpening = choice
                let active = config.activeDelayedOpening
                #expect(active == (behavior.delayedOpeningChoices.contains(choice) ? choice : .off))
                let policy = SidebarPresentation(configuration: config, hasNotchTrigger: false, fullScreen: false)
                let plain = SidebarPresentation(behavior: behavior, hasNotchTrigger: false, fullScreen: false)
                switch active {
                case .hideEdge:
                    // Hide edge presents exactly as Auto-Hide, plus the reveal delay.
                    let autoHide = SidebarPresentation(behavior: .hide, hasNotchTrigger: false, fullScreen: false)
                    #expect(config.effectiveIdleBehavior == .hide)
                    #expect(policy.mode == autoHide.mode && policy.autoHides == autoHide.autoHides)
                    #expect(policy.fadesWhenIdle == autoHide.fadesWhenIdle)
                    #expect(policy.revealDelay == 0.8 && policy.stepAsideDelay == nil)
                    #expect(SidebarDelayedOpening.hideEdge.title == "Hide edge")
                    #expect(SidebarDelayedOpening.hideEdge.delayCopy?.title == "Opening delay")
                case .stepAside:
                    #expect(policy.mode == plain.mode && policy.autoHides == plain.autoHides)
                    #expect(policy.stepAsideDelay == 1.4)
                    #expect(SidebarDelayedOpening.stepAside.delayCopy?.title == "Closing delay")
                case .off:
                    // Auto-Hide and Mac Notch keep their existing behaviour.
                    #expect(policy.mode == plain.mode && policy.autoHides == plain.autoHides)
                    #expect(policy.stepAsideDelay == nil && policy.revealDelay == 0)
                    #expect(SidebarDelayedOpening.off.delayCopy == nil)
                }
            }
        }
        #expect(!SidebarIdleBehavior.stayVisible.delayedOpeningChoices.contains(.stepAside))
        #expect(SidebarIdleBehavior.stayVisible.delayedOpeningChoices.contains(.hideEdge))
        #expect(SidebarConfiguration.factoryDefaults.delayedOpening == .hideEdge)
    }

    @Test func delayedOpeningDecodesOldProfilesAndClampsTheDelay() throws {
        let oldProfile = Data("{\"idleBehavior\":\"stayVisible\"}".utf8)
        let restored = try JSONDecoder().decode(SidebarConfiguration.self, from: oldProfile)
        #expect(restored.delayedOpening == .hideEdge)
        #expect(restored.openingDelay == SidebarSettingsValues.defaultOpeningDelay)
        #expect(restored.closingDelay == SidebarSettingsValues.defaultClosingDelay)
        let unknown = Data("{\"delayedOpening\":\"later\",\"openingDelay\":9}".utf8)
        let clamped = try JSONDecoder().decode(SidebarConfiguration.self, from: unknown)
        #expect(clamped.delayedOpening == .hideEdge)
        #expect(clamped.openingDelay == SidebarSettingsValues.openingDelayRange.upperBound)
        #expect(clamped.closingDelay == SidebarSettingsValues.defaultClosingDelay)
        let prior = Data("{\"delayedOpening\":\"stepAside\",\"openingDelay\":1.2}".utf8)
        let restoredPrior = try JSONDecoder().decode(SidebarConfiguration.self, from: prior)
        #expect(restoredPrior.openingDelay == 1.2)
        #expect(restoredPrior.closingDelay == SidebarSettingsValues.defaultClosingDelay)
    }

    @Test func openingAndClosingDelaysPersistIndependently() throws {
        let suite = "SidebarDelayValues-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var config = SidebarConfiguration.factoryDefaults
        config.openingDelay = 0.8
        config.closingDelay = 1.4
        config.saveSingleSidebar(in: defaults)

        let restored = SidebarConfiguration(defaults: defaults)
        #expect(restored.openingDelay == 0.8)
        #expect(restored.closingDelay == 1.4)
    }

    @Test func stepAsideWaitsForAnUnusedRestAndStaysAsideUntilThePointerLeaves() {
        var stepAside = SidebarStepAside()
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 10, delay: 0.5) == .checkAfter(0.5))
        // Movement restarts the wait, so the original deadline does not step aside.
        stepAside.pointerInteracted(now: 10.25)
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 10.5, delay: 0.5) == .checkAfter(0.25))
        // An open window list counts as use.
        #expect(stepAside.update(pointerInside: true, inUse: true, now: 10.75, delay: 0.5) == .checkAfter(0.5))
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 11.25, delay: 0.5) == .stepAside)
        #expect(stepAside.isSteppedAside)
        // Moving or clicking underneath keeps it aside until the pointer leaves.
        stepAside.pointerInteracted(now: 11.4)
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 11.5, delay: 0.5) == .none)
        #expect(stepAside.update(pointerInside: false, inUse: false, now: 11.6, delay: 0.5) == .none)
        #expect(!stepAside.isSteppedAside && stepAside.phase == .idle)
    }

    @Test func stepAsideIgnoresHandTremorButCountsRealMovement() {
        var stepAside = SidebarStepAside()
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 10, delay: 1) == .checkAfter(1))
        stepAside.pointerMoved(to: CGPoint(x: 100, y: 100), now: 10)
        // Small wobbles around the rest point keep the original deadline.
        stepAside.pointerMoved(to: CGPoint(x: 102, y: 99), now: 10.4)
        stepAside.pointerMoved(to: CGPoint(x: 99, y: 103), now: 10.8)
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 11, delay: 1) == .stepAside)
        stepAside.reset()
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 20, delay: 1) == .checkAfter(1))
        stepAside.pointerMoved(to: CGPoint(x: 100, y: 100), now: 20)
        // A move past the tolerance is use and restarts the wait.
        stepAside.pointerMoved(to: CGPoint(x: 110, y: 100), now: 20.5)
        #expect(stepAside.update(pointerInside: true, inUse: false, now: 21, delay: 1) == .checkAfter(0.5))
    }
}

//// Keep these pure; the controller owns the timer and the fade.
//////////////////
