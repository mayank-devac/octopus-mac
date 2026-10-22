# Octopus project memory

## 2026-10-14 — Snap preview, behaviour modes and divider adjustment

These notes record Mayank's decisions and source inspection from this chat; recheck current code before using them as implementation facts.

### Product decisions

- **Legacy is the default**, with Current selectable in Preferences > Snap > Snap behaviour; the preference key is `windowSnapMode`.
- **Current mode** prepares the selected layout before release, requests each participating window's size at most once, keeps an accepted different size, and stops remaining placement without automatic reflow or rollback.
- If companions cannot fit or be verified during preparation, show a primary-only preview and snap the dragged window once; leave companions unchanged.
- Releasing before preparation is ready cancels the drop with a short message; do not apply an unseen recomputed layout.
- Current Undo restores only verified changed companions and keeps the dragged window snapped; retain identity, Desktop and achieved-frame checks.
- Show **app names**, not numbered companion labels, in Current previews.
- Preserve recent/all selection: recent mode selects one companion; all mode uses the configurable 2–8 window cap, default four, on the destination display/Desktop.
- Give a window extra preview space by reducing neighbouring areas before release, rather than automatically retrying after refusal; unknown app limits are not guaranteed predictions.
- For Current same-monitor left/right/top/bottom group previews, press **Option after preparation**, move the pointer relative to the existing divider, and release the mouse while holding Option to commit the last displayed frames.
- Releasing Option first restores normal dragging; Escape cancels without frame writes; corner shortcuts take priority.
- Divider movement freezes the selected participants and companion grouping, uses known size/readability limits, and performs geometry calculations only; no AX inventory scan or live window resize per pointer event.
- First-version divider adjustment excludes corners, icon pairing, Legacy, free movement, single-window fallback and cross-display layouts.

### Source navigation

- `octopus/UI/Sidebar/SidebarDragController.swift`: preparation lifecycle, app-name labels, Option detection, preview overlays, locked divider gesture and exact displayed-plan drop.
- `octopus/UI/WindowLayout/WindowLayoutModel.swift`: prepared snapshots and `WindowLayoutDividerGesture`; original window frames remain distinct from proposed target frames.
- `octopus/UI/WindowLayout/WindowLayoutPlanner.swift` and `WindowLayoutAllocator.swift`: pre-snap selection, single-window fallback, captured `edgeGroups`, divider allocation and limits.
- `octopus/UI/WindowLayout/WindowLayoutController.swift`: native preparation/commit, settings and topology cancellation, focus ordering and guarded companion Undo.
- `octopus/UI/WindowLayout/WindowControlAccess.swift` and `octopus/UI/Sidebar/SidebarWindowPlacement.swift`: native access and snap-only single-attempt writes; preserve unrelated placement policies.
- `octopus/UI/WindowLayout/WindowLayoutSettings.swift` and `octopus/UI/Preferences/PreferencesWindowLayoutView.swift`: Legacy/Current selection and gesture help.
- `octopusTests/WindowLayoutTests.swift` and `octopusTests/SidebarDragTests.swift`: geometry, stale-plan rejection, shortcut conflicts and native setter-count fixtures.

### Investigation and limitations

- Source inspection found repeated size requests in the placement writer and repeated reallocation in the legacy executor; Current bypasses the primary-placement/legacy-follow-up chain.
- Mayank reported the "size request remains unconfirmed" message on the **same monitor**; the affected app was not identified.
- The Current writer uses eight settle polls with 25 ms pauses plus read latency; this message can represent an unchanged size, unstable readings or a changed final read, and does not prove a permanent app minimum.
- Smarter bounded confirmation, optional resize-completion notifications, move-only fallback, context-bound accepted-size suggestions and explicit larger-area retries were discussed as options, not implemented in this chat.
- Reported minimums and previous accepted-size samples cannot establish universally exact first-time previews; one-attempt placement can still leave gaps, overlap or partial results.

### Verification status recorded on 2026-10-14

- The user ran the divider test command; the build failed in `WindowLayoutTests.swift` with five "Cannot use mutating member on immutable value: '$0' is immutable" diagnostics, so that test session did not run tests.
- The test fix moves `gesture.update(...)` outside `#expect` and asserts the returned Boolean; source/diff checks passed, but no successful rebuild or test rerun was confirmed afterward.
- Native Option-drag delivery, Escape cancellation and end-to-end window behaviour still need a real-app check; do not claim production readiness or a measured flicker-free result.
- Do not run builds, tests, linters or type checks unless Mayank explicitly asks; hand off the focused commands and preserve unrelated changes.

## 2026-10-23 — Existing-window presentation contract

- Clicking a sidebar/map window must reveal that exact existing window, restoring it if minimized and unhiding its app if needed; changing the menu-bar app name is not success. Never create a replacement window.
- Sidebar and map share `WindowPresentation.bringForward`; keep one canonical restore/activate/raise/verify sequence, independent of sidebar filtering.
- Mayank reproduced app activation without window presentation across apps on the current desktop, including Brave with ChatGPT still visible. The live bug remains unresolved until that exact case succeeds.
- Verify the actual running executable before attributing results: on 2026-10-23 it was `.build/DerivedData/Build/Products/Debug/octopus.app`, whereas prior automated verification used `/tmp/octopus-mission-control-verification`. Different paths alone do not establish a stale build.
