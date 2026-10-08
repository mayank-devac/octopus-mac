# Plan 004: Pair visible windows by dragging one app icon onto another

**Status:** implemented in source; diff reviewed. Build, focused tests and live acceptance remain unverified. Mayank requested commands only.
**Planned at:** `6a7f026`, 9 October 2026, plus current working-tree changes.
**Effort:** M–L. **Risk:** medium for hit testing, high for native two-window writes.

The worktree already contains uncommitted changes to mouse shortcuts, PreferencesShortcutsView, SidebarController, SidebarSettings and existing tests; another task also added `SidebarPositionScrollCapture.swift` during planning. Preserve those changes and reread affected files before implementation; the commit alone is not the complete baseline.

## Recent implementation

- Added a measured icon border, stable four-side selection and two window outlines. Hover only reads metadata; it never moves real windows.
- Kept the same authenticated drag session. Visible icon pairing is resolved before Desktop-transfer sections; inactive-Desktop rows keep their existing route. A target that closes during a drag stays blocked, including on subsequent pointer updates.
- Added an explicit two-window plan/service using the existing layout controller and reader queue. Both selected windows are checked before writing; only B then A are moved. The automatic all-window setting does not select additional windows.
- Moved native layout access into `WindowControlAccess`, preserving the reader's handle generations, fullscreen exclusions and existing frame writer. Reads distinguish optional absence from provider failures and use a whole-operation deadline. Destination visibility is checked again before each setter.
- Added pair Undo for both original visible scopes, separate from ordinary companion-only Undo. Changed windows or inactive original Desktops decline restoration. Partial failures report possible movement without guessing that it is safe to undo someone else's change.
- Added comments above routing, geometry, native access, focus and Undo decisions, plus focused coverage for directions, rejected-drop routing, minimum sizes, cancellation, partial failure, Undo and AX response decoding.
- Reviewed the actual source/diff; no build, test, type check or GUI automation was run for this implementation. Existing mouse/scroll settings were preserved.

Remaining limits: native writes to two apps are not atomic, so a late app rejection can leave one window moved. Real multi-display smoothness, timing and small-icon usability require the live acceptance checks below.

## Product outcome and confirmed choice

Use the same configured app-icon drag that already supports window placement and Desktop transfer. Drag icon A onto visible icon B to arrange their two existing windows on B's visible display and native Desktop.

Mayank confirmed: **choose left/right or top/bottom from the drop position**.

| Position inside B's icon | Dragged A | Target B |
| --- | --- | --- |
| Left side | Left half | Right half |
| Right side | Right half | Left half |
| Top side | Top half | Bottom half |
| Bottom side | Bottom half | Top half |

The operation pairs windows into a layout; it does not embed one running application inside another, merge documents or close a window.

Recommended boundaries for the first implementation:

- Both source and target windows must be ordinary, non-hidden, non-minimised windows on currently visible native Desktops.
- They may be on the same display or different visible displays; B's display/Desktop is the destination.
- Move only the two explicitly chosen windows. An existing **All other normal windows** setting must not cause an icon-pair drop to rearrange a third window.
- App icons represent the exact window whose title is shown below them. Capture both window identities; do not silently switch to another window from either app.
- Support app-icon drags first. Popup title-row drags retain their existing placement behaviour.
- The gesture is explicit, so the recommendation is to allow it independently of the automatic companion-adjustment toggle. This is a proposed UX detail, not a separately confirmed user decision.
- Keep display-edge corner behaviour as free movement. Icon-side selection has four directions and never requests quarters.

## User experience

1. Start the normal configured drag on A. Retain the current press-time window capture, drag threshold, original mouse-down event and click suppression.
2. When A reaches an eligible B icon, outline **B's icon**, not its whole Desktop section. Only one icon has the pair outline at a time.
3. Highlight the selected border segment and show a short label such as `A left · B right`, plus two non-interactive outlines on B's destination work area.
4. Moving within the icon changes the direction; leaving clears the pair border/preview. Hover must never move a real window.
5. On a valid native drop, revalidate both identities/scopes and size constraints, remove drag overlays, then arrange the two windows.
6. Focus A once after successful placement. Do not activate B, raise all windows belonging to either app, or switch to an inactive Desktop.
7. Escape, foreign drops, centre-without-direction, self-drop or an invalid target produce no pair mutation. An attempted pair that cannot fit explains the reason without a generic beep.

### Direction selection on a small icon

Use four sides of the actual icon rectangle, not four quarters of the row:

- Normalise pointer offsets from the icon centre by the icon's half-width/half-height.
- The dominant axis chooses horizontal or vertical; its sign chooses left/right or top/bottom.
- Keep the previous side within a small diagonal tie band to avoid flickering between choices.
- A small centre zone retains an already selected direction on the same target. If the first observation is in the centre and no side has been selected, remain unarmed and ask the user to move toward a side.
- A diagonal selects one half-direction, never a corner/quarter layout.
- Initial proposed centre/tie bands are 25% and 10% of the normalised icon radius; validate with the actual rendered icon size before shipping. These are design starting points, not measured constants.

The existing drag ghost can cover much of a small icon. Keep the border visible outside the icon and offset/dim the ghost only during pair hover if necessary; do not change the accepted Desktop-transfer ghost styling globally.

## Preventing conflict with Desktop transfer

Current source: `SidebarDragController.update(at:)` asks `desktopDropTarget` and handles sidebar/section drops before the screen-placement branch. `drop(at:)` also commits Desktop transfer first. Desktop section rectangles include app rows, so an app icon is not currently a distinct destination type.

Introduce one resolver used by **both preview and drop**, rather than adding another independent gesture recogniser:

```text
eligible visible icon + chosen direction -> pair(source, target, direction)
visible pair icon, but self/centre/invalid -> blocked; never reinterpret as transfer
Desktop popup row or monitor/section target -> existing Desktop transfer policy
inactive-Desktop icon/section -> existing transfer handling, never pair highlighting
outside sidebar on a usable display -> existing edge snap/free placement
excluded popup/footer/invalid surface -> no operation
```

Important details:

- Pair hit testing must happen before calling `desktopDropTarget`, because that callback can open the Desktop popup as a side effect.
- A source on an inactive Desktop remains eligible for the **existing transfer** behaviour where its policy allows it; it does not gain pair eligibility.
- Do not let a visible icon-pair rejection fall through to a broad section transfer rectangle. Wrong intent must fail safely.
- Existing transfer restrictions remain: ordinary different Desktop IDs on the same monitor; monitor popup behaviour, clipping and source-token validation stay intact.
- Pair targets across visible displays must be collected by the parent `SidebarController`, which already owns the per-display controllers. The origin display controller alone cannot see every destination icon.
- Do not install a new native drop receiver on every icon. Keep the existing authenticated drag/drop surfaces and classify their pointer destination.

## Current architecture facts

| Existing code | Relevant fact |
| --- | --- |
| `SidebarDragController.swift`: `begin`, `accepts`, `update`, `drop`, `finish` | One native session, captured source ID, session nonce, preview/drop surfaces, and finish/cancellation cleanup. |
| `SidebarController.swift`: display registry and `desktopDropTarget` | Parent owns display controllers; each child owns its own inventory, anchors and transfer resolver. |
| `SidebarView.swift`: `SidebarViewState`, app-row overlay | Existing anchor belongs to a whole row; pairing needs a separately measured icon rectangle and visual pair state. |
| `SidebarDesktopTransfer.swift`: `visibleFrame`, `resolve`, `allows` | Established clipped native-view bounds and exact transfer eligibility. Reuse the clipping approach. |
| `WindowLayoutModel.swift` / `WindowLayoutExecutor.swift` | Existing automatic adjustment treats the anchor as unchanged and writes companions in one scope; it cannot be used unchanged for a pair that moves both windows across scopes. |
| `WindowLayoutController.swift` | Existing app-owned coordinator should own pair scheduling/cancellation too; do not create another global observer/coordinator. |

Keep current SwiftUI/AppKit patterns, value-type plans/results, off-main AX work, main-thread view state, and focused Swift Testing tests.

## Native reliability prerequisites

The review in `.agent/auto-snap-review.md` was documentation-only and identified outstanding issues. Current source still contains the relevant bulk parser, preparation loops and observed-frame recovery pattern. Do not label the new gesture reliable merely because it calls these methods.

Before enabling pair mutation, address the contracts the pair path depends on:

1. **Provider values:** distinguish optional CFNull/unsupported values from genuine read failure, while keeping required identity/geometry strict.
2. **Whole-request budget:** capture deadline/cancellation before handle resolution and metadata reads, and check between calls; an executor-only budget does not bound preparation.
3. **Normal-window admission:** distinguish a verified non-normal CG/AX surface from an unreadable window, so a helper surface does not become an app target or incorrectly invalidate a normal one.
4. **Mutation safety:** recheck modal/sheet/minimised/fullscreen state when another write attempt occurs, without restoring the full inventory scan.
5. **Recovery ownership:** do not automatically overwrite an external/manual frame change just because the observed frame remained stable. Prefer reporting partial completion to speculative rollback.

Scope these changes to the native operations reused by pairing. Do not make a whole-app refactor or repair unrelated review findings as a hidden part of this feature. If a small shared boundary cannot be established safely, stop and separate that prerequisite into its own implementation request.

## File-by-file plan

| File | Addition/change | Why and verification |
| --- | --- | --- |
| **New** `octopus/UI/Sidebar/SidebarIconPairDrop.swift` | Pure `PairDropDirection`, icon-target snapshot and `SidebarDropIntent` types; side/centre/tie selection; ordered pair/transfer/place resolution. | Keeps routing out of nested UI conditionals. Tests must prove visible-icon priority and blocked-icon non-fallback. |
| `octopus/UI/Sidebar/SidebarView.swift` | Add one pair-highlight entry ID/direction to view state; a distinct icon anchor callback; stroke/selected-side border with no hit interception; accessible labels/actions. | Row/title/action-column bounds must not pretend to be icon bounds. Preserve scaling, layout and mouse shortcut callbacks. |
| `octopus/UI/Sidebar/SidebarController.swift` | Collect clipped icon targets across display controllers; provide them to the active drag; publish/clear one pair highlight; freeze the target catalogue for a drag and refresh geometry after scrolling. | Source and destination display controllers differ. Preserve current uncommitted position/shortcut changes. |
| `octopus/UI/Sidebar/SidebarDragController.swift` | Store pair preparation/direction for the current session; use the pure resolver before the section callback; show paired outlines; commit one explicit pair intent after authenticated drop; clear pair state on every finish/cancel. | Reuse the existing drag rather than redesigning it; no writes during pointer movement and no second drag recogniser. |
| `octopus/UI/Sidebar/SidebarDesktopTransfer.swift` | Reuse/expose the existing clipped-view geometry helper for icon anchors; retain Desktop transfer rules. | Do not loosen Space/monitor restrictions to make pairing work. Existing transfer tests should keep the same expected behaviour. |
| `octopus/UI/WindowLayout/WindowLayoutModel.swift` | Add a typed explicit pair request/plan containing both exact identities, original scopes/frames, destination scope, direction, intended frames and topology/request revision. | Existing single-anchor companion plans cannot describe a source that starts on a different display. |
| `octopus/UI/WindowLayout/WindowLayoutPlanner.swift` | Add pure pair planning for the four half directions, both windows' minima/readability limits, positive work-area geometry and non-overlap. | Pair exactly A and B; no recent-window lookup and no third-window selection. |
| **New** `octopus/UI/WindowLayout/WindowControlAccess.swift` | Establish the narrow layout-native boundary: resolve explicit identity, read current state, write frame, typed provider errors, request deadline/cancellation. Move only duplicated layout-specific native logic into it where needed. | Gives pair/automatic layout one correctness contract; avoids growing the 1,669-line inventory with another validator family. No new observer system. |
| `octopus/UI/Sidebar/SidebarWindowInventory.swift` | Adapt existing queue/cache/handle operations to that narrow boundary; supply exact source/target preparation and final validation. | Keep sidebar discovery, UI projection, focus and Desktop transfer ownership unchanged; add a thin adapter rather than another large feature block. |
| **New** `octopus/UI/WindowLayout/WindowPairSnapService.swift` | Execute a validated two-window plan through the shared native access boundary; preserve per-window expected scope during a cross-display move; verify final identities/frames/scope and return typed success/partial failure. | The existing companion executor assumes its anchor never moves. Do not run ordinary `.place` twice and accidentally trigger automatic all-window reflow. |
| `octopus/UI/WindowLayout/WindowLayoutController.swift` | Add an explicit pair entry point using the existing scheduler/cancellation lifetime; suppress ordinary companion notification for pair commits; store a typed pair Undo record only after verified success. | One owner for window layout work. Late hover preparation/drop results cannot overrule a newer drag. |
| `octopus/Models/AXUIElement.swift` | Correct and share the typed bulk attribute decoder/fallback contract needed by pair reads; preserve strict malformed/error rejection. | Existing review R1 concerns actual provider representations. Add tests through the provider/decoder boundary, not only pre-extracted valid AXValues. |
| `octopus/UI/Preferences/PreferencesWindowLayoutView.swift` | Explain icon pairing and the independent explicit two-window action; present Undo for the last operation type, if implemented as proposed. | Do not add the abandoned external/new-window trigger modes or unnecessary settings. |
| **New** `octopusTests/SidebarIconPairDropTests.swift` | Pure direction and routing tests, clipped-hit fixtures, centre/self/off-Desktop and overlapping-section cases. | Test the decision the native receiver actually uses, rather than directly calling a guessed destination. |
| `octopusTests/WindowLayoutTests.swift` | Pair plan/executor/provider tests: both scopes, minima, exact identities, budgets, cancellation, transient errors, no third-window writes and partial failure. | Reuse existing injected read/write/clock style; assertions must observe the production path. |
| `octopusTests/SidebarDragTests.swift`, `SidebarDesktopTransferTests.swift`, `SidebarTests.swift` | Extend existing regression coverage where routing/state contracts change. | Escape/foreign-drop checks, configured gesture and Desktop transfer remain protected. |

`WindowControlAccess` is a focused prerequisite, not permission to reorganise unrelated modules. Keep the adapter contract explicit:

```text
readVisibleWindow(exactID, expectedScope?, deadline, cancellation)
    -> normalWindow / excludedSurface / unknownOrFailed
writeFrame(validatedWindow, requestedFrame, expectedPreWriteScope,
           expectedPostWriteScope, deadline, cancellation)
    -> confirmedActualFrame / failure / cancelled
```

Keep one owner for native cache/queue state. Do not create separate generations or clone observer registries in the pair service.

## Identity, visibility and operation rules

- The source identity stays the one captured at mouse-down. B's displayed identity is captured when it becomes the hovered target and retained until the pointer leaves it.
- Cached UI visibility is only a hover hint. On preparation and drop, require both apps/windows alive, ordinary top-level windows, not hidden/minimised/fullscreen/modal/sheet-blocked, writable size/position, and membership in exactly one currently visible ordinary Space.
- “Visible” means on a currently visible Desktop and not hidden/minimised; a covered window may still qualify. Fully unobscured pixels are not a reliable selection requirement.
- Read physical display geometry as well as Space IDs, including when separate Spaces is off. No inactive Space switching, tab/window substitution or app relaunch is allowed.
- Clip icon hit frames to the sidebar scroll viewport, screen and actual icon anchor. Exclude title labels, action buttons, popups and neighbouring icons.
- Freeze the session's candidate identities, not their actual window state. Closing/minimising/replacing a target clears the border and cancels its pair intent.
- Prepare once when the hovered target changes, with a session/target-generation guard. Pointer movement uses pure geometry; no full AX inventory scan per move.
- Revalidate at drop and before writes, under a whole-operation budget. Proposed initial total is four seconds with existing per-call timeouts; one in-flight call can finish after cancellation, so check again afterward.

## Execution and failure policy

1. Preflight **both** windows and both requested rectangles before the first write. If either known minimum cannot fit, reject with zero pair writes.
2. Recommend resizing B into its complementary destination half first, then placing A into its chosen half. This avoids first covering B with A; the temporary visual change must be assessed live.
3. For A crossing displays, keep the deliberate cross-display write policy. For B already on the destination display, use the same-display policy. Choose named intent/policy rather than adding more ambiguous Boolean combinations.
4. Revalidate source identity and expected original scope before its move, and destination membership after it. Do not require A to belong to B's scope before A has been moved.
5. Verify final actual frames for both windows, destination display/Space membership and non-overlap. An app-limited `placed(adjusted: true)` is not successful pair placement.
6. Focus A once, through the proven exact-window focus-before-follow-up-raise path. Do not activate every app as it is resized.
7. Cancel on Escape, permission/topology/visibility changes, stale identities or newer user intent. Block double drops while the same pair request is pending.
8. If one write succeeded and another failed, report partial completion honestly. Do not apply the existing speculative recovery rule to an uncertain external update.

macOS exposes separate position/size setters and no public atomic transaction spanning two apps. Preflight reduces failure; it cannot guarantee that both apps accept the writes together. Visible resizing/transition smoothness must be tested, not promised.

### Proposed Undo behaviour

An explicit pair operation deliberately moves both windows. Recommendation: **Undo pair snap** restores both original frames/scopes only when both current identities and post-pair frames still match and both original display/Spaces remain visible.

Keep the existing companion-only Undo semantics for ordinary edge snapping. If safe multi-scope pair Undo cannot be implemented in this request, call that out before implementation; do not silently apply companion-only Undo to the new gesture or automatically switch Desktops to restore A.

## Implementation order and validation

1. **Native contract gate:** close the relevant provider/budget/admission/safety gaps with focused tests; establish the small access boundary without changing existing gesture UX.
2. **Pure routing and pair geometry:** add the four-side resolver and explicit pair plan, including blocked-icon non-fallback.
3. **Border/preview wiring:** hook measured icon targets across displays into the existing native session, with no real-window mutation during hover.
4. **Explicit pair commit:** wire the pair service and coordinator, suppress incidental companion adjustment, then add scoped Undo if approved as proposed.
5. **Regression and live acceptance:** run the focused command below when authorised; request an agreed-monitor live check before claiming refined visual behaviour.

Focused cases:

- A dropped on each side of B produces the intended complementary halves.
- The same pointer inside an overlapping Desktop section selects pair only for eligible visible icons.
- Self/centre/rejected pair zones do not fall through to transfer; inactive-Desktop drops retain the existing transfer intent.
- Other display's icon registry works; a display disconnect or Space change cancels.
- Clipped/offscreen icons, title labels, popup corridor and action columns do not become pair targets.
- New hover preparation finishing after the pointer leaves B cannot restore B's border or commit.
- Both windows' minima are checked before any writes; late clamp/failure is not success.
- Cross-display A validates its original scope before the move and destination scope after it; B never leaves its own visible destination Desktop.
- The existing automatic **all-window** option cannot cause writes to C during a pair drop.
- Transient provider errors, optional CFNull, closed/replaced windows, deadlines and interrupted preparation are correctly classified.
- Partial failure never overwrites an unrelated actor's move through guessed rollback.
- Undo restores only its operation's exact identities and declines changed/inactive original scopes.
- Configured mouse/modifier drag, click suppression, Escape, foreign-source/nonce rejection and Desktop popup/transfer remain unchanged.

Command to run **after implementation and only when Mayank requests tests**:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-icon-pair \
  -resultBundlePath /tmp/octopus-icon-pair-tests.xcresult \
  -only-testing:octopusTests/SidebarIconPairDropTests \
  -only-testing:octopusTests/WindowLayoutTests \
  -only-testing:octopusTests/SidebarDragTests \
  -only-testing:octopusTests/SidebarDesktopTransferTests \
  -only-testing:octopusTests/SidebarTests test
```

Use a new result-bundle path for repeat runs and confirm named suites/nonzero executed counts. No install or dependency changes are expected. The new suite now exists; this command has not been run for the implementation.

Live acceptance, only with renewed user authorisation: same display and cross-display pairs, different visible Spaces, multiple-window apps, small icons/scrolling, slow and minimum-size-limited apps, direction changes through centre/diagonals, cancellations and repeated drops. Agree monitor focus and one running build first; no `osascript`/scratch-probe workaround.

## Limits and stop conditions

- App-icon pairing chooses one displayed window per icon, not every window/tab in that app. Same PID is allowed only if the two exact window IDs differ and the UI can actually select them.
- No pairing with hidden/minimised/inactive-Desktop/fullscreen/utility/modal/sheet windows. Unknown membership/identity declines rather than guessing.
- Pairing two windows does not guarantee all other unchanged windows remain unobscured; the user explicitly chose a pair.
- Border direction on a small icon, AX latency, private Space metadata and cross-display visual transitions remain risks requiring real validation.
- Future source changes to gesture settings, icon magnification, sidebar scrolling or native observer ownership affect this path; test routing through the real resolver.
- Stop if provider contracts remain unsafe, the access boundary needs a broad unrelated refactor, Desktop-transfer routing changes unexpectedly, or a pair commit cannot suppress the ordinary companion pipeline.

The original planning step changed documentation only. The implementation above now changes source and tests; builds, tests and live behaviour remain unverified.
