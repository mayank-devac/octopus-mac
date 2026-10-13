# octopus

Octopus is a macOS window switcher and window-management app. This repository is
Mayank Baral's modified version of the original Octopus by Xander Gouws and Omar Hayat.

Source code: [mayank-devac/octopus-mac](https://github.com/mayank-devac/octopus-mac).

## Key Features

octopus lets you bind applications to number keys and cycle through their windows with an Alt-Tab-like interface.

We built octopus because we wanted a fast and simple window switcher for macOS.

- Bind applications to number keys to refocus to **any** window for that app
- Assign profiles for different sets of bindings
- Do your binding and profile management through the keyboard
- Customizable keyboard shortcuts


## Usage

### Binding
You should start by binding different applications to the number keys. You can do this:
- through **Preferences → Profiles** (accessed through the menu bar), or
- by selecting the application of your choice and then pressing <kbd>Ctrl</kbd> + <kbd>Option</kbd> + <kbd>Shift</kbd>.

### Profiles
You can also set your bindings up in different profiles.

For example, you may want two profiles:
- "Coding": Which binds your favourite editor, browser, and terminal
- "Browsing": Which binds your favourite web browser, messaging app, and music client

You can switch between profiles:
- using the menu bar, or
- by binding them to the number keys, and then pressing <kbd>Ctrl</kbd> + <kbd>Option</kbd> + <kbd>[0-9]</kbd>.

### Switching applications
Suppose you're in your coding profile, and have your editor bound to `0`.

To switch between apps and windows:
1. Hold <kbd>Control</kbd> and press <kbd>0</kbd> to open a panel showing each of your editor's windows.
2. Press <kbd>0</kbd> multiple times to select the specific window you want.
3. Release <kbd>Control</kbd> to switch to the selected window.

In this way, octopus gives every app its own 'Alt-Tab'.

Note that window switching is scoped to your current [macOS space](https://support.apple.com/en-ca/guide/mac-help/mh14112/mac).

### Customization

You can customize the modifiers for switching applications and profiles, and for binding different applications in **octopus Preferences → Shortcuts**.

octopus also pairs well with [Rectangle](https://github.com/rxhanson/Rectangle):
- Rectangle positions & re-arranges your windows
- octopus re-focuses your windows


## Installation

Simply: 
1) Download the `.zip` and unzip the file.
2) Drag `octopus.app` into your Applications folder.

Beta downloads, when available, are published in
[octopus-dist](https://github.com/mayank-devac/octopus-dist/releases).
This source repository does not provide a newly built or notarized app.

### Compatibility

octopus is compatible with **macOS 14.6 (Sonoma)** and onwards. 

You can find your macOS version from the ** → About This Mac** page.


## Development

Clone this repository and open the Xcode project:

```sh
git clone https://github.com/mayank-devac/octopus-mac.git
cd octopus-mac
open octopus.xcodeproj
```

Use Xcode with a macOS SDK supported by the project. Xcode resolves the
KeyboardShortcuts and Sparkle packages automatically. Select the `octopus`
scheme and **My Mac** as the destination.

For a local app build, choose your own team under **Signing & Capabilities** for
the app and test targets. The existing team ID belongs to the maintainer; it
does not include signing credentials or give you access to that team.
Use a unique bundle identifier for your local build if required by signing.
Never commit signing certificates, private keys, passwords, or local credentials.

To build without signing from Terminal:

```sh
xcodebuild -project octopus.xcodeproj -scheme octopus \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The app target supports macOS 14.6 or later; the test targets require macOS 15
or later. Local builds need Accessibility permission to control other apps.
The updater currently points to the maintainer's `octopus-dist` feed and verifies
updates using its public signing key. Fork maintainers should configure their
own feed and public key before distributing builds.

Issues and pull requests are welcome. Include your macOS version, steps to
reproduce the issue, and the result you expected. Do not include private window
titles, account details, or credentials in reports.

## Licence

This version of Octopus is distributed under **GNU GPL version 3 only
(GPL-3.0-only)**; see [LICENSE](LICENSE). Modifications to Octopus are
Copyright (c) 2026 Mayank Baral.

The original Octopus code by Xander Gouws and Omar Hayat was released under MIT.
Its existing copyright and permission notices are preserved in
[LICENSES/Octopus-MIT.txt](LICENSES/Octopus-MIT.txt). Previously MIT-licensed
versions remain available under their original terms.

The Rectangle reference files retain their own [MIT licence](clone/Rectangle/LICENSE)
and are not compiled or bundled. External dependencies retain their respective
licences: [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
and [Sparkle](https://github.com/sparkle-project/Sparkle).

When distributing a build of this GPLv3 version, include the required licence
notices and provide its matching source code under GPLv3. The private release
scripts are not included; the source build command above uses standard Xcode tools.


## FAQ
<details>
<summary><b>Why is it called "octopus"?</b></summary>
<br>
The name comes from the starting sounds of the words "refocus" and "reframe". And, like a coral octopus supports a diverse ecosystem, octopus supports your workspace—helping you navigate between windows quickly and easily.
</details>


## Related Projects
- [yabai](https://github.com/asmvik/yabai)
- [Aerospace](https://github.com/nikitabobko/AeroSpace?tab=readme-ov-file)
- [Rectangle](https://github.com/rxhanson/Rectangle)
- [AltTab for macOS](https://github.com/lwouis/alt-tab-macos/tree/master)
