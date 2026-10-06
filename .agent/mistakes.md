# octopus Mistakes and Prevention

## 2026-10-05 — Sidebar and window-menu UI

### Changed too many interaction details together

- **Mistake:** Magnification size, label movement, row height, menu hover tracking, and panel sizing were changed across the same iteration. This made the sidebar unnaturally tall and made regressions harder to trace.
- **Prevention:** Change one visible interaction at a time. Preserve the last accepted layout values, then build and visually check before changing another dimension.

### Used compilation as proof of pointer behaviour

- **Mistake:** Successful builds and geometry tests were treated as strong evidence for hover behaviour, while repeated cursor movement still failed in the running app.
- **Prevention:** Pointer changes require a real interaction check: move back and forth repeatedly, reverse direction, cross between the icon and menu, scroll, and test both one-window and multi-window apps. Compilation only proves the code builds.

### Stacked fixes before confirming the root cause

- **Mistake:** Several hover and magnification workarounds were added after earlier fixes failed, which increased complexity and changed the design.
- **Prevention:** When a fix fails twice, stop adding patches. Return to the last accepted behaviour, isolate one event path, and verify the exact failure before editing again.

### Nearly accepted a test run that executed zero tests

- **Mistake:** The first focused `xcodebuild` filter completed without failures, but its result contained zero executed tests because the Swift Testing identifier did not match.
- **Prevention:** Confirm the named test appears in the output or inspect the result bundle's test count before reporting a test as passed.

### Broke the build while adding the spacing slider

- **Mistake:** The controller referenced `SidebarSettings.appSpacing` even though the property belonged to `SidebarLayout`, and `verticalPadding` was removed while still being used.
- **Prevention:** Before removing or moving a symbol, search all references. After the final edit, run the build and fix compiler errors before reporting completion.

### Reported completion before final verification

- **Mistake:** Some edits were described as complete while their latest version had not been built or checked in the running app.
- **Prevention:** State exactly what was verified. Do not call an interaction complete until the final code builds and the real behaviour is exercised; if UI access is unavailable, mark visual behaviour as unverified.

## 2026-10-06 — Sidebar minimise/restore and hover regressions

### Used visibleRect as if it were the row's own bounds

- **Mistake:** Hover detection used an anchor view's `visibleRect` directly. With modern AppKit's unclipped views, that rectangle extended over neighbouring rows: moving over row 2 highlighted row 1, including row 1's minimise button, while clicking row 2 still worked.
- **Prevention:** Hit-test `view.bounds.intersection(view.visibleRect)`, then convert to screen coordinates. Use the full row bounds to locate its action column. Keep one pointer-position path for both row selection and button feedback.
- **Evidence:** `CyclePanelController.sidebarPointerTarget` and `SidebarTests.nativeMenuGeometryDrivesRowAndButtonHoverWithoutCompetingCallbacks` reproduce the screen-coordinate path; the test failed with row 2 resolving to row 1 before bounding the rectangles and passed afterwards.

### Tested row callbacks instead of deciding which row the pointer hits

- **Mistake:** Earlier native tests called a chosen row's `mouseMoved` handler directly. They proved that handler could select its row, but bypassed the overlapping hit areas that caused the real bug. I also tried several event-path changes before reproducing that precise failure, repeating the earlier lesson above.
- **Prevention:** Feed actual native-view screen coordinates through the production hit resolver, including titles, action buttons, footer, and points outside the popup; replay stale row events to confirm they cannot overwrite the current pointer target. Passing fixture tests still does not establish live cross-app behaviour.

### Removed live windows during inconsistent minimise/restore snapshots

- **Mistake:** Core Graphics visibility and AXMinimized were treated as one consistent snapshot. During Dock animations they can briefly disagree, removing and re-adding an app and changing the sidebar's size; failed AX reads were also mistaken for empty window lists.
- **Prevention:** Preserve a previously verified window while AX still enumerates the same live identity. Preserve the last verified app entry on a failed read, but honour a successful empty list. Clear fallback data on desktop changes, stop, or permission loss, remove terminated apps, and revalidate every action.

### Added noisy feedback for every rejected sidebar action

- **Mistake:** Generic `NSSound.beep()` calls were added for missing focused-window selection, rejected actions, and failed activation. This produces the Mac alert sound without explaining whether the request was stale, unsupported, or actually failed.
- **Prevention:** Choose explicit feedback behaviour rather than sounding an alert for every guard failure; keep safe rejection and inventory refresh independent of audible feedback.
- **Applied behaviour:** Mayank requested quiet sidebar failures: missing focus, rejected actions, and unsuccessful activation refresh the inventory without an alert sound; live-target safety checks remain in place.
