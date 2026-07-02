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

## Runtime Foundation Boundaries

The runtime foundation is an integration surface, not a second terminal model. It records bounded metadata that lets the Swift shell, Zig core, renderer, command services, and future AI tools agree on what happened without copying terminal output into long-lived app state.

| Boundary | Current Foundation | Integration Rule |
| --- | --- | --- |
| Resize | `TerminalResizeTrace` records requested winsize and optional view/cell measurements. `TerminalResizeCycleSnapshot` compares the derived grid with PTY, screen, and renderer sizes. | Resize wiring must measure the AppKit viewport, derive rows and columns from cell metrics, apply PTY winsize, resize screen state, and invalidate renderer state. Ledger snapshots are diagnostics only; they do not choose the winning size. |
| Event flow | `TerminalEventLedger` groups metadata-only events under a `TerminalEventTraceID`: PTY read byte counts, parser event kinds, screen mutation counts, and render-frame metadata. | The ledger may tie PTY, parser, screen, and renderer stages together for debugging. It must not store raw bytes, terminal text, pasted text, command output, or environment values. |
| Scrollback | Zig `Scrollback` owns portable core scrollback behavior. Swift `BoundedScrollbackRows`, `SegmentedScrollbackStore`, and `TerminalScrollbackDiagnosticsSummary` provide bounded app-layer storage and pressure summaries. | Search, copy mode, command spans, and AI context may reference scrollback ranges through stable coordinates or summaries. They must not create unbounded copies of raw scrollback content. |
| Command context | `TerminalShellIntegration` consumes OSC 7 and OSC 133 metadata into command spans. `TerminalCommandRegistry` owns app/window command identifiers and shortcuts. | Shell command spans are app-layer metadata. They may feed search, copy mode, workspace restore, notification, and AI context bridges, but they must not mutate terminal cells or replace parser state. |
| AI approval | `AIContextLayer`, `AICommandContextBridge`, `AIAgentActionApproval`, and `TerminalSecurityPolicy` define redacted context snapshots and policy-backed action decisions. | AI tools consume redacted app-layer context and dispatch explicit commands. Sending text, pasting text, opening local files, exporting raw output, or persisting context must pass through approval/evaluation before touching the terminal session. |

These boundaries are intentionally metadata-first. When live integration is added, app code should wire existing session, screen, renderer, and security services into these contracts instead of introducing parallel histories, raw-output logs, or AI-specific shortcuts around terminal ownership.

## Metal Renderer

`TerminalRenderFrame` defines the renderer-facing frame contract without AppKit, Metal, `CGRect`, `CGSize`, or `NSRange` types. `TerminalMetalView` adapts that contract to `MTKView`, CoreText glyph rasterization, Metal buffers, dirty-rect invalidation, and presentation callbacks.

The current renderer uses Metal for glyph atlas, background, cursor, underline, strikethrough, and box-drawing passes. A future Linux or Windows renderer should consume `TerminalFrame`-shaped data through a backend-specific adapter instead of depending on AppKit or Metal types.
