# Should any part of Kurotty be Rust?

The question as asked is "Swift → Rust", but Kurotty is not a Swift-only app. It
is Swift/AppKit for the application, Zig for a core library loaded at runtime,
and Metal for rendering. So the question is narrower: **the only place a third
language could go is where the second language already is**, and before choosing
between Zig and Rust you have to establish what that slot currently holds.

It holds a parser that no longer runs on the output path, and a dylib that still
ships.

This document has been revised once. The first version rejected Rust partly on a
claim that has since been empirically refuted: that the `vte` crate loses because
its value is a Rust trait against a grid **on the same side of the boundary**,
and Kurotty's grid is on the Swift side, so adopting it means moving the grid,
which is the whole rewrite. **Rio disproves the "you cannot move the grid" step**
— `librio` moves it, and a Swift frontend renders across it. Section 4 replaces
that argument. The conclusion survives, but for a different and sharper reason,
and the superseded reasoning is marked where it appears.

Claims are marked **[verified]** when something was run and its output observed,
and **[read]** when they rest on reading the code. Anything unmarked is a
judgement call, not a finding. Kurotty measurements were taken on the development
machine (Apple silicon, Zig 0.16.0, Swift 6.3.3) and are single-machine numbers,
not a benchmark suite. Rio claims were checked against a clone of
`github.com/raphamorim/rio` at `76faf8a` (2026-08-07) and the GitHub API on the
same day; paths given as `librio/...` and `frontends/canario/...` are paths in
that repository, not in Kurotty.

---

## 0. The headline

The first version's lead recommendation has landed. `core.feed` is off the output
path (`edcbb7d`, "perf: drop the shadow parser from the output path, port the VT
corpus to Swift") **[verified]**. `feed` is deliberately absent from the
`TerminalCore` protocol so no production path can reach it
(`Sources/KurottyCore/TerminalCore.swift:1-16`), and `CoreBridge.feed` survives
off-protocol for the ABI conformance test only
(`Sources/KurottyApp/CoreBridge.swift:136-142`). The Zig VT corpus was ported to
Swift (`tests/KurottyRenderingTests/TerminalVTCorpusTests.swift`).

The measurement that made the language question answerable stands, and is worth
restating because it is what any Rust proposal has to beat. Measured against the
shipped `ReleaseFast` dylib through `dlopen`, exactly as `CoreBridge` loaded it,
before the parser was cut **[verified]**:

| Workload, 120×40 grid | Shipped | Same code, `DebugAllocator` → `smp_allocator` | Factor |
|---|---|---|---|
| Plain 80-column lines | 4.88 MB/s | 25.49 MB/s | 5.2× |
| SGR-wrapped 80-column lines | 5.38 MB/s | 28.64 MB/s | 5.3× |
| Per-cell 256-colour churn | **1.59 MB/s** | 77.71 MB/s | **49×** |

The right-hand column is the same Zig source with one line changed —
`src/abi.zig:4` — built in the same mode:

**The core was not slow because it is Zig. It was slow because it ships a
debugging allocator and allocates per parser event.** A Rust rewrite that kept
the same design would land in the same place; a Rust rewrite that fixed the
design would win exactly what the one-line Zig change already wins. That line is
still `std.heap.DebugAllocator(.{ .thread_safe = true })` today
(`src/abi.zig:4`) **[verified]**, in a dylib that is still built, signed,
`lipo`'d and shipped.

So the live question is no longer "is the Zig parser costing us". It is: **is
there a native core worth having at all, and if so, in which language.** Section
4 is the new evidence on that; sections 8 to 10 answer it.

---

## 1. What the non-Swift core actually does today

### Every export, and whether Swift calls it

`src/abi.zig` exports 17 symbols. `CoreBridge` resolves 14 of them
(`CoreBridge.swift:231-248`). Live call sites in `Sources/`
**[verified by grep]**:

| Export | Swift wrapper | Non-test callers in `Sources/` |
|---|---|---|
| `create` / `destroy` | `CoreBridge.init` / `deinit` | `TerminalCoreFactory.swift:5`, one per surface |
| `feed` | `CoreBridge.feed:136` | **none** — off `TerminalCore`, ABI test only |
| `mark_damage` | removed with `feed` | **none** |
| `record_key` | `recordKeyEvent` | live |
| `record_present` | `recordFramePresented` | live |
| `resize` | `resize(cols:rows:)` | resize path |
| `last_latency` | `lastLatencyMicros` | **none** |
| `begin_frame` / `end_frame` | `beginFrame` / `endFrame` | **none** |
| `cell_at`, `copy_row`, `copy_row_cells` | `cell(row:col:)`, `copyRow`, `copyStyledRow` | **none** |
| `last_error` | resolved, no wrapper | **none** |
| `cursor_row`, `cursor_col`, `width`, `height` | not resolved | **none** |

Every export that could return screen state has zero non-test callers. What
remains live is `create`/`destroy`/`resize` and the two timestamp calls feeding a
latency metric that `lastLatencyMicros` never reads.

The self-diagnostics still say so out loud (`CoreBridge.swift:108-118`):

```
parserMutationOwner: .swiftScaffold
screenMutationOwner: .swiftScaffold
renderMutationOwner: .swiftScaffold
mutationHandoffReady: false
```

### Zig that Swift cannot reach at all

`src/` is 1,820 lines across 10 files. Three modules have no export path
whatsoever **[verified by grep]**: `src/scrollback.zig` (66), `src/pty.zig`
(182) and `src/screen_mutation.zig` (189) are imported by `src/core.zig` and
reachable only from `tests/core_tests.zig` and `bench/main.zig`. That is 437
lines, 24% of the core, that no ABI touches. The Swift side has its own
`SegmentedScrollbackStore`, its own PTY in `ShellSession.swift`, and its own
`TerminalEventLedger.ScreenMutation`.

### Does it earn its place?

No. It no longer costs main-actor time per output chunk — that was the fix — but
it still costs a Zig toolchain in three workflows, two cross-compiles, a separate
codesign, a `lipo -verify_arch` gate, and a `dlopen` boundary with an
`unsafeBitCast` behind it (`CoreBridge.swift:308`). Against that, it provides one
thing nothing else does: an input-to-present latency metric (`src/metrics.zig`) —
with zero readers.

---

## 2. Where the time actually goes

Nothing in the shipping app measures this. There are **zero** occurrences of
`os_signpost` or `OSSignposter` in `Sources/` **[verified]**; the only timing
call in the tree is `monotonicMicros()` inside `CoreBridge.swift`, feeding the
metric nobody reads. `bench/main.zig` has no timing at all — it prints counters,
so `zig build bench` (run on every push, `ci.yml:22-23`) can only fail on a
crash.

**Before the first version of this document, nobody knew.** What follows are
first numbers, not a measurement culture.

### The output path, end to end

PTY bytes are read on `readQueue`, decoded to `String`, and delivered to the main
queue (`ShellSession.swift:512`). Everything after that is main-actor and
sequential (`TerminalSurfaceView.appendOutput`, line 1854 onward):

```
interpreter.interpret(text)                                :1874
updateRendererFrame()                                      :1889 → :1250
  └─ rebuildAtlasBuffers() on the next draw                TerminalMetalView.swift:1471
```

PTY backpressure is implemented (`TerminalOutputBackpressure.swift` plus the
suspend/resume pair in `ShellSession.swift`) **[read]**. The main actor, not the
kernel buffer, is the constraint.

### Measured cost per stage

**Swift interpreter inner loop [verified, replica]**: `interpret` iterates
`Character` — grapheme clusters — and calls `appendPrintable(String(character))`,
one `String` allocation per printable character
(`TerminalOutputInterpreter.swift:109-113`). A standalone replica of exactly that
loop shape, with the real `isTerminalPrintableGrapheme` predicate:

| Loop | Throughput | Per byte |
|---|---|---|
| `for character in text` + `String(character)` | 32.1 MB/s | 31.2 ns |
| The same counting loop over `text.utf8` | 792 MB/s | 1.26 ns |

**25× apart, in the same language, at `-O`.** The replica does far less work per
character than the real `appendPrintable` (no `wcwidth`, no wrap handling, no
`screen.set`), so 32 MB/s is an *upper bound* on the real interpreter, not an
estimate of it. This is now the largest known cost on the output path, and it is
a Swift-side representation problem.

**The per-cell walks [verified, replica]**: `updateRendererFrame` walks every
visible cell building three fresh arrays (`TerminalSurfaceView.swift:1250`), then
`rebuildAtlasBuffers` walks `terminalFrame.cells` again ignoring `dirtyRows`
(`TerminalMetalView.swift:1471-1490`) **[verified, still true]**. Replicas of
both, over a 120×40 viewport:

| Walk | Per flush | Per cell |
|---|---|---|
| `updateRendererFrame` | 0.086 ms | 17.8 ns |
| `rebuildAtlasBuffers` | 0.120 ms | 25.0 ns |
| Both, one output flush | **0.195 ms** | 40.7 ns |

That is **2.3% of an 8.3 ms frame budget at 120 Hz**. Damage tracking does not
reduce CPU here, and instances are re-encoded once per scissor rect
(`TerminalMetalView.swift` calls `encodeTerminalContent` inside the rect loop).
Both are true. Neither is where the time is. Keep this number: **40.7 ns/cell,
in-process, no FFI** is the figure any per-cell FFI boundary has to be compared
against. Section 4 is where that matters.

### What is still unmeasured

- Real `interpret` throughput in situ (the replica is a lower bound on cost).
- Glyph rasterisation and atlas-miss cost, per new glyph rather than per cell.
- The `String` decode at the PTY boundary (`ShellSession.swift:512`).
- Anything at large viewports. All figures above are 120×40; a 300×100 pane is
  6× the cells and would put the two walks near 1.2 ms/flush.
- **The cost of a C-ABI call returning a small struct by value, per cell.** No
  number is claimed for it anywhere in this document. It is the single most
  important number to obtain before any of section 4's options is taken
  seriously.

---

## 3. Is any hot path limited by the language?

For every hot path found, no.

| Hot path | Actual limit | Language-bound? |
|---|---|---|
| Zig `feed` (historic), 1.59 MB/s coloured | `DebugAllocator` in production (`src/abi.zig:4`) plus one heap allocation per parser event | **No.** One line recovers 49×. Moot now: the call is gone. |
| Swift `interpret` | `Character` grapheme iteration and `String(character)` per printable char | **No.** 25× available by iterating `text.utf8`, still in Swift. |
| `updateRendererFrame` / `rebuildAtlasBuffers` | Walks every cell regardless of damage | **No.** Rust would carry the same walk. 40.7 ns/cell is not a language ceiling. |
| Per-rect re-encode | No area-crossover heuristic, 64-rect budget | **No.** GPU-side algorithm. |

The one place where a language-level cost is genuinely visible is the screen
representation, and even there the fix is Swift-side:

`TerminalScreen.cells` is `[[TerminalScreenCell]]` (`TerminalScreen.swift:6`) —
one heap allocation per row. `TerminalScreenCell` measures **96 bytes stride**
**[verified]**, of which two fields are ARC-managed: `character: Character` and
`linkURL: String?`. The Zig equivalent is a 16-byte POD `extern struct`, with a
compile-time size assertion (`src/cell.zig:60-71`) **[verified]**. A 120×40
viewport is 460 KB of Swift cells against 76 KB of Zig cells, plus retain/release
traffic on every cell copy.

That is a real 6× memory difference and real ARC traffic — and it is a **data
layout choice, not a language limit**. Swift can hold a flat `[UInt32]`/`[UInt64]`
cell array with an out-of-line side table for links and grapheme clusters, which
is what Ghostty and Alacritty both do in their own languages.

---

## 4. Rio: the counter-example, and what survives it

### 4.1 What `librio` is

`librio` is a crate in the Rio repository, `crate-type = ["rlib", "staticlib"]`,
described in its own manifest as "Embeddable terminal core extracted from Rio:
PTY, VT state, render-state pull API, exposed as a C ABI"
(`librio/Cargo.toml`) **[verified]**. Its README states: "No drawing or windowing
code — bring your own renderer" (`librio/README.md`) **[verified]**. It is not
published to crates.io; each release carries `RioKit.xcframework.zip` (12.2 MB),
plus a bare `librio.a` (33.8 MB, unstripped) and `librio.h` — confirmed on the
`v0.5.19` release assets, 2026-08-07 **[verified via GitHub API]**.

The header is 300 lines (`librio/include/librio.h`). It gives a host: engine and
surface lifecycle, PTY spawn with argv, text and key input, resize, scroll,
selection, working directory, buffer dump and replay, a callback block for
title/bell/progress/clipboard, and a render-state object.

This is a real, shipped, C-ABI terminal core in Rust. The first version of this
document asserted that no such thing existed in a usable shape and that adopting
Rust's VT ecosystem therefore meant designing the flattened snapshot ABI
yourself. **That assertion is now false and is withdrawn.**

### 4.2 Canario is Swift over a Rust grid

`frontends/canario` sits beside `frontends/rioterm` in the same repository. It is
29 files, 7,421 lines of Swift **[verified]**. It links `librio.a` from the
xcframework and AppKit, CoreText, CoreGraphics and QuartzCore
(`Makefile:70-92`) **[verified]**. It contains **zero** references to Metal,
`MTL*` or `CAMetalLayer` **[verified by grep over `frontends/canario/Sources`]**.
Its renderer says so itself (`frontends/canario/Sources/CPURenderer.swift:4-9`):

```
// canario draws entirely on the Swift side: it pulls cell data from
// librio's render state (`rio_render_state_cell`, which returns fully
// resolved RGB colors) and paints glyphs + backgrounds with AppKit /
// CoreText. No GPU renderer from Rio is involved.
```

So Rust owns grid, VT and PTY; Swift owns renderer and windowing. That is the
**inverse of Ghostty**, which the first version of this document cited as the
only coherent counter-model. It is a third shape, and neither Ghostty nor
Kurotty's own measurements covered it.

### 4.3 The parser is not the `vte` crate

Rio does not depend on `vte`, and does not depend on `copa` either: neither name
appears in `Cargo.lock` **[verified]**. The parser is vendored at
`rio-vt/src/performer/parser/` (2,292 lines), and its own module doc says
(`rio-vt/src/performer/parser/mod.rs:7-11`) **[verified]**:

```
Forked from Alacritty's VTE; previously the standalone `copa` crate. The
[`Perform`] trait keeps a single dispatch shape so the same state machine
drives the production [`Performer`], unit-test dispatchers, and external
consumers that need a raw escape-sequence parser [...] without pulling in a
second VTE implementation.
```

Two consequences. First, the "mature Rust VT crate ecosystem" argument is
narrower than it looks: the most credible embeddable Rust core in this space
forked the crate rather than consuming it, for dispatch-shape reasons. Second,
what Kurotty would be adopting is Rio's fork, on Rio's release cadence, not a
semver-stable third-party crate.

### 4.4 What survives: the boundary is per-cell, and it selects the renderer

The render-state API is (`librio/include/librio.h:238-250`) **[verified]**:

```c
rio_render_state_t *rio_render_state_new(const rio_surface_t *surface);
void  rio_render_state_update(rio_render_state_t *state);
bool  rio_render_state_row_dirty(const rio_render_state_t *state, uint16_t line);
void  rio_render_state_reset_dirty(rio_render_state_t *state);
rio_cell_s rio_render_state_cell(const rio_render_state_t *state,
                                 uint16_t line, uint16_t column);
```

`rio_render_state_cell` is the **only** cell reader in the header. There is no
row copy, no span, no bulk buffer. It returns a struct by value —
`{uint32_t codepoint; rio_color_s fg; rio_color_s bg; uint16_t style_flags;}`
(`librio.h:123-128`), and `rio_color_s` carries pre-resolved RGB with this
comment (`librio.h:111-121`) **[verified]**:

```
/* Always the resolved RGB, regardless of `kind`, so a CPU renderer can
   read r/g/b directly without owning a palette. */
```

The implementation does a `catch_unwind`, a null check, a bounds-checked square
lookup, a style resolution and two colour conversions **per call**
(`librio/src/capi.rs:913-946`) **[verified]**.

Two things follow, and they are the heart of the matter.

**One: the API author designed for a CPU host, and says so in a comment.** The
palette resolution that a GPU renderer would do once, in a shader or a uniform,
is done per cell per call so that a CPU painter does not have to.

**Two: Canario ignores the one affordance that would make the boundary cheap.**
`rio_render_state_row_dirty` and `rio_render_state_reset_dirty` exist. Canario
calls **neither** — zero occurrences across all 29 files **[verified by grep]**.
It runs two unconditional full-grid passes per frame: a background pass
(`CPURenderer.swift:173-190`) and a glyph pass (`CPURenderer.swift:194-257`),
each calling `rio_render_state_cell` for every cell, plus a third read for the
wide-icon lookahead and a fourth for the cursor. Rio's own launch post for
`librio` describes the intended usage as "pull only the rows that changed and
draw them" (`rioterm.com/blog/2026/07/27/rio-vt-and-librio`) **[read]**. The
reference frontend does not do it.

At Kurotty's 120×40 that shape is 9,600 FFI calls per frame; at 300×100 it is
60,000 per frame, 7.2 M/s at 120 Hz. That is arithmetic, not measurement — the
per-call cost is unmeasured here and is named in section 2 as the number to get.
But the comparison is with 40.7 ns/cell for two in-process walks that Kurotty
already considers a cost worth noting.

**And the decisive evidence is in Canario's own history.** It did not start as a
CPU renderer **[verified]**:

| Commit | Date | What happened |
|---|---|---|
| `f19da65` | 2026-07-09 | "add canario frontend experiment (swiftui + metal)" — adds `MetalSurface.swift` with a real `CAMetalLayer`, P3 colourspace, triple-buffered drawables |
| `e9e7e3e` | 2026-07-16 | "canario: live shells via riokit xcframework" — the commit that first wires Canario to `librio`, and the commit that **removes `CAMetalLayer`** |
| `7683f73` | 2026-07-26 | "Render canario on the CPU in Swift" — adds `CPURenderer.swift` |
| `3a8797e` | 2026-08-05 | renames `MetalSurface.swift` to `Surface.swift`; today it is an `NSView.draw(_:)` host |

Canario had a Metal layer before it had a terminal. The Metal layer went out in
the same commit the Rust core came in.

**So the refuted step and the surviving step are different.** It is not true that
the grid cannot move. It is true that once the grid is behind a per-cell pull
API, the cheapest renderer to build is a CPU renderer, and in the one shipped
instance of this design that is the renderer that got built — after a GPU one was
started and dropped. Adopting a Rio-shaped boundary in Kurotty would mean
**regressing a 3,084-line Metal renderer (`TerminalMetalView.swift:482`,
`TerminalMetalView: MTKView`) to buy a parser.** That is the claim, and it holds.

The boundary is also lossy relative to what the Rust side holds. `rio_cell_s`
carries one `uint32_t codepoint`. `rio-vt` tracks combining marks — `zerowidth`
extras, used internally at `librio/src/render_state.rs:311-316` — but they are
not exposed through the per-cell C API **[verified]**. Neither is cell width,
underline colour, or the hyperlink. Kurotty's screen carries `linkURL` per cell
and its Swift side reads it directly; those features would need new ABI or would
be lost.

None of this is a criticism of `librio`. It is a well-shaped library for the host
it was designed for. Kurotty is not that host.

### 4.5 Maturity

Rio: created 2022-10-05, 7,241 stars, 318 forks, actively pushed
(GitHub API, 2026-08-07) **[verified]**. `rio-vt` is credibly production-grade.

Canario: **50 commits** touching `frontends/canario`, first on 2026-07-09, most
recent 2026-08-07 **[verified]**. It is about one month old. It ships as
`Canario.dmg` on every release and `.github/SECURITY.md:31` lists it in scope
alongside Rio. I could **not verify** a "beta" label: no `beta`, `experimental`
or `preview` marker appears in `frontends/canario/`, the `librio` README, the
`v0.5.19` release notes, or the `librio` launch post. Its first commit calls it
an "experiment"; nothing since re-labels it. **Treat the label as unverified;
treat the age as verified.**

Distribution shape matters too, and cuts against Kurotty specifically: the
xcframework has exactly one slice, `macos-arm64`
(`librio/xcframework-info.plist`); the `librio-xcframework` target builds only
`--target aarch64-apple-darwin` (`Makefile:107-117`); Canario is built by
`swiftc -target arm64-apple-macosx14.0` and ad-hoc signed with `codesign --sign -`
(`Makefile:70-92`); and goreleaser builds it `goarch: [arm64]` while `rioterm`
gets both `x86_64-apple-darwin` and `aarch64-apple-darwin`
(`.goreleaser.yaml:45-51, 83-89`) **[all verified]**. Kurotty ships universal and
notarized (section 6). Rio has not solved that problem for this artefact; Kurotty
would have to.

---

## 5. Three shapes, and which one Kurotty is

| | Grid + VT | Renderer | Windowing | Boundary |
|---|---|---|---|---|
| **Ghostty** | Zig | **Zig** (Metal pipeline, `CAMetalLayer`, `CVDisplayLink`) | Swift/AppKit | Swift hands Zig a bare `NSView` pointer (`include/ghostty.h`); no per-cell read API for drawing |
| **Rio + Canario** | **Rust** (`librio`) | Swift (AppKit/CoreText, CPU) | Swift | One C call per cell, colours pre-resolved for a CPU painter |
| **Alacritty** | Rust | Rust | Rust | None — same process, same language, borrowed iterators |
| **Kurotty** | Swift | **Swift/Metal** | Swift/AppKit | Zig dylib present, nothing read from it |

Ghostty and Rio are the two coherent ways to have a native core. Ghostty keeps
the renderer next to the grid and hands the host a window. Rio keeps the renderer
in the host and hands it cells one at a time. **Kurotty's renderer is its most
developed subsystem and it is on the Swift side. That is the fact that decides
which of the two shapes is available.**

Ghostty's own `libghostty-vt` is worth naming here precisely because it is the
same problem solved with a different granularity. `include/ghostty/vt/render.h`
gives a stateful render-state object with two-phase update
(`ghostty_render_state_begin_update` / `_end_update`, so a renderer holding a
lock minimises the critical section), global *and* per-row dirty state, row
iterators, per-row cell cursors, a `_get_multi()` batch read, and graphemes
exposed through the boundary **[read, fetched 2026-08-07]**. That is what a
boundary designed with a GPU host in mind looks like: spans, not cells. It also
still carries, verbatim in `include/ghostty/vt.h`: "WARNING: This is an
incomplete, work-in-progress API. It is not yet stable and is definitely going to
change" **[verified, still present 2026-08-07]** — and Ghostty's own Swift app
does not consume it.

So the state of the art in 2026-08 is: one shipped, stable, per-cell C ABI whose
reference host is a CPU renderer; and one unstable, row-batched C ABI whose
author has not adopted it in his own Swift app. Neither is ready for a Metal
host today. They differ in which direction they would have to move to get there,
and `libghostty-vt` has less distance to cover.

kitty's core is C compiled as a CPython extension — `Screen` literally contains
`PyObject_HEAD`. Not separable. wezterm's `wezterm-term`/`termwiz` split remains
**unverified** here.

---

## 6. What Rust would actually cost

The Zig toolchain is unusually cheap here, which sets a high bar. What the build
does today **[verified by reading the pipeline]**:

- **Install**: bare `brew install zig` in all three workflows (`ci.yml:17-18`,
  `release.yml:25`, `flake-hunt.yml:36`). No version pinning anywhere — a latent
  supply-chain and reproducibility problem in its own right, independent of this
  decision. (Rio, for contrast, pins `rust-toolchain.toml` to 1.96.1.)
- **No caching at all**. Zero `actions/cache` steps **[verified]**. Every run is
  a cold build.
- **Cross-compilation is free**: `package-release.sh:118` runs
  `zig build -Dtarget=...` for both arches from a single arm64 runner with no
  extra SDK, then `lipo -create` (`package-release.sh:128, 133`).
- **Signing**: the dylib is signed separately and first, because the app has
  hardened runtime (`package-release.sh:200`, `--options runtime`) and **no
  entitlements file exists in the repo** **[verified]** — so library validation
  is in force and a `dlopen`'d dylib must carry the same Team ID.
- **Notarization**: only the DMG (`package-release.sh:254-263`).

Adding Rust means paying all of that again, plus:

1. **A third toolchain in CI.** `rustup target add x86_64-apple-darwin`, and a
   real need for `actions/cache` that Zig has not forced — Cargo cold builds are
   materially more expensive than Zig's. Unmeasured here; it is the number to
   obtain before committing.
2. **Universal binaries that Rio does not currently produce for this artefact.**
   `RioKit.xcframework` is arm64-only (section 4.5). Kurotty's
   `BUILD_ARCHES=(arm64 x86_64)` (`package-release.sh:13`) and its
   `lipo -verify_arch arm64 x86_64` gate would either force a second build of
   `librio` for `x86_64-apple-darwin` and a `lipo` of the static archives, or
   force Kurotty to drop Intel. Neither is hard; both are new.
3. **A second FFI boundary, or a replaced one.** A static archive is in some ways
   *better* than the current `dlopen`: linking `librio.a` at build time removes
   the `dlsym` + `unsafeBitCast` hazard (`CoreBridge.swift:306-308`) and the
   library-validation coupling entirely. That is a genuine advantage and should
   be recorded as one. What it does not remove is the per-cell call on the render
   path (section 4.4).
4. **Editing the pipeline's string-matching tests.**
   `tests/KurottyRenderingTests/GlyphRenderingRegressionTests.swift` still
   asserts on the literal text of `package-release.sh` and `release.yml`
   (e.g. `:1775`, `:1786`) **[verified]**, though far fewer than when this
   document was first written. Any toolchain change fails `swift test` until
   these are edited in lockstep.
5. **The portability dividend, which Kurotty does not collect.** This is the
   one that matters most. Rust's principal return in this class of project is a
   core that runs on macOS, Linux and Windows. Kurotty is macOS-only AppKit:
   `TerminalMetalView: MTKView`, `NSView`, `NSWindow`, `CVDisplayLink`,
   AppKit-specific IME. **Adopting Rust for portability while the entire
   application layer is AppKit is paying the toolchain cost and taking none of
   the return.** Ghostty pays the same cost and collects it; Rio pays it and
   collects it across three platforms and a browser. Kurotty would not.

---

## 7. What Rust would actually buy

**Memory safety at the ABI — partially real, and better than the first version of
this document allowed.** The current boundary has genuine hazards: `CoreBridge`
is `@unchecked Sendable` with no lock (`CoreBridge.swift:68`); `symbol` does
`unsafeBitCast` on a `dlsym` result with no signature check
(`CoreBridge.swift:306-308`); there is no `abi_version` export
(`docs/abi.md:5-21`); `repositoryRootURL()` bakes `#filePath` into the shipped
binary (`CoreBridge.swift:294`). Rust does not fix the `@unchecked Sendable` or
the missing version symbol — those are Swift-side. But adopting a **static
library** rather than a runtime-loaded dylib does dissolve the `dlsym` and
`#filePath` hazards structurally, because there is no symbol resolution at
runtime to get wrong. That is an argument for static linking, not for Rust; Zig
can produce a static archive too (`build.zig` already builds one).

**A maintained VT implementation — the strongest argument, and it is stronger
than it was.** The first version rejected this on the grounds that `vte`'s value
is a ~30-callback Rust trait that cannot cross a C ABI without becoming ~30
function pointers per surface on the hot path. **That framing is superseded.**
`librio` demonstrates the alternative: keep the callbacks inside Rust, let Rust
own the grid, and expose a pull API instead. The chatty-callback objection does
not apply to `librio`, and this document should not repeat it.

What replaces it is narrower and, for Kurotty, worse: the pull API is per cell,
and per-cell pull selects the renderer (section 4.4). The cost is no longer
paid per escape sequence on the input side; it is paid per cell on the output
side, which is exactly where Kurotty's Metal renderer lives.

**Performance — not an argument.** Section 3.

---

## 8. The options

### A. Delete the non-Swift core, go pure Swift

Delete `src/`, `bench/`, `stress/`, `tests/core_tests.zig`, `CoreBridge.swift`
and the `TerminalCore` protocol; drop the `zig build` steps from `ci.yml`, the
two cross-compiles and the `lipo`/codesign/verify steps for the dylib from
`package-release.sh`, `install-app.sh` and `verify-release-artifact.sh`.

The precondition that blocked this — porting the Zig VT corpus — is **done**
(`tests/KurottyRenderingTests/TerminalVTCorpusTests.swift`, `edcbb7d`).

- **Buys**: one toolchain; no ABI, no `@unchecked Sendable`, no dylib signing
  step, no library-validation coupling; the `#filePath` leak goes with it.
- **Costs**: the latency metric must be reimplemented in Swift (~30 lines,
  currently unused).
- **Forecloses**: nothing structural. A native core can be reintroduced later
  against a screen the Swift side has by then made flat and POD — which is the
  prerequisite for any core to be worth having.

### B. Keep Zig and connect it

Give the Zig core screen ownership: replace `DebugAllocator` with
`smp_allocator` or `c_allocator`, add an `abi_version` export, add a real lock,
switch the render path to `copyStyledRow`, delete the Swift interpreter.

- **Buys**: one parser; a 16-byte POD cell.
- **Costs**: the Zig grid is far behind the Swift interpreter on VT semantics —
  no OSC handling in `applyCsi` (`src/abi.zig`), no DCS, no charsets, no scroll
  regions, no hyperlinks, no shell integration marks — and all of that is wired
  into Swift features (command history, links, search, command progress, agent
  status). You would be porting the interpreter into Zig and re-exporting
  everything Swift reads off `TerminalScreen`.
- **Forecloses**: little, but commits the project to maintaining a VT
  implementation in a second language, permanently.

### C. Rewrite the core in Rust

Everything in B, plus a toolchain migration, plus rewriting 1,820 lines of
working Zig, plus rewriting the ABI and `CoreBridge`.

- **Buys**: nothing B does not buy. Writing your own Rust VT implementation gets
  you the same maintenance burden in a language with a heavier build.
- **Costs**: strictly greater than B for a strictly smaller delta.
- **Verdict**: rejected under every scenario in this document. If you are
  writing the VT implementation yourself, the language is not the question.

### C′. Adopt `librio` — do not write Rust, link it

This is the option the new evidence creates, and it is the serious one. Link
`librio.a`, let Rust own PTY, VT and grid, delete both the Swift interpreter and
the Zig core, and rewrite `TerminalMetalView` to source cells from
`rio_render_state_cell`.

- **Buys**: a maintained, production-exercised VT implementation, including the
  entire semantic layer Kurotty is missing (section 9), plus sixel and kitty
  graphics, plus search and selection, for zero VT maintenance. The largest
  single reduction in owned surface area available to this project.
- **Costs**: the renderer. Every cell read becomes an FFI call with a
  `catch_unwind` and a per-call style resolution; Kurotty's atlas and instance
  buffers would be rebuilt from that. The one shipped host of this API responded
  to it by deleting its Metal layer. Also: an arm64-only artefact against a
  universal-binary pipeline; `linkURL` and combining marks lost or requiring new
  ABI; Kurotty's shell-integration, command-progress, agent-status and
  command-history features all read `TerminalScreen` directly and would need
  re-sourcing; and a hard dependency on one maintainer's release cadence for the
  single most correctness-critical component in the product.
- **Forecloses**: the Metal renderer as it exists, and — for as long as the
  boundary is per-cell — the ability to be faster than a CPU painter.

### D. Leave it as-is

- **Buys**: nothing.
- **Costs**: a debugging allocator in production; an unpinned Zig toolchain; a
  `dlopen` boundary with `unsafeBitCast` behind it; a `#filePath` leak in a
  shipped binary; and the ongoing implication in `docs/abi.md` and `DESIGN.md`
  that Kurotty has a native core, which shapes decisions that rest on nothing.

---

## 9. The question actually asked

"Should I think about doing it in Rust?" — answered directly, in four parts.

### 9.1 What a Rust core would concretely mean

Not "port the Zig". Concretely, given that Kurotty's renderer is Metal and its
grid is Swift, there are only two coherent end states:

- **Rust owns grid and VT, Swift renders** (option C′). The Metal renderer is
  rewritten to pull cells across a C boundary, one call per cell per frame, from
  a struct that does not carry Kurotty's link or grapheme data. On the one
  shipped example of this shape, the renderer became a CPU renderer.
- **Rust owns grid, VT *and* the Metal pipeline**, Swift keeps windowing — the
  Ghostty shape in a different language. That means writing a Metal renderer in
  Rust to replace 3,084 lines of working Swift. No terminal does this, and it
  trades Kurotty's most developed subsystem for nothing.

There is no third arrangement where Rust does useful work and the Metal renderer
survives unchanged. A Rust core that parses into a grid Swift never reads is what
the Zig core already was, and it was deleted from the output path for cause.

### 9.2 Conditions under which it becomes the right call

These are named as things that could actually become true, not as hedges.

1. **Cross-platform ambition.** If Kurotty is ever to run on Linux or Windows,
   the calculation inverts immediately: portability is Rust's actual return, and
   the AppKit application layer becomes the thing to replace rather than the
   thing to protect. Today Kurotty is macOS-only AppKit and collects none of it.
   This is the single largest potential flip.
2. **A maintainer who prefers Rust.** Not a soft consideration. A VT
   implementation is maintained for years; the language its maintainer is fastest
   and most careful in is a legitimate primary input. If the person doing the
   work would rather write Rust, that outweighs a 40 ns/cell argument.
3. **`libghostty-vt` or `librio` reaching a shape that suits a GPU host.**
   Specifically: a row- or span-granular read with graphemes and per-cell
   metadata, and a stable API. `libghostty-vt` already has the shape
   (`_row_cells_*`, `_get_multi`, two-phase update) and lacks the stability;
   `librio` has the stability and lacks the shape. Either one closing its gap
   changes the answer — and note that `librio`'s gap is smaller than it looks: a
   `rio_render_state_row_cells(state, line, out, cap)` is a bounded amount of
   work on Rio's side, and worth *asking for* before concluding anything.
4. **VT conformance debt growing past what is worth hand-maintaining.** This is
   the condition with live evidence, and it deserves a full answer.

### 9.3 The VT conformance debt, weighed honestly

A concurrent conformance pass reports **six VT bugs** in the Swift interpreter. I
did not see that work — the branch `fix/vt-corpus-conformance` has no commits
against `origin/develop` at the time of writing — so **the specific six are
unverified here.** What I did verify is the structural debt they sit on, in the
current tree **[all verified by reading
`Sources/KurottyApp/TerminalOutputInterpreter.swift`]**:

- The parser has seven states: `normal`, `escape`, `escapeDesignator`,
  `escapeDecPrivate`, `csi`, `osc`, `oscEscape` (`:266-351`). **There is no DCS,
  APC or PM state at all** — `ESC P`, `ESC _` and `ESC ^` payloads fall through
  and print literally.
- Charset designators are recognised and then **discarded**: `beginsTwoByteDesignator`
  matches `( ) * + - . / %` (`TerminalModel.swift:73-80`), and
  `case .escapeDesignator` sets `parserState = .normal` and returns
  (`:318-320`). DEC Special Graphics is not mapped.
- **No soft reset.** `CSI ! p` dispatches on final `p`, which routes to
  `respondToCapabilityQuery` (`:496-497`). DECSTR does not exist.
- **No DECSCUSR.** There is no `case "q"` in `executeCsi` at all.
- **No synchronized output.** `setMode` handles modes 1, 6, 7, 25, 47, 1004,
  1047, 1048, 1049, 2004 and the colour-scheme mode (`:595-648`). 2026 is absent.

That is not six bugs; that is five missing feature areas, and six bugs is what
missing feature areas look like from the outside. **The debt is real and the
argument for buying a VT implementation rather than growing one is the strongest
argument in this document.**

Two things weigh against it, and I hold them to be decisive today.

First, **the debt is bounded and Swift-shaped.** DCS/APC/PM is a parser state
that consumes to `ST` — tens of lines. Charset designation is a translation table
and a flag. Soft reset is a list of assignments. DECSCUSR is a cursor-shape enum
Kurotty already needs for its own UI. Synchronized output is a frame-hold flag
the renderer is already structured for. This is a few hundred lines of Swift
against a known corpus that **already exists in the repository**
(`TerminalVTCorpusTests.swift`, ported precisely so this work could be done in
Swift). It is not an open-ended commitment.

Second, **buying the parser means selling the renderer.** Section 4.4. The
exchange rate is bad: Kurotty would give up its most developed subsystem, its
universal build, its per-cell link data and its direct `TerminalScreen` reads —
which the shell-integration, link, search, command-progress and agent-status
features depend on (section 8, option B) — to avoid a few hundred lines of Swift
it has the tests for.

If, a year from now, the conformance list has grown rather than shrunk — sixel,
kitty graphics, full DEC mode coverage, DECRQM, reflow — then the debt has
outgrown "a few hundred lines" and condition 4 has fired. That is a real
possibility and it should be checked against, not assumed away.

### 9.4 What it costs

Section 6, in one line each: a third toolchain in CI with no caching
infrastructure to build on; a second FFI boundary (with the honest note that a
static archive is *safer* than today's `dlopen`); universal-binary builds against
an arm64-only upstream artefact; notarization and hardened-runtime signing for
one more component; and no portability dividend at all, because the application
is macOS-only AppKit.

---

## 10. Recommendation

**No Rust in Kurotty today. The reasoning has changed; the answer has not.**

The first version rejected Rust partly because the good Rust VT code could not
cross a C boundary. That was wrong, and `librio` is the proof. The correct reason
is narrower and better: **the one shipped C ABI for a Rust terminal core is a
per-cell pull API designed for a CPU host, and the only frontend built on it
deleted its Metal layer in the same commit that adopted the core.** Kurotty's
Metal renderer is the asset that decides this. Adopting a Rio-shaped boundary
buys a parser and pays for it with the renderer.

Ordered actions:

1. **Take option A: delete the Zig core.** Its last blocker is gone — the VT
   corpus is ported and `core.feed` is off the output path. What remains is a
   dylib with a debugging allocator, an unpinned toolchain, a `dlsym` +
   `unsafeBitCast` boundary, a `#filePath` leak in a shipped binary, and 437
   lines Swift cannot reach, in exchange for a latency metric with no readers.
   Deleting it is the largest reduction in owned surface area available, and it
   costs ~30 lines of Swift to replace the metric.
2. **Close the VT conformance gaps in Swift, against the corpus that is already
   there.** In order of user-visible payoff: DCS/APC/PM consumption (stops
   neovim's probes dumping on screen and sixel dumping megabytes), synchronized
   output (2026), charset designation, DECSCUSR, soft reset. The tests exist;
   this is the work condition 4 is measured against.
3. **Spend the recovered budget on the Swift representation, not on a language.**
   Iterate `text.utf8` rather than `Character` in `interpret` (25× measured
   headroom on the inner loop); flatten `[[TerminalScreenCell]]` to a POD array
   with an out-of-line side table for `linkURL` and multi-scalar graphemes. The
   96-byte, two-ARC-field cell is the one place the current design carries a
   genuine language-level cost, and Swift can fix it in Swift.
4. **Before any of it, add measurement.** `os_signpost` intervals around
   `interpret`, `updateRendererFrame`, `rebuildAtlasBuffers` and the draw, plus a
   dropped-frame counter. Every number in this document is a first measurement on
   one machine.
5. **Obtain one number this document does not have: the cost of a C-ABI call
   returning a small by-value struct, per cell, from Swift.** It is the number
   that decides option C′ and every future variant of it. A one-afternoon
   benchmark against `librio.a` at 120×40 and 300×100 would settle in hours an
   argument this document can only reason about.

### If you do not want to delete the Zig core

Then option B, not C. Replace `src/abi.zig:4` with `std.heap.smp_allocator`
today — one line, 5× on plain output and 49× on coloured, verified — add an
`abi_version` export, pin the Zig toolchain, and put a lock behind `CoreBridge`.
That makes the core merely inert rather than a liability, and buys time.

### Evidence that would flip this

- **Kurotty targeting a second platform.** The moment Linux or Windows is a real
  goal, Rust's return arrives and this recommendation inverts. Nothing else on
  this list is as large.
- **A row- or span-granular read API on either core.** Concretely:
  `rio_render_state_row_cells()` landing in `librio` with graphemes and cell
  width, or `libghostty-vt` declaring `render.h` stable and Ghostty's own Swift
  app consuming it. Either makes "adopt a proven VT core" a linking decision for
  a GPU host rather than a renderer rewrite. **Worth actively asking Rio for
  before deciding anything** — it is a small change on their side and it would
  change the answer here.
- **The conformance list growing rather than shrinking.** If step 2 is done and
  the gap list is longer a year later — reflow, DECRQM, sixel, kitty graphics —
  then hand-maintaining a VT implementation has outgrown its budget and buying
  one is correct, whatever it costs the renderer. Track the list; it is the
  metric.
- **A maintainer who would rather write Rust.** Stated plainly because it is
  legitimate and because no measurement in this document outweighs it.
- **A measured hot path that is allocation-free, cache-bound, and still too slow
  in Swift.** Nothing found here is. If profiling after step 3 shows the
  flattened Swift screen still losing to a native core on a real workload, the
  argument reopens — and at that point Rust and Zig should be compared again from
  scratch, because `librio` has changed what the Rust side of that comparison
  looks like.
