# Kurotty

<p align="center">
  <img src="kurotty.png" alt="Kurotty" width="400" height="400">
</p>

Kurotty is a macOS-first terminal emulator built around Swift/AppKit, Zig, and native Metal rendering. The goal is a fast, low-latency terminal with direct control over terminal state, glyph rendering, scrollback, and UI chrome.

Kurotty is still an early developer build. It is usable for local testing, but the terminal core and TUI compatibility work are still moving quickly.

## Install

### Recommended For Users

The intended install path is a signed `kurotty.app` from GitHub Releases.

1. Download the latest `kurotty.app.zip` or `.dmg` from the Releases page.
2. Move `kurotty.app` to `/Applications`.
3. Open `kurotty`.

Packaged releases are the right path for normal users because they do not require cloning the repository, installing Zig, or running developer build commands. Until the first packaged release is published, use the local app install below.

### Local App Install

This creates a release build, wraps it as `kurotty.app`, and installs it into `/Applications`.

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain

```sh
git clone git@github.com:skyepodium/kurotty.git
cd kurotty
./scripts/install-app.sh
open /Applications/kurotty.app
```

To install somewhere else:

```sh
INSTALL_DIR="$HOME/Applications" ./scripts/install-app.sh
open "$HOME/Applications/kurotty.app"
```

### Contributor Build

Use this path when changing the terminal core, renderer, tests, or benchmarks.

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- Zig

```sh
git clone git@github.com:skyepodium/kurotty.git
cd kurotty
zig build
swift run kurotty
```

Run `zig build` before launching when you want the Swift app to load `zig-out/lib/libkurotty_core.dylib` through the runtime ABI bridge.

## Current Features

- Native macOS windowing with tabs, split panes, pane headers, menus, keyboard input, IME, clipboard, preferences, and app icon wiring.
- Browser-style tabs with close buttons, plus button, active state, and split-pane chrome.
- Editable JSON settings at `~/Library/Application Support/Kurotty/settings.json`, with validation and live application to existing terminal views.
- Theme presets for `kuro-dark`, `lightty`, and `custom`.
- GPU rendering through a Metal glyph atlas and instanced foreground, background, cursor, underline, and strikethrough draws.
- Terminal styling basics: 16-color, bright, dim, inverse, underline, strikethrough, `38;5`, `48;5`, `38;2`, and `48;2`.
- App-level scrollback with mouse wheel navigation and scrollbar thumb display.
- OSC title, working-directory, color query, and iTerm2-compatible notifications.
- Zig parser, grid, scrollback, metrics, renderer orchestration, and C ABI scaffolding with unit and stress coverage.

## Keyboard Basics

- `Cmd+T`: new tab
- `Cmd+W`: close the active pane or tab
- `Cmd+D`: split the active pane vertically
- `Cmd+Shift+D`: split the active pane horizontally
- `Cmd+Option+Arrow`: move focus between split panes
- `Cmd+[` / `Cmd+]`: move between tabs
- `Cmd+,`: open settings

## Settings

Kurotty stores user settings here:

```sh
~/Library/Application Support/Kurotty/settings.json
```

The settings file controls font size, window size, theme, rendering debug flags, and terminal behavior. Use the app menu or edit the JSON directly, then relaunch if a setting is not applied live yet.

## Architecture

- `Sources/KurottyApp/` contains the Swift/AppKit shell: app lifecycle, windows, tabs, splits, input, settings, shell lifecycle, and the bridge to Zig.
- `Sources/KurottyApp/Shaders/` contains the Metal shader source used by the SwiftPM resource bundle.
- `src/` contains the Zig terminal core: parser, grid, scrollback, PTY boundary, metrics, renderer orchestration, and C ABI exports.
- `tests/`, `bench/`, and `stress/` contain regression, benchmark, and high-volume gates.

The live AppKit surface still owns a Swift terminal-screen scaffold while the Zig grid/parser ABI is being integrated as the eventual source of truth.

## Task Notifications

Kurotty requests macOS notification permission on launch. It sends notifications only when the app is not active.

Kurotty supports iTerm2-compatible notifications through OSC 9:

```sh
printf '\e]9;Build finished\a'
```

Use that at the end of long-running commands:

```sh
swift build; printf '\e]9;Swift build finished\a'
```

Kurotty also notifies when the shell session exits while the app is inactive.

## Verification Gates

Run the smallest relevant gate first, then broaden based on the files changed.

```sh
zig build test
zig build
zig build bench
zig build stress-scrollback
zig build leak-check
swift build
swift test
```

For Swift/AppKit/Metal changes, start with `swift build` and the relevant `swift test --filter ...` coverage. For Zig parser, grid, scrollback, metrics, renderer, ABI, or allocation changes, use the corresponding Zig gates above.

## Roadmap

- Move the live terminal screen source of truth from the Swift scaffold to Zig.
- Improve xterm/VT conformance and Codex-class TUI compatibility.
- Add robust Unicode shaping, fallback font, and grapheme cluster coverage.
- Expand full-app screenshot comparison automation.
- Publish signed release builds so normal users can install without local build tools.
