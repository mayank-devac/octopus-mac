# Implementation plans

Planned with the improve skill and implemented on 2026-10-06 after Mayank explicitly requested implementation and tests.

| Plan | Outcome | Status | Dependency |
| --- | --- | --- | --- |
| [001](001-sidebar-active-app-click.md) | Add icon toggle, safe restoration, and sidebar hover-list controls | IMPLEMENTED; build + 19 focused tests passed; live validation pending | Mayank chose to verify the rebuilt app manually |
| [002](002-optional-numpad-shortcuts.md) | Make numpad digit shortcuts optional and off by default | IMPLEMENTED in octopus; diff reviewed; build, regression test, and live REAPER verification pending | None |
| [003](003-auto-window-layout.md) | Adjust recent/all normal companions after an Octopus half-snap; add Snap settings | IMPLEMENTED; performance/focus fixes added; final 48 tests / 51 executions passed; visual smoothness remains unverified | Original three-trigger/tree proposal was superseded by Mayank's scope clarification; final validation limited to automated tests at Mayank's request |
| [004](004-icon-to-icon-pair-snap.md) | Drag onto a visible app icon to pair two windows using the chosen icon side | IMPLEMENTED in source; diff reviewed, build/tests/live acceptance pending (commands only requested) | Shared native access/provider checks implemented for the pair path; real multi-display timing remains unverified |

Product controls are confirmed. The follow-up discovers hidden/minimised AX windows at startup like the keyboard list, and restores immediate row interaction with button hover feedback. See the plan's evidence and remaining manual checks; do not claim production readiness before live cross-app validation. Builds/tests were explicitly authorised for this implementation.
