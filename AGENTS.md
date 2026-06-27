# Kurotty Agent Rules

These rules apply to the whole repository. Follow the closest `AGENTS.md` first if a narrower one is added later.

## Scope

- Kurotty is a macOS Swift/AppKit + Zig + Metal terminal emulator.
- Swift/AppKit owns windows, menus, tabs, splits, keyboard input, IME, pasteboard, shell lifecycle, preferences, and the bridge to Zig.
- Zig owns the target terminal state engine: parser, grid, scrollback, PTY boundary, renderer orchestration, metrics, allocation, and C ABI exports.
- The current AppKit surface still contains a Swift screen/parser scaffold until Zig becomes the live screen source of truth.
- Metal owns GPU rendering: glyph atlas, instance buffers, cell/background/cursor/decoration drawing, and shader behavior.
- Do not edit source code while doing documentation-only work.
- Do not revert user changes. Read the worktree first and keep diffs small.

## Code Style

- Prefer guard clauses and early returns. Handle unsupported state, empty input, missing resources, invalid dimensions, and unavailable GPU/ABI resources at the top of the function.
- Keep the happy path shallow. Split nested parser, rendering, shell, or settings logic into named helpers when branching grows.
- Use direct names. Avoid abbreviations unless they are terminal standards (`CSI`, `OSC`, `PTY`, `SGR`, `ABI`, `IME`, `GPU`).
- Keep AppKit entry points thin. `AppDelegate`, menu wiring, and window controllers should compose services/views instead of owning terminal behavior.
- Keep Zig modules explicit and allocation-aware. Functions that allocate must make ownership and cleanup visible at the call site.
- Keep Metal shader structs and Swift buffer layouts in sync. Any layout change requires a matching regression test or documented manual verification.

## Constants And Tokens

- Do not add hardcoded magic values. Put new numeric and string values behind named constants, enums, or token objects before use.
- Include units in names: `*_PX`, `*_MS`, `*_MICROS`, `*_ROWS`, `*_COLUMNS`, `*_BYTES`, `*_COUNT`, `*_RATIO`.
- Keep domain constants separate from design tokens.
- Terminal protocol numbers are allowed only when named by protocol meaning. Examples: SGR color mode, escape byte, delete byte, default cursor movement count.
- UI values such as font sizes, padding, colors, atlas dimensions, cursor thickness, scroll sensitivity, and window sizes belong in design tokens or renderer constants.
- Storage keys, settings keys, bundle resource names, dylib paths, dispatch queue labels, menu titles, and command strings must be named constants.
- Test fixtures may define local named constants. Do not hide unexplained values inside assertions.

## Settings JSON

- User-editable settings must be modeled as versioned JSON, not scattered `UserDefaults` keys.
- The canonical user settings file is `Application Support/Kurotty/settings.json`.
- Settings need typed defaults, schema versioning, validation, and migration rules before they affect rendering, shell, or PTY behavior.
- Keep settings keys stable and documented. Rename keys only with a migration path.
- Do not persist secrets, raw terminal output, pasted text, command history, or environment dumps in settings.

## Project Structure

- `Sources/KurottyApp/`: Swift/AppKit shell, Metal host view, app lifecycle, input, preferences, and Zig bridge.
- `Sources/KurottyApp/Shaders/`: Metal shader source loaded by SwiftPM resources.
- `src/`: Zig terminal core and public module exports.
- `tests/`: Zig core tests and Swift rendering regression tests.
- `bench/`: benchmark smoke checks.
- `stress/`: high-volume stress gates.
- `docs/`: architecture, ABI, testing, and other developer documentation.
- Keep cross-language contracts in docs and tests when changing `src/abi.zig`, `CoreBridge`, shader buffer layouts, or settings schema.

## Assets

- Keep the project icon at `kurotty.png` and `Sources/KurottyApp/Resources/kurotty.png` as matching PNG files.
- Kurotty app icon PNGs must be 1024 x 1024 px RGBA, with transparent rounded-corner alpha.
- Keep the cat artwork visually readable inside the icon; do not shrink the artwork to fix Dock sizing.
- Dock sizing is controlled in AppKit: the loaded application icon `NSImage` must be assigned a 50 x 50 pt logical size before setting `NSApp.applicationIconImage`.
- Keep the README image markup at 400 x 400 unless intentionally changing the README layout.

## Testing And Verification

- Run the smallest relevant gate first, then broaden before claiming completion.
- Zig parser/grid/scrollback/metrics/renderer changes require `zig build test`.
- Zig ABI, build, or package changes require `zig build`.
- Performance-sensitive Zig changes require `zig build bench`; scrollback changes also require `zig build stress-scrollback`.
- Allocation and ownership changes require `zig build leak-check`.
- Swift/AppKit/Metal changes require `swift build` and relevant `swift test` coverage.
- UI or rendering changes require visual evidence when automated screenshot coverage is missing.
- Documentation changes that list commands must use commands that were run successfully in the current branch, or explicitly mark them as unverified.

## Performance

- Preserve low latency and bounded memory as product requirements, not optional cleanup.
- Avoid unnecessary allocations on parser, PTY read, input, frame build, glyph atlas, and draw paths.
- Do not rebuild buffers, textures, glyphs, or screen rows unless input, layout, damage, or settings require it.
- Keep damage tracking narrow. Full-surface redraws need a documented reason and should be treated as scaffold debt.
- Add before/after evidence for performance work: benchmark output, stress result, latency metric, allocation evidence, or frame/render observation.

## Security And Privacy

- Treat terminal input, output, pasteboard contents, environment variables, paths, and command history as sensitive.
- Do not log raw terminal streams, pasted text, shell commands, environment dumps, or PII.
- Do not commit secrets, private keys, tokens, provisioning files, or real user settings.
- Sanitize paths and dynamic library loading. Do not add broad search paths or network loading for the Zig core.
- Shell/PTTY code must close file descriptors, clean up child processes, and avoid leaking handles across exec boundaries.
- Entitlements, permissions, sandbox changes, and file access expansion require documentation of purpose and risk.

## Code Review Standards

- Review diffs before handoff. Remove accidental source, generated, build artifact, and cache changes.
- Check public contracts separately: C ABI, settings schema, shader buffer layouts, terminal protocol behavior, and user-visible preferences.
- Every PR summary should include intent, changed files, verification commands, and remaining risk.
- Review comments require technical validation. If a suggestion is not applied, document the reason briefly.
- Do not mix unrelated cleanup with behavior changes.
