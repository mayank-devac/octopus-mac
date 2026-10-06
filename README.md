# octopus

The macOS window manager that gives every app its own Alt-Tab. 

![Cover photo. octopus logo and UI.](./github-assets/octopus-banner-1280-short.jpg)

[Download for macOS](https://getoctopus.app) · [GitHub Releases](https://github.com/gouwsxander/octopus/releases/latest) (Requires macOS 14.6+)

[How we made octopus (YouTube)](https://youtu.be/niRCi5zJvHU)

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

Download the latest release on [our website](https://getoctopus.app) or [GitHub](https://github.com/gouwsxander/octopus/releases/latest)

Simply: 
1) Download the `.zip` and unzip the file.
2) Drag `octopus.app` into your Applications folder.

octopus is free/pay-what-you-want. Use the link on our website to support us.

### Compatibility

octopus is compatible with **macOS 14.6 (Sonoma)** and onwards. 

You can find your macOS version from the ** → About This Mac** page.


## Development

Please share issues and feedback via the [GitHub issues page](https://github.com/gouwsxander/octopus/issues).

Feel free to submit pull requests, though we can't guarantee that we'll get to them.


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
