# Kurotty Design

Kurotty is a macOS-first terminal emulator optimized for low latency, low memory use, and direct control over terminal rendering.

## Product Shape

- Native macOS app built with Swift/AppKit.
- Target terminal state engine built in Zig and exported through a small C ABI.
- Current live surface still includes a Swift terminal-screen scaffold until the Zig grid/parser ABI becomes the only screen source of truth.
- Text rendering path built on Metal with a glyph atlas and instanced cell drawing.
- User settings are local, versioned JSON at `Application Support/Kurotty/settings.json`.

## Architecture

### Swift/AppKit Shell

Responsibilities:

- App lifecycle, windows, tabs, splits, menus, preferences, app icon, and first responder behavior.
- Keyboard input, command shortcuts, IME composition, pasteboard actions, and shell session I/O.
- Loading `zig-out/lib/libkurotty_core.dylib` when available and falling back only in explicit, tested paths.
- Translating current terminal view state into terminal frames for Metal.

Design rules:

- Keep app and window entry points as wiring.
- Keep shell, input, preferences, settings, rendering host, and core bridge in separate types.
- Use early returns for missing pasteboard text, invalid view sizes, unavailable dylibs, unavailable Metal resources, and unsupported command selectors.
- Never expand AppKit-owned terminal protocol semantics without documenting why the temporary scaffold is still needed.

### Zig Core

Responsibilities:

- Parser, grid, scrollback, metrics, PTY boundary, renderer orchestration, and C ABI.
- Deterministic memory ownership with visible init/deinit pairs.
- Bounded scrollback and damage data structures.

Design rules:

- Keep `src/core.zig` as the module export surface.
- Keep ABI functions narrow, stable, and documented in `docs/abi.md`.
- Use explicit allocator ownership and regression tests for parser, grid, scrollback, metrics, renderer, and PTY changes.
- Avoid global mutable state. If process-wide state becomes necessary, expose lifecycle and reset behavior.

### Metal Renderer

Responsibilities:

- Glyph atlas texture management.
- Vertex, instance, uniform, background, cursor, and glyph draw calls.
- Shader behavior in `Sources/KurottyApp/Shaders/`.

Design rules:

- Keep Swift buffer structs and Metal shader structs layout-compatible.
- Put atlas sizes, slot dimensions, cursor dimensions, clear colors, and shader buffer indices behind named renderer constants.
- Use design tokens for terminal palette, font, padding, opacity, and UI color choices.
- Prefer damage-based updates over full rebuilds. Document and test any full redraw path.

### Terminal Protocol And Screen Semantics

Responsibilities:

- Classify terminal escape sequences before mutating screen or text style state.
- Preserve CSI parameter structure, including colon subparameters, through the parser boundary.
- Maintain enough cell metadata for the renderer to distinguish program output from terminal-created placeholders.

Design rules:

- SGR handling applies only to non-private `CSI ... m`. Private CSI sequences with final `m`, such as Kitty keyboard protocol `CSI > 4 ; 2 m`, must not change foreground, background, underline, dim, or any other text style.
- `;` separates CSI parameters, while `:` separates subparameters inside a parameter. SGR examples such as `4:0`, `4:3`, `38:5:n`, and `38:2::r:g:b` must stay element-based instead of being flattened into unrelated style codes.
- The Claude Code rendering failure was a protocol-classification bug: `ESC[>4;2m` was incorrectly read as SGR underline plus dim, so every following text cell appeared underlined. The durable fix is private-CSI exclusion from SGR, not a Claude-specific workaround.
- Erase, clear, scroll, insert, and delete operations create placeholder blank cells. Printable spaces from the PTY are content cells. Text decorations and link hover lines render for content cells and wide-glyph continuations according to model metadata, not by guessing from the literal space character.
- Renderer behavior should follow the terminal model. If a TUI looks wrong, first capture and inspect the PTY escape stream, then compare with a reference terminal such as Ghostty before changing renderer heuristics.
- Regression tests should cover CSI parsing, private-CSI versus SGR policy, colon SGR subparameters, placeholder blank decoration policy, and the smallest Swift rendering path affected by the bug.

## Constants, Tokens, And Settings

- Domain constants describe protocol, ABI, shell, PTY, file paths, queue labels, and timing.
- Design tokens describe UI color, typography, spacing, radius, opacity, window size, terminal cell defaults, and renderer dimensions.
- Settings JSON stores user preferences such as font, theme, scrollback limit, cursor style, shell path, and renderer options.
- Theme presets are named settings contracts. `kuro-dark` preserves the existing dark palette, `lightty` provides a bright colorful palette, and `custom` leaves user-provided color values intact.
- Defaults live in typed settings/design-token code, not in views or controllers.
- Settings changes that affect rendering or PTY behavior need validation, migration, and tests.

## Testing Strategy

Required gates by change type:

| Change | Verification |
| --- | --- |
| Zig parser/grid/scrollback/metrics/renderer | `zig build test` |
| Zig build, ABI, or package wiring | `zig build` |
| Benchmark-sensitive core path | `zig build bench` |
| Scrollback capacity or memory behavior | `zig build stress-scrollback` |
| Allocator ownership or cleanup | `zig build leak-check` |
| Swift/AppKit/Metal code | `swift build` and relevant `swift test` |
| Rendering behavior | Swift rendering tests plus visual evidence when screenshots are not automated |
| Documentation commands | Run the listed commands or mark them as unverified |

## Performance Targets

- Keep input-to-present latency measurable through the metrics path.
- Keep parser and PTY read paths allocation-conscious.
- Keep scrollback bounded and stress-tested at one million lines.
- Keep rendering work proportional to visible cells and damage; current full visible-frame rebuilds are scaffold debt until damage-region clipping is wired through the live Swift renderer.
- Add measurable evidence for performance changes before claiming improvement.

## Security And Privacy

- Terminal streams, pasted text, command history, environment variables, and local paths are sensitive.
- Do not persist raw terminal data outside explicit user-requested features.
- Do not store secrets in settings JSON or documentation.
- Keep dynamic library loading local and predictable.
- Document entitlement, sandbox, permission, and file-access changes before merging them.

## Review Checklist

- Does the change preserve Swift/AppKit, Zig, and Metal ownership boundaries?
- Are new values named constants or design tokens with units where applicable?
- Are settings represented through typed, versioned JSON rather than scattered persistence?
- Are ABI and shader layout changes reflected in docs and tests?
- Did the author run the smallest relevant verification commands and report remaining risk?
