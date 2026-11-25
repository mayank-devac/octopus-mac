//
//  MacJiTests.swift
//  octopusTests
//
//  MacJi trigger matching, key mapping, result ranking and panel placement.
//

import AppKit
import Testing
@testable import octopus

struct MacJiTests {
    private func tracker(typing text: String, trigger: String = "::") -> MacJiTriggerTracker {
        var tracker = MacJiTriggerTracker(trigger: trigger)
        text.forEach { tracker.apply(.text(String($0))) }
        return tracker
    }

    @Test func queryFollowsTriggerAndEndsAtSpace() {
        #expect(tracker(typing: "hi ::roc").query == "roc")
        #expect(tracker(typing: "hi ::roc").replacementLength == 5)
        #expect(tracker(typing: "::").query == nil)
        #expect(tracker(typing: "::roc ").query == nil)
        #expect(tracker(typing: ";;dog", trigger: ";;").query == "dog")
    }

    @Test func triggerInsideWordIsIgnored() {
        #expect(tracker(typing: "std::string").query == nil)
    }

    @Test func deleteAndResetEditTheBuffer() {
        var typed = tracker(typing: "::rocx")
        typed.apply(.deleteBackward)
        #expect(typed.query == "roc")
        typed.apply(.reset)
        typed.apply(.text("a"))
        #expect(typed.query == nil)
    }

    @Test func keysMapToPanelActionsAndBufferInput() {
        #expect(MacJiKeyAction(keyCode: 36, modifiers: []) == .insert)
        #expect(MacJiKeyAction(keyCode: 36, modifiers: .shift) == .copy)
        #expect(MacJiKeyAction(keyCode: 53, modifiers: []) == .close)
        #expect(MacJiKeyAction(keyCode: 0, modifiers: []) == nil)
        #expect(MacJiTypedKey(keyCode: 0, modifiers: .command, characters: "a") == .reset)
        #expect(MacJiTypedKey(keyCode: 51, modifiers: [], characters: "\u{8}") == .deleteBackward)
        #expect(MacJiTypedKey(keyCode: 41, modifiers: .shift, characters: ":") == .text(":"))
    }

    @Test func invalidTriggersFallBackToDefault() {
        #expect(MacJiSettings.validTrigger(";;") == ";;")
        #expect(MacJiSettings.validTrigger("") == "::")
        #expect(MacJiSettings.validTrigger(": :") == "::")
        #expect(MacJiSettings.validTrigger("em") == "::")
    }

    @Test func aliasPrefixRanksBeforeSubstring() {
        let catalog = EmojiCatalog(emojis: [
            Emoji(emoji: "🎸", description: "guitar", category: "Objects", aliases: ["guitar"], tags: ["rock"]),
            Emoji(emoji: "🚀", description: "rocket", category: "Travel & Places", aliases: ["rocket"], tags: []),
            Emoji(emoji: "🐊", description: "crocodile", category: "Animals & Nature", aliases: ["crocodile"], tags: []),
        ])
        #expect(MacJiSearch.results(for: "roc", in: catalog).map(\.emoji) == ["🚀", "🎸", "🐊"])
    }

    @Test func panelFlipsAboveCaretNearScreenBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let card = MacJiView.cardSize
        let below = MacJiPanelPlacement.frame(card: card, caret: CGRect(x: 100, y: 600, width: 1, height: 16),
                                              pointer: .zero, visibleFrames: [screen])
        #expect(below.maxY - MenuShadowMargin.size <= 600)
        let above = MacJiPanelPlacement.frame(card: card, caret: CGRect(x: 100, y: 20, width: 1, height: 16),
                                              pointer: .zero, visibleFrames: [screen])
        #expect(above.minY + MenuShadowMargin.size >= 36)
    }
}
