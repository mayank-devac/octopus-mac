# octopus Mistakes and Prevention

## 2026-10-08 — Automatic snap adjustment

- **Scope mistake:** The first design grew into a general layout/tree system before the existing-drag follow-up behaviour was settled. Mayank explicitly narrowed it to Octopus snaps, then requested a recent/all affected-window dropdown. Follow the latest decisions, not the superseded three-trigger proposal.
- **Performance mistake:** Most-recent adjustment initially reread the whole app/Space inventory, repeated AX metadata checks and added a fixed 150 ms delay. The revised path scopes visible candidates and reads selected metadata; a 100-candidate test verifies one companion metadata callback, not one total AX call or measured latency.
- **Resize/focus mistake:** Companions reused duplicate size writes and could reassert too early on repeated old frames. Placement also retained AXMain/AXRaise before exact-window focus, despite the prior focus incident. Same-display companion policy and placement focus ordering were corrected; final visual effectiveness remains unverified.
- **Verification mistake:** Two app builds, stale accessibility IDs and conflicting monitor focus made live checks difficult to attribute. A green test run cannot dismiss reported delay/flicker. Mayank requested stopping UI clicks; do not resume them without a new request.
- **Prevention:** Preserve the already-snapped anchor on companion failure, validate exact identity/display/Space, keep live frame readback, obtain scope approval for shared helpers, and verify the whole real interaction before claiming smoothness. Final focused checks passed 48 tests / 51 executions; no final flicker-free claim was made.
- **Full story, prompts, failed attempts, evidence and remaining limits:** [Automatic snap process](auto-snap-process.md).

### Additional lessons from the strict review at `17a248e`

The [source-verified review](auto-snap-review.md) found outstanding issues; these are not marked fixed by the successful test run.

- **Bulk AX contract:** A successful bulk call can contain optional CFNull or per-attribute errors. The faster path does not yet handle every permitted representation. Test the actual provider boundary, preserve genuine optional absence and keep transient failure distinct from it.
- **Recovery ownership:** A stable post-write frame is not proof that Octopus caused it. Recovery can overwrite an external update when the token remains valid. Test that counterexample without flipping cancellation, and decline ambiguous automatic rollback.
- **Whole-request budget:** The four-second executor budget starts after snapshot preparation. Bound and cancel handle-resolution/metadata loops too; per-call timeouts alone do not bound a queued operation.
- **Normal-window admission:** A layer-zero CG surface is not automatically a normal AX window. Separate verified non-normal surfaces from failed/unknown reads so an auxiliary surface does not invalidate otherwise eligible companions.
- **Mutation safety:** Cheap identity/display/Space checks do not replace live modal/sheet/minimised eligibility checks when another write attempt occurs. Recheck only the necessary safety state rather than reinstating full inventory scans.
- **Lost lifecycle work:** A Boolean “refresh queued” gate can discard a launch/termination event. Coalesce a follow-up reconciliation and preserve the event's app identity when updating recency.
- **Structural debt:** The inventory grew from 1,410 to 1,669 lines; it was already above 1k. Establish a focused native-access boundary rather than adding more feature modes and near-duplicate validators. Showing feedback should not require an unused inventory/full drag controller.
- **Review honesty:** The independent critic's stale-Undo claim was rejected because `undoAdjustment` already calls `cancel`, which clears Undo before validation. Verify call chains before recording or fixing an alleged bug; strict reviews must not manufacture findings.
- **Baseline/UI discipline:** The original full real-window baseline gate was not completed, and monitor-focus interference prevented a clean final visual verdict. Do not silently replace live gates with fixture counts or resume stopped UI automation through another technology.

## 2026-10-07 — Cross-Desktop focus and minimise

- **Mistake:** Adding a targeted private focus request left an earlier `AXMain`/`AXRaise` in the production focus path; unit-test success was previously treated as stronger evidence than it was. The icon and popup minimise decisions also ignored whether the target window was on a visible Desktop.
- **Fix:** Request the exact window before the follow-up raise; focus remote targets before minimising; recheck live visibility in the action executor; make popup labels describe focus versus restore/minimise.
- **Prevention:** Trace the complete click sequence, confirm the running build's checkout, and verify icon and popup behaviour in the real app. Never use a successful build/private-API return as proof of a flicker-free Space transition. Respect repository-only checks and no `osascript`/standalone probes; each responsible process needs its own relevant permissions.
- **Evidence:** Final result bundle reports 67 passed / 0 failed / 0 skipped, and Mayank confirmed both paths work without flicker on the launched final build. [Full incident, history, evidence and remaining limits](cross-desktop-focus.md).

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
