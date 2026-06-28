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
- Every settings key must declare its lifecycle contract: live-applied, next-session, or launch-only.
- Do not store per-session shell launch state in the global settings JSON unless it is explicitly an app-wide default. Session state belongs with the pane or shell lifecycle.
- Do not perform filesystem existence checks during settings load/save on the main actor. Validation that touches the filesystem must be isolated from UI-thread config serialization or deferred to the launch boundary.
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

## macOS IME Input

- macOS IME composition belongs to AppKit. Do not manually compose Hangul jamo, normalize partial jamo into syllables, or hide pending jamo in Kurotty code.
- `keyDown` for printable text must offer the event to `NSTextInputContext` first. The required order is `view.inputContext?.handleEvent(event)` and only then a fallback such as `interpretKeyEvents([event])` if AppKit did not handle it.
- Do not send `event.characters` or `charactersIgnoringModifiers` directly to the PTY for printable text when an IME path may own the event.
- PTY writes for text input must come from confirmed `insertText` or from explicit terminal control keys only. `setMarkedText` is preedit state and must not write to the PTY.
- `setMarkedText`/marked text is a visual composition overlay; clear or redraw it without mutating the terminal screen buffer as committed text.
- Input-source changes may discard stale AppKit marked text, but must not synthesize replacement text.
- The critical regression case is: type `d` in English, switch to Korean IME, type `안녕`; PTY output must be `d안녕`, not `dㅇㅏㄴ녕` or any compatibility-jamo sequence.
- IME verification must include real event-flow evidence when possible: `keyDown`, `setMarkedText`, `insertText`, `unmarkText`, and PTY write logs. Source-shape tests alone are not enough to claim an IME fix.

## Assets

- `kurotty-profile.png` is the source image for the Kurotty cat icon. Preserve it as an input asset and do not overwrite, resize, crop, delete, or regenerate it during icon replacement work.
- `kurotty.png` and `Sources/KurottyApp/Resources/kurotty.png` are generated icon outputs. They must always contain matching bytes.
- Never regenerate an icon from a previously generated `kurotty.png`. Repeated crop/resize passes compound the scale error and make the cat progressively smaller. Delete generated outputs if needed, then rebuild them exactly once from `kurotty-profile.png`.
- Kurotty app icon PNG outputs must use this contract:
  - PNG canvas: 1024 x 1024 px.
  - Color/alpha: RGBA.
  - Visible icon tile: 825 x 825 px, centered in the 1024 px canvas at offset (99, 99).
  - Transparent padding: everything outside the centered visible tile is transparent.
  - Visible tile content: scale the full square source image uniformly into the 825 x 825 px tile. Do not crop the cat, do not independently scale the foreground cat, and do not add extra internal padding.
  - Visible tile corner radius: preserve the current macOS-style radius ratio, `224 / 1024`; for an 825 px visible tile this is about 180 px.
- The 825 px visible tile is an observed Dock calibration for this project: a full 1024 px visible tile rendered around 65 px in the Dock, while 790 px rendered slightly small; 825 px is the current target for an approximately 50 px perceived Dock icon.
- Dock sizing is a two-part contract: keep the PNG visible tile at 825 px and keep the loaded application icon `NSImage` assigned a 50 x 50 pt logical size before setting `NSApp.applicationIconImage`.
- Keep the cat artwork visually readable inside the icon. If the icon appears too large or too small in the Dock, adjust only the centered visible tile size from `kurotty-profile.png`; never shrink or crop just the cat foreground.
- Keep the README image markup at 400 x 400 unless intentionally changing the README layout.
- After changing icon assets, verify all of the following before handoff:
  - `kurotty-profile.png` still exists and is unchanged unless the user explicitly requested changing the source.
  - `kurotty.png` and `Sources/KurottyApp/Resources/kurotty.png` are byte-identical.
  - Both generated PNGs are 1024 x 1024 px and have alpha.
  - The generated alpha bounding box is exactly 825 x 825 px at `(99, 99, 924, 924)`.
  - `swift build` succeeds and the SwiftPM resource bundle copy of `kurotty.png` matches `Sources/KurottyApp/Resources/kurotty.png`.
  - Restart Kurotty after the build so the Dock uses the new bundled icon.

## Testing And Verification

- Run the smallest relevant gate first, then broaden before claiming completion.
- Source-shape tests may guard wiring and regressions, but do not prove behavior by themselves. Pair them with executable behavior tests, integration tests, or documented manual evidence before claiming a user-visible fix.
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
