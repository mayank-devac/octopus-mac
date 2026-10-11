# Plan 007: Reopen a running sidebar app with no windows

## Status and final decision

Implemented on 11 October 2026. **Mayank confirmed that the rebuilt sidebar opens a windowless app without an Automation prompt.** The final build and **77 focused sidebar/mouse tests passed**, with zero failures/skips and no result-bundle runtime warnings.

Mayank approved using the centred menu's system reopening route and accepted that macOS may relaunch the app if it quits during the request. This supersedes the earlier strict PID-only/Automation design.

The sidebar now calls the existing `Application.reopen()` helper backed by `NSWorkspace.openApplication`. The centred menu remains unchanged. No per-target Automation setup is required; normal Accessibility permission is still required for sidebar window control.

## Files and implementation

### octopus/UI/Sidebar/SidebarWindowInventory.swift

- Keep three window states: confirmed empty, existing and unknown. Use a fresh AX window list and revalidated `knownWindows` handles for other Desktops. Raw CG drawing/backing surfaces are not a reopen veto. Failed AX reads stay unknown.
- `SidebarAppReopen.action` validates intent before/after the potentially blocking read. Empty selects system reopen; existing/unknown selects ordinary app activation; cancelled/stale requests reject.
- The worker validates the same captured running regular app/PID, own-process exclusion, permission and Desktop generation before handing a reopen request to the main thread.
- `requestSystemReopen` rechecks the exact pending token, foreground intent and live app, then uses the existing activation-yield helper and a transient `Application(running)` model. It calls `reopen(configuration:completion:)`, the same native helper used by the centred menu.
- Open configuration activates the app, reuses its running instance, supplies no custom Apple event and suppresses system error prompts. A missing bundle URL falls back to activation; throw/completion failure refreshes quietly.
- Keep the two-second duplicate-click hold. Release it when an unfiltered snapshot observes a window, the original process exits, cancellation occurs or expiry fires. A failure clears the hold immediately. Expiry never resends or reactivates.
- NSWorkspace owns activation. Completion is marshalled to the main thread, checks token ownership and never reasserts focus for a late request.
- Removed direct Apple-event sending, consent preflight/prompt queues, permission-dialog foreground exceptions, retry plumbing and temporary debug tracing.
- Existing exact-window focus/raise ordering and window actions are preserved.

### octopus/UI/Sidebar/SidebarWindowPlacement.swift

Preserve the repaired normal mouse route: the default minimise/restore click selects `.activateApp(entry.pid)` only when target/preferred ID are nil, the entry has no windows and no other-window group. Stale captured targets reject; normal existing-window actions remain unchanged. Removed its temporary tracing call.

### octopus/Info.plist and octopus/octopus.entitlements

Removed the Automation usage-description key and Apple Events entitlement added for the superseded design. The built Info.plist and actual signed app were inspected to verify both are absent. Existing saved OS Automation approvals are not used by this path and need not be reset.

### octopusTests/SidebarTests.swift and octopusTests/MouseShortcutTests.swift

Retain window absence/unknown/remote-handle decisions, before/after read cancellation, two-second hold/publication/termination behavior and the native default left-click route/stale-target tests.

Replace the old event-descriptor test with the system-open configuration contract: activation enabled, no new instance, no custom Apple event and no error prompt. Remove obsolete consent/preflight/Allow tests because that flow no longer exists. The five removed tests account for the previous total changing from 82 to 77.

## Verification

- Final test log: `/tmp/octopus-system-reopen-tests.log`.
- Final result bundle: `/tmp/octopus-system-reopen-results`: 77 passed, 0 failed, 0 skipped.
- Rebuilt app: `/tmp/octopus-windowless-verification/Build/Products/Debug/octopus.app`.
- Signed-entitlement inspection: no `com.apple.security.automation.apple-events`.
- Built Info.plist inspection: no `NSAppleEventsUsageDescription`.
- Actual source diff inspected; `git diff --check` passed.
- Mayank opened the rebuilt app and confirmed sidebar reopening without an Automation prompt. The app name/newness of its prior approval was not specified, so do not claim every app was tested.
- Tests/report reads ran outside the default sandbox due to Xcode service/cache restrictions. No source changes were copied into the other checkout or active app; Mayank handles restart.

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus \
  -destination 'platform=macOS' -derivedDataPath /tmp/octopus-windowless-verification \
  -disableAutomaticPackageResolution \
  -only-testing:octopusTests/SidebarTests \
  -only-testing:octopusTests/MouseShortcutTests test
```

## Verified history and protected behavior

The initial failures had two concrete causes: normal left clicks mapped to minimise and dropped nil targets, and raw CG surfaces were counted as real windows. Ghostty's user-triggered diagnostic recorded zero AX windows but nine CG surfaces; removing that veto allowed reopening.

A PID-only implementation with Automation consent was tested live, but Mayank preferred avoiding a consent prompt for each target app. The final system route replaces it rather than trying to grant universal Automation access.

Keep existing-window focus/minimise/hide/close/placement, gestures, ordering, Finder exclusion and Desktop/display filtering. No new Desktop-membership helper or private API was introduced.

## Limits

- Known-terminated/stale apps are rejected before dispatch. There is no atomic check-and-open guarantee: the app can quit after validation and macOS can relaunch it. Mayank explicitly accepted this.
- The target app decides whether to show a window, welcome/Open dialog or no UI.
- Already-submitted system opening/activation cannot be recalled. Cancelling a token prevents later Octopus work, not the OS's processing of an accepted request.
- A slow app taking longer than two seconds may receive another request from a later deliberate click if it still appears windowless. There is no automatic retry.
- Failed Accessibility reads stay unknown; verified remote handles protect existing windows. Universal live behavior, full-screen and multi-display regression checks are not claimed complete.
- Keep only one Octopus copy for unambiguous manual checks. Computer Use blocks Ghostty inspection; live validation came from Mayank's actions, not an alternate UI-inspection route.

## References

- [System opening API](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:))
- [Open configuration](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration)
- [Target-controlled reopen behavior](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:))
