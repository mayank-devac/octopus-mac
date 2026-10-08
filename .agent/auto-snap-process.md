# Auto-snap implementation: process, mistakes and evidence

Date: 8 October 2026, Asia/Kolkata. Project: `/Users/mayank/Desktop/mac/windows_drag`.

This is an account of the work in this chat, not a claim that the feature is production-ready. The source reviewed at the end is commit `17a248e`. The reliability/maintainability review is in [auto-snap-review.md](auto-snap-review.md). Existing historical notes remain intact.

## The story and final product decision

The conversation began with a Git request. The actual worktree branch was `newfeature_drag`, although the user called it features_drag. Thirteen already-committed changes were fast-forwarded into local `main`, ending at `db25387`. No network push happened: the repository had no remote, and the assistant asked for a repository URL. At this review, `main` still resolves to `db25387`; the newer auto-snap work is on the feature branch.

Mayank then asked for automatic adjustment of other windows when a new window is snapped, informed by yabai, AeroSpace, Rectangle and AltTab. The initial planning questions led to a broader proposal with three trigger modes and AeroSpace-like new-window insertion. That was genuinely requested at that point; the later reduction in scope was a legitimate product change, not a user mistake.

During implementation Mayank clarified the essential behaviour: **the icon drag and single-window snap already exist; add a follow-up arrangement of the destination Desktop's other windows.** A dragged window moving from one monitor to another should occupy the chosen half on the destination, while a companion occupies the opposite half. Source-display windows should remain unchanged.

The final scope is:

- React to successful **Octopus snaps only**. Other-tool detection and automatic insertion on window creation are outside this implementation.
- New Preferences tab: **Snap**. Adjustment is **enabled by default**.
- **Adjust** dropdown: **Most recently used other window** (default), or **All other normal windows**.
- In all-window mode, left/right snaps arrange companions vertically in the remaining half; top/bottom snaps arrange them horizontally.
- Top-edge drag selects **top half**. Corners allow **free movement**. Explicit Maximise remains a named action and does not rearrange companions.
- If companions cannot fit, preserve the user's already-completed snap and explain the failure.
- Undo restores only the companions, subject to identity/scope/frame checks; it does not move the snapped window back to its source display.

This scope supersedes the original tree/three-trigger proposal in `plans/003-auto-window-layout.md`.

## Prompts and decisions, in order

The table records the important prompts and answers; quotation marks denote short verbatim selections, while other descriptions are paraphrases.

| Stage | User prompt or answer | Effect on the work |
| --- | --- | --- |
| Git | Push committed worktree changes to main | Updated local main; online push remained unavailable without a remote. |
| Research | Add auto snap so other apps are shown properly; read four reference projects; provide a reliable, robust plan | Inspected the existing drag/writer path and reference source. |
| Proof | Invoked `principle-prove-it-works` and requested fact-based verification | Kept planning geometry proof separate from live app behaviour. |
| Initial trigger choice | Add a dropdown for all three proposed trigger modes | Initial plan covered Octopus snaps, recognised external snaps and window creation. |
| Initial participation | All normal windows on that display and Desktop | Planned exact physical-display/native-Space boundaries. |
| New-window behaviour | “like aerospace” | Investigated actual MRU-parent insertion rather than assuming a local rectangle split. |
| Implementation | Implement the entire plan, consider real UX, ask for decisions, copy/read reference code if useful | Started settings/model/writer/controller work and focused checks. |
| Corners/default | Free movement in corner areas; enable Octopus-only adjustment by default | Removed quarter targets and adopted an enabled default. |
| Failure behaviour | Keep the basic snap and explain why neighbour adjustment failed | Primary placement is preserved on companion failure. |
| First top-edge choice | Keep top-edge maximise | This was subsequently superseded by the explicit top-half example. |
| Scope correction | “how to snap … is already coded”; add adjustment after snapping | Separated native placement from companion arrangement. |
| Trigger cut | Only adjust after an Octopus snap for now | Removed the unused external/new-window modes and tree machinery. |
| Cross-display example | Drag an icon from one monitor to another; top half should put the other window in bottom half | Added top-half edge behaviour and destination-only arrangement. |
| First companion choice | Adjust only the most recently used other window | Set recent mode as the default. |
| Final companion choice | Put both recent/all choices in a settings dropdown | Implemented both affected-window options; this is not the old trigger-mode dropdown. |
| Build feedback | Supplied a missing-controller compilation error | Checked actual Xcode discovery/build output instead of assuming the file was included. |
| Live feedback | Works, but fluctuates, feels unrefined, and delays increase with many apps | Revisited the runtime path and repeated AX reads. |
| Clarification | Crowded-Desktop issue in most-recent mode; companion initially identified as fluctuating | Narrowed performance work to candidate selection and companion writes. |
| Additional scope approval | Approved changing `octopus/Models/AXUIElement.swift` | Added bulk position/size reads with a fallback for unsupported bulk calls. |
| Further live feedback | The dragged window also flickers; read four `.agent` notes | Rechecked the placement focus order and removed its pre-focus main/raise preparation. |
| Validation boundary | Clicks interfered with focus on another monitor; “just do the tests needed” | Stopped UI automation and finished with focused automated checks. |
| Retrospective | Summary, both strict review skills, MCP memories and mistakes.md | Wrote this account and the separate review; recorded durable lessons. |

## What was implemented

`SidebarDragController` continues to calculate the native preview/drop frame and submit `.place`. `SidebarPlacementRequest` now carries snap intent. A successful, unadjusted placement emits a completion containing the exact window and action timestamp. One app-owned `WindowLayoutController` receives it, validates the destination, selects companions, plans their frames and invokes frame-only writes.

Responsibilities are currently divided as follows:

- `WindowLayoutSettings.swift`: enabled flag and recent/all selection.
- `WindowLayoutModel.swift`: identities/generations, scope, candidates, snapshots, plan and cancellation token.
- `WindowLayoutPlanner.swift`: opposite-half geometry, candidate selection, minimum/readability checks.
- `WindowLayoutExecutor.swift`: guarded writes, final frame checks and best-effort recovery.
- `WindowLayoutController.swift`: lifecycle, scheduling, action ordering, cancellation, status and Undo.
- `SidebarWindowInventory.swift`: native notifications, AX handle resolution, live metadata, frame writes and focus integration.
- `AXUIElement.swift`: bulk frame read and checked value decoding.
- `PreferencesWindowLayoutView.swift`/`PreferencesView.swift`: new Snap settings.

The final performance pass removed the full inventory read from each companion adjustment and the fixed 150 ms scheduling wait. Fresh Core Graphics data scopes the candidates, while most-recent selection ordinarily asks for one companion's AX metadata. Startup/focus tracking subscribes at the app level rather than enumerating all windows. Geometry remains a live read; it is not trusted from a frame cache.

The companion writer uses one initial size write followed by position on the same display, then bounded readback. Repeated reachable old frames no longer immediately trigger another companion resize. The dragged target retains the original cross-display writer's protective sequence.

The placement branch previously called an early AXMain/AXRaise preparation before the exact-window focus request. That was removed, retaining the existing focus-first and follow-up-raise flow. This is a source change addressing the known ordering hazard; it is **not** new proof of a flicker-free transition.

## What was done wrong and what did not work

| Mistake or failed approach | What actually happened | Lesson |
| --- | --- | --- |
| Too much design before a concrete two-window example | A tree-based three-trigger design and prototype preceded the user's repeated clarification that the drag already existed. Some breadth matched earlier answers, but the assistant did not narrow quickly enough. | First state a real gesture, destination, affected windows and failure behaviour. Reconfirm after a scope change. |
| The baseline live gate was not fully completed | The plan required real cross-app/cross-display baseline checks before batch implementation. That full matrix was not demonstrated before development proceeded. | Mark an unmet gate explicitly; do not quietly substitute source inspection or fixtures for it. |
| Expensive first implementation | It reread the entire inventory after each snap and repeated capability/minimum/state queries around frame writes. | Separate cheap candidate discovery from expensive metadata; validate the selected windows, not every app. |
| Fixed waiting instead of readiness | A 150 ms delay was added to allow activation to settle. It contributed latency without proving readiness. | Use actual identity/scope/frame evidence and bounded failure handling. Avoid arbitrary UX delays. |
| Redundant companion resizing | The cross-display size–position–size policy was reused for companions already on the destination display, with heavy checks between writes. | Preserve necessary cross-display safeguards; use the smallest verified same-display sequence. |
| Focus ordering remained inconsistent | The previously fixed click-focus path was focus-first, but placement still had an early main/raise step. | Trace the complete placement-to-focus chain, not just the shared activation helper. |
| A patch hit the wrong declaration | Snap metadata initially landed on `SidebarPlacementTarget` instead of `SidebarPlacementRequest`; inspection caught it. Some patch attempts were rejected due to invalid/misaligned hunks. | Use struct/function-qualified patch context and inspect the actual artifact immediately. |
| A real compile type error | A Core Graphics window-order dictionary was indexed with `SidebarWindowID` rather than its `windowID`. | Keep PID/window composite identities distinct from raw CG IDs; compile before asking the user to test. |
| The user's missing-controller build error was not a verified single root cause | Files were being created during development; the later own build included the controller, and separately exposed the raw-ID mismatch. | Do not blame the user's build or claim a proven root cause without matching the exact source/build snapshot. |
| Multiple running builds confused observation | Both `/tmp/octopus-auto-layout/.../octopus.app` and the workspace `.build/DerivedData/.../octopus.app` were running. | Verify executable provenance and use one known build for a live check. |
| UI checks were not coordinated with normal user activity | Elements became invalid while monitor focus, sidebar projection and settings changed. More clicks/restarts were attempted before the user asked to stop. | Normal user focus changes are expected, not user error. Coordinate a test window/time or stop and use the accepted validation boundary. |
| New fast-path failure was not fully diagnosed live | The running UI reported an unverified-window/location failure. Diagnostic messages became more specific, but the user then explained monitor-focus interference and stopped UI automation. | Record an unresolved observation as unresolved. Do not assign it to either the provider or focus with certainty. |
| Test volume could have implied more than it proved | The planning prototype passed 2,406 assertions, but it did not control real windows. Production tests passed while the user still reported bugs. | Counts prove the cases that ran, not polished UX or broad app compatibility. |
| New code increased structural debt | The already-large inventory file grew by 259 lines, and another reader/controller path was added. | Put a clean window-control boundary in place; passing tests do not justify indefinite file growth. |

There were no new app dependencies added. Xcode did resolve existing Sparkle/KeyboardShortcuts packages in the chosen derived-data directory; an initial sandbox restriction prevented package-manifest diagnostics from being written, so the authorised build was rerun with access to the existing Xcode caches. System-log/result-bundle readers also encountered sandbox restrictions. These were tool/environment limitations, not feature bugs.

## Reference knowledge gained

- **yabai:** layouts are explicit relationships, not guesses from overlapping frames. Its frame writer also explains the two-sided display-clamping problem. It warns against treating delayed AX frame events as an always-current cache.
- **AeroSpace:** new windows join the most recent tiled window's parent after that window, rather than always splitting only that window's rectangle. It uses its own workspace model; copying that model into native-Space Octopus would be a much larger product change.
- **Rectangle:** validates actual achieved frames and size constraints, handles coordinate/work-area conversion and brackets frame changes with its Enhanced UI policy. Its cross-display sequence is relevant; its policy must not be copied blindly into unrelated same-display work.
- **AltTab:** failed AX reads are uncertainty, not proof of closure; window/observer/process generations and bounded recovery matter. It is a lifecycle reference rather than a geometry engine.
- **Apple's bulk AX contract:** a successful call can still contain per-attribute errors or CFNull. The independent review verified this against the installed SDK header. The current implementation has not fully handled that contract; see review finding R1.

No entire reference window manager was vendored as part of this feature. The planning runner fetched pinned Rectangle geometry source into a temporary harness. The final simple companion planner is not the discarded tree prototype.

## Preferences applied

Use plain language and short progress updates; ask practical product questions; preserve the existing drag/click/transfer behaviours; do not spawn routine coding agents; inspect relevant `.agent` notes and source; preserve unrelated Git work; avoid secret-bearing files; do not introduce dependencies or broad refactors merely to appear thorough.

Tests/builds were explicitly authorised for the implementation. UI automation was stopped when Mayank requested tests only. One independent read-only critic was used in the later review because the explicitly invoked red-alert skill calls for it; no subagent edits were integrated.

The agent did not commit, unstage or rewrite the user's changes. The feature source appeared in commits `2bf819c`, `2798b09` and `17a248e` during the conversation; those commit operations were not performed by the assistant.

## Verification: what is established and what is not

| Evidence | Established | Does not establish |
| --- | --- | --- |
| Planning harness: 2,406 assertions | Pinned Rectangle allocator plus proposed tree adapter passed deterministic geometry fixtures | Final production code, AX calls, focus or live app compatibility |
| Initial focused bundle | 109 tests / 112 parameterised executions, zero failures/skips | Visual smoothness |
| Optimised broader bundle | 114 tests / 117 executions, zero failures/skips | All AX-provider representations or all real-world races |
| Final focused bundle | 48 tests / 51 executions, zero failures/skips | End-to-end latency or absence of cross-display flicker |
| Live settings observation | Snap tab, enabled default, recent/all labels and named top-half actions were present | Every dropdown behaviour was exercised live |
| One live companion observation | Blank TextEdit window reached a 1920 × 525 half-height size; UI reported adjustment and offered Undo | Reliable mixed-display behaviour across repeated gestures |
| User cross-display feedback | The feature moved companions as intended in the user's test | A clean pass: the same feedback reported delay/fluctuation and crowded-Desktop bugs |

Result bundles: `/tmp/octopus-auto-layout-focused-tests.xcresult`, `/tmp/octopus-auto-layout-optimized-tests.xcresult`, `/tmp/octopus-auto-layout-final-focused-tests.xcresult`. Counts above come from the actual result summaries observed in this chat, not new test runs during this documentation request. These temporary artifacts may later be removed.

The 100-candidate test counts **planner metadata callbacks**. It is not a measured AX-call total or a benchmark of one hundred real apps. No end-to-end latency measurements were established.

A blank TextEdit document was created for a live check; existing document contents were not edited. Final cleanup of that blank document was not confirmed after the user stopped UI automation. Do not close or terminate user-owned documents to manufacture a clean test state.

Current conclusion: implementation and focused checks exist, but final visual smoothness is unverified and the review found outstanding defects. Do not describe this rollout as production-ready.

## Rules to carry forward

1. Start with a concrete two-window, two-display example; define display versus native Desktop explicitly.
2. Keep source-proven changes, user observations, hypotheses and automated fixtures separate in reports.
3. Preserve exact PID/window identity captured at press; never substitute another window if a handle disappears.
4. Measure discovery, metadata, writes and readback separately before adding delays or parallel workers.
5. Test the real AX payload boundary, including optional CFNull/error values and unsupported bulk calls.
6. Keep all normal-window admission separate from CG visibility; a layer-zero surface is not automatically an eligible AX window.
7. A post-write observation is not proof that Octopus owns that change; recovery must not erase an external update.
8. Apply safety checks at the mutation boundary, and budget/cancel preparation as well as writes.
9. Fix the whole focus sequence. Never reintroduce an early AXMain/AXRaise before targeted focus without a demonstrated need.
10. Stop UI automation when requested. Do not bypass that boundary with osascript, synthetic events or standalone probes.
11. Preserve the most recent accepted scope and separate historical plans from implementation instructions.
12. Review structural growth and actual provider integration before claiming success from test counts.
