# Plan 005: Repair the staged adaptive window-layout contract

## Status
- Priority: P1; effort: M; risk: medium.
- Planned at: HEAD 954e3c7, 9 October 2026, plus the existing staged adaptive-layout diff.
- Scope: staged window-layout files and their direct callers/tests. Implementation is explicitly authorised by Mayank.
- Verification remains commands-only. Do not run a build, test, install, or GUI check without a new request.
- Implementation status: source repairs completed; actual combined diff reviewed. Build, focused suites and live acceptance have not been run by the assistant.

## Diagnosis and vetted findings
| Finding | Origin | Impact | Fix risk | Evidence |
| --- | --- | --- | --- | --- |
| HIGH: native writer replaces the executor's expected frame with a fresh one | Pre-existing in touched native adapter | An external move between validation and write can be overwritten | Medium: migrate the writer callback and all callers together | SidebarWindowInventory.swift writeLayoutWindow; WindowLayoutController.swift execute/undoAdjustment |
| HIGH: refused AX size writes can become learned app constraints | Introduced by staged learning over legacy adjusted flag | A transient provider error can poison layout and its cache | Low: classify failed/blocked setters before returning the result | WindowControlAccess.swift write; SidebarWindowPlacement.swift adjusted result |
| MEDIUM: balanced populations exclude feasible unequal column groups | Introduced by new allocator | A tall app may need its own column, while three shorter apps share another | Medium: keep existing shapes first, add a bounded constraint-aware shelf fallback | WindowLayoutAllocator.swift grouped/allocate |
| MEDIUM: numeric conversion and final-read cancellation need stronger guards | Introduced in staged allocator/executor | Malformed dimensions can trap; late cancellation can be reported as success | Low | PixelBounds/pixels; WindowLayoutExecutor.apply/restore |
| Resolved build mistakes | Earlier implementation | Old plan constructor and private nested-type extension prevented compilation | Already repaired; keep them covered in the verification gate | Owner's failed build output; current explicit PixelBounds initializer |

The old HEAD executor planned fixed halves and automatically restored touched peers after any mismatch. The staged executor instead learns bounds and moves the shared split, including the snapped window. Mayank approved shrinking that window only as much as required, and rejected the automatic bounce back. Preserve those decisions.

## Design and conventions
Swift AppKit/SwiftUI, Xcode project octopus.xcodeproj, scheme octopus, Swift Testing unit suites.
Native operations stay on SidebarWindowReader.queue. Window identity includes CG ID, PID and reader generation. Use one WindowControlBudget across preparation and writes. Do not select replacement windows, change inactive Desktops, launch apps, or parallelise writes to the same layout.

The important boundary becomes:
- read(identity) -> verified WindowLayoutWindow
- write(the exact verified WindowLayoutWindow, target frame, deadline) -> SidebarPlacementResult
WindowControlAccess.write owns fresh preflight/eligibility checks. The executor supplies its actual expected starting frame; no adapter substitutes another one.

## File-by-file steps
1. WindowLayoutExecutor.swift: pass the verified live window into the write callback for apply and restore; check cancellation/deadline after final readback. Add comments describing observation ownership and partial failure.
2. WindowLayoutController.swift: call WindowControlAccess directly with that snapshot and the shared budget; retain the current exact-identity metadata map for reads. Name cache lifetime/count limits. Keep input cancellation, Undo and notifications.
3. SidebarWindowInventory.swift: remove the redundant read/write layout adapters after tracing every caller. Retain reader-owned handle generations, queue, Spaces and caches.
4. WindowControlAccess.swift: share the two AX setter bookkeeping branches locally; return cancelled for failed safety checks and failed for refused native setters. Only successfully issued writes with a mismatching achieved frame may become learned size constraints.
5. WindowLayoutAllocator.swift: validate finite, nonnegative, representable bounds and unique identities before integer conversion. Preserve band/balanced-grid order, then try greedy contiguous shelf groups constrained by height and intersecting width limits. This is a bounded shelf solver, not exhaustive arbitrary rectangle packing.
6. WindowLayoutTests.swift: migrate writer callbacks; cover external movement, failed writes not being learned, late cancellation, malformed inputs, and an 800-high app beside a column of three 200-high apps.
7. Add explanatory comments above changed nontrivial functions, focusing on invariants and why fallback exists, not narrating syntax.

## Boundaries and limits
Do not refactor the entire 1,566-line inventory. HEAD already exceeds 1k; this diff reduces it, so the claim that the change crossed the threshold is rejected.
Do not weaken exact window/Space validation to improve apparent speed. AX changes across multiple apps are not atomic. If limits are impossible or identity/readback is uncertain, stop and report partial state without automatic rollback.
No security exploit was established; these are correctness, ownership and maintainability findings.
The original 650 ms clamp retry cost is real, but short stable observations are not proof of a minimum. Do not alter retry timing without further evidence.

## Verification commands and done criteria
Run only when authorised:
~~~sh
xcodebuild -project octopus.xcodeproj -scheme octopus \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-review-verification \
  -disableAutomaticPackageResolution \
  -only-testing:octopusTests/WindowLayoutTests \
  -only-testing:octopusTests/SidebarDragTests \
  -only-testing:octopusTests/SidebarDesktopTransferTests test
~~~
Expected: TEST SUCCEEDED, named suites execute nonzero tests.
Read-only check now: git diff HEAD --check (exit 0), and no conflict markers.
Live acceptance still required: reproduce the owner's 600 px clamp, cancellation, all-window grid fallback and Undo on the agreed display.
Stop if another task changes these files during implementation or a fix requires changing the decided gesture/Space behaviour.

## Review coverage
Reviewed staged layout changes against HEAD and their native reader, frame writer, pair and Undo callers. Not a whole-app security audit, dependency audit or live timing qualification. Earlier .agent reviews remain historical evidence, not proof that their findings still exist.

## Implemented repair ledger
- The executor supplies WindowLayoutWindow to apply/Undo writers. Controller calls WindowControlAccess directly; both redundant inventory adapters were removed.
- The native access boundary classifies refused setters as failed and blocked eligibility as cancelled. Console retains raw AX results; UI feedback stays in plain language.
- Allocator inputs are checked before integer conversion, including duplicate identities and malformed/oversized dimensions. Balanced shapes keep existing order, then a bounded height-aware shelf fallback handles unequal populations.
- Removed the unused allocation wrapper/column-count state and the unused Undo frame copy; frame maps are the direct shared result.
- Final readback rechecks cancellation/deadline. Cache lifetime/count caps are named and documented. Comments explain the native and layout invariants.
- Regression cases cover snapshot ownership, refused-write learning, late cancellation, numeric safety and unequal shelves. Test source was updated, but tests were not executed.
- Owner's compiler output exposed an ambiguous CGSize .nan literal in the new regression test; it is now explicitly CGFloat.nan. The reported local-monitor Sendable warning was repaired by returning Bool through MainActor.assumeIsolated, and its unused screen binding was replaced with an existence check.

## What was done wrong previously
The implementation grew into adaptive allocation while the executor/native frame contract still allowed a different starting frame to be substituted. Tests mostly used callback writers and did not qualify the real AX boundary. The earlier fixed-half executor restored a clamped window, producing the owner's visible bounce. Model/planner revisions were mixed during staging, and a private nested initializer was moved outside its accessible scope; both caused reported build failures. Diff checks were correctly reported as source checks, but they did not establish compilation or real-window smoothness.
The new malformed-input test also used an overloaded numeric shorthand that failed compilation. Explicit scalar types are required where CoreGraphics initializers have multiple overloads. No subsequent build/test success has been established in this turn.
