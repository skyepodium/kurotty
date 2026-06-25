# Kurotty

![Kurotty](kurotty.png)

Kurotty is a macOS-first terminal emulator scaffold focused on low latency, low memory use, and direct control over the rendering stack.

## Architecture

- Swift/AppKit owns the native shell: windows, tabs, splits, keyboard events, IME, clipboard, menu, app lifecycle, and preferences.
- Zig owns performance-critical terminal state: parser, grid, scrollback, PTY boundary, renderer orchestration, metrics, and C ABI exports.
- Metal owns the GPU path: glyph atlas, cell rendering pipeline, scrolling, and damage tracking.

## Current Status

- Swift/AppKit shell includes window, tab, split, keyboard/IME, clipboard selectors, menu, lifecycle, preferences, and app icon wiring.
- Metal rendering uses a GPU glyph atlas with instanced glyph/cell rendering, cursor quads, foreground color, and background color instances.
- The app screen model supports SGR color/style basics: 16-color, bright, inverse, `38;5`, `48;5`, `38;2`, and `48;2`.
- App-level scrollback is integrated into the visible terminal surface and can be viewed with mouse wheel scrolling.
- Zig parser/grid/scrollback/metrics/renderer orchestration are covered by unit tests.
- Parser coverage includes printable runs, CSI, private mode sequences, OSC strings, and string-control swallowing for DCS/PM/APC.
- A 1,000,000-line scrollback stress gate exists at `zig build stress-scrollback`.
- CI runs an allocator-backed leak check through `zig build leak-check`.
- Zig core builds static and dynamic libraries; Swift loads the dynamic ABI at runtime when `zig-out/lib/libkurotty_core.dylib` exists.
- Known remaining work: full xterm/VT conformance, TUI edge-case compatibility, glyph shaping/fallback fonts, damage-region clipping in the Swift renderer, and screenshot comparison automation that drives the full app.

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
