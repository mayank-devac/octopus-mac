# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Octopus is a macOS menu-bar app (SwiftUI + AppKit, Swift 5, `LSUIElement`-style accessory app) that provides a window sidebar, window snapping/layout, Alt-Tab-style per-app cycling, Mission Control previews and keyboard/mouse shortcuts. It controls other apps through the Accessibility (AX) API plus a few private-API Objective-C shims. App target: macOS 14.6+; test targets: macOS 15+.

Dependencies (Swift packages): `KeyboardShortcuts`, `Sparkle` (updates).

## How to behave

Act like a senior developer owning this repo.

- **Understand first.** Read the surrounding code, the relevant `.agent/*.md` note and existing tests before editing. Trace the full call chain before calling something a bug or a fix.
- **Smallest correct change.** Do what was asked and nothing more. No drive-by refactors, new modes or speculative abstractions. If scope needs to grow, say so and ask.
- **Root cause over patches.** Fix the cause, not the symptom. Reuse existing helpers and patterns instead of adding near-duplicates.
- **Clean repo.** No dead code, commented-out code, debug prints, stray files or unrelated formatting churn in diffs. Put scratch files in the scratchpad, not the repo. Keep commits focused, with a clear message explaining why.
- **Smart arrangement.** Put code where its responsibility lives (controller / model / settings / view, in the matching `UI/<Feature>/` folder). Split a file when it takes on a second responsibility. Keep names descriptive and consistent with neighbours.
- **Comments that aid navigation.** Put concise explanations above the code they clarify, especially for non-obvious behavior (AX quirks, ordering constraints, private-API caveats). For long functions or substantial code blocks, a slash-divider header and a brief explanatory closing comment may mark the section. Keep both useful and descriptive; avoid decorative dividers in short blocks, trailing end-of-line comments, and comments that merely restate the code.
- **Safe by default.** Handle failure paths explicitly (AX calls fail often), avoid force-unwraps, keep UI and AX work on the right actor/thread, and never weaken permission or signing handling.
- **Test what you change.** Add or update Swift Testing cases next to the behavior (`octopusTests/`). Prefer pure geometry/planning tests; do not rely on them for pointer, hover or Space behavior. When a change alters existing behavior or defaults, update every test that depends on the old behavior in the same change.
- **Be honest and concise.** Report exactly what was and wasn't verified, flag risks and open questions, and keep explanations short and plain.
- **Ask before risky actions.** Confirm before deleting files, rewriting history, pushing, or changing signing, entitlements, the update feed or licences.
- **No session links.** Never add a Claude Code session link (`Claude-Session: …` / `claude.ai/code/session_…`) to commit messages, PR descriptions or comments.
- do test when needed and alway least amount of test . use tail so that you read less and save my tokens - basically smartly read whats necessary . 

## Commands

```sh
# Build + restart the app from .build/DerivedData (Debug by default; CONFIGURATION=Release to override)
./build.sh

# Unsigned build only
xcodebuild -project octopus.xcodeproj -scheme octopus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build

# All tests
xcodebuild -project octopus.xcodeproj -scheme octopus -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData test

# Single test file / test (Swift Testing identifier is Suite/testName)
xcodebuild ... test -only-testing:octopusTests/WindowLayoutTests
```

- There is no linter configured.
- Unit tests use **Swift Testing** (`#expect`), not XCTest. A filter that does not match runs **zero tests and still "passes"**: confirm the named test actually appears in the output.
- `Config/Base.xcconfig` includes `Config/LocalSigning.xcconfig`, which is git-ignored. Create it locally with your own team/bundle id if signing fails. Never commit signing material.
- The app needs Accessibility permission to do anything useful at runtime.

## Architecture

Entry point `octopus/octopusApp.swift`: a SwiftUI `App` (Settings scene + `MenuBarExtra`) whose `AppDelegate` is the real composition root. It constructs and wires the controllers below, and callbacks between them are injected as closures there (e.g. `tabSnapExclusions`, `onPairLayoutAttempted`, `focusUsingSidebar`). Add cross-feature wiring there, not by having features reference each other directly. Start/stop of each controller is mirrored in `applicationDidFinishLaunching` / `applicationWillTerminate`.

Feature areas under `octopus/UI/` (each has a `*Controller` owning lifecycle, plus view/model/settings files):

- `Sidebar/` – the largest area. Sidebar panel, drag-to-snap (`SidebarDragController`), icon-to-icon pair drop, window discovery/inventory, Desktop (Space) transfer, and window focus/placement. `SidebarWindowInventory` is already very large; prefer extracting a focused native-access boundary over growing it.
- `WindowLayout/` – the snap/auto-layout engine: `Planner` (choose companions) → `Allocator` (compute frames) → `Executor`/`Controller` (write frames via AX, verify, undo). `WindowControlAccess` and `SidebarWindowPlacement` are the AX read/write layer. Settings include a Legacy vs Current snap mode (`windowSnapMode`).
- `KeyboardShortcuts/`, `CyclePanel/`, `RadialWindows/`, `MissionControl/`, `WindowGroups/` (tab groups), `Profiles/`, `Preferences/`, `AppMenu/`.
- `Models/` – `Application`, `Window`, `Bindings`, `Profile`, AX helpers.
- Objective-C shims (`SidebarWindowFocus.{h,m}`, `SidebarSpaceTransfer.{h,m}`) call private APIs for exact-window focus and moving windows between Spaces. They are exposed to Swift via the bridging header.
- `Updates/SparkleConnector.swift` – Sparkle wrapper. Update feed lives in the separate `octopus-dist` repo (`octopus-dist/` here); `scripts/verify-update.swift` checks release archives.

Other directories: `clone/Rectangle/` is reference-only third-party code (own MIT licence, pinned in `manifest.json`; not compiled). `LICENSES/` holds the original Octopus MIT notice, which must stay in the app. `WEB/` is the marketing site and is git-ignored.

## Hard-won rules (from `.agent/mistakes.md` and `.agent/memory.md`)

Read the relevant `.agent/*.md` file before touching that area; recheck current code before relying on them as facts.

- **Presenting a window** (sidebar and map) must go through the single `WindowPresentation.bringForward` sequence: restore if minimised, unhide app, request the exact window, raise, verify. Never create a replacement window, and never treat app activation alone as success. Keep exact-window focus before any `AXMain`/`AXRaise`.
- **AX writes**: a stable post-write frame is not proof Octopus caused it. Validate window identity, display and Space before each write; keep live frame readback; do not auto-roll-back ambiguous state. Bulk AX results may contain `CFNull` or per-attribute errors: keep "optional absence" distinct from transient failure.
- **Snap behaviour**: preserve the already-snapped anchor when companion placement fails. Current mode asks each window for its size at most once and does no automatic reflow.
- **UI changes**: change one visible interaction at a time and keep the last accepted layout values. If a fix fails twice, revert to the last accepted behaviour and isolate one event path rather than stacking workarounds.
- **Verification honesty**: a green build/test run does not prove pointer, hover, flicker or Space-transition behaviour; say what was and wasn't checked in the real app. Check which `octopus.app` is actually running (usually `.build/DerivedData/Build/Products/Debug/octopus.app`) before attributing results.
- Do not run builds, tests or UI automation unless the user asks; hand off the commands instead. No `osascript`/standalone probes against live windows.
- Before removing or moving a symbol, search all references.

## Conventions

- Settings are `UserDefaults`/`@AppStorage` keys registered in the relevant `*Settings` type (`SidebarSettings.registerDefaults()` runs at launch).
- `plans/` (git-ignored) holds numbered implementation plans with status tables; update `plans/README.md` when changing a plan's status.

- **Clarity and maintainability**: Prefer concise, well-organized code that is easy to understand and modify. Group related functionality and use clear names and headings so developers can find things easily. Structure documentation with clear sections and concise explanations or footers where useful. 
- In way that developers find it graspable. in way so the developer have chnage/edit less code and takes less time to achieve goals. less pieces for next chnage .
- you very allowed to create files instead of putting everything on one file .you should create files to just oranise and keep findable .
- specific files for specific thing - so that devleoper know where to go. use inport where the files is needed.

- **Comment example**: Use descriptive headers and explanatory closing comments for long functions or substantial blocks, not as boilerplate around every function.
  ```swift
  ////////////////////                <--- these part of style : starting 
  //// Build the display order
  /// Keep apps with open windows together at the top.
  // Place windowless apps last so they are easy to distinguish.


  func displayOrder() -> [String] {
      ["Active apps", "Windowless apps"]
  }

  //// Preserve this order so the sidebar is easy to scan.
  //////////////////                 <----------- for ending 
  ```
adapt this style from now 