# Architecture

## Swift/AppKit Shell

The AppKit layer is responsible for platform integration:

- `TerminalWindowController` creates the main window and tab container.
- `SplitTerminalView` manages vertical and horizontal terminal panes.
- `TerminalInputView` handles keyboard events, IME via `NSTextInputClient`, paste, copy, and command dispatch.
- `MainMenu` wires app, file, split, tab, edit, and preferences actions.
- `PreferencesWindowController` provides the first preferences shell.
- `TerminalMetalView` hosts Metal rendering and reports frame-present timestamps to the core bridge.
- `TerminalSession` is the platform-neutral session contract. `ShellSession` is the current macOS/Darwin `forkpty` implementation selected through `TerminalSessionFactory`.
- `TerminalCore` is the app-facing terminal core contract. `CoreBridge` is the current dynamic C ABI loader selected through `TerminalCoreFactory`.

## Zig Core

The Zig layer owns state that must be fast and predictable:

- `Parser` emits printable and CSI events.
- `Grid` owns visible cell bytes and cursor movement.
- `Scrollback` stores indexed historical lines and has a one-million-line stress gate.
- `Metrics` records input-to-present latency samples.
- `RendererOrchestrator` tracks damage rectangles and frame stats before Metal consumes them.
- `abi.zig` exposes a small C ABI to the Swift shell.
- `core.zig` is the public portable barrel for the Zig core. Platform PTY adapters are not exported from that barrel.

## Metal Renderer

`TerminalRenderFrame` defines the renderer-facing frame contract without AppKit, Metal, `CGRect`, `CGSize`, or `NSRange` types. `TerminalMetalView` adapts that contract to `MTKView`, CoreText glyph rasterization, Metal buffers, dirty-rect invalidation, and presentation callbacks.

The current renderer uses Metal for glyph atlas, background, cursor, underline, strikethrough, and box-drawing passes. A future Linux or Windows renderer should consume `TerminalFrame`-shaped data through a backend-specific adapter instead of depending on AppKit or Metal types.
