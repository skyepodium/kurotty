# Kurotty

<p align="center">
  <img src="kurotty.png" alt="Kurotty" width="400" height="400">
</p>

<p align="center">
  <img src="kurotty-preview.gif" alt="Kurotty preview" width="700">
</p>

Kurotty is a macOS-first terminal emulator built with Swift/AppKit, Zig, and Metal.

Kurotty is currently an early developer build. Download the latest alpha release if you only want to try the app; build from source if you want to contribute.

[Download](#download) · [Features](#features) · [Architecture](docs/architecture.md) · [Build From Source](#build-from-source) · [License](#license)

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
- OSC title, working-directory, color query, and terminal-generated notifications.
- Local tmux control-mode integration: `tmux -CC` windows become native tabs and panes become native splits.

Run `tmux -CC` or `tmux -CC attach` in a local Kurotty shell to enter native tmux mode. Kurotty keeps ordinary `tmux` in its standard terminal UI and supports multiple simultaneous local control-mode sessions, including clients launched from different panes of the same split tab. It reconstructs each pane's screen, cursor, alternate screen, and terminal modes on attach, then mirrors window order, pane titles, layout, focus, zoom, output, and native resizing. Pane replay and pending mutations are bounded, new panes are captured before live output is shown, and the exact original shell pane or tab is restored after detach or a control-client transport failure. Advanced swap, rotate, zoom, layout, and detach commands are available from the Command Palette while a control-mode session is active. SSH and remote tmux control connections are intentionally outside this local integration.

Kurotty normalizes OSC 9, OSC 777 `notify;title;body`, and rich iTerm2 OSC 1337 notifications into one typed notification path before showing macOS notifications. Terminal BEL rings the bell and, while Kurotty is unfocused, shows the payload-free fallback `Kurotty` / `Check your terminal.` Numeric OSC 9 progress extensions are not treated as desktop alerts. No source is selected by a CLI name or by scraping rendered terminal text.

For ordinary shell commands, Kurotty automatically loads bundled zsh, bash, or fish integration and consumes standard OSC 133 command boundaries. This reports completion from command metadata such as exit status and duration for any program. The integration is resolved from the running app's resource bundle, preserves the user's shell environment, and does not modify dotfiles or store a username, home directory, checkout path, or `/Applications` path. Unsupported shells continue without injection and may emit OSC 7/133 themselves.

Long-running interactive programs do not return control to the shell after each internal task. Exact task content therefore requires an explicit OSC 9/777/1337 or bridge payload. BEL carries only an attention signal—not a title, response, success state, or completion meaning—so Kurotty does not guess those fields from an application name or screen wording.

Kurotty also implements xterm focus reporting (`CSI ? 1004 h/l` with `CSI I/O` responses). Interactive programs can therefore apply their own standard unfocused-notification policy without Kurotty-specific detection.

Programs launched inside Kurotty may also use its producer-neutral bridge without knowing an installation path:

```sh
$KUROTTY_NOTIFY_COMMAND --notify "Build finished"
$KUROTTY_NOTIFY_COMMAND --notify-json '{"version":1,"event":"task.completed","session_id":"pane-42","duration_ms":2600,"title":"Build finished","body":"Tests passed."}'
```

The JSON contract is producer-neutral. `body` (or the legacy aliases `message`, `text`, and `summary`) contains the user-visible work result; `title` and `subtitle` are optional. Version 1 also preserves optional `event`, `session_id`, and `duration_ms` metadata. The command sends only to a live KuroTTY bridge, so a KuroTTY helper invocation cannot accidentally publish another application's desktop notification.

Explicit OSC 9/777/1337 and bridge events preserve producer-supplied content. When a producer emits only BEL, Kurotty can show only the fixed `Check your terminal.` fallback; it never reconstructs a response from submitted input, rendered cells, output volume, or a quiet timer. OSC 0 window titles and their BEL terminators remain title protocol, not task notifications.

Kurotty exports `KUROTTY_NOTIFY_SOCKET` and `KUROTTY_NOTIFY_COMMAND` from the running bundle for every child shell. It does not edit another program's configuration or assume `/Applications`, a username, a checkout path, or a particular producer.

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

Developer notes live in `docs/`, including the [architecture overview](docs/architecture.md).

## License

Kurotty is released under the MIT License.
