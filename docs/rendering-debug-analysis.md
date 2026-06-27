# Kurotty Rendering Debug Analysis

## Scope

This note documents the investigation behind the bottom input line, cursor placement, and stale background artifacts seen while running Codex TUI in kurotty.

The goal is not to special-case Codex. A terminal emulator should render the terminal model: grid cells, attributes, and one model cursor. TUI input rows belong to the terminal grid unless kurotty explicitly owns a UI outside the terminal viewport.

## Current Rendering Structure

- `ShellSession` owns the PTY and forwards decoded UTF-8 output to `TerminalSurfaceView`.
- `TerminalSurfaceView` parses control bytes, maintains `TerminalScreen`, cursor row/column, current SGR style, selection, and damage.
- `TerminalSurfaceView.updateMetalFrame()` converts the model into a `TerminalFrame`.
- `TerminalMetalView` renders `TerminalFrame` with Metal:
  - merged cell background runs
  - glyph atlas instances
  - decorations
  - one cursor rectangle
  - optional debug overlay

The terminal grid is the only source of truth for TUI content. Codex's `>` prompt marker and gray input row are PTY output, not a native AppKit input overlay.

## Ghostty Reference

Ghostty keeps the same ownership boundary: terminal data lives in the terminal model, while the renderer projects grid cells and cursor state into pixels. Relevant references from the upstream Ghostty repository:

- Repository: https://github.com/ghostty-org/ghostty
- Terminal API entry points: https://github.com/ghostty-org/ghostty/blob/9f62873bf195e4d8a762d768a1405a5f2f7b1697/src/terminal/Terminal.zig#L44-L45
- Screen model: https://github.com/ghostty-org/ghostty/blob/9f62873bf195e4d8a762d768a1405a5f2f7b1697/src/terminal/Screen.zig#L78-L85
- Page/cell structures: https://github.com/ghostty-org/ghostty/blob/9f62873bf195e4d8a762d768a1405a5f2f7b1697/src/terminal/page.zig#L1907-L1951
- Generic renderer grid path: https://github.com/ghostty-org/ghostty/blob/9f62873bf195e4d8a762d768a1405a5f2f7b1697/src/renderer/generic.zig#L2323-L2425
- Metal backend viewport/draw path: https://github.com/ghostty-org/ghostty/blob/9f62873bf195e4d8a762d768a1405a5f2f7b1697/src/renderer/Metal.zig#L2140-L2189
- Cursor renderer model: https://github.com/ghostty-org/ghostty/blob/9f62873bf195e4d8a762d768a1405a5f2f7b1697/src/renderer/cursor.zig#L34-L67

The useful principle for kurotty is not code reuse. It is the ownership split: parser updates model, renderer draws model, cursor is one projected model cursor.

## Evidence Added

Debug flags:

- `--debug-pty-log` or `KUROTTY_DEBUG_PTY_LOG=1`
- `--debug-screen-dump` or `KUROTTY_DEBUG_SCREEN_DUMP=1`
- `--debug-layout` or `KUROTTY_DEBUG_LAYOUT=1`
- `--debug-full-model-redraw` or `KUROTTY_DEBUG_FULL_MODEL_REDRAW=1`
- `--debug-render-rects` or `KUROTTY_DEBUG_RENDER_RECTS=1`

Instrumentation now records:

- raw PTY bytes and escaped decoded text
- cursor row/column
- row text
- foreground/background style runs
- dirty/full damage state
- render pass load/store action
- clear color and background color
- drawable and cursor rect diagnostics

These logs separate parser/model defects from renderer defects. If the screen dump already has a broken background run, the renderer should not be patched around it.

## Reproduction Logic

The minimal model-level issue is equivalent to:

```text
ESC[48;5;250m> input text ESC[K
```

The expected behavior for erase-in-line is that erased cells keep the active erase style. Before this fix, `ESC[K` called `TerminalScreen.clear(...)` without `currentStyle`, producing default-background cells after the cursor. That makes an input row look split even before Metal draws it.

This explains why widening dirty rects or drawing a second input rectangle did not stabilize the result: the terminal model itself no longer described one continuous gray input row.

## Root Cause Classification

### A. Parser/Model Problem

Confirmed.

`eraseInLine` and related erase/insert/delete operations created default `TerminalScreenCell()` values. For TUI rows that set an active background color and then clear to the end of line, kurotty discarded that background.

Fix:

- `TerminalScreen.clear(...)` accepts a style.
- `eraseInLine` and `eraseInDisplay` pass `currentStyle`.
- character/line insert and delete fill newly blank cells with `currentStyle`.

### C. Overlay Duplicate Rendering Problem

Confirmed.

The renderer contained input-line-specific expansion logic. It tried to infer a Codex-like row from background color and cursor position, then generated a separate input background. That created a second source of truth for a row that already exists in the terminal grid.

Fix:

- Removed input-line layout/background inference from `TerminalMetalView`.
- Removed input-line-specific background expansion.
- Backgrounds now come from merged terminal cell runs only.
- Cursor is still drawn once from model row/column.

### D. Damage Redraw Risk

Partially mitigated.

Full redraw is enabled as the current safe path. The Metal render pass is configured with `.clear` every frame and does not rely on previous drawable contents. Dirty rectangles are still tracked for diagnostics, but rendering no longer depends on stale input-line fragments.

### E. Buffer Lifecycle Risk

One concrete issue was found.

`isAtlasPathReadyForRendering` previously required `atlasInstanceCount > 0`. That prevented background and cursor quads from rendering on frames with no visible glyphs. The readiness check now only verifies resources; glyph instance count only controls the glyph draw call.

## Coordinate Findings

The cursor source is `TerminalSurfaceView.cursorRow/cursorColumn`. The Metal cursor rect is derived from:

```text
x = padding + cursorColumn * fixedCellWidth
y = bounds.height - padding - fixedCellHeight * (cursorRow + 1)
```

The cursor path should not have its own input-line coordinate system. With the overlay removed, the remaining expected mismatch sources are parser cursor position, row/column conversion, or font metric/pixel snapping.

## Current Fix Direction

The minimal safe repair is:

1. Keep Codex input/status rows in the terminal grid.
2. Remove inferred input overlay geometry.
3. Preserve active SGR style when erase/insert/delete creates blank cells.
4. Full-clear/full-model-redraw before reintroducing narrower damage.
5. Keep debug logging available to compare model row/col with pixel rects.

## Regression Checks

Run:

```sh
swift test --filter GlyphRenderingRegressionTests
swift test
zig build test
git diff --check
```

Manual checks:

```sh
KUROTTY_DEBUG_PTY_LOG=1 KUROTTY_DEBUG_SCREEN_DUMP=1 KUROTTY_DEBUG_RENDER_RECTS=1 swift run kurotty
```

Then run:

- `codex`
- `/status`
- type and delete input text
- move cursor left/right
- resize the window
- compare `bgRuns` for the input row with the visible gray band

The expected state is that the input row's gray background appears as terminal cell background runs, not as a separate overlay background.
