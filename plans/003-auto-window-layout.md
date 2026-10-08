# Plan 003: Adjust neighbouring windows when a window is snapped or opened

## Current implementation scope (supersedes the original proposal below)

Mayank clarified the scope during implementation on 8 October 2026:

- Keep the existing icon drag, native drop validation and single-window placement. After a successful Octopus half-snap, adjust other windows on the destination physical display and visible native Desktop.
- Add a **Snap** Preferences tab. Adjustment is **enabled by default**.
- The **Adjust** dropdown chooses **Most recently used other window** (default) or **All other normal windows**.
- Recent mode adjusts one companion. All mode shares the remaining half vertically beside a left/right anchor, or horizontally above/below a top/bottom anchor.
- The top edge snaps to **top half**, not maximise. Corners are **free movement**. Explicit Maximise remains available as a named placement action and does not adjust neighbours.
- A failed companion arrangement preserves the user's already-completed snap and explains the failure. Undo restores only the companions; it never moves the snapped target back to its source display.
- Automatic reactions to other tools and newly opened windows are **out of this implementation**, following Mayank's explicit cut in scope. The old three-trigger design and AeroSpace tree are historical research, not required implementation work.

Implementation checklist:

- [x] Existing placement completion carries explicit snap intent to one app-owned coordinator.
- [x] Live identity, display, Desktop, eligibility, minimum size and actual frames are checked.
- [x] Both affected-window options are implemented in the planner and Preferences UI.
- [x] Frame-only companion writes preserve focus and leave the snapped anchor alone.
- [x] Bounded cancellation, guarded recovery and companion-only Undo are implemented.
- [x] Corners are removed and the top edge uses a half; focused regression expectations are updated.
- [x] Initial focused run: **109 tests / 112 parameterised executions passed**, no failures or skips, from `/tmp/octopus-auto-layout-focused-tests.xcresult`.
- [x] Live Snap-tab defaults and both dropdown labels observed. Live top-half action resized the blank TextEdit companion to a 1920 × 525-point half-height window; successful companion adjustment and Undo availability appeared in the running app. A limited-app failure was also observed and correctly declined.
- [x] Repeated focused verification after the performance/focus changes: broader run **114 tests / 117 executions**, then final `WindowLayoutTests` and `SidebarDragTests` run **48 tests / 51 executions**, all passed, no failures or skips. Final bundle: `/tmp/octopus-auto-layout-final-focused-tests.xcresult`.
- [x] Mayank confirmed that the cross-display gesture works, but reported delay and visible fluctuation in both the companion and dragged window. Those reports prompted the changes below; they are not recorded as a clean visual pass.
- [x] Final diff checked. At Mayank's request, further UI clicking stopped; visual smoothness, live all-window mode and live Undo are **not newly verified**.

Latest reliability/performance changes:

- Companion discovery now uses fresh visible Core Graphics records scoped to the destination display/Desktop. It resolves only the chosen apps' AX handles, instead of rereading the entire app/Space inventory after each snap.
- Most-recent candidate selection has a production-path test with 100 candidates that verifies one companion metadata read. All mode still reads each selected normal window.
- Focus tracking subscribes at the app level without enumerating every window on startup/app changes. Actual frames and current safety flags are read live; frame geometry is not taken from a stale cache.
- Removed the fixed 150 ms companion delay. Permission, window identity, process generation, Desktop/display and interruption guards remain in place.
- Companion writes on the same display send size then position once, with bounded final confirmation. A repeated reachable old frame no longer causes an immediate duplicate resize. The original cross-display writer retains its normal protection for the dragged target.
- Mayank explicitly approved changing `octopus/Models/AXUIElement.swift`. The shared position/size read uses one bulk AX call and falls back to individual reads for unsupported providers; malformed/error values remain failures.
- The placement path no longer sets AXMain/AXRaise before requesting the exact window's focus. It uses the existing focus-first/follow-up-raise sequence documented in `.agent/cross-desktop-focus.md`.
- Failed snapshot messages distinguish a missing handle, unreadable state and a changing destination/frame. They decline adjustment instead of moving an unverified target.

Remaining limits: app minimum sizes and unsupported AX providers can still reject a layout; macOS does not provide an atomic multi-app resize. No measured end-to-end latency or flicker-free claim is made from the unit-test results. The user reported monitor-focus interference during the UI automation and requested automated tests only for the final checks.

Only the original research/prototype below is described as “planning proof”. Its 2,406 assertions do not test the final production implementation, whose evidence is tracked above.

---

Status: **PLANNED — source checked and geometry prototype tested; production implementation and live verification pending.**

Planned against `db25387fb8e378a0914a6ecb06a380fca8c5516e`, 8 October 2026.
Priority P1; effort L; implementation risk HIGH because several independent applications are modified.
Use this file as a self-contained handoff. Implement phases in order. Do not mark a phase complete on compilation alone.

## 1. Confirmed product choices and recommended boundaries

Mayank requested automatic adjustment of neighbouring windows after snapping. He confirmed:

1. Add a **new snap tab** with a dropdown offering all three trigger modes.
2. Arrange **all normal windows on that display and native macOS Desktop**, not only previously snapped windows.
3. For new windows, use behaviour **like AeroSpace**.

Recommended first release:

- New tab: **Window Layout**, next to Sidebar. Reuse the existing SwiftUI Form style and sizing helpers.
- Toggle: **Automatically adjust other windows**, initially off for existing and new installations.
- Dropdown **Adjust windows when**:
  - **Snapping with Octopus** — only an explicitly accepted Octopus half-snap.
  - **Snapping with any tool** — includes the first mode and recognised external half-snap shapes.
  - **Snapping or opening a window** — includes both snap modes plus new-window insertion and layout maintenance after close/minimise/hide/restore.
- Explain below the dropdown: other-tool snaps are recognised from the resulting window position; not every macOS arrangement can be identified.
- Add **Undo last arrangement** in this tab, with the affected display name. It restores only the last safe automatic transaction and is disabled when that snapshot is stale. Do not persist live window IDs across restarts.
- Initial automatic snap coverage: left half, right half, and bottom half. The internal complementary top half is a layout region, not a new drag target.
- Corners and maximise retain their existing single-window placement. They remove the explicitly moved window from the current automatic group and invalidate that group's layout cache, so later actions cannot silently restore its old tile. Support corner reflow in a separately specified follow-up. Maximising deliberately covers other windows; it cannot simultaneously promise a non-overlapping arrangement.
- Ordinary free dragging remains free dragging. In the third mode a manually detached window stays floating for the session, until explicitly snapped back in. First adoption includes all eligible normal windows; subsequently respect these explicit user detachments.
- If automatic preflight cannot fit the windows, an explicit Octopus snap still follows its existing single-window behaviour once, with a message that neighbours could not be adjusted. An inferred snap leaves its already-snapped target alone; a creation event leaves the newly opened window at its natural frame. Do not silently disable the user's basic snap action because automation cannot fit the peers.
- Automatic modes operate even if the sidebar is hidden or disabled. Turning the layout feature off stops its extra observers and future automatic mutations; it does not move windows back.

These boundaries are recommendations, not additional user approvals already obtained. Review them before implementation, especially supported snap shapes and floating-window behaviour.

## 2. What the current code actually does

| File and symbols | Verified behaviour and consequence |
| --- | --- |
| `octopus/UI/Sidebar/SidebarDragController.swift`: `place`, `update`, `drop` | Both native drops and accessible placement actions calculate one frame and call `inventory.perform(.place(...))`. Preview movement does not write AX frames. The drop validates the source/session token before reaching this path. |
| `octopus/UI/Sidebar/SidebarWindowPlacement.swift`: `SidebarPlacementRequest` | Contains frame, work area, resize flag, Desktop generation. It currently loses snap intent, display identity and destination Desktop identity. Extend the intent, do not guess the target from rounded geometry for Octopus-originated requests. |
| Same file: `SidebarPlacementWriter.apply` | Size/position/size writes, bounded settling, up to three attempts, actual frame readback, two-point matching, and reachability correction. `.placed(frame, adjusted: true)` can mean the requested tile was not achieved. It is not a successful multi-window layout. |
| `SidebarWindowInventory.swift`: `placementTarget`, reader `.place` branch | Checks window identity, live Desktop membership, move/resize support, fullscreen/modal/sheets. The existing action may restore/unhide, prepare a raise and request foreground focus. Never call it in a loop for neighbouring windows. |
| Same file: `SidebarPendingAction` | Its cancellation is tied to the frontmost app or original target app. A multi-app layout needs a separate batch token; reusing a peer PID with this focus guard would cancel valid work or change focus incorrectly. |
| Same file: `observe` | Observes creation, destruction, movement, resize and minimise changes, but collapses them to `onChange()`. External snap and new-window triggers need typed events plus live snapshots. A refreshed list is not proof that a window was newly created. |
| `SidebarController.swift`: `SidebarDisplayController` | Each sidebar display owns an inventory and stops it when disabled. Attaching automation independently to every display controller risks duplicate layouts and cannot operate when the sidebar is off. |
| `SidebarSpaces.swift`: `SidebarSpaceReader` | Native Desktop metadata uses dynamically resolved SkyLight read APIs. A missing API must disable scope-dependent automatic changes rather than guessing; no new Space-moving API is needed. |
| `octopus/octopusApp.swift`: `AppDelegate` | Owns the sidebar's start/stop lifetime. Add one app-owned layout coordinator here. |
| `PreferencesView.swift` | Four tabs in a 650-point-wide TabView. Add one tab using the existing component pattern. |
| `octopusTests/SidebarDragTests.swift` | Swift Testing, `@Test`, `#expect`, pure geometry and closure-injected writers. Follow this pattern for new tests. |

Current request excerpt, `SidebarWindowPlacement.swift`:

```swift
struct SidebarPlacementRequest: Equatable {
    let frame: CGRect
    let workArea: CGRect
    let resize: Bool
    let desktopGeneration: Int
}
```

Current production writer result check in the reader accepts `case .placed`; automatic layout must additionally validate `adjusted == false` and a fresh whole-batch readback.

`.agent/mistakes.md` records previous mistakes treating AX failures as empty lists and passing fixture tests as proof of live behaviour. `.agent/window-placement-reliability.md` records unresolved live cross-display placement failures. Treat the existing single-window writer as reusable infrastructure requiring a live baseline, not already proven for this new feature.

## 3. Reference findings, pinned to inspected source

Source snapshots were fetched through GitHub's tree API and raw source URLs on 8 October 2026. They are external research, not dependencies to install.

| Project | Inspected revision and source | Lesson used |
| --- | --- | --- |
| yabai | [`dd845723`, `src/view.c`](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/view.c), `window_node_split`, `window_node_update`, removal; also event loop and window manager | Represent a layout explicitly and update affected regions, instead of deriving all intended relationships from overlapping live frames. Binary splits are useful for directional snapping; a daemon or scripting addition is unnecessary for this feature. |
| AeroSpace | [`74a1bf17`, `MacWindow.swift`](https://github.com/nikitabobko/AeroSpace/blob/74a1bf17e82d70e0a21945ba04bb4f590bf19f83/Sources/AppBundle/tree/MacWindow.swift), lines 214–241; also TreeNode, TilingContainer, normalization, layoutRecursive and refresh | A normal newly detected window joins the most recent tiled window's parent immediately after that window; otherwise it joins the root. Use containers and cancellable reconciliation. Root orientation follows display shape. |
| Rectangle | [`18c058aa`, `MultiWindowManager.swift`](https://github.com/rxhanson/Rectangle/blob/18c058aa856afd3b09fc98a567dc492d2b981b85/Rectangle/MultiWindow/MultiWindowManager.swift), `tileWindowsInBands`; [`GridTiling.swift`](https://github.com/rxhanson/Rectangle/blob/18c058aa856afd3b09fc98a567dc492d2b981b85/Rectangle/MultiWindow/GridTiling.swift); AccessibilityElement, WindowManager, history, GridTiling tests | Plan with actual size constraints, allocate exact backing pixels and read achieved frames. Its band allocator distinguishes infeasible layouts. Its frame writes account for macOS cross-display size clamping. |
| AltTab | [`6d8940b5`, `AXUIElement.swift`](https://github.com/lwouis/alt-tab-macos/blob/6d8940b5307d7348aaca70259c28147fc5ab00b3/src/macos/api-wrappers/AXUIElement.swift); also AxObserverRegistry, observer health spec, AXCallScheduler and Window | Preserve uncertainty: an unanswered AX call does not mean a window closed. Keep process/observer generations, distinguish stale elements from transient timeouts, and bound recovery. This project informs lifecycle handling, not layout geometry. |

Scope of the AeroSpace comparison: Octopus borrows its **insertion/group behaviour**, not its emulated workspaces, full command system, accordion layout or precise weight semantics. Equalise flexible siblings within a group subject to constraints. This is explicitly a simpler design choice; AeroSpace preserves adaptive weights.

If any implementation copies external code, inspect that exact repository's license at the pinned revision and retain the required notices. Prefer a small original implementation of the group model; do not vendor entire window managers.

## 4. Concrete behaviour

Use `NSScreen.visibleFrame` as the work area, so the Dock and menu bar remain reserved. Work in points at the API boundary and backing pixels inside the allocator.

Examples, assuming all windows can fit:

| Event | Result |
| --- | --- |
| Two normal windows; A snaps left | A gets the left half; B gets the right half. |
| A, B, C; C snaps left | C gets the left half; A and B split the right half vertically. Previous peer order is retained. |
| C snaps right | The preceding example mirrors: C right, A/B left. |
| C snaps bottom | C gets bottom half; A/B share top half horizontally. |
| New C opens in third mode; A and B share a horizontal root, A is most recent | Insert C immediately after A: A, C, B become three horizontal siblings, roughly thirds. This is not a nested split that leaves B at half width. |
| New C opens when A belongs to a nested vertical group | C joins that vertical group after A; unrelated groups retain their allocated outer region when feasible. |
| No eligible windows in destination scope | The first new window fills the work area in third mode. An explicit snap still keeps the chosen half. |
| A normal fixed-size window overlaps the proposed layout | Do not automatically move or cover it. Reject that automatic arrangement with a clear reason. |
| Not enough space to keep every eligible window above its known minimum/readability floor | Reject automatic rearrangement before writing. Do not shrink into unusable strips or silently discard a window. |

All-normal scope refers to real window surfaces, not one window per app or one window per tab. More than one window from the same app must remain distinct.

Default root orientation: horizontal when work-area width is at least its height, otherwise vertical. Explicit snap construction overrides that orientation locally. Choose the perpendicular peer orientation: vertical peers beside a left/right anchor, horizontal peers above a bottom anchor.

## 5. Architecture: small model, one owner, one batch executor

Suggested new files under `octopus/UI/WindowLayout/`:

1. **`WindowLayoutSettings.swift`** — enabled flag, Codable/string-backed three-case trigger enum, safe defaults and validation. No changes to existing sidebar setting keys.
2. **`WindowLayoutModel.swift`** — value types for scope, identity, snapshot, recursive group, intent, result and last committed layout.
3. **`WindowLayoutPlanner.swift`** — pure tree edits and constrained allocation. No AX, AppKit event monitors or app activation.
4. **`WindowLayoutController.swift`** — main-thread lifecycle, trigger classification, generations, scheduling, cancellation, self-write acknowledgement and Undo.
5. **`WindowLayoutExecutor.swift`** — off-main batch execution through validated reader operations. No UI and no independent window discovery system.

Add `PreferencesWindowLayoutView.swift`. Keep `SidebarPlacementWriter` as the single low-level frame-writing policy.

Key types:

```text
LayoutScope(displayIdentifier, nativeSpaceID, topologyGeneration)
LayoutWindowIdentity(pid, processGeneration, cgWindowID)
LayoutNode = window(identity) | group(axis, orderedChildren)
LayoutIntent = octopusSnap(identity, target, scope)
             | observedSnap(identity, target, scope)
             | createdWindow(identity, scope)
LayoutPlan(scope, snapshotRevision, targetFrames, unchangedFrames, focusPolicy)
LayoutBatchResult = applied(actualFrames) | rejected(reason)
                  | cancelled | partiallyApplied(actualFrames, reason)
```

Use an indirect Swift enum with value semantics for the tree. Derive a leaf's path by traversal when needed; do not add mutable parent pointers or an app-wide tree singleton. Track recency separately. Persist settings, not window identities or AX handles.

One **app-owned coordinator** is the only authority for layouts, including snaps arriving from different sidebar displays. For the first implementation it may own one headless `SidebarWindowInventory` using the existing reader, active only while automation is enabled. This adds one set of observation resources rather than one new coordinator per sidebar. Preserve existing sidebar inventories and UI projection logic; a shared inventory refactor is not a prerequisite.

Extend the reader/inventory with narrowly scoped snapshot and **frame-only batch** methods. Keep private reader state queue-confined. A typed event bridge can carry a retained AX element and notification into that queue, resolve it against cached exact identity, then publish immutable events. Preserve the existing `onChange` refresh path. Unknown identity does not trigger a layout.

Do not let each per-display inventory independently execute a layout. Route explicit snap intent to the single coordinator before the existing `.place` action runs. When automation is disabled or the target is outside supported automatic shapes, use the existing placement path exactly once.

## 6. Eligibility, scope and snapshot rules

Before planning, obtain a fresh, successful snapshot from the reader. Do not use filtered sidebar entries as the full candidate set.

- Include standard top-level normal windows on the requested physical display and **exact visible ordinary Space**. WindowServer owner PID/window ID and live AX identity must agree.
- Require finite positive frames and readable state. Require movable/resizable windows for reflow. Fixed normal windows are protected rectangles: a plan intersecting them is rejected. Excluded utility panels/dialogs are not forcibly managed, so the non-overlap promise applies to eligible normal windows only.
- Exclude app-owned Octopus windows, menu/popover surfaces, fullscreen windows, modal windows and windows with attached sheets. Never move a parent while a sheet is active.
- Exclude hidden/minimised peers; never restore them merely to fill space. An explicitly dragged original target may keep the existing restore behaviour; automatic creation/detection does not restore anything.
- Reject unknown Space membership and multiple-Space/sticky memberships. Display number and Desktop order are labels; use identifiers.
- Use physical display geometry as well as Space ID, including when separate Spaces is disabled. A shared Space does not grant permission to rearrange another display's windows.
- Revalidate process generation, AX/window identity, state, exact scope and topology immediately before each mutation and at final readback.
- Cross-display explicit snaps have a separate two-stage path: first use existing single-window placement once, then verify the target's actual frame and destination display/visible Space. Only then plan destination-peer adjustment with the anchor already in place. The source display is not reflowed. If membership or the requested tile cannot be confirmed, skip automatic adjustment. Recovery of this second stage covers only peer changes, never a speculative move back to the source display. A target still on its source display cannot pass the same destination-scope guard as a peer; do not reuse that guard blindly.
- A timeout or failed read produces **unknown**, not absence. Keep the last good layout model, invalidate the pending plan, and wait for another legitimate event. Never replay an expired intent later.
- Start with a successful baseline inventory. Startup, enabling a mode, visiting another Desktop, wake and permission recovery must not classify all discovered windows as newly opened. They populate the baseline without writes. Subsequent creation is a separate event.
- Initial scope adoption is triggered by a real accepted snap or real new-window event; adopt all eligible windows then, in stable spatial order. Existing groups retain peer order.

The exact display/Space resolver is a critical spike. If existing private read APIs cannot prove destination membership reliably on a supported macOS version, disable automatic layout there and preserve single-window placement. Do not substitute AeroSpace-style workspace emulation.

## 7. Planner rules and failure handling

### Plan without moving anything

1. Check all input identities are unique and all geometry is valid. Cap one scope at **32 eligible windows** initially. More windows yields an explicit unsupported-capacity result; never process only the first 32.
2. On a half snap, remove the target from its old group, collapse empty/single-child groups, and construct a root split containing the exact anchor half plus a perpendicular peer group in the complementary half. Preserve the prior peer order; first adoption sorts by spatial position and exact identity as tie-breaker.
3. Keep the anchor boundary fixed for that snap. If a minimum would shift the requested half boundary, reject instead of unexpectedly snapping somewhere else.
4. On creation in the third mode, insert after the most recent eligible tiled window **in that window's parent**; fall back to root when no such window exists. Recency is captured before auto-focus/creation notifications can promote the newcomer itself.
5. Prune only successfully confirmed closed windows; temporarily remove minimised/hidden members. Restoration in the third mode inserts once, without unhiding or focusing another app. Explicitly floating members remain excluded for the session.
6. Compute subtree minima bottom-up. Along a group's split axis, sum child minima; across that axis take their maximum. Allocate flexible siblings as evenly as possible within those constraints, using integer backing pixels and deterministic remainder distribution.
7. Min-size attributes may be unavailable. Try readable `AXMinSize`/`AXMinimumSize` without assuming either is supported. Combine valid reported limits with a proposed **320 × 200 point readability floor**. This floor is a product choice requiring live validation, not a macOS guarantee. Larger actual app minima can still reject a write.
8. Every proposed frame must be positive, contained in the work area, and non-overlapping with other participant frames or protected fixed-window rectangles. If infeasible, return rejection with **zero writes**.
9. Skip frame writes that already match the requested frame. Preview is advisory; use the latest snapshot at drop. An obsolete preview must not determine the mutation set.

The prototype under `plans/proofs/` executes Rectangle's actual constraint allocator with this proposed group adapter. Production code must independently implement this contract and test it in Swift Testing; the prototype is not a production dependency.

“Zero writes” here means zero automatic peer-layout writes. The explicit single-window fallback described in section 1 is a distinct action, executed once only on a rejection before the batch starts. After any partial batch failure, perform guarded recovery/reporting; do not automatically launch another fallback action that might overwrite a later user move.

### Execute as a guarded batch

macOS AX cannot atomically resize several applications: [Apple's setter](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) operates on one attribute of one element. This is a best-effort batch, not a guaranteed all-or-nothing transaction.

1. Acquire one coordinator-wide layout token. Record pre-write frames, identity/generations and original focus. Coordinate per-PID reservations with sidebar actions; a conflicting focus/minimise/transfer must cancel or reject the batch, not race its writes.
2. Prevalidate all participants before the first write. If the scope or any required identity changes, reject the plan. Never substitute another window from the same app.
3. For same-display explicit snaps, move peers before the anchor to avoid first covering them with it. An external snap or the verified second stage of a cross-display snap already has the anchor in place; peers adjust around its confirmed frame. All peer writes are frame-only. Do not call the current `.place` action for each peer.
4. Reuse the existing writer with a batch-specific `canContinue` guard and deadlines. Bracket Enhanced UI adjustment per app with guaranteed cleanup on every exit. Preserve assistive-technology compatibility; check current Rectangle policy and verify VoiceOver before release.
5. Suggested initial budgets: existing **0.2-second AX messaging timeout**, **4-second whole-batch forward deadline**, and a separate **2-second maximum guarded recovery budget**. These are proposed upper bounds, not measured latency guarantees; an already-running blocking call may return after the deadline. Check before and after every call.
6. Read every actual final frame once the writer has settled. Success requires matching all intended frames and scope, including no remaining peer/anchor overlap. `.placed(adjusted: true)` is a layout failure even if that window is reachable.
7. On failure, stop remaining writes. Best-effort restore already touched windows only if their identity, scope and current frame still agree with our last observed write result. If a user or other manager has changed a touched window, stop recovery for that window. Never undo the user's later action.
8. Never attempt recovery after permission loss, a Desktop switch, display disconnection or uncertain identity. Record partial state, clear the committed tree, and give one useful message: for example, “Automatic layout stopped because an app restricted resizing. Some windows may have moved.” No generic beeps or notification spam.
9. Focus the explicit snapped target at most once after success, using the existing target-specific focus path. Automatic/external actions preserve the existing focused window and do not raise each peer. If focus changes during the batch, cancel rather than pulling the user back.
10. Keep a one-step Undo snapshot only after a fully verified batch. Apply Undo with identical guards and readback. Close/minimise/Space/topology changes invalidate it; a manual frame mismatch disables it instead of overwriting that change.

If an app clamps an unknown minimum, do not infer a permanent size limit from one intermediate frame or loop until it cooperates. First release rejects and recovers that batch. Adaptive clamp learning can be added later only with reliable settled observations.

## 8. Events, feedback loops and coexistence

- **Octopus mode:** use explicit intent from accepted native drop or accessibility placement action. Escape, foreign drops, entering/leaving a snap zone and preview updates produce zero layout writes.
- **Any-tool mode:** observe moved/resized frames and recognise only supported half rectangles within two points of the current work area. Require the frame to change from the preceding successful snapshot and settle through two bounded, agreeing observations; never reinterpret a still-resizing intermediate frame as a snap. Suggested debounce is 150 ms, to be tuned by the spike. Geometry recognition is heuristic and must be described as such.
- **Creation mode:** require a real creation identity/event after the baseline. Wait for valid identity, scope, role and frame, with a bounded readiness window; if still unknown, skip rather than moving a late window after the user has begun using it. Coalesce startup bursts belonging to the same active transaction; normal launches may create several windows.
- Creation takes precedence over inferred snap geometry for the same newly opened identity, so a window born at half-screen size is inserted only once.
- Use an active transaction ID and per-window expected-write ledger to acknowledge our move/resize events. Do not launch another automatic transaction from an acknowledgement. After completion, reconcile actual state and compare against the committed snapshot; matching delayed acknowledgements cause no writes.
- Manual Octopus intents take priority over inferred events. Keep at most one queued inferred intent per scope, replace stale ones, and revalidate before execution. Do not build an unbounded queue or add a periodic global retile loop.
- Ordinary peer manual resizing/movement outside a recognised snap detaches it for the session; it must not immediately jump back to its old tile. An explicit snap readopts it.
- If other software repeatedly changes the just-applied layout, stop automatic reactions for that scope and explain the conflict. Start with a proposed detector of three contradictory layout changes within two seconds; tune using actual coexistence tests. Resume after an explicit Octopus snap or user toggling automation. Do not promise cooperative operation with a second continuous tiling manager.
- AX observer failure is not permission loss unless the error actually indicates permission failure. Unsupported notification registration does not invalidate all other capabilities. Rebuild stale observer generations with bounded recovery; use legitimate user/app/lifecycle events for reconciliation instead of continuous polling.
- Preserve current sidebar title/menu/drag behaviour and Desktop transfer routing. Drop into a sidebar Desktop section remains a transfer, not a layout trigger.

## 9. Implementation phases and proof gates

| Phase | Work | Gate before moving on |
| --- | --- | --- |
| 0: real-window feasibility spike | Reproduce existing left/right placement on Finder, browser, Terminal and Xcode; same display and cross-display. Read requested/actual frames and record focused identity and Space before/after. Investigate existing known writer failures first. | A half-snap reaches its intended frame repeatedly on the supported baseline. Limited apps give a correct bounded failure. No wrong-side landing. If this fails, fix/specify the writer before adding batch automation. |
| 1: settings and pure model | Add Window Layout tab, safe settings, scope/identity/tree, half-snap planner and MRU-parent insertion. | Focused new Swift tests cover exact frames, minimum rejection, identity uniqueness, root/nested insertion, pruning and disabled defaults. No production frame mutations yet. |
| 2: guarded batch and Octopus mode | Add single app-owned controller, frame-only reader methods, shared cancellation/reservations, readback, safe recovery and Undo. Route accepted Octopus half-snap intent into it. | Live two/three-window snap, partial failure, manual interruption and Undo pass, with no peer focus stealing or hidden-window restore. |
| 3: inferred snaps | Typed events, frame-settle detection, expected-write ledger and conflict pause. | Native macOS half snap and Rectangle half snap cause exactly one adjustment; Octopus's own events cause none. Unsupported snap shapes remain unchanged. Continuous-manager conflict stops within the bounded policy. |
| 4: AeroSpace-like creation | Creation baseline, readiness, MRU-parent insertion and close/minimise/hide/restore maintenance. | Normal new windows join the expected parent; a dialog, new tab, startup scan, Space switch and observer replacement do not create duplicate/mistaken members. |
| 5: release qualification | Run the compact real-scenario matrix below, accessibility check, performance measurements and source/diff review. | All shipped dropdown modes pass their own live gate. Leave the feature opt-in. Do not ship active but unverified dropdown modes or label the feature production-ready early. |

Keep each phase a focused commit on `codex/auto-window-layout`. No installs or dependency changes should be necessary. Do not push without a separate request.

## 10. Focused tests and actual-world acceptance

Create `octopusTests/WindowLayoutTests.swift`, covering these behaviours through production planner/reducer/executor seams, not a second test-only algorithm:

1. Mirrored left/right and bottom snap with two and three normal windows; preserve the anchor's half and peer order.
2. MRU-parent insertion into root and nested groups; root fallback; one-window initial layout; close collapses a group.
3. Known minimum/readability shortage produces zero writes; fixed protected window intersection rejects; unknown minimum clamp yields partial-failure/recovery, never success.
4. Negative monitor origins, odd pixel dimensions, 1×/2× scale, Dock/menu-bar work area and non-finite/empty geometry.
5. Same-app multiple windows and reused PID/window IDs with a new generation never select a replacement target.
6. Failed snapshot stays unknown; successful empty snapshot is absence. A delayed AX-element replacement heals the same surface rather than adding a new window.
7. Baseline startup/mode enable/wake/Space switch are not creation; a real creation runs once; a new tab does not become a second physical window.
8. Self-write acknowledgements, event bursts, external snap settling and out-of-order callbacks produce one appropriate batch; stale events produce none.
9. Permission/topology/focus changes, close mid-batch, one unresponsive app and conflicting sidebar transfer cancel safely; all reservations clear and Enhanced UI cleanup runs.
10. Peer writes never activate/unhide/unminimise; only successful explicit snap focuses the original target once.
11. Recovery/Undo require exact live identity, scope and frame agreement; intervening manual changes are preserved.
12. Capacity cap, debounce and conflict-pause policies are deterministic using an injected clock; no indefinite retries or pending queue growth.

Use the existing closure-injected writer tests as the style example. Parameterise geometry cases rather than adding hundreds of nearly identical test methods.

### Commands for implementation verification

The project has an `octopus` scheme and an `octopusTests` target; app target deployment minimum is macOS 14.6. The scheme also contains UI tests. These commands deliberately select only focused unit suites. They have **not** been run for this plan; `WindowLayoutTests` does not exist yet.

```sh
cd /Users/mayank/Desktop/mac/windows_drag
xcodebuild -project octopus.xcodeproj -scheme octopus \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-auto-layout \
  -resultBundlePath /tmp/octopus-auto-layout-tests.xcresult \
  -only-testing:octopusTests/WindowLayoutTests \
  -only-testing:octopusTests/SidebarDragTests \
  -only-testing:octopusTests/SidebarTests \
  -only-testing:octopusTests/MouseShortcutTests \
  -only-testing:octopusTests/SidebarDesktopTransferTests test
```

Use a fresh result-bundle path for subsequent runs. Confirm the named new suite actually executed and test counts are nonzero; a successful empty filtered run is not evidence.

### Compact live acceptance matrix

Use a debug build from the exact checkout/commit. Log scope, requested/actual frames, transaction result and focused window ID; avoid logging window titles or document contents. Exercise the production path through the UI; a standalone AX probe alone cannot establish end-to-end correctness.

| Scenario | Required observation |
| --- | --- |
| Finder + browser + Terminal, three supported halves | Every eligible window stays visible inside the correct work area; original dragged window lands on the requested side. |
| Xcode/large-minimum app and a deliberately narrow work area | Preflight rejection or honest bounded partial failure with guarded restoration; never a success label over overlapping frames. |
| Two windows from one app, then open/close a third | Distinct identities; correct MRU-parent placement; no switch to another window. |
| Minimise/hide and restore in creation mode | Excluded windows remain hidden; restored normal window inserts once. |
| Sheet/dialog/fullscreen/utility panel and native tabs | No inappropriate resize, parent movement or duplicated surface. |
| Two displays, negative origins, mixed scale, different Dock positions | Only destination scope is rearranged. Actual screen/Space membership agrees with the plan. |
| Separate Spaces on and off; same display with multiple Desktops | No movement on other visible displays or inactive Desktops. Unknown membership declines layout. |
| Close a peer, switch Desktop, disconnect display, revoke AX access during writes | Prompt cancellation; stale queued intent cannot move a newly encountered window. Partial state is reported correctly. |
| Native macOS snap and Rectangle snap, plus repeated resizes | One adjustment per recognised settled external snap; ordinary dragging does not trigger a retile loop. |
| AeroSpace or yabai actively rearranging the same display | Octopus's automatic mode detects repeated conflict and stops instead of endlessly competing. This is failure containment, not supported joint management. |
| Feature on with sidebar off; restart, enable mode, wake | Modes work independently of sidebar lifetime; baseline discovery causes no surprise rearrangement. |
| Undo after success, and after subsequent manual move | Safe arrangement restores once; later manual changes disable unsafe Undo. |
| VoiceOver and keyboard-only Preferences navigation | Settings are labelled/reachable and Enhanced UI cleanup does not break assistive behaviour. |
| 2, 6 and 12 eligible windows; one slow app; event burst | Main UI remains responsive, forward work obeys the bounded policy, queue is coalesced and callback volume becomes quiet after settlement. Measure latency before making performance claims. |

Run core real-window checks on macOS 14.6, 15 and 26 if those versions are shipped/supported. Qualify Stage Manager, Mission Control and macOS native tiling settings explicitly on those versions. Until demonstrated, these transient modes must cancel/decline rearrangement or be documented as unsupported; do not invent a reliable detection signal without verifying it. No finite test matrix proves all apps or macOS versions.

## 11. Proof performed for this planning task

Ran:

```sh
python3 plans/proofs/run-auto-layout-model.py
```

Observed:

```text
Rectangle source commit: 18c058aa856afd3b09fc98a567dc492d2b981b85
Rectangle source SHA256: eb9ffd8fc166553775ec3046e8721ac8d93d10908827c635a96de7682d3f4c6b
PASS: 2406 deterministic geometry assertions; real Rectangle allocator + proposed tree adapter
NOT TESTED: AX writes, notifications, focus, native Desktops, live windows, rollback, third-party managers
```

The runner fetches the pinned upstream Swift source and prepends it to the proposed tree harness, then executes through the existing Swift toolchain in a temporary directory. No installs, repository app builds or app-window mutations occurred. Assertions cover group insertion/removal, exact pixel partition, minima/shortage, duplicate rejection, determinism and backing scales. Assertion count is not an app-compatibility count.

This validates the geometry approach for those fixtures. It does **not** prove trigger detection, AX frame application, concurrency, recovery or the finished feature. Those are required implementation gates, not implied successes.

## 12. Files in scope, stop conditions and final acceptance

In scope for implementation:

- New WindowLayout files and new Preferences tab/test files named above.
- `octopus/octopusApp.swift`: coordinator lifetime and dependency wiring.
- `PreferencesView.swift`: one new tab.
- `SidebarController.swift` and `SidebarDragController.swift`: explicit intent routing and shared busy/cancellation coordination.
- `SidebarWindowInventory.swift`: typed events, generation-safe snapshots, frame-only batch access and resource reservations.
- `SidebarWindowPlacement.swift`: explicit snap metadata or narrow reusable writer adaptation, preserving single-window behaviour when disabled.
- `SidebarSpaces.swift`: only scope-resolution additions demonstrably required by the spike.
- Existing focused tests when their callers' signatures change; project file only if automatic Xcode source discovery is insufficient.

Out of scope: changing sidebar visuals/hover/mouse bindings, keyboard-cycle semantics, Desktop transfer/focus internals beyond coordination, adding dependencies/daemons, disabling SIP, emulating workspaces, persistent live-window layouts, app-specific undocumented resize hacks, and unrelated refactors.

Stop and report if the baseline writer fails the exact requested half, scope cannot be established, normal-window identity cannot be proven, an observer change requires broad lifecycle refactoring, or proposed transaction budgets cannot accommodate normal supported apps. Do not stack speculative fixes or call the feature ready.

Acceptance checklist:

- [ ] All three requested dropdown modes and off/default behaviour work in the real app.
- [ ] First adoption includes all eligible normal windows in the exact scope; every later membership change follows the stated rules.
- [ ] Proposed production geometry is tested directly, including deterministic minima rejection.
- [ ] Requested and actual frames are checked end to end; failures cannot be reported as successful layouts.
- [ ] Self-events do not retile, a second tiler cannot cause an endless conflict loop, and unknown snapshots never remove live windows.
- [ ] Peer windows are never raised/restored merely to arrange them; focus is verified.
- [ ] Cancellation, guarded recovery, Undo and assistive behaviour pass live checks.
- [ ] Supported macOS/Space/display configurations have recorded results and remaining limitations.
- [ ] Only in-scope files changed and the actual diff is reviewed.

Maintenance: window inventory/Space API changes, writer settling rules, macOS native tiling and Preferences lifetime can all affect this feature. Keep policy in the planner/controller and AX effects in the reader/executor so those changes are independently testable.
