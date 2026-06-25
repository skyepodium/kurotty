# Kurotty

<img src="kurotty.png" alt="Kurotty" width="400" height="400">

Kurotty is a macOS-first terminal emulator scaffold focused on low latency, low memory use, and direct control over the rendering stack.

## Architecture

- Swift/AppKit owns the native shell: windows, tabs, splits, keyboard events, IME, clipboard, menu, app lifecycle, and preferences.
- Zig owns the tested performance-critical core scaffold: parser, grid, scrollback, renderer orchestration, metrics, and C ABI exports.
- Metal owns the live GPU path: glyph atlas, instanced cell/background/cursor rendering, and shader behavior.

## Current Status

- Swift/AppKit shell includes window, tab, split, keyboard/IME, clipboard selectors, menu, lifecycle, preferences, and app icon wiring.
- Settings are stored as editable JSON at `~/Library/Application Support/Kurotty/settings.json`, validated on save, and applied to existing terminal views after saving from `Kurotty > Settings...`.
- Metal rendering uses a GPU glyph atlas with instanced glyph/cell rendering, cursor quads, foreground color, background color instances, and underline/strikethrough decoration instances.
- The app screen model supports SGR color/style basics: 16-color, bright, dim, inverse, underline, strikethrough, `38;5`, `48;5`, `38;2`, and `48;2`.
- App-level scrollback is integrated into the visible terminal surface and can be viewed with mouse wheel scrolling.
- Zig parser/grid/scrollback/metrics/renderer orchestration are covered by unit tests.
- Parser coverage includes printable runs, CSI, private mode sequences, OSC strings, and string-control swallowing for DCS/PM/APC.
- A 1,000,000-line scrollback stress gate exists at `zig build stress-scrollback`.
- CI runs an allocator-backed leak check through `zig build leak-check`.
- Zig core builds static and dynamic libraries; Swift loads the dynamic ABI at runtime when `zig-out/lib/libkurotty_core.dylib` exists.
- Current limitation: the live AppKit surface still owns a Swift terminal-screen scaffold while the Zig grid/parser ABI is being integrated as the eventual source of truth.
- Known remaining work: full xterm/VT conformance, Codex-class TUI compatibility, Zig-owned live screen state, glyph shaping/fallback fonts, damage-region clipping in the Swift renderer, and screenshot comparison automation that drives the full app.

## Commands

```sh
zig build test
zig build
zig build bench
zig build stress-scrollback
zig build leak-check
swift build
swift test
```

Run `zig build` before launching the Swift app if you want the AppKit shell to call the Zig ABI.
The Swift debug executable is built at `.build/debug/Kurotty`.
