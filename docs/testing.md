# Testing And Performance Gates

## Required Local Gates

```sh
zig build test
zig build
zig build bench
zig build stress-scrollback
zig build leak-check
swift build
swift test
```

## Coverage

- Parser golden behavior: printable runs and CSI SGR parameters.
- Grid behavior: wrapping, cursor movement, erase display.
- Scrollback behavior: indexed lookup, memory budget smoke, and one-million-line stress.
- Metrics behavior: key event to frame-present latency samples.
- Metal/AppKit shell: compile-time validation through SwiftPM.
- Rendering regression: `swift test` runs `KurottyRenderingTests`, including a deterministic offscreen Metal framebuffer hash. The test compiles the `TerminalMetalView` production shader string, renders terminal-frame-shaped glyph, background, decoration, and cursor instance data into a shared `MTLTexture`, reads the bitmap back, and checks both a SHA-256 snapshot hash and targeted BGRA pixel probes.
- AppKit bitmap fallback: `KurottyRenderingTests` also keeps a CPU/AppKit glyph bitmap hash for environments where display capture is unavailable.

## Runtime Foundation Verification

Run these from the repository root when changing the runtime integration surface:

| Area | Command |
| --- | --- |
| Resize cycle diagnostics | `swift test --filter TerminalResizeLedgerTests` |
| PTY/parser/screen/render event metadata | `swift test --filter TerminalEventLedgerTests` |
| Swift scrollback bounds and pressure summaries | `swift test --filter TerminalScrollbackDiagnosticsTests` |
| Shell integration command spans | `swift test --filter TerminalShellIntegrationTests` |
| AI redaction and context snapshots | `swift test --filter AIContextLayerTests` |
| AI command context bridge | `swift test --filter AICommandContextBridgeTests` |
| AI action approval decisions and audit records | `swift test --filter AIAgentActionApprovalTests` |
| Zig parser/grid/scrollback/PTY foundations | `zig build test` |
| One-million-line Zig scrollback stress gate | `zig build stress-scrollback` |
| Documentation whitespace check | `git diff --check -- docs/architecture.md docs/testing.md DESIGN.md` |

These commands prove the foundation contracts. They do not prove full live AppKit integration, installed-app behavior, or screenshot correctness unless paired with the manual checks below.

## Current Non-UI Runtime Slice Commands

Use this smaller set for `feature/non-ui-runtime-next-slice` changes. Run only the rows affected by the code or documentation change, then run the documentation whitespace check for docs edits.

| Slice | Commands |
| --- | --- |
| Source-of-truth diagnostics | `swift test --filter TerminalEventLedgerTests`<br>`swift test --filter TerminalResizeLedgerTests`<br>`zig build test` |
| Render coalescing and damage evidence | `swift test --filter TerminalPixelProbeTests`<br>`swift test --filter GlyphRenderingRegressionTests` |
| Shell opt-in metadata | `swift test --filter TerminalOSCDispatcherTests`<br>`swift test --filter TerminalShellIntegrationTests`<br>`swift test --filter TerminalCommandHistoryNavigatorTests` |
| Command UX | `swift test --filter TerminalCommandRegistryTests`<br>`swift test --filter TerminalCommandPaletteTests`<br>`swift test --filter CommandPaletteWindowControllerTests`<br>`swift test --filter TerminalCommandHistoryNavigatorTests` |
| AI agent action API | `swift build`<br>`swift test --filter AIContextLayerTests`<br>`swift test --filter AICommandContextBridgeTests`<br>`swift test --filter AIAgentActionApprovalTests` |
| Documentation-only changes | `git diff --check -- docs/architecture.md docs/testing.md DESIGN.md` |

Run `swift build` before the filtered Swift tests when source files changed. For documentation-only edits, run the documentation whitespace check first, then run the filtered Swift commands when the Swift test target compiles. A compile failure is a branch verification blocker, not a documentation pass.

The AI agent action API tests cover non-UI backend contracts only: stable request kind metadata, approval-gated handler dispatch, action-ID matching for supplied approvals, context-reference de-duplication, command-output approval state, and audit/redaction guarantees. They do not create dialogs or validate presentation behavior.

## Manual Rendering Checks

- Full-window screenshot comparison is still manual. The automated Swift tests do not launch the app, attach to a shell, or capture an `NSWindow`.
- Run `zig build` before launching the app when checking the Swift shell against the Zig ABI at runtime.
- Manual UI checks should cover live shell output, resizing, scrolling, IME/marked text, cursor position, and any visual artifact that requires the real AppKit window/display stack.

## Next Gates

- Replace the CPU/AppKit glyph hash with a production glyph-atlas text baseline after shaping/fallback font behavior is stable enough for cross-machine snapshots.
- Add an automated full-app screenshot comparison only when CI can provide a reliable macOS display-capture surface.
- Replace benchmark smoke counters with monotonic timer measurements after the Zig timing API wrapper is added.
- Add macOS PTY integration tests after `Pty.spawn` is implemented.
