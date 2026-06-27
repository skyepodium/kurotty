# TUI Rendering Debug Notes

## Current Symptom

Codex TUI looked different in kurotty than iTerm2: bottom input/status rows moved or clipped, typing caused redraw instability, and old output appeared to overlap newer output.

## Source Of Truth

TUI input rows are terminal grid content. Kurotty should not infer a native input rectangle for Codex. The parser owns cells, attributes, cursor row/column, and scroll margins; Metal draws that model every frame.

## Root Cause

The remaining high-confidence model defect was missing DECSTBM support. Kurotty ignored `CSI r`, so TUIs could not reserve a scroll region above their input/status area. Line feed, reverse index, `CSI S/T`, and line insert/delete operated on the full screen. iTerm2 honors the scroll region, so bottom rows stay fixed there.

Secondary edge case: when the cursor was already past the last column, `ESC[K` clamped the clear range into the last column instead of no-oping.

## Fix

- Added `scrollRegionTop` and `scrollRegionBottom` to `TerminalSurfaceView`.
- Added `CSI r` handling with cursor home and full damage.
- Made LF, RI, `CSI S/T`, and line insert/delete region-aware.
- Added region-aware `TerminalScreen` mutators.
- Reset scroll region on resize, reset, and alternate-screen transitions.
- Kept erase/insert/delete blanks styled with `currentStyle`.
- Made past-end clear ranges no-op before clamping.

## Debug Flags

```sh
KUROTTY_DEBUG_PTY_LOG=1 \
KUROTTY_DEBUG_VT_PARSER=1 \
KUROTTY_DEBUG_SCREEN_DUMP=1 \
KUROTTY_DEBUG_SCROLL_REGION=1 \
KUROTTY_DEBUG_BACKGROUND_RUNS=1 \
KUROTTY_DEBUG_RENDER_RECTS=1 \
swift run kurotty
```

Useful checks:

- `scrollRegion` should match the rows a TUI keeps fixed.
- `screen dump` should show gray input background as cell background runs.
- `background runs` should include trailing non-default background cells even when they contain spaces.
- `render frame` should show `.clear` load action and full redraw diagnostics.

## Regression Tests

Run:

```sh
swift test --filter GlyphRenderingRegressionTests
swift test
zig build test
git diff --check
```

Manual:

- Run `codex`.
- Run `/status`.
- Type and delete text in the bottom input row.
- Resize the window.
- Compare against iTerm2 using the same shell, font, and theme.
