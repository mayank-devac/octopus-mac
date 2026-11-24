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
        for behavior in SidebarIdleBehavior.allCases {
            config.idleBehavior = behavior
            for choice in SidebarDelayedOpening.allCases {
                config.delayedOpening = choice
                let active = config.activeDelayedOpening
                #expect(active == (behavior.supportsDelayedOpening ? choice : .off))
                let policy = SidebarPresentation(configuration: config, hasNotchTrigger: false, fullScreen: false)
                let plain = SidebarPresentation(behavior: behavior, hasNotchTrigger: false, fullScreen: false)
                switch active {
                case .hideUntilEdge:
                    // Hide until edge presents exactly as Auto-Hide, plus the reveal delay.
                    let autoHide = SidebarPresentation(behavior: .hide, hasNotchTrigger: false, fullScreen: false)
                    #expect(config.effectiveIdleBehavior == .hide)
                    #expect(policy.mode == autoHide.mode && policy.autoHides == autoHide.autoHides)
                    #expect(policy.fadesWhenIdle == autoHide.fadesWhenIdle)
                    #expect(policy.revealDelay == 0.8 && policy.stepAsideDelay == nil)
                case .stepAside:
                    #expect(policy.mode == plain.mode && policy.autoHides == plain.autoHides)
                    #expect(policy.stepAsideDelay == 0.8 && policy.revealDelay == 0)
                case .off:
                    // Auto-Hide and Mac Notch keep their existing behaviour.
                    #expect(policy.mode == plain.mode && policy.autoHides == plain.autoHides)
                    #expect(policy.stepAsideDelay == nil && policy.revealDelay == 0)
                }
            }
        }
    }

    @Test func delayedOpeningDecodesOldProfilesAndClampsTheDelay() throws {
        let oldProfile = Data("{\"idleBehavior\":\"stayVisible\"}".utf8)
        let restored = try JSONDecoder().decode(SidebarConfiguration.self, from: oldProfile)
        #expect(restored.delayedOpening == .off)
        #expect(restored.openingDelay == SidebarSettings.defaultOpeningDelay)
        let unknown = Data("{\"delayedOpening\":\"later\",\"openingDelay\":9}".utf8)
        let clamped = try JSONDecoder().decode(SidebarConfiguration.self, from: unknown)
        #expect(clamped.delayedOpening == .off)
        #expect(clamped.openingDelay == SidebarSettings.openingDelayRange.upperBound)
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
}

//// Keep these pure; the controller owns the timer and the fade.
//////////////////
