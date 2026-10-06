# Sidebar click: None, Hide, or Minimise

Status: IMPLEMENTED — build and 19 focused sidebar tests passed; Mayank chose to verify the rebuilt app manually; live cross-app confirmation remains pending.
Planned against commit `cc4cc0d`, clean working tree, on 2026-10-06.
Effort: medium. Main risk: changing sidebar inventory and restoration, rather than adding the setting.

## Implementation evidence

- [x] Saved None/Hide/Minimise preference, default Minimise, with invalid-value fallback.
- [x] Active-app icon minimises the verified focused window; background clicks activate; hidden/all-minimised entries restore first.
- [x] Hidden/minimised windows are discovered from the keyboard list's AX window enumeration, including at startup. The live identity registry is rebuilt after desktop changes; closed/terminated windows are removed.
- [x] Sidebar-only per-window Minimise/Restore buttons and an app-level Hide action; hidden apps offer Restore and disable Hide.
- [x] Off-main-thread AX work with the existing timeout, per-app in-flight guards, cancellation on desktop changes/stop/permission loss, and double-click suppression.
- [x] Final `xcodebuild ... -only-testing:octopusTests/SidebarTests test` built successfully and ran 19 passing tests. Log: `/tmp/octopus-sidebar-tests.log`; build output: `/tmp/octopus-sidebar-verification/Build/Products/Debug/octopus.app`.
- [x] Final source diff inspected; `git diff HEAD --check` passed.
- [ ] Live tests with other apps, modal dialogs, full screen, multiple monitors/desktops, and permission loss. Computer Use was previously not approved for octopus; Mayank subsequently chose manual verification of the rebuilt app. No alternative desktop-control route was used.

Follow-up UI fixes: restored the original title-row tap gesture instead of a title Button, removed sidebar button focus effects, added an immediate subtle button hover/press style, and kept the selected-row background separate from action feedback. Menu opening now shows the published inventory before requesting a background refresh. Snapshot scans use only the minimise capability hint; full modal/sheet/full-screen validation remains on the action path. Row and button hover now share one panel-level pointer-position path for mouse movement, dragging, and scrolling. Per-row tracking callbacks and SwiftUI onHover state were removed. Geometry is bounded with bounds.intersection(visibleRect), because unclipped NSViews on newer macOS versions can report a visibleRect covering other rows.

The isolated native layout test now renders the actual sidebar controls and verifies stable row bounds and correct title/button/footer hit regions while minimised/hidden states change. A proposed in-process button-press test was removed because the hidden SwiftUI fixture did not expose usable accessibility button nodes; it did not verify presses. Automated tests do not prove cross-app AX behaviour. The implementation must not be labelled production-ready until the live flows below are exercised.

## Follow-up: disappearing icons and jumping selection

- Keep a previously verified, still-enumerated AX window listed when Core Graphics visibility and AXMinimized temporarily disagree during Dock minimise/restore animations. New unknown off-screen windows still need the normal discovery rules.
- A failed AX window-list query preserves the last verified app entry; a successful empty list removes it. A failed role read can preserve only the same previously verified AX window, with duplicate IDs rejected.
- Clear this fallback state on desktop changes, permission loss, and stop; terminated apps and successfully enumerated closed windows are removed. All actions still revalidate the live target.
- Use one panel-level pointer target for both row selection and button hover feedback. Native row views provide geometry only; their stale mouse events cannot change selection.
- Intersect each row/footer's visibleRect with its own bounds. The native test reproduced row 2 being resolved as row 1 before this fix, and passes after it. Use the full row bounds to locate the action column even when clipping occurs.
- The sidebar passes mouse input through wherever its wide hit area overlaps the popup. Inventory refreshes no longer raise an already-visible sidebar above the popup.
- Regression coverage: inconsistent minimise/restore visibility snapshots keep the sidebar frame unchanged; native geometry resolves each row title, each action button, the footer, and points outside the menu correctly; stale row events cannot overwrite the current pointer target; overlapping sidebar/popup input belongs to the popup. The final focused suite has 19 passing tests; real Dock animation and rapid hovering still need live confirmation.

## Outcome and decisions

Add Preferences → Sidebar → “Clicking the active app” with `None`, `Hide`, and `Minimise`. Default: `Minimise`, including existing installations without a saved value. Explain that the setting changes only clicks on an app already in front. The default changes existing users' click behaviour; `None` restores today's activation behaviour.

Confirmed by Mayank:

1. Clicking the app icon minimises only its front window.
2. Hidden/minimised entries must remain available for restoration. Today's filtering would otherwise remove the app icon when its last visible window disappears.

Mayank confirmed that “menubar” means the sidebar hover window list and approved one Minimise/Restore button per window row plus one “Hide app” action for the whole app. Do not add Minimise all. Window-specific Minimise is possible; native Hide is app-wide, so a “Hide this window” action would be misleading.

## Original source at planning time and protected behaviour

- `octopus/UI/Sidebar/SidebarController.swift:229`: `activate(_:)` cancels hover work, dismisses the sidebar window menu, then calls `inventory.focus(entry.preferredID)`. Icons focus an existing window; they do not launch an app.
- `octopus/UI/Sidebar/SidebarSettings.swift:12`: register defaults through `UserDefaults.standard.register(defaults:)`. Match the existing raw-string enum pattern used for `SidebarSide`.
- `octopus/UI/Preferences/PreferencesSidebarView.swift`: preferences use `@AppStorage`; the footer explicitly excludes hidden apps/minimised windows, and the form has a fixed 375-point height.
- `octopus/UI/Sidebar/SidebarWindowInventory.swift:21`: eligibility currently requires `onScreen && normalLevel && standardWindow && !minimized && !hidden && !ownProcess`.
- Inventory discovery at line 286 first matches AX windows against an on-screen-only Core Graphics list. Simply removing the eligibility exclusions will not discover hidden/minimised windows.
- Inventory `focus(_:)` at line 167 and reader `raiseIfEligible(_:)` at line 366 reject hidden/minimised/off-screen targets. Restoration needs a separate validated path.
- Accessibility calls use the existing serial reader queue and a 0.2-second API timeout. Keep blocking calls off the main UI thread.
- Desktop changes invalidate pending snapshots through `desktopGeneration`. Preserve this protection for new click actions.
- Hover-menu window selection uses `onSidebarActivate` and the existing focus path. It must continue selecting a window, regardless of the icon-click preference. Keyboard shortcuts remain unchanged.
- `octopus/Models/Window.swift` has a focus fallback that can reopen an app; do not reuse that path for sidebar actions.
- `octopusTests/SidebarTests.swift` uses Swift Testing (`@Test`, `#expect`) and inert local AX handles. Follow that pattern without controlling other apps in automated tests.
- `octopus/UI/CyclePanel/CyclePanelView.swift:50` attaches activation to the whole row. New action buttons must not also fire that activation gesture.
- `octopus/UI/CyclePanel/CyclePanelController.swift:135` supplies the shared menu with `entry.windows`; its panel size is computed in `updatePanelSize()`. Account for any action footer in that calculation, including small-screen scrolling. The hover list shares its view/state with the keyboard switcher; controls must be explicitly sidebar-only.

No local `.agent` maps or AGENTS.md were found in the bounded file lookup. Project connector notes agree that sidebar activation should revalidate windows, stay app-agnostic, reuse the existing window menu, and avoid intentional interaction delays; these are also supported by the current source.

## Recommended behaviour

| Click-time state | Action |
| --- | --- |
| App is behind another app, with an eligible visible window | Existing preferred-window activation |
| App is already in front, setting None | Existing activation behaviour; no hide/minimise |
| App is already in front, setting Hide | Hide the app through `NSRunningApplication.hide()`; this affects the whole app, including its other desktops |
| App is already in front, setting Minimise | Minimise its currently focused eligible window, not a cached preferred window |
| Retained app is hidden | Unhide and focus its retained target; if that target is also minimised, restore it first |
| App has no eligible visible windows and a retained minimised target | Restore and focus that target, even if the app still reports itself as frontmost |
| App/window quit, closed, moved to another desktop, or permission was lost | Discard stale target and refresh; no substitute target |
| Minimise unsupported, a modal dialog is focused, or focused window is full screen | No minimise and no automatic Hide fallback |

“Clicked again” is based on live front-app/window state, not a double-click gesture or remembered last icon. Sample it before menu dismissal, then revalidate before mutation. An app can remain frontmost after its last window is minimised, so restoration must take precedence over the active-app action.

With multiple visible windows, minimising one may expose another window of the same app. A later completed click would minimise that new focused window. This is normal front-window behaviour, not an all-window toggle; confirm this consequence with Mayank if he expects one click to remove the entire app.

## Scope

Modify only:

- `octopus/UI/Sidebar/SidebarSettings.swift`
- `octopus/UI/Preferences/PreferencesSidebarView.swift`
- `octopus/UI/Sidebar/SidebarController.swift`
- `octopus/UI/Sidebar/SidebarWindowInventory.swift`
- `octopus/UI/Sidebar/SidebarView.swift` only if retained entries need a visual state indicator
- `octopus/UI/CyclePanel/CyclePanelView.swift` for sidebar-only menu controls
- `octopus/UI/CyclePanel/CyclePanelController.swift` for sidebar-only action callbacks and panel sizing
- `octopus/Models/CyclePanelState.swift` only if needed to carry sidebar window states while preserving keyboard presentation
- `octopusTests/SidebarTests.swift`

Preserve the keyboard switcher, profiles, bindings, generic Application/Window focus behaviour, existing visible-window discovery fallback, and sidebar positioning. No new dependency, permanent polling, deliberate delay, launch/reopen shortcut, commits, or publishing.

## Implementation order

### 1. Save and display the preference

Add a small enum such as `SidebarActiveAppClickAction` (`none`, `hide`, `minimize`) and key `sidebarActiveAppClickAction`. Register `minimize`, use the same default in `@AppStorage`, and parse missing/invalid values consistently. Add the picker and helper text. Include the preference in the controller's `Settings` and `matchesExceptAppSpacing` comparison so the spacing optimisation remains correct. Make sure the extra picker fits the preferences window; adjust the form height if necessary.

Inspect the resulting diff and preferences layout; no tests/builds until Mayank requests execution.

### 2. Retain restorable entries without breaking desktop scope

Keep a small in-memory set of previously verified sidebar windows and their app/window identities. Retain an entry when it becomes hidden or minimised and its AX window still exists, rather than treating every off-screen window as eligible. Remove closed/terminated entries and clear retained desktop membership on desktop change, inventory stop, or permission loss. Never use title/geometry matching alone to mutate a retained off-screen target; verify the retained AX identity and PID/window ID again.

Updated scope requested by Mayank: use the same AX window enumeration as the keyboard list to discover hidden/minimised windows directly, including at startup. Read all Core Graphics window metadata for exact-ID matching, while ordinary visible windows remain restricted to on-screen records. Verify AX ownership and roles. An authoritative AX ID must never fall back to another window's title/frame. Keep the previous verified AX identity only as a fallback when a restorable window has no reported ID or Core Graphics match. This is a live registry, not persistent session membership. Native activation/Spaces behaviour and AX availability remain app-dependent; do not forcibly move windows between desktops.

Keep visible eligibility separate from retained restorable membership. For the sidebar hover list, expose both visible and retained windows with explicit state, allowing a minimised row to offer Restore. Do not feed minimised targets into the old visible-only menu focus callback: route their selection through the validated restoration path. Allow an icon to exist with no visible windows; its title can use the retained title or app name. Preserve process-based app identity and stable ordering. The keyboard presentation must not inherit this sidebar-only membership change.

Inspect snapshots for visible, hidden, minimised, closed, and changed-desktop states. Do not simply relax `SidebarWindowPolicy.isEligible`.

### 3. Route icon clicks through validated actions

In the controller, close/cancel hover interaction and route icon clicks to one sidebar-specific action path. Retain the normal window-menu selection path.

Use live `NSWorkspace.shared.frontmostApplication` plus AX focused-window state. Revalidate target and desktop generation on the reader queue immediately before window mutation; check again before final main-thread activation. For Minimise, verify the window is ordinary, actually focused, not full screen, not minimised, and exposes a settable `kAXMinimizedAttribute`; set it to true and check the AX result. For restore, set it to false on the validated retained target, then raise and activate. For Hide, validate app state and check `hide()`'s Boolean result. Refresh after success or failure.

Ignore additional clicks for that app while its action is in flight, releasing the guard on every completion/error/cancellation. Do not queue a second minimise based on stale state. Keep the existing AX timeout and avoid retries/keyboard simulation. Represent unsupported/failure outcomes truthfully; choose a small existing UI feedback pattern if available, rather than showing success.

Inspect that no delayed action can minimise a newly switched-to window or reopen a closed app, and that restoration runs before the active-app branch.

### 4. Add controls to the sidebar hover list

Show a compact Minimise/Restore button on each window row and one clearly labelled “Hide app” action for the whole menu. Clicking a row title still focuses that window (restoring first if required); clicking its action button affects only that target and must not trigger the row's activate callback. Hovering alone never executes an action. Explicit menu actions are independent of the active-app icon-click preference, including when it is None.

Route these actions through the same inventory validation/AX queue used by icon actions. A menu Minimise targets the selected row's validated window rather than the app's focused window; it need not bring that window forward first. Check support/full-screen/modal safety for that target. An app-level Hide closes the menu; per-window actions refresh its state without recreating rows or resetting scroll/selection. Keep the app-name header hidden in sidebar mode; a Hide app action does not require reintroducing it.

Pass sidebar-only controls/callbacks explicitly into the shared CyclePanel view. Do not infer presentation solely from `showsHeader`. Adjust `updatePanelSize()` to include the action area's height and preserve screen-edge positioning. Check action button labels/tooltips and accessibility so their scope is clear. Inspect pointer tracking and hit testing: row hover selection must continue working over the added controls.

### 5. Verify the actual user flow

Add focused tests in `SidebarTests.swift` for the new behavioural rules: inactive app always activates, None preserves behaviour, active Minimise uses focused target, restore takes priority even with a frontmost app, unsupported/modal/full-screen targets are rejected, and stale/closed/desktop-changed retained entries are discarded. Keep tests simpler than the implementation; prefer the existing policy/state seams rather than a new general mocking framework. Update the visible-only eligibility test only if its actual contract changes; retained membership should be a separate policy.

When Mayank asks to run verification, use the existing shared octopus scheme and test target:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus -destination 'platform=macOS' -only-testing:octopusTests/SidebarTests test
```

Expected: focused SidebarTests pass, including the new behaviours. This command was derived from the checked-in scheme; it has not been run. The test target currently declares macOS 15.0; check the executor's host compatibility before running.

Manual checks remain required because policy tests cannot prove other apps' Accessibility behaviour:

1. One window: activate → minimise → icon remains → restore the same window and content.
2. Two windows: only the focused window minimises; the other remains; verify the documented next-click behaviour. In Hide mode all app windows hide, and clicking the retained icon restores the app.
3. Background app: icon activates it rather than hiding/minimising it. None always preserves the previous focus behaviour.
4. Quick repeated click, switch apps while AX work is pending, close target window, and quit target app: no wrong-window action or reopen.
5. Full screen and a save dialog: no forced exit or unexpected Hide fallback. Permission loss or an unresponsive target: octopus remains responsive and refreshes safely.
6. Desktop switch and two monitors: stale membership is cleared; actions don't unexpectedly move windows or restore a different desktop's target. Native Hide still has app-wide effects.
7. Change setting and restart octopus: saved selection persists; no saved selection defaults to Minimise. Apps already hidden/minimised must be discoverable without prior visible-window history, when their AX windows expose usable identities.
8. Hover-menu click/Enter and keyboard switching still focus selected windows.
9. Hover a multi-window app: minimise one chosen row without raising it, restore that row, and hide the whole app via Hide app. Row buttons never trigger title activation, list refresh preserves interaction, and no controls appear in keyboard-switcher mode. Check a small display with enough windows to scroll.

## Done criteria and stop conditions

- Preference shows all three choices, defaults to Minimise, and persists.
- Implement the confirmed individual window controls and app-level Hide; no Minimise all action.
- The actual minimise/hide → retained icon → restore flow succeeds on real apps.
- Accessibility work remains off the UI thread with the existing timeout.
- Focused tests pass when authorised; manual checks and limitations are reported separately.
- Only scoped source files change; inspect `git diff` before claiming completion.

Stop and ask if a target cannot be safely revalidated or if implementation requires changing the keyboard switcher's behaviour. Unsupported target apps are a bounded failure case, not a reason to add speculative fallback patches.

## macOS references

- [Apple: hide an application](https://developer.apple.com/documentation/appkit/nsrunningapplication/hide%28%29) — app-level action with a success/failure result.
- [Apple: AXMinimized](https://developer.apple.com/documentation/applicationservices/kaxminimizedattribute) — window-level minimised state.
- [Apple: AXUIElement APIs](https://developer.apple.com/documentation/applicationservices/axuielement) — check settable attributes and returned AX errors.

- [Apple: NSView clipping and visibleRect](https://developer.apple.com/documentation/appkit/nsview/clipstobounds) — explains why visibleRect must not be treated as the row's own hit bounds.
