# Kurotty Design

Kurotty is a macOS-first terminal emulator optimized for low latency, low memory use, and direct control over terminal rendering.

This design favors boring correctness over feature breadth. Rendering speed matters, but terminal state correctness comes first: PTY bytes, parsed escape events, screen mutations, and rendered cells must remain separable enough to inspect independently.

## Product Shape

- Native macOS app built with Swift/AppKit.
- Target terminal state engine built in Zig and exported through a small C ABI.
- Current live surface still includes a Swift terminal-screen scaffold until the Zig grid/parser ABI becomes the only screen source of truth.
- Text rendering path built on Metal with a glyph atlas and instanced cell drawing.
- User settings are local, versioned JSON at `Application Support/Kurotty/settings.json`.
- AI-era workflow features are app-layer features. They must not mutate terminal core state directly.

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

### Resize And Frame Truth

Responsibilities:

- Keep the measured viewport, derived terminal grid size, PTY winsize, screen size, and renderer drawable size synchronized through one resize cycle.
- Coalesce redundant resize events without hiding the final size from the PTY or renderer.
- Make resize mismatches diagnosable from metadata logs without recording terminal contents.

Design rules:

- A resize cycle follows this order: measure viewport pixels, derive rows and columns from cell metrics, apply PTY winsize, resize the screen model, invalidate renderer frame state.
- Each cycle should have a trace record with old and new pixel size, cell size, rows, columns, PTY result, screen result, renderer drawable size, and timestamp.
- Renderer clipping bugs should be debugged with cell rects, glyph bounds, dirty rects, scissor rects, and atlas slot metadata before changing terminal model semantics.
- Full redraw paths are allowed as correctness fallbacks, but they are scaffold debt until damage and clipping evidence proves narrower redraws.

### IME And Text Input

Responsibilities:

- Let AppKit own marked text, composition, and commit lifecycle.
- Draw preedit text as an overlay tied to cursor position without committing it to the screen model.
- Send text to the PTY only after AppKit commits it through `insertText` or after explicit terminal control-key handling.

Design rules:

- `setMarkedText` updates visual preedit state only; it must not write to the PTY and must not mutate committed terminal cells.
- IME debug evidence should include key event metadata, marked text updates, insert commits, unmark events, cursor cell, overlay rect, and PTY write metadata.
- Korean IME regressions should be treated as input lifecycle bugs, not fixed by synthesizing Hangul inside Kurotty.

### Shell Integration And AI Context

Responsibilities:

- Detect command lifecycle, cwd, prompt/output ranges, exit code, and duration without requiring a shell script for basic behavior.
- Expose command and pane context to AI tooling through a redacted app-layer context service.
- Keep terminal core behavior correct when shell integration is disabled, unavailable, remote, or partially supported.

Design rules:

- Start with passive OSC 7 and OSC 133 support before adding shell-specific opt-in scripts.
- Command spans belong outside the screen model, but may reference scrollback ranges and screen snapshots.
- AI tooling must consume redacted context bundles and dispatch explicit commands. It must not directly mutate screen buffers, PTY state, renderer state, or settings.
- Raw terminal output, pasted text, environment variables, and command history are sensitive. Persist them only for explicit user-requested features with redaction and retention limits.

### Workspace, Tabs, And Splits

Responsibilities:

- Provide browser-like top-level tabs and predictable split panes inside each tab.
- Support agent-era workflows where shell, agent, logs, server output, and browser-like surfaces can be viewed together.
- Persist layout state separately from process restart or agent resume policy.

Design rules:

- Model tabs and splits as a durable tree with stable pane identifiers, focus, titles, profile metadata, cwd, and restore policy.
- Session restore should rebuild layout first. Process resume, agent resume, and command replay are separate opt-in steps.
- Focus movement, pane resize, search, copy mode, quick terminal, and command palette actions should be command-dispatchable so UI, shortcuts, and automation share one action surface.

### Theme And Native UI

Responsibilities:

- Keep the terminal viewport visually quiet and predictable.
- Provide a polished macOS-native shell for tabs, splits, preferences, command palette, and status surfaces.
- Let beginners use the app without editing config while preserving deep customization for advanced users.

Design rules:

- Brand expression should stay in the app icon, subtle empty states, preferences, and small command-palette accents. Do not decorate the terminal viewport.
- Kurotty can be cute, but it must not look like a toy: restrained spacing, compact controls, clear focus states, and stable typography are more important than illustrations.
- Theme data belongs in typed settings and theme manager contracts, not scattered view colors.
- Built-in themes should be immediately usable. Custom themes should validate color contrast, required palette slots, and fallback behavior.

## Constants, Tokens, And Settings

- Domain constants describe protocol, ABI, shell, PTY, file paths, queue labels, and timing.
- Design tokens describe UI color, typography, spacing, radius, opacity, window size, terminal cell defaults, and renderer dimensions.
- Settings JSON stores user preferences such as font, theme, scrollback limit, cursor style, shell path, and renderer options.
- Theme presets are named settings contracts. `kuro-dark` preserves the existing dark palette, `lightty` provides a bright colorful palette, and `custom` leaves user-provided color values intact.
- Defaults live in typed settings/design-token code, not in views or controllers.
- Settings changes that affect rendering or PTY behavior need validation, migration, and tests.
- Each settings key should declare whether it is live-applied, next-session, or launch-only.
- GUI preferences are required for common settings. File editing remains the advanced path.
- Project or workspace settings may override profiles only through explicit precedence rules and visible UI indication.

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
- Fast-output cases such as `yes`, `cat large.log`, `npm install`, `docker logs -f`, and long AI agent transcripts must remain responsive.
- Parser batches, screen mutations, and renderer presents should be coalesced enough to avoid repaint storms while keeping input latency low.
- Scrollback storage should use bounded segments or rings rather than unbounded front-removal arrays on hot paths.

## Security And Privacy

- Terminal streams, pasted text, command history, environment variables, and local paths are sensitive.
- Do not persist raw terminal data outside explicit user-requested features.
- Do not store secrets in settings JSON or documentation.
- Keep dynamic library loading local and predictable.
- Document entitlement, sandbox, permission, and file-access changes before merging them.
- Clipboard reads from terminal escape sequences should default to ask. Clipboard writes should be policy-controlled and visible.
- Remote shell title, notification, URL open, and clipboard actions should go through profile security policy.
- OSC 52, URL/file links, shell integration scripts, command history, and AI context export require explicit redaction and audit behavior.

## Review Checklist

- Does the change preserve Swift/AppKit, Zig, and Metal ownership boundaries?
- Are new values named constants or design tokens with units where applicable?
- Are settings represented through typed, versioned JSON rather than scattered persistence?
- Are ABI and shader layout changes reflected in docs and tests?
- Did the author run the smallest relevant verification commands and report remaining risk?
