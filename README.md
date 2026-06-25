# Kurotty

Kurotty is a macOS-first terminal emulator scaffold focused on low latency, low memory use, and direct control over the rendering stack.

## Architecture

- Swift/AppKit owns the native shell: windows, tabs, splits, keyboard events, IME, clipboard, menu, app lifecycle, and preferences.
- Zig owns performance-critical terminal state: parser, grid, scrollback, PTY boundary, renderer orchestration, metrics, and C ABI exports.
- Metal owns the GPU path: glyph atlas, cell rendering pipeline, scrolling, and damage tracking.

## Current Status

- Zig parser/grid/scrollback/metrics are covered by unit tests.
- A 1,000,000-line scrollback stress gate exists at `zig build stress-scrollback`.
- Swift/AppKit shell builds and includes window, tab, split, keyboard/IME, clipboard selectors, menu, lifecycle, preferences, and `MTKView` hosting.
- Zig core builds static and dynamic libraries; Swift loads the dynamic ABI at runtime when `zig-out/lib/libkurotty_core.dylib` exists.
- PTY spawn and full glyph rasterization are intentionally still skeleton surfaces.

## Commands

```sh
zig build test
zig build
zig build bench
zig build stress-scrollback
swift build
```

Run `zig build` before launching the Swift app if you want the AppKit shell to call the Zig ABI.
