# Sidebar drag-to-position windows

## Recommendation

**Build this inside Octopus, using Rectangle as the main reference. Don’t fork or embed an entire window manager.**

Basically, we already have window discovery, individual window identities, Accessibility permission handling, and safe focus/restore actions in [SidebarWindowInventory.swift](/Users/mayank/Desktop/mac/windows_drag/octopus/UI/Sidebar/SidebarWindowInventory.swift:401). We need to add dragging, placement previews, and move/resize operations.

| Project | Fit for this feature | Decision |
|---|---|---|
| **Rectangle** | Closest match: manual snapping and window geometry. Its MIT licence permits reuse with required notices. | Study its placement logic; adapt small pieces where useful. [Source](https://github.com/rxhanson/Rectangle/blob/main/LICENSE) |
| **AltTab** | Primarily window switching, which Octopus already handles. GPL-3.0 also introduces different redistribution requirements when incorporating code. | Don’t copy it for snapping. [Source](https://github.com/lwouis/alt-tab-macos) |
| **AeroSpace** | Automatic tiling with its own virtual workspaces. | Too much unrelated architecture for this interaction. [Source](https://github.com/nikitabobko/AeroSpace#readme) |
| **yabai** | Broad window, display, and Space management. Some advanced features require partially disabling SIP, macOS’s system protection. | Don’t introduce its engine or privileged setup. Ordinary move/resize does not require that setup. [Source](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) |

The hard part is reliable mouse behaviour and handling apps that resist resizing—not calculating half a screen.

## Agreed interaction

- **One window:** drag its sidebar icon.
- **Several windows:** open the existing popup and drag the specific window’s row.
- Show an outline while dragging. Move the actual window only after release.
- Away from snap areas, preserve its size and place it with its top-centre beneath the pointer, constrained to the usable display area.
- Screen sides snap to halves, corners to quarters, and the top edge maximises within the desktop. Maximising does **not** enter native fullscreen.
- Support connected displays and their currently visible desktops. Hidden/minimised windows restore on drop when their desktop membership is verified.
- Escape or dropping back on the sidebar cancels without changing the window.

## Implementation

- Fix click-versus-drag handling in [SidebarView.swift](/Users/mayank/Desktop/mac/windows_drag/octopus/UI/Sidebar/SidebarView.swift:232): defer the normal click action until mouse-up; movement beyond six points starts dragging. This prevents an active window being minimised before the drag begins.
- Use one drag-session controller for icons and popup rows. Lock the selected window identity at drag start; suspend hover menus and sidebar auto-hide during dragging.
- Keep preview geometry separate from window control. Use the display under the pointer, account for Dock/menu-bar reservations, and convert AppKit coordinates to Accessibility coordinates centrally.
- Add an internal placement action carrying the exact window ID and target rectangle. Run it through the existing serial Accessibility queue and cancellation checks.
- Before changing anything, revalidate the window, desktop membership, permission, and writable position/size attributes. Restore if necessary, apply placement, read back the actual frame, then raise the selected window.
- Follow Rectangle’s relevant size–position–size approach for cross-display placement, with bounded calls and no endless retries. Preserve attribution for any copied code. [Implementation reference](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)
- Cancel if the window closes, permission disappears, the desktop changes, or display configuration changes.

No external app dependency or public API is needed.

## Limitations

- **Some windows cannot fit the preview.** Apps enforce minimum sizes; terminals may resize in character-sized steps. Read back the result and show quiet explanatory feedback when it differs. Rectangle faces the same restriction. [Known limitations](https://github.com/rxhanson/Rectangle#common-known-issues)
- **Placement is not atomic.** macOS changes position and size separately, so a slow app can briefly jump or only partially accept the operation. Preview-first reduces repeated calls but cannot remove this limitation.
- **Other Spaces and native fullscreen remain excluded.** Rectangle documents the absence of a public API for moving windows between Spaces. Octopus already uses private APIs for Space metadata; reading that metadata does not provide reliable cross-Space movement. [Source](https://github.com/rxhanson/Rectangle#common-known-issues)
- **Other tiling managers may undo our placement.** We should report the resulting frame, not continuously fight another manager.
- Fixed-size windows can move if supported; resizing is unavailable. Modal dialogs and windows with attached sheets are excluded initially.

## Verification

No code was changed and no builds or tests were run; this recommendation is based on source inspection.

For implementation, use focused checks for click/drag separation, exact window selection, snap geometry, coordinate conversion, cancellation, and rejected placements. Then manually verify Safari, Finder, a Chromium/Electron app, and Terminal—including minimise/restore, rapid pointer reversals, mixed-display arrangements, and a window closing mid-drag.

**Live interaction checks are required before calling this feature complete.** Compilation alone cannot establish reliable dragging.
