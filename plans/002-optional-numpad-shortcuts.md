# Plan 002: Make numpad digit shortcuts optional

- Status: IMPLEMENTED in octopus on 2026-10-07; diff reviewed; build/test and live REAPER checks pending (not authorised to run)
- Planned at: `0930671`, 2026-10-07
- Priority: P1; effort: S; risk: low; dependencies: none
- Category: bug / shortcut compatibility

## Outcome and reason

Add one persistent “Use numpad digits for shortcuts” checkbox in Preferences → Shortcuts. Default it to off, including existing installations without an explicit preference. Top-row digit shortcuts keep their current behaviour. Enabling it opts into numpad equivalents for app activation, app binding, and profile switching.

Currently every enabled action automatically registers all ten numpad digits with its configured modifiers. Global hotkeys consume matching key events before a foreground app can use them. REAPER uses numpad shortcuts, so overlapping combinations can stop reaching REAPER. Registration does not depend on whether an app/profile is assigned to a digit; the action can consume the key and then beep for a missing binding.

This is a verified source-level conflict mechanism, not a confirmed diagnosis of the installed binary or the reported update. The exact failed shortcut and whether quitting Reef restores it remain unconfirmed. Plain digits and numpad operators are not registered by the inspected code.

## Checkout and evidence

This plan targets `/Users/mayank/Desktop/mac/octopus`, whose product and scheme are named octopus. Mayank authorised implementation of this plan in the current checkout. The neighbouring `/Users/mayank/Desktop/mac/Reef-main` contains the same numpad registration logic in `Reef/UI/KeyboardShortcuts/{ModifierManager,ShortcutController}.swift`; that checkout was not changed.

- `octopus/UI/KeyboardShortcuts/ModifierManager.swift:13–52`: persistent modifier preferences use `@AppStorage` with `didSet { updateShortcuts() }`.
- `ModifierManager.swift:60–62`: startup rebuilds saved shortcut registrations.
- `ModifierManager.swift:148–156`: registers all digits for all three actions.
- `ModifierManager.swift:169–175`: main-row and numpad registration currently share the same enabled condition:

```swift
KeyboardShortcuts.setShortcut(
    enabled ? .init(keypadKeys[number], modifiers: modifiers) : nil,
    for: keypadName
)
```

- `octopus/UI/KeyboardShortcuts/ShortcutController.swift:19–21,38–48,64–84`: distinct keypad key codes/names and existing handlers. Keep these handlers; removing registrations is sufficient.
- `octopus/UI/Preferences/PreferencesShortcutsView.swift`: existing modifier checkboxes and “Reset shortcut modifiers?” confirmation.
- `octopus/octopusApp.swift`: creates ModifierManager before ShortcutController at launch, allowing stale saved keypad values to be cleared before handlers register.
- `octopusTests/MenuBarLabelTests.swift`: existing Swift Testing pattern (`import Testing`, `@testable import octopus`, `@Test`, `#expect`).

Library references: [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and its [registration implementation](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift). Latest upstream source confirms registered hotkeys consume events and suppressing callbacks does not release them. Use the existing `setShortcut(nil, for:)` pattern; no dependency upgrade is required.

## Scope

Modify only:

- `octopus/UI/KeyboardShortcuts/ModifierManager.swift`
- `octopus/UI/Preferences/PreferencesShortcutsView.swift`
- `octopusTests/ModifierManagerTests.swift` (new, focused regression tests)
- This plan and its index for status updates

Do not change REAPER preferences, keyboard mappings, Num Lock state, app/profile bindings, sidebar behaviour, shortcut modifiers, dependency versions, or add application-specific exceptions. Do not change the shortcut handlers unless source evidence proves it necessary.

## Implementation

1. Add `@AppStorage("numpadShortcutsEnabled") var numpadShortcutsEnabled = false` to ModifierManager, with `didSet { updateShortcuts() }`. Follow the existing persistence pattern. An absent preference means off; an explicit saved true means on. Do not infer consent from previously saved keypad shortcuts.
2. Leave main-row registration unchanged. Change only the keypad branch to use `enabled && numpadShortcutsEnabled`. Always call `setShortcut(nil, for: keypadName)` when off or the action has no modifiers. Skipping registration is insufficient because old persisted registrations must be cleared at launch and live registrations released immediately on toggle.
3. Add the labelled checkbox and brief helper text: “Also use numpad 0–9 for app and profile shortcuts. These combinations may conflict with other apps.” Bind directly to the shared ModifierManager property. Adjust the current fixed form height enough to keep the control and existing disabled-action note visible.
4. Preserve the existing modifiers-only reset: it must not change the numpad preference. Keep its confirmation wording explicit. Changing modifiers while numpad is off must not re-enable numpad registrations.
5. Add focused tests against actual `KeyboardShortcuts.getShortcut(for:)` values, rather than merely checking the boolean. Cover all three keypad name families across 0–9. Use serial execution and snapshot/restore only the exact touched UserDefaults/shortcut keys in teardown, since these APIs share process-global state. Do not clear the whole preference domain or instantiate the full app.

After each implementation step, inspect the focused diff. Do not run builds/tests unless Mayank explicitly authorises them; provide the commands below otherwise.

## Verification

Source / scope checks:

```sh
git diff --stat 0930671..HEAD -- octopus/UI/KeyboardShortcuts/ModifierManager.swift octopus/UI/Preferences/PreferencesShortcutsView.swift
git diff --check
git diff -- octopus/UI/KeyboardShortcuts/ModifierManager.swift octopus/UI/Preferences/PreferencesShortcutsView.swift octopusTests/ModifierManagerTests.swift
```

Expected: review any drift before editing; no whitespace errors; no unrelated source changes.

Focused test command, to be run only on user request:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus -destination 'platform=macOS' -derivedDataPath /tmp/octopus-numpad-verification -only-testing:octopusTests/ModifierManagerTests test
```

Expected: named tests actually execute and pass; zero executed tests is not success. The project/scheme/test target are verified from the shared scheme; the command has not been run.

Required regression scenarios:

- Missing preference + stale saved keypad shortcuts: startup clears all 30 keypad shortcuts; main-row shortcuts remain configured.
- Enable → disable → enable: keypad shortcut values appear, clear, and return with current modifiers.
- Change modifiers while off, and recreate ModifierManager: keypad shortcuts remain nil.
- Enabled keypad preference + action with no modifiers: both digit families for that action remain nil, with no plain-digit interception.
- Reset shortcut modifiers: keeps the numpad preference, uses restored modifiers, and respects action enablement.

Required real-world check before claiming the conflict fixed:

1. Identify one failing REAPER combination and confirm it works with Reef fully quit. Ensure only one Reef/octopus instance is running during the check.
2. With the corrected product running and the checkbox off, verify that combination works immediately and after relaunch; verify top-row app switching still works.
3. Enable the checkbox: verify a matching numpad shortcut performs Reef's action. Disable it again and verify REAPER receives the same combination without restarting either app.
4. Check an unbound digit and REAPER's relevant main/MIDI editor context. Check plain numpad digits and operators remain usable. If operators or plain digits fail, investigate separately rather than claiming this toggle fixes every keypad problem.

## Done criteria and limits

- The preference persists; missing values default off for fresh and upgraded installations.
- Off clears all 30 keypad shortcut values at startup and immediately during use.
- Top-row shortcuts and chosen modifiers remain unchanged; enabling restores numpad equivalents.
- Focused regression tests pass when authorised, with nonzero execution; real REAPER interaction is checked before reporting runtime resolution.
- No code outside scope changes; update `plans/README.md` with actual verification and limitations.

Stop and report if the chosen checkout differs, the library does not release `nil` registrations, or the reported failed key cannot overlap these registrations. Enabling this option deliberately restores possible conflicts. Users who previously used Reef through the numpad must explicitly enable it after upgrading; that is the trade-off of an off-by-default compatibility fix.
