# Auto-snap: adversarial and strict code-quality review

Date: 8 October 2026. Reviewed source: `17a248e`, compared with feature baseline `db25387`.

**Verdict: do not treat this feature as production-ready.** Passing fixture tests do not close the provider, recovery, lifecycle and topology gaps below. This request is documentation-only; these findings were not fixed here.

Scope: the new WindowLayout code, its native reader/writer integration, shared frame decoding, relevant tests and the three feature commits. This was not a security audit of the entire app. No new builds/tests or UI actions were run for this review. No CRITICAL or externally exploitable security flaw was established in the inspected path.

Method: the main agent performed the strict structural review and verified the findings. A separate `gpt-5.6-luna` critic reviewed the bounded source independently using red-alert. Its claims were treated as leads, not authority; one claim was disproved and others were qualified below.

## Strict maintainability findings

### Q1 — HIGH: feature integration enlarges an already incohesive native inventory

**Evidence:** `octopus/UI/Sidebar/SidebarWindowInventory.swift` is **1,669 lines**, up from **1,410** at `db25387`. The new focus tracking, candidate discovery, capability reads, bulk-state parser and frame writes occupy roughly lines 1050–1292. `WindowLayoutController.swift:12–14` directly constructs that reader plus a second inventory/drag controller for feedback. `SidebarController.swift:62–65` already constructs a separate inventory per sidebar display.

This did **not** cross from below 1,000 lines to above it; the file was already over the threshold. The regression is adding 259 net lines and another responsibility mode to it, while making the formerly private reader an internal dependency of the new feature. Queue ownership, observer state, recency and handle generations now span several independent instances. The same eligibility, identity, scope and provider rules are implemented through multiple paths: `validatedWindow`, `placementTarget`, `layoutWindow`, `currentLayoutWindow`, and `layoutIdentityIsCurrent`.

**Code-judo remedy:** establish one focused window-control access boundary with typed `read candidate / read current state / write frame` operations. Keep sidebar projection and visual interaction in sidebar code. Reuse that access layer from the layout coordinator rather than borrowing an entire inventory implementation and growing it. This is more useful than moving the same 1,669-line class into another file. Extract a small feedback presenter so showing a message does not require an unused inventory and full drag controller.

**Proof required:** existing exact-window/focus/transfer tests remain unchanged in behaviour; each source event has one owner; observer/candidate read counts remain bounded. This is a recommended follow-up, not permission to perform a broad refactor in this review.

### Q2 — MEDIUM: contracts hide policy behind flags and nominal safety metadata

**Evidence:** `SidebarWindowPlacement.swift:167,206,223,241` uses `repeatSizeAfterMove` to control both the extra size write and the cross-display landing step. `acceptStableMismatch` separately changes settling. `WindowLayoutExecutor.swift:13,56` changes overlap validation using `restoring`. `WindowLayoutPlan.desktopGeneration` is stored but is not itself checked by the executor. `WindowLayoutController.swift:35–40,241–250` uses the same cancellation routine to stop pending work, clear status and invalidate Undo.

These are different policies/lifetimes compressed into incidental Boolean combinations and a broad reset. A future caller can reasonably misunderstand what disabling a repeated resize also disables. A named generation field can look like enforced protection even when the actual protection comes from a separate controller token.

**Remedy:** represent the two deliberate placement intents clearly—cross-display primary placement and same-display companion adjustment—and document their required guarantees. Separate cancellation of pending work from invalidation of a committed Undo record. Remove unused metadata or enforce its invariant. Do not add a generic state-machine framework; delete the ambiguous combinations.

## Reliability red-team findings

### R1 — HIGH: successful bulk AX results with optional CFNull values are rejected

**Evidence:** `SidebarWindowInventory.swift:1214–1236` recognises optional unsupported values only when they are AXValue-wrapped errors. `CFNull` is not recognised. A missing `AXSubrole`, `AXSheets` or optional Boolean therefore produces `nil` and rejects a window even when initial individual reads accepted it. `AXUIElement.swift:49–54` similarly returns the failed decode immediately on an outer success, without examining a recoverable unsupported slot for its fallback policy.

The installed Apple SDK's `AXUIElement.h:225–244` explicitly permits CFNull/error entries in a successful bulk response. This was verified directly in the SDK, independently of the critic's claim. Public API reference: [AXUIElementCopyMultipleAttributeValues](https://developer.apple.com/documentation/applicationservices/1462051-axuielementcopymultipleattribute).

**Trigger:** a valid normal AX window omits a supported-optional field and returns CFNull in that slot. `layoutWindow` defaults an individually unsupported field, then `currentLayoutWindow` rejects the bulk representation of the same absence. Adjustment stops before a peer write.

**Remedy:** one typed decoder should distinguish value, optional absence, unsupported capability, transient failure and invalid element. Preserve defaults for genuinely optional absence; required identity/geometry failures must remain failures. Permit a narrow individual-read fallback when a provider reports unsupported bulk/slots, not for every timeout. Add tests through the bulk-reader boundary, not only `decodeWindowFrame` with already-extracted AXValues.

**Confidence:** high, API contract and source branch verified. This does not establish that CFNull caused the particular live failure seen in the chat.

### R2 — HIGH: the advertised batch budget starts after potentially slow preparation

**Evidence:** `WindowLayoutController.swift:117–133` prepares the snapshot before calling the executor. `WindowLayoutExecutor.swift:14` starts its four-second clock only then. `SidebarWindowInventory.swift:1145–1148` can enumerate an app's windows and query each window ID; `1154–1175,1188–1201` perform state, frame, minimum and Space reads. Snapshot/candidate callbacks receive no shared deadline or cancellation predicate.

**Trigger:** the selected app has many windows, responds slowly, or many highest-ranked candidates must be excluded. The token may be cancelled while preparation continues making reads on the serial queue. The four-second write budget does not bound that time. A planning test with 100 readily accepted DTO candidates says nothing about these provider calls.

**Impact:** delay/resource use can remain large in the very crowded-Desktop case the feature was intended to improve; a cancelled job can delay the next job.

**Remedy:** capture a whole-request deadline before preparation, pass it and cancellation into handle resolution/metadata loops, check them between calls and abandon an expired intent. Retain per-call timeouts, but do not mistake them for an operation-wide budget. Add a slow-provider/cancelled-preparation test with an injected clock and call counter.

**Confidence:** high for missing preparation budget; actual worst-case latency was not measured.

### R3 — HIGH: recovery can overwrite a change made by another actor

**Evidence:** `WindowLayoutExecutor.swift:40–44` records any post-write live frame, including a mismatching one, into `observed`. Lines 68–73 restore the original frame if the current frame still equals that observation. That comparison proves stability, not ownership.

**Constructed trigger:** a write fails or partially applies; another tiler/app changes the peer without mouse/key input or a focus change; the first post-write read sees that external frame. The batch token remains current. Recovery reads the same external frame and overwrites it with the old original frame. This follows the existing callback flow; no external app was driven to reproduce it during this review.

`userInterruptionPreventsRecoveryOverTheUsersMove` changes the cancellation Boolean to false, so it does not cover an external mutation that leaves the token valid.

**Remedy:** do not infer write ownership from an arbitrary observed frame. Track which expected write was acknowledged, and decline automatic recovery when ownership is ambiguous; offer explicit guarded Undo instead. Include a callback test where an external change occurs but cancellation stays true. macOS cannot make several AX updates atomic, so the policy must be honest about partial state.

**Confidence:** high for the source-level counterexample; not a newly observed live user overwrite.

### R4 — MEDIUM: CG surface admission and AX normal-window admission are conflated

**Evidence:** `SidebarWindowInventory.swift:1110–1136` admits visible layer-zero surfaces from regular apps before proving they are normal AX windows. Handle resolution returns only Bool (`1141–1151`); `WindowLayoutPlanner.swift:15–17` treats any failed read as a globally incomplete snapshot and stops.

**Trigger:** a layer-zero auxiliary/dialog/backing surface on the destination Space ranks before a valid companion, but has no matching AXWindows entry or fails the normal-subrole validation. Its known ineligibility is represented the same way as a timed-out normal window. Recent mode can decline rather than continue to a normal candidate; all mode can lose the entire arrangement.

**Remedy:** return typed candidate outcomes: eligible normal window, verified non-normal surface, and unknown/failed read. Skip verified non-normal surfaces; fail conservatively for unknown required participants. Reuse the established normal-window admission policy. Test a real-like CG fixture containing a dialog/backing surface before a normal window.

**Confidence:** high for the branch behaviour, medium for frequency. This is not assigned as the cause of monitor-focus interference reported by Mayank.

### R5 — MEDIUM: mutation-time checks omit fresh safety-state eligibility

**Evidence:** `SidebarWindowInventory.swift:1270–1289` checks `currentLayoutWindow(...).eligible` once at writer entry. Each setter's `stillInScope` checks token/identity/display/Space through `layoutIdentityIsCurrent`, but not current minimised/modal/sheet/fullscreen state or move/resize capability.

**Trigger:** an app opens a sheet or changes its window state automatically during the writer's settling/retry period, without an input event cancelling the token. A later setter can still operate on that window if AX accepts it.

**Remedy:** recheck the small necessary safety-state set before each new write attempt, while keeping metadata reads batched and avoiding full-inventory scans. Do not solve this by reinstating all expensive reads around every setter. Test state change during settling, independently of token cancellation.

**Confidence:** high for missing checks; whether a particular toolkit rejects the write itself is provider-dependent.

### R6 — MEDIUM: focus-subscription refresh drops lifecycle changes during an active refresh

**Evidence:** `WindowLayoutController.swift:55–61,80–88` calls `refreshTracking` on launch/termination, but `trackingRefreshQueued` causes a new request to be discarded. The in-flight refresh uses the captured application list and merely clears the flag when done. `SidebarWindowInventory.swift:1051–1059` installs subscriptions only for that list.

**Trigger:** app B starts while the startup/earlier subscription refresh is queued. The B refresh is discarded. B's activation may record one focused window, but the initial task never subscribes to B's focus notifications. Subsequent same-app window switches may leave recency stale until another lifecycle refresh occurs.

**Remedy:** coalesce with a dirty/follow-up flag and reconcile once after the active refresh, as the existing sidebar inventory's refresh mechanism already does. Capture the activation notification's app identity rather than reading whichever app is frontmost when the deferred Task eventually executes. Add a lifecycle ordering test.

**Confidence:** high for lost refresh; incorrect MRU choice is timing-dependent.

### R7 — MEDIUM: current topology/work area is not revalidated at the setter boundary

**Evidence:** `WindowLayoutController.swift:42–43` defers screen-change cancellation through a Task. Displays/work area are captured at `114,126`. `SidebarWindowInventory.swift:1243–1258` validates physical bounds against that old display array and does not compare a fresh work area or enforced topology generation.

**Trigger:** screen arrangement/work-area changes between the snapshot and a setter, before cancellation reaches the worker. Live Space/owner checks reduce the risk, but can still agree while the old work area is no longer correct.

**Remedy:** promptly cancel the thread-safe token from the main-thread screen-change callback and enforce a topology/work-area version at the write boundary. A currently running AX call cannot be revoked; document that remaining limit rather than promise atomicity.

**Confidence:** medium, narrow timing race. Not reproduced during this review.

## Findings considered and rejected or qualified

- **“Undo stays enabled after validation failure” — rejected.** `undoAdjustment` calls `cancel()` at line 184; that clears `undo` and `canUndo` at 248–249 before validation. The independent reviewer missed this call chain.
- **“Every late anchor failure must roll back peers” — qualified, not listed as an unconditional defect.** Executor line 48 deliberately returns a partial-state message before recovery. This is inconsistent with some other failure paths, but conservative avoidance of further writes after an uncertain anchor can be a valid policy. Specify the policy and test it; do not automatically “fix” it by restoring more windows.
- **“The change crosses the 1k-line threshold” — rejected wording.** It grows an already-oversized file from 1,410 to 1,669; the structural criticism remains, but the threshold claim would be false.
- **“Passing 2,406 assertions proves the shipped feature” — rejected.** Those were planning prototype assertions against an external allocator/tree adapter that the final feature does not use.
- **“Monitor-focus interference proves a provider defect” — rejected.** Both invalid UI indices and an unverified-window result occurred. The final user request stopped UI automation; their causal relationship was not established.
- **“The app reopens windows during snapping” — not established.** The inspected path restores/unhides existing targets when needed and requests focus; it does not launch an app to manufacture a window. Flicker can come from ordering/animation without a reopen.

## Recommended repair order and approval bar

1. Correct the AX boundary contract (CFNull/error slots/fallback) and add provider-level tests.
2. Add preparation deadlines/cancellation and resolve candidate classification without rebuilding the full inventory per snap.
3. Make recovery ownership explicit; add the uncancelled-external-change counterexample.
4. Test lifecycle refresh ordering and mutation-time eligibility/topology changes.
5. Establish a focused access-layer boundary and small feedback presenter; preserve existing drag/focus/transfer behaviours throughout.
6. At a user-authorised time, qualify the actual supported app/display matrix and measure latency. Do not resume UI automation under the earlier permission after the user stopped it.

Use the existing focused suites and the smallest missing boundary/race tests. No new dependency, daemon, workspace emulation, global retile loop, or repository-wide cleanup is justified by these findings. Approval requires the major contract/recovery gaps to be closed and the remaining live limits to be explicit.
