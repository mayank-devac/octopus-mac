# Plan 006: Maximise the shown app window with a double click

## Status
- Priority: P2; effort: S; risk: medium for gesture interference.
- Planned at: HEAD 954e3c7, 9 October 2026, plus staged layout work.
- Mayank confirmed: fill the current display, staying on the current native Desktop.
- Source implementation authorised. Build/tests are commands-only until requested.
- Implementation status: source and native gesture regression cases completed; build/tests/live behaviour unverified.

## Current state and convention
SidebarView.item installs SidebarPointerRegion over each app row. The callbacks capture the exact preferred window whose title the row shows. PointerView captures the mouse-down event and drag callback; a 6-point drag suppresses click actions. SidebarClickGate currently suppresses fast grouped repeats, so a new double-click callback must bypass that gate only on opted-in app rows.

SidebarDragController.place(id, at: .maximize) already validates that exact window, locates its display and submits a work-area placement. Reuse it via SidebarView.onPlacement. This is maximise, not macOS native Full Screen and not a toggle.

## Files and implementation
1. SidebarView.swift: opt app rows into a plain-left double-click callback with their exact window ID. Preserve mouse/modifier bindings. Delay the plain-left single callback until NSEvent.doubleClickInterval expires; matching second down cancels it and invokes maximise only on release inside the row.
2. PointerView: capture both callbacks and window identity at mouse down. Cancel pending clicks on drag, Escape, view removal or a changed target. Suppress the third/fourth grouped click after a handled double. A row without a window or double callback keeps the old immediate click gate.
3. SidebarTests.swift: drive actual native mouse-down/up/drag methods; deterministically commit/cancel pending singles without sleeping. Check one maximise and zero minimise/hide callbacks, normal single fallback, identity changes, triple click suppression, modifier clicks and drag cancellation.
4. Existing onPlacement/SidebarDragController.place is the canonical native action; do not add a second window writer or fullscreen API.
5. Comments must explain why single clicks wait and why stale/removal/drag paths cancel pending work.

## UX and limitations
Single plain-left actions wait for the user's configured macOS double-click interval so the window cannot first disappear. Other buttons/modifier clicks remain immediate. Only the row's captured live window can be maximised; inaccessible, closed, fullscreen, sheet or fixed-size windows use the existing placement rejection feedback.
The interval comes from [Apple's NSEvent.doubleClickInterval](https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval). The second release must still have clickCount 2; macOS can set a prolonged mouse-up to zero.

## Implemented details
PointerView stores typed Press/PendingClick snapshots, uses a nonce to reject stale timers, and cancels pending work on drag, Escape, target changes and view removal. Cross-display drag freezing cancels pending actions in sibling sidebars. Grouped third clicks cannot run a destructive single action after maximise. Explicit placement increments its generation and cancels old layout intent before preparation. Maximise reuses SidebarView.onPlacement and SidebarDragController.place.

## Verification
~~~sh
xcodebuild -project octopus.xcodeproj -scheme octopus \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-review-verification \
  -disableAutomaticPackageResolution \
  -only-testing:octopusTests/SidebarTests \
  -only-testing:octopusTests/MouseShortcutTests \
  -only-testing:octopusTests/SidebarDragTests test
~~~
Expected TEST SUCCEEDED and nonzero named-suite counts. Do not execute unless Mayank requests.
Read the actual diff and run git diff HEAD --check now. Live check: plain-left double click fills the same display/Desktop, single mapped click still executes once, and icon dragging cannot fire a pending click.
Do not commit/push, alter system double-click preferences, or add a native fullscreen Space transition.
