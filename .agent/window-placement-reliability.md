# Window placement, click focus, and display-name work

Dates: 2026-10-07 and 2026-10-08.

This records what was asked, what was read, what was changed, what was tried and
failed, and what is still unverified. Provenance is kept explicit: **tests passing is
not live proof**. No change below was observed by the assistant on a real multi-display
setup; the owner tested builds and reported results, quoted where relevant.

## Summary table

| # | Request | Outcome | Live status |
| --- | --- | --- | --- |
| 1 | Clicking a covered (behind the front app) icon should bring it forward, not minimise | Fixed in `SidebarIconMousePolicy` | Not yet confirmed live |
| 2 | Hide the display name when there is one display | Fixed in `SidebarMonitor.title` | Not yet confirmed live |
| 3 | Snap right half lands on left half, warning "This app limited the window size or position." | Three successive hypotheses; third (re-assert + enhanced UI) is current | **Unconfirmed**; first two did not fix it |
| 4 | Half-size window dragged to another display does not reach full size | Addressed by the same writer rework | **Unconfirmed** |

## 1. Click focus: never minimise a covered app

**Report:** with a maximised app hidden behind the front app, clicking its sidebar icon
minimised instead of focusing.

**Cause (from source):** `SidebarIconMousePolicy.action(.minimize)` returned
`.minimize(id, requireFocused: false)` for any window that was not hidden, minimised or
off-Desktop. CoreGraphics reports a window that is merely covered as *on screen*, so a
covered window was treated as "visible and safe to minimise".

**Change (`SidebarWindowPlacement.swift`):** the mapped minimise shortcut minimises only
when the target is the focused window of the frontmost app
(`frontmostPID == entry.pid && entry.focusedID == id`), and then with
`requireFocused: true` so the executor rechecks focus at run time. Everything else
returns `.focus(id)`. The popup's per-window minimise button is deliberately unchanged:
it is an explicit per-window control.

**Tests:** two `MouseShortcutTests` that had pinned the old (wrong) behaviour were
updated rather than preserved. Result: `** TEST SUCCEEDED **`
(`.build/click-focus-verification.log`). The log was not inspected for an exact test
count at the time.

## 2. Single-display heading

The monitor heading is also the drop target that opens the desktop-transfer popup, so
removing the heading would remove the only way to transfer a window between Desktops on
one display. `SidebarMonitor` gained `isOnlyDisplay`; with one screen the title is
`Desktops` (no number, no name). With several displays titles are unchanged
(`1 · Name`). The Preferences pickers still list display names (they are choices, not
labels). Test `displayNamesAppearOnlyWhenSeveralDisplaysAreConnected` added; the old
single-display expectation was updated. Log: `.build/display-name-verification.log`.
`Desktops` is a label I chose; change it if you prefer another.

## 3 and 4. Snap lands on the wrong side / does not reach full size

### What the owner reported, in order

1. Dragging an app to another Desktop "does not get applied"; right/left snaps land on
   the opposite side with the "limited" warning.
2. Clarified through questions: the gesture is a **drop on a screen edge zone** (not the
   sidebar sections), the message is the warning, and it affects only that window.
3. After my first fix: "snaps to the left half of its current desktop, then moves to the
   second desktop and snaps in the right half, plus the warning", when the app is
   full-screen-sized and has to change dimensions.
4. After my second fix: (a) a half-size window on display 1 dragged to display 2 did not
   reach full dimensions; (b) the right half became the **left half of the second
   display** (the display the preview highlighted).

### The unchanged part: geometry is correct

Reading `snap(at:screen:)`, `frame(for:in:)`, `flip` and the drop path showed the
preview and the requested frame agree and are correct for left/right/top/corners, and
`NSScreen.screens.first` is the menu-bar display so the y-flip is right for every
display. So the preview was right and the *write to the other app* was where it went
wrong. This is why a static read of the coordinate maths found nothing.

### Attempt 1: poll before correcting (partially wrong)

*Hypothesis:* the writer wrote size, position, size, then read the frame once. Apps
apply AX writes asynchronously, so the read could show the old width at the new
position. That looks out of bounds, and the "keep reachable" correction then moved the
window left.

*Change:* poll the frame until it matched, or stopped changing, before correcting.

*What went wrong:*
- My first version accepted "two identical consecutive reads" as settled. A regression
  test showed that stale, out-of-bounds reads can repeat, so that early exit was wrong.
  It now only trusts a stable frame when it is in bounds.
- A fake `Result<_, SidebarPlacementResult>` did not compile (the type is not an
  `Error`). Replaced with the existing `SidebarPlacementResult`.
- The deeper flaw: polling only **waited**. If the app had dropped the last size write,
  waiting could not recover it, and the code still moved the window to compensate. The
  owner confirmed the problem remained.
- It also did not explain "left half on its current desktop, then jumps".

### Attempt 2: land on the target display first (incomplete, partly contradicted)

*Hypothesis (after the owner's second report):* "second desktop" meant the **second
display**. Resizing first shrinks the window to half width on the source display (seen
as a left half there), then the position write jumps it across.

*Change:* if the window's centre is outside the target display's work area, write its
position to the work area's origin first, then run size-position-size.

*Problems:*
- It rested on an interpretation of the owner's words; it was never confirmed.
- I wrote it before reading Rectangle. Rectangle documents the opposite default
  (size, position, size) for cross-display moves. The pre-move is a superset of that
  sequence rather than a replacement, but I had not checked this at the time.
- It did not wait for the move to register, nor re-assert dropped writes. The owner
  then reported bugs 4a and 4b.

### Reference reading (what was done and what was learned)

Prompted by the owner, specific files were fetched and read. Files already vendored
under `clone/Rectangle/` (see its `manifest.json`, which pins the commit) and files read
transiently under `/tmp/refs` (not committed):

| Source | File | Used for |
| --- | --- | --- |
| Rectangle (vendored) | `AccessibilityElement.swift` | `setFrame`, enhanced-UI policy |
| Rectangle | `WindowManager.swift` | execute flow, `moveWindow`, mover chain, `isMovedAcrossDisplays` |
| Rectangle | `WindowMover/StandardWindowMover.swift` | calls `setFrame` |
| Rectangle | `WindowMover/BestEffortWindowMover.swift` | post-hoc constrain-to-screen after the move |
| Rectangle | `ScreenDetection.swift` | which display a frame belongs to; `screenFlipped` |
| AeroSpace | `MacWindow.swift` | `setAxFrame` entry point (inner AX implementation was not fetched) |
| AltTab | `AXUIElement.swift` | **fetch failed** (path not found); nothing was learned from it |
| GitHub code search | n/a | unauthenticated API returned 401; not used |

Knowledge gained from Rectangle:

1. **Why size, position, size:** its comment: *"To handle moving to different displays,
   we have to adjust the size then the position, then the size again since macOS will
   enforce sizes that fit on the current display."* A size written while the window is
   still on the old display is clamped to that display, so the second size write after
   the move is what achieves the final size. If that write is dropped, the window keeps
   the old size.
2. **AXEnhancedUserInterface:** `performWindowAdjustment` / `beginWindowAdjustment`
   read the app's `AXEnhancedUserInterface`, switch it off for the adjustment, and
   restore it afterwards (per policy). With it on, apps animate AX writes, so
   consecutive writes overlap and can be lost.
3. **Best-effort fix-up comes last:** `BestEffortWindowMover` constrains a window to the
   screen only *after* `setFrame`, as a final step. It does not use a stale intermediate
   read to decide where the window should be.
4. **Cross-display bookkeeping:** Rectangle compares source and destination screens
   (`isMovedAcrossDisplays`) and brings the window to front afterwards.

### Attempt 3 (current): confirm each stage, re-assert, suspend enhanced UI

Implemented in `SidebarPlacementWriter.apply` (`SidebarWindowPlacement.swift`) and
`SidebarWindowInventory.swift`.

1. **Opening read.** If the window's centre is not inside the target work area, write
   the position at the work area origin and poll until the window is reported on the
   target display. Size writes then happen on the display the window ends on.
2. **Normal sequence:** size, position, size. If the app rejects the size write
   outright (AX error), size writes stop, to avoid pointless retries.
3. **Confirm by polling** until the frame matches the request, or stops changing while
   still on screen. A frame that is out of bounds keeps being re-read, because it may
   be the old size at the new position. Maximum 8 polls of 25 ms per stage.
4. **Re-assert dropped writes** (up to two more attempts): if the size or origin has not
   been applied, write the missing part again. This addresses the macOS display-fit
   clamp and dropped late writes.
5. **Only then** apply the "keep reachable" correction, and only if the frame is still
   out of bounds. Windows with a real app minimum size are still reported with the
   warning and kept on screen.
6. **Executor:** placement runs inside `withoutEnhancedUserInterface(pid:)`. The flag is
   turned off if it was on and restored afterwards. The time budget for placement was
   raised from 1.2 s to 2 s so the confirmation passes fit; it is still bounded.

Fixed-size windows (no resize) skip the display landing step and the size writes.

### Tests (all in `SidebarDragTests.swift`)

- `placementUsesSizePositionSizeAndReadsTheActualResult` (updated: expects the opening
  read first).
- `aWindowOnAnotherDisplayLandsOnTheTargetDisplayBeforeBeingResized`
- `slowResizeIsNotMistakenForAnOutOfBoundsWindowAndMovedToTheOppositeSide`
- `droppedSizeWritesAreReassertedInsteadOfShiftingTheWindowToTheLeft` (bug 4b)
- `aSmallWindowCanGrowToTheFullSizeOfALargerTargetDisplay` (bug 4a; the fake clamps a
  size to 600 while the window is off the target display)
- `appMinimumSizeIsReportedAndTheResultIsKeptReachable` (passes `wait: {}` to avoid
  real sleeping)

The writer takes an injectable `wait` closure so these tests do not sleep. Last run:
`** TEST SUCCEEDED **` for `SidebarDesktopTransferTests`, `MouseShortcutTests`,
`SidebarTests` and `SidebarDragTests`
(`.build/placement-reassert-verification.log`). Intermediate logs:
`placement-settle-verification.log`, `placement-display-verification.log`.

### Honest limits

- The fake apps in the tests encode my model of how apps misbehave (late, dropped or
  display-clamped writes). They prove the writer handles that model, not that every real
  app behaves that way.
- No live reproduction was possible from the assistant's side. The Rectangle comment is
  strong evidence for the clamp, but the exact app the owner is testing was never
  identified.
- "Second desktop" was interpreted as the second **display**. If the owner meant another
  **Space**, the cause is different. Placement is rejected when the window is not on a
  visible Desktop, and a native full-screen window (its own Space) should be rejected
  too. That case was not changed.
- The first-drop-on-another-Space scenario from the very first report was not resolved:
  the reported symptom turned out to be the edge-zone snap, so desktop transfer
  (`SidebarSpaceTransfer.m`, SkyLight) was read but not changed.
- `AXEnhancedUserInterface` is restored even for apps that had it on deliberately, as
  Rectangle does by default. VoiceOver/Switch Control users are the case Rectangle treats
  specially; this implementation does not special-case them.
- Worst-case placement time for an unresponsive or min-size-limited app is a few hundred
  milliseconds longer than before (bounded by the 2 s deadline).

## Process lessons

1. Do not stack hypotheses without evidence. Attempts 1 and 2 were each plausible and
   each failed; attempt 3 followed reading how a mature app solves the same problem.
   (This repeats the `.agent/mistakes.md` rule: when a fix fails twice, stop and
   re-ground.)
2. Read the reference implementation **before** designing the write order, not after.
3. "Desktop" is ambiguous in this app (Space vs display). Ask which one before changing
   cross-display behaviour.
4. A single immediate AX read after a write is not an authority; confirm, and re-write
   what was not applied, before deciding the app limited the frame.
5. Do not use a stale intermediate frame to decide where a window "should" go.
6. Update tests that pin wrong behaviour instead of preserving them; add a regression for
   each failure mode, using a fake that reproduces the specific misbehaviour.
7. Always report only exercised verification: test results are not live behaviour.

## How to re-run

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -disableAutomaticPackageResolution \
  -only-testing:octopusTests/SidebarDesktopTransferTests \
  -only-testing:octopusTests/MouseShortcutTests \
  -only-testing:octopusTests/SidebarTests \
  -only-testing:octopusTests/SidebarDragTests test
```

Obtain the owner's approval before building or testing in a new task (per
`cross-desktop-focus.md`).

## What to check live

1. Half-size window on display 1, dropped on the top edge of display 2: expect the full
   work area of display 2, no warning.
2. Dropped on the right edge of display 2: expect the right half of display 2, no
   warning, no visible left-half flash.
3. Repeat with an app that is known to enable `AXEnhancedUserInterface` and with an app
   that has a large minimum width.
4. If any case fails: record the app, both displays' sizes and arrangement, and whether
   the window ends on the right display; the next step is logging the size and position
   each AX write actually produced.
