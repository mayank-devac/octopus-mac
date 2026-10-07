# Cross-Desktop focus, flicker, and minimise incident

Date: 2026-10-07 (Asia/Kolkata)

## Outcome and evidence

The sidebar focus path no longer sets the target window as main or raises it before requesting focus for that exact window. Icon minimise shortcuts and the popup window-action button now focus a window on another Desktop before allowing a later click to minimise it. The popup label/icon describes the focus action.

The final build was launched from this worktree's `.build/DerivedData/Build/Products/Debug/octopus.app`. Mayank tested both paths after launch and answered **“Both paths work without flicker”** to this explicit check: from another Desktop, first click focuses without minimising, the next click minimises, and the next restores. This is user-observed live verification; it is not an automated frame-by-frame recording or a guarantee for every macOS version and application.

The final Xcode result bundle independently reports **67 passed, 0 failed, 0 skipped**, with no reported runtime warnings, across `MouseShortcutTests`, `SidebarTests`, and `SidebarDragTests`. Those tests establish covered decisions and regressions, not the appearance of a Space transition.

## Original problem

Mayank reported that selecting an existing window on another Desktop briefly showed the app on the current Desktop, flickered, then switched to the Desktop containing the window. He clarified that this affected all apps he tried, not one particular application. The intended experience is to navigate to the existing window's Desktop and focus it without briefly surfacing it elsewhere or moving it between Desktops.

“Open” here means focus or restore an existing window. “Restore” means bring back a minimised window; it does not mean maximise its dimensions or enter full screen.

## Previous investigation: supplied history, not independently rerun

The following details came from Mayank's supplied investigation summary. Keep their provenance separate from the current source inspection and final verification:

- An earlier change added the Objective-C `SidebarWindowFocusRequest` bridge, the Swift `SidebarFocusActivation` helper, and focused tests in `SidebarDragTests.swift`.
- Builds and unit tests were reported as successful. They did not establish that the Desktop transition worked or that flicker was gone. Mayank reported that the attempted fix was actually worse.
- The bridge dynamically resolved private SkyLight/SLPS APIs to request focus for a specific PID/window ID. Successful symbol lookup or a successful request return did not establish the final focused window or active Desktop.
- Existing raises before and after activation remained in place, so adding the bridge had not replaced the full focus sequence.
- External probes failed to establish a reliable cross-Space transition: one could not find a suitable off-Space window, others had trouble identifying windows or mapping their Spaces, and one probe initially failed to compile.
- A probe reported `AX trusted=0`. That describes that probe's responsible process; it does not prove that Octopus itself lacked Accessibility permission.
- The earlier work consulted AltTab source, but that did not prove a working fix in Octopus.
- A proposed change to the synthetic event buffer and coordinates was not completed before the coding service hit a quota limit. This incident fix did not implement that proposed buffer change.
- Despite instructions to test in this repository without temporary probes or `osascript`, the reported investigation created scratch files under `/tmp/focusprobe`, later removed them, used `osascript` to launch TextEdit and create empty untitled documents, moved windows between Spaces, briefly switched the user's Desktop, and killed the TextEdit process it had launched. These side effects did not produce useful verification and must not be repeated.
- A separate earlier request concerned `defaultShadowOpacity = 1.15`; the supplied history did not show it implemented or verified. Current source inspection found `defaultShadowOpacity = 1`. Shadow styling was not changed as part of this focus fix.

## What current source inspection established

### Focus request ordering

`SidebarWindowReader.perform(.focus)` restored/unhid the target when necessary, then called `prepareWindowForActivation`. That helper set `AXMain` and performed `AXRaise`. Only after that did `requestForeground` yield activation and call `SidebarWindowFocusRequest`, with app activation as a fallback. A subsequent foreground-confirmed raise also remained.

Thus the early raise was a confirmed property of Octopus's code, not an inference about macOS internals. It preceded the exact-window focus request and could compete with that request during a Space transition. Removing that preparation from the `.focus` branch was the narrow candidate tested here. The final live result supports this correction for the reported sidebar issue; it does not independently diagnose the WindowServer's internal animation timing.

The early preparation helper remains in the placement path, which has separate current-Desktop eligibility checks. It was not globally removed.

### Minimise intent ignored Desktop visibility

After the focus change, Mayank reported another issue: the mapped minimise shortcut would first minimise a remote window; clicking again restored it and navigated to its Desktop.

`SidebarIconMousePolicy` checked only hidden/minimised state before returning `.minimize`. A normal off-Desktop window therefore qualified for minimisation. The popup's window-action button had the same omission. Mayank explicitly chose **“Focus first for the popup button too.”**

The ordinary focus/hide policy already considered visible windows. A new regression test includes an app that is already active while the selected window is remote, because matching the app's PID does not establish that this particular window is visible.

## Final behaviour

| Target state | Icon's mapped minimise shortcut / popup window-action button |
| --- | --- |
| Normal window on another Desktop | Focus that exact window; do not minimise it |
| Normal window on a visible Desktop | Minimise, subject to the existing eligibility checks |
| Minimised window | Restore and focus, subject to the existing restore checks |
| Hidden app/window | Show and focus, preserving existing eligibility checks |
| Closed or invalid target | Reject/refresh through the existing validation path; do not choose a replacement |

For multiple monitors, “visible” means on any currently visible Desktop, not necessarily the monitor containing the pointer. A covered window can still be on a visible Desktop. Shortcut assignments are preserved; this rule belongs to the mapped action, not a hard-coded left or right mouse button. Maximisation and desktop-transfer drags remain separate actions.

The action executor also rechecks live on-screen state before minimising. If a still-normal window has become off-screen while its action was queued, it routes through `.focus` for the same PID/window ID instead. That route repeats the existing validation and cancellation checks. Cached UI state is not treated as sufficient authority to minimise a remote target.

## Files and changes

- `octopus/UI/Sidebar/SidebarWindowInventory.swift`: removed the pre-activation main/raise preparation from `.focus`; added the live visibility check before `.minimize`; corrected the helper comment that previously promised a guaranteed Space-switch order.
- `octopus/UI/Sidebar/SidebarWindowPlacement.swift`: icon minimise policy now includes the selected window's off-screen state and focuses it first.
- `octopus/UI/CyclePanel/CyclePanelController.swift`: popup window-action callback focuses remote windows first, including eligible windows that cannot themselves be minimised.
- `octopus/UI/CyclePanel/CyclePanelView.swift`: remote normal windows display the focus arrow and “Focus” help/accessibility label instead of a minimise affordance.
- `octopus/UI/Sidebar/SidebarView.swift`: accessibility hints distinguish a normal remote window from a genuinely hidden/minimised window.
- `octopus/UI/Sidebar/SidebarWindowFocus.h` and `.m`: comments describe a request, not a guaranteed visible Desktop/key window; private event layout was unchanged.
- `octopusTests/MouseShortcutTests.swift`: added `remoteWindowClickFocusesBeforeMinimizingEvenWhenItsAppIsAlreadyActive`, covering remote active/inactive apps, focus/hide routing, subsequent local minimisation, and restoration.
- `octopusTests/SidebarDragTests.swift`: renamed an existing policy test to `windowTargetedFocusUsesWindowRequestBeforeAppFallback`; its old name incorrectly implied proof of visual Desktop ordering.

Pre-existing staged edits to preferences, settings, sidebar UI, the Swift bridging header, and the earlier focus bridge were preserved. This work did not commit, unstage, reset, or rewrite them.

## Verification procedure and results

1. Inspected the relevant project mistakes and drag notes, current source, and staged diff before editing. Queried project memory as navigation, then checked its foreground-restoration claim against source.
2. Confirmed the original running process came from the other checkout, `/Users/mayank/Desktop/mac/octopus/.build/DerivedData/Build/Products/Debug/octopus.app`. Its behaviour could not be assumed to represent this worktree's latest source.
3. Obtained explicit permission to build/test here and replace the running Octopus instance for the live test. Computer Use accessed the actual app; there were no standalone probes, `osascript` scripts, manufactured documents, or window-transfer experiments.
4. The first sandboxed build failed because Xcode could not write its Swift package diagnostic cache. It was retried with approval outside the sandbox. Build products and task logs were placed under this repository's ignored `.build` directory. Xcode itself also used its normal system caches and generated its own error-result bundle.
5. The initial focus candidate passed 24 `SidebarDragTests`. After the minimise/popup changes, the three focused suites passed 67 tests; the final UI-label revision was rebuilt and passed the same 67 tests.
6. Inspected the final Xcode result bundle with `xcresulttool`; confirmed the exact executed counts rather than relying only on `TEST SUCCEEDED`. Report-cache access required sandbox escalation.
7. Used Octopus's Quit menu, then launched the exact `.app` path from `windows_drag`. The post-quit inspection reported process-not-found, consistent with that app exiting; the subsequent launch returned the new sidebar with monitor headings and updated accessibility actions.
8. Computer Use performed a sidebar click during baseline inspection and a Control-Right Desktop-navigation attempt after the final launch. Settled AX snapshots alone did not prove either animation timing or the final Desktop, so those attempts were not counted as visual proof.
9. Mayank performed the final icon and popup sequence on the launched build and confirmed both paths worked without flicker. `git diff --check` also passed.

Final evidence (local ignored build artifacts; not committed):

- `.build/focus-sandbox-attempt.log`: initial sandbox failure.
- `.build/focus-verification.log`: the intermediate 67-test run; this log replaced the earlier 24-test run log.
- `.build/DerivedData/Logs/Test/Test-octopus-2026.10.07_19-15-47-+0530.xcresult`: initial 24-test result bundle.
- `.build/focus-final-verification.log`: final build/test log.
- `.build/DerivedData/Logs/Test/Test-octopus-2026.10.07_21-07-03-+0530.xcresult`: final result bundle, 67 passed / 0 failed / 0 skipped.

Reproduce the focused checks from this repository root:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
  -disableAutomaticPackageResolution \
  -only-testing:octopusTests/MouseShortcutTests \
  -only-testing:octopusTests/SidebarTests \
  -only-testing:octopusTests/SidebarDragTests test
```

Always obtain Mayank's authorisation before running builds/tests in a new task. This session's authorisation covered these runs.

## Permissions and limitations

- Octopus needs its own Accessibility authorisation to operate other applications' windows. A terminal/probe or editor's grant is not proof of Octopus's grant.
- The Computer Use tool needs access to Octopus for UI testing. If access is rejected, do not bypass it with another control mechanism.
- Screen Recording permission is relevant if recording the transition is chosen; it is not required merely to build or run ordinary unit tests. No frame-by-frame recording was made here.
- The private SkyLight/SLPS bridge remains version-sensitive. Its return value is not completion evidence, and the current bridge does not independently verify delivery of both synthetic key-window events.
- The follow-up raise still waits for app foreground confirmation, not a verified completion of the Desktop animation. We did not add arbitrary sleeps, change event-buffer bytes, or introduce a second Space-switch mechanism to promise stricter sequencing than the live evidence supports.
- Hidden/minimised remote windows keep the existing unhide/restore ordering. The manual confirmation covers the reported sequence, not every combination of full screen, modal sheets, permissions changing mid-action, multiple windows per app, or future macOS versions.
- Closed/stale targets, eligibility checks, expiry, and cancellation remain protected by existing validation. There is no automatic retry loop that repeatedly steals focus.

## Similar path found, intentionally left unchanged

`octopus/Models/Window.swift: Window.focus()` raises before activating the application and may reopen it on failure. The keyboard presentation of `CyclePanelController.activateSelectedWindow()` still uses that path; the sidebar presentation uses its dedicated validated path instead.

This is a similar ordering risk worth a separate reproduction, not a confirmed second bug. Replacing it here would expand scope and could change deliberate keyboard-launch behaviour. The existing placement path also retains early preparation, but it is constrained to eligible visible-Desktop placement. Neither was represented as newly verified by this sidebar test.

## Prevention rules

1. Trace the entire production click path before changing one helper: target selection, restoration, main-window writes, raises, activation, completion and fallback all matter.
2. Treat app activation, exact-window focus, minimise, restore, maximise and moving a window between Desktops as distinct operations.
3. Never minimise a remote window from these sidebar controls before focusing it; revalidate visibility immediately before the mutation as well as deciding the UI action.
4. Keep a specific PID/window ID throughout the action; reject a stale target instead of substituting another app window.
5. Verify the exact running executable and source checkout before attributing a result to a patch.
6. Passing helper tests, compilation and accepted private-API calls do not prove live Desktop behaviour. Confirm the actual icon and popup interaction on the built app, including the return click and restore.
7. When a candidate fails, reassess the evidence instead of stacking delays, synthetic-event changes or private APIs.
8. Respect repository-only testing and the prohibition on `osascript`/standalone scratch probes; obtain permission for desktop-affecting interaction and never infer one process's Accessibility grant from another's.
9. Keep UI labels consistent with the action: a button that navigates/focuses must not advertise minimisation.
10. Record provenance and limitations honestly. Finalise the incident report and durable lesson only after the agreed verification, and update stale memory rather than preserving an obsolete all-window activation rule.

## References consulted

- [Apple: activateAllWindows](https://developer.apple.com/documentation/appkit/nsapplication/activationoptions/activateallwindows): this option brings all of an application's windows forward; it is not proof of exact-window/Space completion.
- [yabai window manager source](https://github.com/asmvik/yabai/blob/master/src/window_manager.c#L1198): the inspected `window_manager_focus_window_with_raise` requests the target process/window and key-window events before the AX raise. Used to compare ordering; not evidence that Octopus works on every system. The linked branch can change.
- AltTab was referenced in the supplied prior investigation. Attempts to retrieve its cited source in this session failed, so no new AltTab implementation claim is based on those fetches.
