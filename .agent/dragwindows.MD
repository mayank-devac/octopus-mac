# Sidebar window dragging

Current focus/minimise behaviour and verification are documented in [Cross-Desktop focus incident](cross-desktop-focus.md); that report supersedes this file's historical descriptions of early raises and app-wide foreground activation for sidebar focus.

Implemented on 2026-10-07. The existing placement baseline passed 63 sidebar, drag and mouse-shortcut tests. Desktop-transfer verification is recorded below; live cross-app behaviour remains unverified.

## What changed

- Dragging an app's sidebar icon moves the current window whose title is displayed under that icon, including apps with several windows. The hover popup remains available for clicking or dragging a different window's title row. Missing/stale current-window identities are rejected rather than replaced; the minimise/restore button remains independent.
- Clicking now commits on mouse-up. Moving more than six points starts dragging and suppresses the click. The original window ID and title are captured in the mouse-down callback, even if the inventory changes before dragging starts.
- The drag shows a translucent outline and window title. The real window changes only after a valid drop. Hover menus, magnification updates and auto-hide pause during dragging.
- Left/right sides select halves, the bottom side selects bottom-half, the top side maximises within the desktop, and corners select quarters. **Preferences → Sidebar → Snap distance** currently allows 20–460 points in 20-point steps, defaulting to 200; these existing values were preserved during the mouse-shortcut change. The chosen distance is saved and captured at the start of each drag so preview and drop agree. Zones remain capped at one-quarter of the display dimension on small displays; corners take precedence. Returning towards the centre clears snapping and resumes free movement.
- Free movement preserves size, uses the pointer as the window's top-centre, and keeps its title bar reachable. Placement respects the Dock and menu bar, negative monitor origins and AppKit/Accessibility coordinate differences.
- VoiceOver exposes named placement actions on eligible icons and popup titles; those actions use the same validated placement path.
- Escape, invalid sidebar/popup drops, desktop/display changes, permission loss or a disappearing target cancel without selecting a replacement window. Valid app-icon drops into another desktop section use the separate transfer action below. Temporary preview and drop windows close when the interaction finishes.

## Transfers between desktop sections

- App icons use the existing configured placement drag (right drag by default). Dropping within an ordinary desktop section transfers only the window named under the pressed icon. Popup title drags retain their existing positioning behaviour. Outside-sidebar icon drops still use placement and snapping.
- All desktops groups occupied desktop sections under Primary/Secondary headings with the actual monitor name. The original gradient separators divide desktops without visible desktop-number labels. Empty desktops have no sidebar rows; dragging a valid app icon onto its monitor heading opens all ordinary desktops in the existing window-list panel/row style, including empty destinations. Active and inactive desktops on the source window's monitor are eligible; Visible desktops retains its existing scope. Full-screen destinations, other monitors, hidden/minimised sources, modal windows, attached sheets, nonstandard/floating windows and multiple-desktop membership are rejected.
- Sidebar rows, sections and the desktop catalogue freeze while dragging. A translucent app icon follows the pointer inside the sidebar and desktop popup; valid destination sections/rows retain the blue highlight. Transfer instructions and unavailable-target previews are absent, and unsupported drags fail quietly. Clipped native section bounds exclude popup overlap and drawing padding. Native periodic drag updates allow bounded edge scrolling without a background timer. The popup's narrow heading-to-list corridor keeps it open while crossing the gap, without capturing neighbouring app icons. Settings changes, removed desktops and missing windows cancel the drag.
- `SidebarDesktopTransfer.swift` owns eligibility, section construction, clipped hit testing and membership verification. `SidebarSpaceTransfer.m` isolates the runtime SkyLight operation and its local-symbol lookup; the header is the app target's Swift bridge. It uses the same operation as yabai without a service, Dock injection or SIP changes.
- `SidebarDesktopMenu.swift` reuses `CyclePanel`, `CyclePanelRow` and `CyclePanelRowAnchor` for the drag-only desktop list. Monitor and desktop anchors are separate, so hovering a monitor chooses from all of its desktops while occupied sidebar sections remain direct drop targets.
- `SidebarWindowInventory` prepares placement and transfer separately, revalidates live identity/state/membership before submitting one move, then observes membership with a two-second deadline. It never resubmits automatically, activates or raises the app, restores/unhides it, or writes its frame. macOS decides stacking order. Unconfirmed completion refreshes the inventory without a transfer message or speculative rollback.
- VoiceOver exposes matching named desktop-transfer actions. Runtime API resolution runs on the worker queue. A read-only native probe confirmed the transfer API is available on this Mac; actual Space transfers, focus preservation and live dragging remain unverified.

Automated desktop-transfer verification: **72 tests passed, 0 failed, 0 skipped** across `SidebarDesktopTransferTests`, `SidebarDragTests`, `SidebarTests` and `MouseShortcutTests`, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_16-06-50-+0530.xcresult`. The build succeeded. `/tmp/octopus-desktop-transfer-tests.log` records the run; the read-only API probe is `/tmp/octopus-desktop-transfer-availability`.

The final popup-scroll guard rebuilt successfully and passed **30 desktop-transfer/drag tests**, with no failures or skips, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_16-08-57-+0530.xcresult`; log: `/tmp/octopus-desktop-transfer-final-tests.log`.

The monitor-heading/desktop-popup revision rebuilt successfully and passed **74 focused tests**, with no failures or skips, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_16-56-17-+0530.xcresult`; log: `/tmp/octopus-monitor-drag-final-tests.log`. Coverage includes empty desktops remaining in the popup catalogue, primary/secondary monitor naming, and the popup crossing corridor excluding adjacent app icons. Live pointer and transfer behaviour remains unverified.

## Mouse shortcuts

**Preferences → Shortcuts → Mouse shortcuts** applies only to sidebar app icons. Window-list rows keep their existing left-click focus and left-drag behaviour; ordinary mouse input in other apps is unaffected.

| Action | Default |
| --- | --- |
| Minimise / restore current window | Right click |
| Move, resize and snap current window | Right click + drag |
| Focus an inactive app, hide an active app | Left click |

- Each row has **Record**, **Reset** and **× remove**. Click Record, then click the recorder itself using the desired mouse button; Control, Option, Shift and Command are optional. Escape or moving focus away cancels recording. Recording stops immediately when captured, preventing release from rearming the control.
- Hide and minimise cannot share the same button/modifier combination. Rejected recordings preserve the previous binding and explain the conflict. Placement may share a click binding because moving beyond six points cancels the click and starts only the matching drag action.
- Reset restores only that row's default. If Hide or Minimise's default is already assigned to the other action, Reset is rejected with the same explanation; it never silently swaps or overwrites another row.
- **Reset all mouse shortcuts** restores the complete default set together, including swapped or disabled bindings, clears recorder/error state and preserves keyboard shortcuts.
- Removing a binding remains disabled across restarts. If Hide is removed, unassigned plain left-click still focuses the app. Right-click restores an already minimised/hidden target. Minimise keeps the exact window identity captured at press and rejects a closed target, even if another window becomes preferred.
- The old Sidebar “Clicking the active app” picker was removed because these mouse rows now own those actions. The keyboard reset control is explicitly labelled “Reset keyboard modifiers” and does not reset mouse rows.

## How it connects

- `SidebarView.swift` supplies native click/drag regions, also used by `CyclePanelView.swift` for popup titles. Both freeze the window identity before the drag threshold is crossed.
- `SidebarDragController.swift` owns the native drag session, preview, temporary drop surfaces and quiet feedback. Its custom pasteboard data contains only a random session token. A drop must come from this controller and match the token; foreign drops and Escape never commit placement. The outline ignores mouse events, while transparent drop surfaces exist only during dragging.
- `SidebarWindowPlacement.swift` holds pure snap/coordinate geometry, eligibility rules and a testable placement writer. No external app or package was added.
- `SidebarSettings.swift` registers and validates the snap-distance preference, including safe defaults for missing or non-finite values. `PreferencesSidebarView.swift` adds one accessible slider using the existing settings layout.
- `MouseShortcuts.swift` provides the shared observable bindings, validation, uniqueness checks and per-row reset. The `sidebarMouseShortcut.minimize`, `.place` and `.hide` keys save the button/modifier combination; an empty string disables the action. Invalid preferences use safe defaults, and duplicate saved click bindings disable minimise rather than triggering both actions.
- `MouseShortcutRecorder.swift` captures only on its native button, with no global input monitor or new permission. `SidebarPointerRegion` handles left, right and additional mouse buttons, freezing callbacks, modifiers and the initiating event at press. Native drag initiation receives that original mouse-down event, matching [AppKit's drag API](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession%28with%3Aevent%3Asource%3A%29).
- `SidebarWindowInventory.swift` handles preparation and the `.place` action on its existing serial AX queue. It revalidates live identity, permissions, ordinary desktop membership, writable position/size, fullscreen/modal status and attached sheets before mutation.
- `SidebarSpaces.swift` reads the currently visible ordinary Space IDs through the existing dynamically loaded private API. Unknown desktop membership disables placement rather than guessing, including for hidden/minimised windows.
- Hidden/minimised windows restore only after validation. Placement uses size-position-size when resizing is supported, reads the resulting frame, and corrects an off-display position where possible. AX calls have a 0.2-second timeout; the write sequence has a 1.2-second deadline. No continuous AX calls or unbounded retries run during pointer movement.
- `AXUIElement.swift` now checks CF value types before decoding position and size, preventing malformed responses from being interpreted as AXValue objects.

## Delays and foreground restoration

Removed the 200 ms icon-magnification animation and 150 ms popup-dismissal grace. Sidebar, preview and feedback panels now explicitly disable native show/hide animations. Hover, reveal and dismissal work still use the next UI turn when needed for correct event/layout ordering; there is no fixed sleep before a click or drag action.

The source-wide timing audit found these remaining times:

| Time | Purpose and decision |
| --- | --- |
| 230 ms | Suppress very fast grouped repeat clicks; the first accepted click is immediate. Keep for toggle safety. |
| 50 ms, up to six retries | Existing settings-window readiness checks in `MenuBarView`; only needed while SwiftUI is creating the settings window. Keep for reliable settings opening. |
| 500 ms | Existing profile-save batching in `ProfileManager`; UI updates immediately and termination calls `saveNow`. Keep to avoid repeated disk writes. |
| 300 ms | Continue an unfinished, finite remote-window discovery scan. Keep to avoid continuous AX/CPU churn. |
| 1 s | Accessibility-status polling in General settings, and sidebar permission checks only while permission is missing. Keep for permission recovery/status. |
| 1 s maximum | New foreground-request expiry. Activation starts immediately; expiration cancels stale intent, and the final raise checks the same deadline. A timer is created only if activation is still outstanding. |
| 50–200 ms maximum | AX request timeouts in discovery and normal window access; fast replies return immediately. Keep to bound unresponsive apps. |
| 75 ms maximum | Discovery work-slice budget, not a sleep. Keep to bound each scan. |
| 1.2 s maximum | Placement write-sequence budget, not a sleep. Keep to stop stalled/partial operations. |
| 3 s visible | Automatic feedback-message dismissal; input and actions remain usable throughout. Keep so messages are readable and do not linger. |

Clicks commit on mouse-up so right-click and right-drag remain exclusive; the six-point drag threshold is distance, not time. macOS's own Dock/minimise/restore animations are outside these app-controlled waits and were not changed.

Restoration and placement now mark the validated target as the app's main window where supported, perform a best-effort early raise, yield activation and request activation with all app windows brought forward. A temporary early raise failure such as `cannotComplete` no longer prevents activation; invalid elements and lost permission still reject it. This follows [Apple's cooperative activation guidance](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation).

The existing workspace activation notification, or an immediate frontmost check, triggers a second raise of the exact validated window after its app is actually foreground. Requests are claimed once, cancel with the existing action lifecycle, expire after one second, and recheck identity, permission and foreground state before raising. No app is launched/reopened, no arbitrary restore sleep is added, and ordinary window size is preserved. macOS can still refuse activation, and a normal window cannot override another app's higher-level always-on-top surface.

## Reference source

`clone/Rectangle/AccessibilityElement.swift` and its `LICENSE` are saved at commit `4003736040e0ba870b32b2f8a6855a7665f02515`. `clone/Rectangle/manifest.json` records immutable URLs, SHA-256 hashes and why each file was consulted.

Rectangle informed the size-position-size ordering and bounded Accessibility calls. Octopus's controller, geometry and writer are implemented locally; Rectangle's broader configuration, Enhanced UI workarounds and animation engine were not imported. The snapshots are outside Xcode's app source group and are not compiled or bundled.

## Verification evidence

The initial integrated run executed **43 tests: 43 passed, 0 failed, 0 skipped**, confirmed from Xcode's result bundle rather than only its exit status:

`/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_04-30-59-+0530.xcresult`

The near-side preview update subsequently rebuilt the app and ran **16 drag tests: 16 passed, 0 failed, 0 skipped**, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_04-37-59-+0530.xcresult`. Added cases cover preview/drop activation 120 points from all four sides, corner priority, leaving the snap zone, and free movement on compact displays. Its log is `/tmp/octopus-drag-near-side-tests.log`.

The configurable-distance and multi-window update ran **48 sidebar/drag tests: 48 passed, 0 failed, 0 skipped**, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_04-44-52-+0530.xcresult`. These include choosing the displayed window rather than the first window, rejecting missing/stale targets, distance-dependent activation, saved-value persistence and invalid-value normalization. Its log is `/tmp/octopus-drag-settings-tests.log`; the subsequent final app build also succeeded.

The mouse-shortcut update ran **60 tests: 60 passed, 0 failed, 0 skipped**, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_05-46-49-+0530.xcresult`. Added checks cover defaults, duplicate rejection, clear/reset persistence, reset conflicts, modifier combinations, extra buttons, right-click versus right-drag, press-time binding capture, recorder capture/Escape/left-release behaviour, inactive-app focus, minimise/restore and target changes or closure. Logs are `/tmp/octopus-mouse-shortcuts-tests.log` and `/tmp/octopus-mouse-shortcuts-build.log`; the final app build succeeded.

The immediate-interaction/foreground/reset-all update ran **63 tests: 63 passed, 0 failed, 0 skipped**, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_06-25-02-+0530.xcresult`. Added checks cover reset-all with swapped/disabled bindings, activation handoff order, rejection/cancellation and temporary versus invalid early-raise errors. Logs are `/tmp/octopus-immediate-focus-tests.log` and `/tmp/octopus-immediate-focus-build.log`; the final app build succeeded. Native covered-window restoration was not exercised because Mayank selected code and automated checks only.

The first synthetic right-mouse fixtures reported `buttonNumber == 0` despite their right-mouse type. Tests now construct correctly typed, CG-backed events with explicit buttons and AppKit screen-coordinate conversion, without posting events to the desktop. Snap tests use the current declared defaults/range instead of historical constants, while the 120-point geometry examples specify that distance explicitly.

Tests cover snap regions, work-area reservations, coordinate conversion, oversized windows, ordinary desktop metadata, unsupported/off-desktop windows, current-window icon targets, native press/drag/release behaviour, original callback capture, cancellation, fixed-size movement, minimum-size adjustment, invalid requests and partial write failures. The existing sidebar regression suite also passed.

An existing popup test expected a 36-point offset although unchanged `SidebarLayout.menuFrame` uses 18 points. Its assertion was corrected to the verified baseline; popup layout behaviour was preserved.

Final Debug build: **BUILD SUCCEEDED**. `git diff --check` passed. Build and test logs are `/tmp/octopus-drag-build.log` and `/tmp/octopus-drag-tests.log`.

Reproduce the focused checks from the repository root:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-drag-verification \
  -only-testing:octopusTests/SidebarTests -only-testing:octopusTests/SidebarDragTests \
  -only-testing:octopusTests/MouseShortcutTests test

xcodebuild -project octopus.xcodeproj -scheme octopus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-drag-verification build
```

## Limits and remaining live checks

- Native fullscreen windows, modal windows, attached sheets and other Spaces are excluded. The app never launches or reopens another app to manufacture a target window. No SIP changes or new system permissions were introduced.
- Fixed-size windows support free movement; snap areas explain that resizing is unavailable. Apps can impose minimum sizes or character-cell increments; adjusted/partial results produce quiet explanatory feedback.
- AX position and size are separate operations. A slow app can partially accept placement, and rollback is not promised. Other tiling managers may subsequently rearrange the window; Octopus does not fight them.
- Earlier Computer Use access was rejected with **“Computer Use was not approved to use octopus.”** For the later focus fix Mayank explicitly chose code and automated verification only. No alternate UI-control method was used to bypass the rejection or that preference.
- Still required: live dragging and final frame checks with Safari, Finder, Terminal and Chromium/Electron; right-button native drag completion/cancellation; live mouse recorder, clear/reset and conflict feedback; settings scrolling/appearance; multi-window app-icon and popup dragging; minimise/restore; repeated drags; rapid pointer reversals; popup action buttons and scrolling; Escape and excluded-area drops; closing the target mid-drag; permission loss; display/desktop changes; VoiceOver and mixed-display arrangements. These scenarios have not been claimed as passed.
