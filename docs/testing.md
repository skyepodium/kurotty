# Testing And Performance Gates

## Required Local Gates

```sh
zig build test
zig build
zig build bench
zig build stress-scrollback
swift build
```

## Coverage

- Parser golden behavior: printable runs and CSI SGR parameters.
- Grid behavior: wrapping, cursor movement, erase display.
- Scrollback behavior: indexed lookup, memory budget smoke, and one-million-line stress.
- Metrics behavior: key event to frame-present latency samples.
- Metal/AppKit shell: compile-time validation through SwiftPM.

## Next Gates

- Add deterministic glyph screenshot baselines once text quads render actual atlas glyphs.
- Replace benchmark smoke counters with monotonic timer measurements after the Zig timing API wrapper is added.
- Add macOS PTY integration tests after `Pty.spawn` is implemented.
