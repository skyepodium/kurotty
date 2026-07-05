# Kurotty

<p align="center">
  <img src="kurotty.png" alt="Kurotty" width="400" height="400">
</p>

<p align="center">
  <img src="kurotty-preview.gif" alt="Kurotty preview" width="700">
</p>

Kurotty is a macOS-first terminal emulator built with Swift/AppKit, Zig, and Metal.

Kurotty is currently an early developer build. Download the latest alpha release if you only want to try the app; build from source if you want to contribute.

[Download](#download) · [Features](#features) · [Build From Source](#build-from-source) · [License](#license)

## Download

Kurotty ships as a notarized Universal DMG for Intel and Apple Silicon Macs.

[Download the latest Kurotty DMG](https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg)

Open the DMG, drag `kurotty.app` to `Applications`, then launch it from `/Applications`.

Shell download:

```sh
curl -fL -o kurotty-macos-universal.dmg \
  https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg
open kurotty-macos-universal.dmg
```

Release notes, checksums, and older builds are available on [GitHub Releases](https://github.com/skyepodium/kurotty/releases). On first launch, macOS may ask for notification permission because Kurotty supports terminal-triggered task notifications.

## Features

- Native macOS tabs, split panes, menus, keyboard input, IME, clipboard, and preferences.
- Metal rendering for glyphs, backgrounds, cursor, underline, and strikethrough.
- Theme presets, scrollback, and editable JSON settings.
- Terminal styling support for 16-color, 256-color, truecolor, dim, inverse, underline, and strikethrough.
- OSC title, working-directory, color query, and iTerm2-compatible notifications.

Kurotty routes OSC 9 and OSC 777 `notify;title;body` messages through typed notification events before showing macOS notifications. OSC 9 banners use the iTerm2-style `Alert` title and `Session <title> #<tab>: <message>` body, while numeric OSC 9 progress extensions are ignored as desktop notifications.

External hooks such as Codex/OMX should not write OSC bytes to `/dev/tty`. Those hooks may not have a controlling TTY, and guessed TTY writes can miss Kurotty entirely. Use the Kurotty notification bridge instead:

```sh
$KUROTTY_NOTIFY_COMMAND --notify "Build finished"
$KUROTTY_NOTIFY_COMMAND --notify-json '{"title":"Codex task finished","body":"Tests passed."}'
```

When Kurotty launches a shell it exports `KUROTTY_NOTIFY_SOCKET` and `KUROTTY_NOTIFY_COMMAND`. For hooks outside that environment, the installed app executable provides the same bridge client:

```sh
/Applications/kurotty.app/Contents/MacOS/kurotty --notify-json '{"last-assistant-message":"Done."}'
```

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

To create a local Universal DMG:

```sh
./scripts/package-release.sh
```

Developer notes live in `docs/`.

## License

Kurotty is released under the MIT License.
