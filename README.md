# Kurotty

<p align="center">
  <img src="kurotty.png" alt="Kurotty" width="400" height="400">
</p>

<p align="center">
  <img src="kurotty-preview.gif" alt="Kurotty preview" width="700">
</p>

Kurotty is a macOS-first terminal emulator built with Swift/AppKit, Zig, and Metal.

Kurotty is currently an early developer build. Install the latest alpha release if you only want to try the app; build from source if you want to contribute.

[Install](#install) · [Features](#features) · [Build From Source](#build-from-source) · [License](#license)

## Install

Download the latest alpha `.zip` from [GitHub Releases](https://github.com/skyepodium/kurotty/releases), verify the checksum, and move `kurotty.app` to `/Applications`.

Current alpha asset name:

- `kurotty-0.1.0-alpha.1-macos.zip`
- `SHA256SUMS`

```sh
shasum -a 256 -c SHA256SUMS
unzip kurotty-0.1.0-alpha.1-macos.zip
mv kurotty.app /Applications/
open /Applications/kurotty.app
```

Notes:

- This is an alpha build.
- The app is ad-hoc signed for local execution, not notarized yet.
- macOS may ask you to confirm opening a downloaded app.

## Features

- Native macOS tabs, split panes, menus, keyboard input, IME, clipboard, and preferences.
- Metal rendering for glyphs, backgrounds, cursor, underline, and strikethrough.
- Theme presets, scrollback, and editable JSON settings.
- Terminal styling support for 16-color, 256-color, truecolor, dim, inverse, underline, and strikethrough.
- OSC title, working-directory, color query, and iTerm2-compatible notifications.

Notification example:

```sh
printf '\e]9;Task finished\a'
```

Kurotty shows OSC 9 messages as macOS `Alert` notifications with the app icon and the message body.

## Build From Source

This path is for contributors and local testing.

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- Zig

```sh
git clone https://github.com/skyepodium/kurotty.git
cd kurotty
zig build
swift run kurotty
```

To install a local app bundle:

```sh
./scripts/install-app.sh
open /Applications/kurotty.app
```

To create the same release zip locally:

```sh
./scripts/package-release.sh 0.1.0-alpha.1
```

Developer notes live in `docs/`.

## License

Kurotty is released under the MIT License.
