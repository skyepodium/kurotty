# Kurotty

<p align="center">
  <img src="kurotty.png" alt="Kurotty" width="400" height="400">
</p>

Kurotty is a macOS-first terminal emulator focused on low latency, bounded memory use, and direct control over the Swift/AppKit, Zig, and Metal layers.

## What Works Today

- Native macOS windowing with tabs, splits, pane chrome, menus, keyboard input, IME, clipboard, preferences, and app icon wiring.
- Editable JSON settings at `~/Library/Application Support/Kurotty/settings.json`, with validation and live application to existing terminal views.
- Theme presets for `kuro-dark`, `lightty`, and `custom`.
- GPU rendering through Metal glyph atlas and instanced foreground, background, cursor, underline, and strikethrough draws.
- Terminal styling basics: 16-color, bright, dim, inverse, underline, strikethrough, `38;5`, `48;5`, `38;2`, and `48;2`.
- App-level scrollback with mouse wheel navigation.
- OSC title, working-directory, color query, and iTerm2-compatible notifications.
- Zig parser, grid, scrollback, metrics, renderer orchestration, and C ABI scaffolding with unit and stress coverage.

## Architecture

- `Sources/KurottyApp/` contains the Swift/AppKit shell: app lifecycle, windows, tabs, splits, input, settings, shell lifecycle, and the bridge to Zig.
- `src/` contains the Zig terminal core: parser, grid, scrollback, PTY boundary, metrics, renderer orchestration, and C ABI exports.
- `Sources/KurottyApp/Shaders/` contains the Metal shader source used by the SwiftPM resource bundle.
- `tests/`, `bench/`, and `stress/` contain regression, benchmark, and high-volume gates.

The live AppKit surface still owns a Swift terminal-screen scaffold while the Zig grid/parser ABI is being integrated as the eventual source of truth.

## Build And Run

Prerequisites:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- Zig

```sh
git clone git@github.com:skyepodium/kurotty.git
cd kurotty
zig build
swift build
./.build/debug/kurotty
```

Run `zig build` before launching if you want the Swift app to load `zig-out/lib/libkurotty_core.dylib` through the runtime ABI bridge.

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

## Test And Verification Gates

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
- Add glyph shaping and fallback font coverage.
- Expand full-app screenshot comparison automation.
