# Architecture

## Swift/AppKit Shell

The AppKit layer is responsible for platform integration:

- `TerminalWindowController` creates the main window and tab container.
- `SplitTerminalView` manages vertical and horizontal terminal panes.
- `TerminalInputView` handles keyboard events, IME via `NSTextInputClient`, paste, copy, and command dispatch.
- `MainMenu` wires app, file, split, tab, edit, and preferences actions.
- `PreferencesWindowController` provides the first preferences shell.
- `TerminalMetalView` hosts Metal rendering and reports frame-present timestamps to the core bridge.

## Zig Core

The Zig layer owns state that must be fast and predictable:

- `Parser` emits printable and CSI events.
- `Grid` owns visible cell bytes and cursor movement.
- `Scrollback` stores indexed historical lines and has a one-million-line stress gate.
- `Metrics` records input-to-present latency samples.
- `RendererOrchestrator` tracks damage rectangles and frame stats before Metal consumes them.
- `abi.zig` exposes a small C ABI to the Swift shell.

## Metal Renderer

The current renderer scaffold creates an `MTKView`, loads a Metal pipeline from package resources, tracks full-surface damage, and presents frames. The next rendering milestone is replacing the clear-pass scaffold with real glyph atlas population and dirty-cell quad emission.
