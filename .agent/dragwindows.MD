# Sidebar window dragging

Implemented on 2026-10-07. The latest app build succeeded and all 48 sidebar/drag tests passed, including configurable snap distance and multi-window icon dragging. Live cross-app pointer verification remains blocked by Computer Use approval, so production interaction readiness is not yet verified.

## What changed

- Dragging an app's sidebar icon moves the current window whose title is displayed under that icon, including apps with several windows. The hover popup remains available for clicking or dragging a different window's title row. Missing/stale current-window identities are rejected rather than replaced; the minimise/restore button remains independent.
- Clicking now commits on mouse-up. Moving more than six points starts dragging and suppresses the click. The original window ID and title are captured in the mouse-down callback, even if the inventory changes before dragging starts.
- The drag shows a translucent outline and window title. The real window changes only after a valid drop. Hover menus, magnification updates and auto-hide pause during dragging.
- Left/right sides select halves, the bottom side selects bottom-half, the top side maximises within the desktop, and corners select quarters. **Preferences → Sidebar → Snap distance** allows 24–300 points in 12-point steps, defaulting to 120. The chosen distance is saved and captured at the start of each drag so preview and drop agree. Zones remain capped at one-quarter of the display dimension on small displays; corners take precedence. Returning towards the centre clears snapping and resumes free movement.
- Free movement preserves size, uses the pointer as the window's top-centre, and keeps its title bar reachable. Placement respects the Dock and menu bar, negative monitor origins and AppKit/Accessibility coordinate differences.
- VoiceOver exposes named placement actions on eligible icons and popup titles; those actions use the same validated placement path.
- Escape, dropping over the sidebar/popup, desktop/display changes, permission loss or a disappearing target cancel without selecting a replacement window. Temporary preview and drop windows close when the interaction finishes.

## How it connects

- `SidebarView.swift` supplies native click/drag regions, also used by `CyclePanelView.swift` for popup titles. Both freeze the window identity before the drag threshold is crossed.
- `SidebarDragController.swift` owns the native drag session, preview, temporary drop surfaces and quiet feedback. Its custom pasteboard data contains only a random session token. A drop must come from this controller and match the token; foreign drops and Escape never commit placement. The outline ignores mouse events, while transparent drop surfaces exist only during dragging.
- `SidebarWindowPlacement.swift` holds pure snap/coordinate geometry, eligibility rules and a testable placement writer. No external app or package was added.
- `SidebarSettings.swift` registers and validates the snap-distance preference, including safe defaults for missing or non-finite values. `PreferencesSidebarView.swift` adds one accessible slider using the existing settings layout.
- `SidebarWindowInventory.swift` handles preparation and the `.place` action on its existing serial AX queue. It revalidates live identity, permissions, ordinary desktop membership, writable position/size, fullscreen/modal status and attached sheets before mutation.
- `SidebarSpaces.swift` reads the currently visible ordinary Space IDs through the existing dynamically loaded private API. Unknown desktop membership disables placement rather than guessing, including for hidden/minimised windows.
- Hidden/minimised windows restore only after validation. Placement uses size-position-size when resizing is supported, reads the resulting frame, and corrects an off-display position where possible. AX calls have a 0.2-second timeout; the write sequence has a 1.2-second deadline. No continuous AX calls or unbounded retries run during pointer movement.
- `AXUIElement.swift` now checks CF value types before decoding position and size, preventing malformed responses from being interpreted as AXValue objects.

## Reference source

`clone/Rectangle/AccessibilityElement.swift` and its `LICENSE` are saved at commit `4003736040e0ba870b32b2f8a6855a7665f02515`. `clone/Rectangle/manifest.json` records immutable URLs, SHA-256 hashes and why each file was consulted.

Rectangle informed the size-position-size ordering and bounded Accessibility calls. Octopus's controller, geometry and writer are implemented locally; Rectangle's broader configuration, Enhanced UI workarounds and animation engine were not imported. The snapshots are outside Xcode's app source group and are not compiled or bundled.

## Verification evidence

The initial integrated run executed **43 tests: 43 passed, 0 failed, 0 skipped**, confirmed from Xcode's result bundle rather than only its exit status:

`/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_04-30-59-+0530.xcresult`

The near-side preview update subsequently rebuilt the app and ran **16 drag tests: 16 passed, 0 failed, 0 skipped**, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_04-37-59-+0530.xcresult`. Added cases cover preview/drop activation 120 points from all four sides, corner priority, leaving the snap zone, and free movement on compact displays. Its log is `/tmp/octopus-drag-near-side-tests.log`.

The configurable-distance and multi-window update ran **48 sidebar/drag tests: 48 passed, 0 failed, 0 skipped**, confirmed from `/tmp/octopus-drag-verification/Logs/Test/Test-octopus-2026.10.07_04-44-52-+0530.xcresult`. These include choosing the displayed window rather than the first window, rejecting missing/stale targets, distance-dependent activation, saved-value persistence and invalid-value normalization. Its log is `/tmp/octopus-drag-settings-tests.log`; the subsequent final app build also succeeded.

Tests cover snap regions, work-area reservations, coordinate conversion, oversized windows, ordinary desktop metadata, unsupported/off-desktop windows, current-window icon targets, native press/drag/release behaviour, original callback capture, cancellation, fixed-size movement, minimum-size adjustment, invalid requests and partial write failures. The existing sidebar regression suite also passed.

An existing popup test expected a 36-point offset although unchanged `SidebarLayout.menuFrame` uses 18 points. Its assertion was corrected to the verified baseline; popup layout behaviour was preserved.

Final Debug build: **BUILD SUCCEEDED**. `git diff --check` passed. Build and test logs are `/tmp/octopus-drag-build.log` and `/tmp/octopus-drag-tests.log`.

Reproduce the focused checks from the repository root:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-drag-verification \
  -only-testing:octopusTests/SidebarTests -only-testing:octopusTests/SidebarDragTests test

xcodebuild -project octopus.xcodeproj -scheme octopus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-drag-verification build
```

## Limits and remaining live checks

- Native fullscreen windows, modal windows, attached sheets and other Spaces are excluded. The app never launches or reopens another app to manufacture a target window. No SIP changes or new system permissions were introduced.
- Fixed-size windows support free movement; snap areas explain that resizing is unavailable. Apps can impose minimum sizes or character-cell increments; adjusted/partial results produce quiet explanatory feedback.
- AX position and size are separate operations. A slow app can partially accept placement, and rollback is not promised. Other tiling managers may subsequently rearrange the window; Octopus does not fight them.
- Computer Use rejected access to the built app with **“Computer Use was not approved to use octopus.”** An approval request was issued, but live UI checks could not proceed. No alternate UI-control method was used to bypass that rejection.
- Still required: live dragging and final frame checks with Safari, Finder, Terminal and Chromium/Electron; multi-window app-icon and popup dragging; the settings slider's live appearance and behaviour; minimise/restore; repeated drags; rapid pointer reversals; popup action buttons and scrolling; Escape and excluded-area drops; closing the target mid-drag; permission loss; display/desktop changes; VoiceOver and mixed-display arrangements. These scenarios have not been claimed as passed.
