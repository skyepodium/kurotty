# Should any part of Kurotty be Rust?

The question as asked is "Swift → Rust", but Kurotty is not a Swift-only app. It
is Swift/AppKit for the application, Zig for a core library loaded at runtime,
and Metal for rendering. So the question is narrower: **the only place a third
language could go is where the second language already is**, and before choosing
between Zig and Rust you have to establish what that slot currently holds.

It holds a parser whose output is discarded, and which is the most expensive
thing on the output path.

Claims are marked **[verified]** when something was run and its output observed,
and **[read]** when they rest on reading the code. Anything unmarked is a
judgement call, not a finding. Measurements were taken on the development
machine (Apple silicon, Zig 0.16.0, Swift 6.3.3) and are single-machine numbers,
not a benchmark suite.

---

## 0. The headline

`kurotty_terminal_feed` runs on every byte the child process writes, on the main
actor, immediately before the Swift interpreter that actually renders
(`TerminalSurfaceView.swift:1859-1860`). Nothing reads its result.

Measured against the shipped `ReleaseFast` dylib through `dlopen`, exactly as
`CoreBridge` loads it **[verified]**:

| Workload, 120×40 grid | Shipped | Same code, `DebugAllocator` → `smp_allocator` | Factor |
|---|---|---|---|
| Plain 80-column lines | 4.88 MB/s | 25.49 MB/s | 5.2× |
| SGR-wrapped 80-column lines | 5.38 MB/s | 28.64 MB/s | 5.3× |
| Per-cell 256-colour churn | **1.59 MB/s** | 77.71 MB/s | **49×** |

The 1.59 MB/s figure confirms the ~1.4 MB/s colour-output number from the earlier
audit. The right-hand column is the same Zig source with one line changed —
`src/abi.zig:4` — built in the same mode, and it is what makes the whole Rust
question answerable:

**The core is not slow because it is Zig. It is slow because it ships a
debugging allocator and allocates per parser event.** A Rust rewrite that kept
the same design would land in the same place; a Rust rewrite that fixed the
design would win exactly what the one-line Zig change already wins.

---

## 1. What the non-Swift core actually does today

### Every export, and whether Swift calls it

`src/abi.zig` exports 17 symbols. `CoreBridge` resolves 14 of them
(`CoreBridge.swift:224-242`; `cursor_row`, `cursor_col`, `width` and `height`
are exported but never resolved, and `last_error` is resolved but never called).
Live call sites in `Sources/` **[verified by grep]**:

| Export | Swift wrapper | Non-test callers in `Sources/` |
|---|---|---|
| `create` / `destroy` | `CoreBridge.init` / `deinit` | `TerminalCoreFactory.swift:5`, one per surface |
| `feed` | `CoreBridge.feed` | `TerminalSurfaceView.swift:1859`, `TerminalInputView.swift:57,100,104,114,142,223` |
| `mark_damage` | inside `CoreBridge.feed:132` | full grid, every feed |
| `record_key` | `recordKeyEvent` | `TerminalSurfaceView.swift:666`, `TerminalInputView.swift:31` |
| `record_present` | `recordFramePresented` | `TerminalSurfaceView.swift:724` |
| `resize` | `resize(cols:rows:)` | resize path |
| `last_latency` | `lastLatencyMicros` | **none** |
| `begin_frame` / `end_frame` | `beginFrame` / `endFrame` | **none** |
| `cell_at` | `cell(row:col:)` | **none** |
| `copy_row` | `copyRow(_:into:)` | **none** |
| `copy_row_cells` | `copyStyledRow` | **none** |
| `last_error` | resolved, no wrapper | **none** |
| `cursor_row`, `cursor_col`, `width`, `height` | not resolved | **none** |

Every export that could return screen state has zero non-test callers. The only
matches outside `CoreBridge.swift` are test doubles
(`TerminalDiagnosticsTests.swift:535-540`,
`TerminalTextInputRouterTests.swift:608-613`) and one source-string assertion
(`GlyphRenderingRegressionTests.swift:2567`).

**The shadow-parser finding still holds, and `core.feed` still runs.** The P0
abort in `src/parser.zig` was fixed by clamping per ECMA-48 rather than
propagating `error.Overflow` (`src/parser.zig:250-256`) **[read]**, but the
roadmap's other recommendation — remove the call — was not taken.

Three of the four self-diagnostics still say so out loud
(`CoreBridge.swift:109-120`):

```
parserMutationOwner: .swiftScaffold
screenMutationOwner: .swiftScaffold
renderMutationOwner: .swiftScaffold
mutationHandoffReady: false
dualWriteRisk: .feedBridgeOnly
reason: "zig-feed-bridge-active-swift-mutation-owner"
```

### Zig that Swift cannot reach at all

`src/` is 1,883 lines across 10 files. Three modules have no export path
whatsoever **[verified by grep]**: `src/scrollback.zig` (66), `src/pty.zig`
(182) and `src/screen_mutation.zig` (189) are imported by `src/core.zig` and
reachable only from `tests/core_tests.zig` (872 lines) and `bench/main.zig`.
That is 437 lines, 23% of the core, that no ABI touches. The Swift side has its
own `SegmentedScrollbackStore`, its own PTY in `ShellSession.swift`, and its own
`TerminalEventLedger.ScreenMutation`.

### The damage tracker

`RendererOrchestrator` (`src/renderer.zig`) accumulates rects, clips them,
collapses past 64, and `beginFrame` returns `draw_calls = 0 or 1`
(`renderer.zig:61-65`). It computes a count. It does not decide what is drawn,
because `begin_frame` and `end_frame` have no Swift callers, and because
`CoreBridge.feed` marks the entire grid damaged on every feed
(`CoreBridge.swift:132`) — so even the count would be constant.

### Does it earn its place?

No. It costs main-actor time on every output chunk, it is the largest single
consumer of that time on colour-heavy output (section 2), it duplicates
subsystems Swift already owns, and its outputs are unread. Against that, it
provides one thing nothing else does: an input-to-present latency metric
(`src/metrics.zig`) — with zero call sites.

---

## 2. Where the time actually goes

Nothing in the shipping app measures this. There are **zero** occurrences of
`os_signpost` or `OSSignposter` in `Sources/` **[verified]**; the only timing
call in the tree is `monotonicMicros()` inside `CoreBridge.swift:307`, feeding
the metric nobody reads. `bench/main.zig` has no timing at all — it prints
counters, so `zig build bench` (run on every push, `ci.yml:18-19`) can only fail
on a crash.

So the honest baseline is: **before this document, nobody knew.** What follows
are first numbers, not a measurement culture.

### The output path, end to end

PTY bytes are read on `readQueue`, decoded to `String`, and delivered to the
main queue (`ShellSession.swift:510-513`). Everything after that is main-actor
and sequential (`TerminalSurfaceView.appendOutput`, line 1840 onward):

```
core.feed(text)          // Zig, result discarded          :1859
interpreter.interpret(text)                                :1860
updateRendererFrame()                                      :1877 → :1236
  └─ rebuildAtlasBuffers() on the next draw                TerminalMetalView.swift:1471
```

Note that PTY backpressure has since been implemented — `TerminalOutputBackpressure.swift`
plus the suspend/resume pair at `ShellSession.swift:548-576` — so roadmap item
3 is closed **[read]**. The main actor, not the kernel buffer, is now the
constraint.

### Measured cost per stage

**Zig `feed`, shipped configuration [verified]**: 205 ns/byte plain, 628 ns/byte
on per-cell colour churn.

**Swift interpreter inner loop [verified, replica]**: `interpret` iterates
`Character` — grapheme clusters — and calls `appendPrintable(String(character))`,
one `String` allocation per printable character
(`TerminalOutputInterpreter.swift:109-121, 141`). A standalone replica of exactly
that loop shape, with the real `isTerminalPrintableGrapheme` predicate:

| Loop | Throughput | Per byte |
|---|---|---|
| `for character in text` + `String(character)` | 32.1 MB/s | 31.2 ns |
| The same counting loop over `text.utf8` | 792 MB/s | 1.26 ns |

**25× apart, in the same language, at `-O`.** The replica does far less work per
character than the real `appendPrintable` (no `wcwidth`, no wrap handling, no
`screen.set`), so 32 MB/s is an *upper bound* on the real interpreter, not an
estimate of it. That is enough for the comparison that matters: on colour-heavy
output the discarded Zig parser costs 628 ns/byte against an interpreter whose
ceiling is 31 ns/byte. **Removing `core.feed` from the output path is a
performance fix, not only a cleanup.**

**The per-cell walks [verified, replica]**: `updateRendererFrame` walks every
visible cell building three fresh arrays (`TerminalSurfaceView.swift:1263-1300`),
then `rebuildAtlasBuffers` walks `terminalFrame.cells` again ignoring
`dirtyRows` (`TerminalMetalView.swift:1479-1490`). Replicas of both, over a
120×40 viewport:

| Walk | Per flush | Per cell |
|---|---|---|
| `updateRendererFrame` | 0.086 ms | 17.8 ns |
| `rebuildAtlasBuffers` | 0.120 ms | 25.0 ns |
| Both, one output flush | **0.195 ms** | 40.7 ns |

That is **2.3% of an 8.3 ms frame budget at 120 Hz**. The roadmap is right that
damage tracking does not reduce CPU (`rebuildAtlasBuffers` ignores `dirtyRows`)
and that instances are re-encoded once per scissor rect
(`TerminalMetalView.swift:953-961` calls `encodeTerminalContent` inside the rect
loop, re-issuing every draw call per rect). Both are true. Neither is where the
time is. **Fixing damage tracking buys at most 0.2 ms/frame at this viewport
size; deleting the shadow parser buys more than that on a single 1 KB colour-heavy
chunk.**

The scissor-rect issue is different in kind: re-encoding per rect is GPU-side
work that a 64-rect budget can make *worse* than a full redraw, and it has no
area-crossover heuristic. That is worth fixing, and it is not a CPU question.

### What is still unmeasured

- Real `interpret` throughput in situ (the replica is a lower bound on cost).
- Glyph rasterisation and atlas-miss cost, which is per new glyph, not per cell,
  and is the most likely hidden hot spot no replica here touches.
- The `String` decode at the PTY boundary (`ShellSession.swift:510`).
- Anything at large viewports. All figures above are 120×40; a 300×100 pane is
  6× the cells and would put the two walks near 1.2 ms/flush — still not
  dominant, but no longer negligible.

---

## 3. Is any hot path limited by the language?

This is the question that decides the answer, and for every hot path found, no.

| Hot path | Actual limit | Language-bound? |
|---|---|---|
| Zig `feed`, 1.59 MB/s coloured | `DebugAllocator` in production (`src/abi.zig:4`) plus one heap allocation per parser event (`parser.zig:206-210`, `232-260`) | **No.** One line recovers 49×. |
| Swift `interpret` | `Character` grapheme iteration and `String(character)` per printable char | **No.** 25× available by iterating `text.utf8`, still in Swift. |
| `updateRendererFrame` / `rebuildAtlasBuffers` | Walks every cell regardless of damage | **No.** Rust would carry the same walk. 40.7 ns/cell is not a language ceiling. |
| Per-rect re-encode | No area-crossover heuristic, 64-rect budget | **No.** GPU-side algorithm. |

The one place where a language-level cost is genuinely visible is the screen
representation, and even there the fix is Swift-side:

`TerminalScreen.cells` is `[[TerminalScreenCell]]` (`TerminalScreen.swift:6`) —
one heap allocation per row. `TerminalScreenCell` measures **96 bytes stride**
**[verified]**, of which two fields are ARC-managed: `character: Character` (16
bytes, heap-backed for anything past a small ASCII case) and `linkURL: String?`
(16 bytes). The Zig equivalent is a 16-byte POD `extern struct`
(`src/cell.zig:60-71`). A 120×40 viewport is 460 KB of Swift cells against 76 KB
of Zig cells, plus retain/release traffic on every cell copy.

That is a real 6× memory difference and real ARC traffic — and it is a **data
layout choice, not a language limit**. Swift can hold a flat
`[UInt32]`/`[UInt64]` cell array with an out-of-line side table for links and
grapheme clusters, which is precisely what Ghostty and Alacritty both do in
their own languages. Rewriting `[[TerminalScreenCell]]` in Rust and shipping it
back across a C ABI would replace an ARC cost with a marshalling cost, per cell,
per frame.

---

## 4. What Rust would actually cost

The Zig toolchain is unusually cheap here, which sets a high bar. What the build
does today **[verified by reading the pipeline]**:

- **Install**: bare `brew install zig` in all three workflows (`ci.yml:12-13`,
  `release.yml:24-25`, `flake-hunt.yml:35-36`). No version pinning anywhere —
  no `build.zig.zon`, no `minimum_zig_version`, no `setup-zig` action. That is a
  latent supply-chain and reproducibility problem in its own right, independent
  of this decision.
- **No caching at all**. Zero `actions/cache` steps. Every run is a cold build.
- **Cross-compilation is free**: `package-release.sh:118` runs
  `zig build -Dtarget=aarch64-macos` and `-Dtarget=x86_64-macos` from a single
  arm64 runner with no extra SDK, no second runner, then `lipo -create`
  (`package-release.sh:133`).
- **Signing**: the dylib is signed separately and first
  (`package-release.sh:196`), because the app has hardened runtime
  (`--options runtime`, line 200) and **no entitlements file exists in the repo**
  — so library validation is in force and a `dlopen`'d dylib must carry the same
  Team ID. `verify-release-artifact.sh:112` gates on
  `lipo -verify_arch arm64 x86_64` for the dylib specifically.
- Only the DMG is notarized (`package-release.sh:254-263`).

Adding Rust means paying all of that again, plus:

1. **A third toolchain in CI.** `rustup target add x86_64-apple-darwin`, and a
   real need for `actions/cache` that Zig has so far not forced — Cargo cold
   builds are materially more expensive than Zig's. Unmeasured here; it is the
   number to obtain before committing.
2. **A second FFI boundary, or a replaced one.** Either `swift-bridge`/`cbindgen`
   generating a C header, or a hand-written `extern "C"` shim. Note that
   Alacritty — the reference Rust terminal — has **zero `#[no_mangle]` and zero
   `extern "C"` in `alacritty_terminal/src/`, and no cbindgen config**. Its API
   is `Term<T: EventListener>` with borrowed, lifetime-parameterised iterators
   (`RenderableContent<'a>`). None of that survives a C boundary; you would be
   designing a flattened snapshot ABI yourself, which is the same work as
   designing Kurotty's own.
3. **Universal builds for two architectures**, `lipo`, separate codesigning,
   `lipo -verify_arch` gates. Identical to the Zig path — no worse, no better.
4. **Editing the pipeline's string-matching tests.**
   `GlyphRenderingRegressionTests.swift:2464-2550` asserts on the literal text of
   `package-release.sh`, `install-app.sh` and `release.yml`, including
   `BUILD_ARCHES=(arm64 x86_64)`, the `swift build --triple` line, both codesign
   lines and the `rm -rf "$WORK_DIR"/zig-*` cleanup glob. Any toolchain change
   fails `swift test` until these are edited in lockstep. (This is roadmap item
   5 collecting interest.)

None of this is prohibitive. All of it is real, and none of it is bought back by
anything in section 3.

---

## 5. What Rust would actually buy

Three candidate arguments. One is real but does not reach the bar; two are not
arguments for Rust at all.

**Memory safety at the ABI — real, but Zig already offers the same fix.** The
current boundary has genuine hazards: `CoreBridge` is `@unchecked Sendable` with
no lock (`CoreBridge.swift:69`) while `Grid.resize` frees `self.cells`
(`grid.zig:59-70`); `symbol` does `unsafeBitCast` with no signature check
(`CoreBridge.swift:301-304`); there is no `abi_version` export
(`docs/abi.md:5-21`); `repositoryRootURL()` bakes `#filePath` into the shipped
binary (`CoreBridge.swift:288-294`). Rust would not fix any of these. Every one
lives on the Swift side of an `UnsafeRawPointer` and a `dlsym`, where Rust's
guarantees stop exactly as Zig's do. `unsafeBitCast` of a `dlsym` result is
equally unchecked whichever language is on the far side. What would fix them is a
lock, a version symbol and a bundle-relative path — in the language that is
already there.

**A mature VT crate ecosystem — the strongest argument, and it still loses.**
`vte` with the `ansi` feature is real and load-bearing for Alacritty: it supplies
the Paul Williams state machine *and* the semantic decode of CSI/OSC/SGR
parameters *and* the `Handler` trait that Alacritty implements
(`alacritty_terminal/src/term/mod.rs:23-27, 1059`). Kurotty's open VT gaps are
exactly the semantic layer — DCS/APC/PM payloads printing literally, no charset
designation, erase filling with the full SGR pen, no soft reset, no DECSCUSR, no
synchronized output. `vte` covers most of that.

It loses on shape, not on quality. `vte`'s value is delivered through a Rust
trait with ~30 callback methods. Crossing a C ABI turns that into ~30 function
pointers per surface, called per escape sequence, each re-entering Swift to
mutate Swift-owned screen state — with the screen state on one side and the
parser on the other. That is the most chatty possible FFI design, on the hot
path, and it is why nobody ships it: Alacritty consumes `vte` in-process, in
Rust, with the grid on the same side of the boundary.

**Performance — not an argument.** Section 3.

---

## 6. What comparable terminals actually do

Ghostty and Alacritty are the two that matter, because one chose Zig for this
exact job and the other chose Rust.

**Ghostty (Zig core, Swift/AppKit macOS UI)** — the closest structural match to
what Kurotty is trying to be, and it draws the line in a completely different
place. Zig owns the VT parser (`src/terminal/Parser.zig`), the screen
(`Screen.zig`, 12k LOC), paged scrollback with reflow (`PageList.zig`, 19.6k
LOC), the glyph atlas (`src/font/Atlas.zig`), **the Metal pipeline and encoding**
(`src/renderer/metal/`), the `CAMetalLayer` (Zig subclasses `CALayer` via `objc`
in `IOSurfaceLayer.zig`), the `CVDisplayLink` (`src/renderer/generic.zig:202`),
and the PTY read loop (`src/termio/Exec.zig`). Swift hands Zig a bare `NSView`
pointer — `typedef struct { void* nsview; }`, `include/ghostty.h:448-450` — and
Zig makes it layer-hosting and takes over. The 90-function embedding ABI has
**no per-cell read API for drawing**; the only text reads exist for clipboard,
accessibility and QuickLook.

Two consequences for Kurotty. First: **Ghostty's Swift side has no VT
interpreter at all** — grepping `macos/Sources` for escape-sequence handling
finds only `GHOSTTY_KEY_ESCAPE` enum mappings. Zig strictly owns screen state.
The dual-parser situation Kurotty is in has no analogue there. Second: Ghostty
uses `std.heap.c_allocator` in release builds, with `DebugAllocator` reserved for
Debug and Valgrind (`src/global.zig:90-111`), with the in-source comment "Use the
libc allocator if it is available because it is WAY faster than GPA." Kurotty
ships the configuration Ghostty explicitly avoids.

Ghostty also now ships **libghostty-vt** (`include/ghostty/vt/`, ~368 exported
functions), whose `render.h` is shaped for precisely "foreign renderer, Zig
grid": a stateful render-state object with dirty tracking and a two-phase update
so an external renderer thread minimises lock hold time. It is the right-shaped
thing. It also carries, verbatim in `include/ghostty/vt.h:10-12`: "WARNING: This
is an incomplete, work-in-progress API. It is not yet stable and is definitely
going to change" — and Ghostty's own Swift app does not consume it. Treat it as
unproven in the Swift direction.

**Alacritty (Rust)** splits the other way: `alacritty_terminal` (11.7k LOC) owns
the grid, scrollback, selection, search, PTY and event loop; the renderer and
glyph atlas live entirely in the binary crate (`alacritty/src/renderer/`, 4.1k
LOC). The bridge is a per-cell iterator (`RenderableContent`,
`alacritty/src/display/content.rs`). That is Kurotty's intended shape — Swift
owns Metal, the core owns the grid. But it works because both sides are Rust in
one process. There is no C ABI to adopt.

**kitty**'s core is C compiled as a CPython extension — `Screen` literally
contains `PyObject_HEAD` (`kitty/screen.h:114`). Not separable. **wezterm** was
not present in the checkout; its Rust `wezterm-term`/`termwiz` split is
**unverified** here.

The pattern across all four: **the core owns the grid, and no one runs two
parsers.** Kurotty runs two and lets neither own the grid.

---

## 7. The options

### A. Delete the non-Swift core, go pure Swift

Remove `core.feed` from `appendOutput` and `TerminalInputView`, delete `src/`,
`bench/`, `stress/`, `tests/core_tests.zig`, `CoreBridge.swift` and the
`TerminalCore` protocol; drop the `zig build` steps from `ci.yml`, the two
cross-compiles and the `lipo`/codesign/verify steps for the dylib from
`package-release.sh`, `install-app.sh` and `verify-release-artifact.sh`; port the
Zig test corpus onto `interpreter.interpret` before deleting it (roadmap item 5
already calls for this, for independent reasons).

- **Buys**: the largest cost on the output path disappears; one toolchain; no
  ABI, no `@unchecked Sendable`, no dylib signing step, no library-validation
  coupling; the `#filePath` leak goes with it.
- **Costs**: the latency metric must be reimplemented in Swift (it is ~30 lines
  and currently unused). The Zig VT corpus must be ported, not discarded — it
  covers fragmented CSI/OSC/DCS reassembly, overflow resync, CJK wide cells,
  combining marks and UTF-8 split across writes, which the Swift suite does not.
- **Forecloses**: nothing structural. A native core can be reintroduced later
  against a screen the Swift side has by then made flat and POD — which is the
  prerequisite for any core to be worth having.

### B. Keep Zig and connect it

Give the Zig core screen ownership: replace `DebugAllocator` with
`smp_allocator` or `c_allocator`, add an `abi_version` export, add a real lock
(or make `CoreBridge` an actor), and switch the render path from
`interpreter.interpret` to `copyStyledRow`. Then delete the Swift interpreter.

- **Buys**: one parser; a 16-byte POD cell; the ~50× that section 0 measures.
- **Costs**: this is the largest of the four. The Zig grid is far behind the
  Swift interpreter on VT semantics — no OSC handling in `applyCsi` at all
  (`src/abi.zig:94`), no DCS, no charsets, no scroll regions, no hyperlinks, no
  shell integration marks — and all of that is wired into Swift features
  (command history, links, search, command progress, agent status). You would be
  porting the interpreter into Zig and re-exporting everything Swift currently
  reads directly off `TerminalScreen`.
- **Forecloses**: little, but it commits the project to maintaining a VT
  implementation in a second language, permanently, with the FFI in the hot path.

### C. Replace Zig with Rust

Everything in B, plus a toolchain migration, plus rewriting 1,883 lines of
working Zig, plus rewriting the ABI and `CoreBridge`, plus CI and packaging
changes, plus editing the source-string assertions that pin the pipeline.

- **Buys**: access to `vte`'s semantic layer — through a ~30-callback C boundary
  on the hot path (section 5). Nothing else that B does not buy.
- **Costs**: strictly greater than B for a strictly smaller delta.
- **Forecloses**: the Ghostty path. Zig is the language Ghostty's C ABIs are
  written for and against; if Kurotty ever wants to stop maintaining a VT
  implementation and adopt `libghostty-vt`, being in Zig makes that a linking
  decision rather than a rewrite.

### D. Leave it as-is

- **Buys**: nothing.
- **Costs**: the measured cost of the discarded parse on every output chunk; a
  dual-write hazard the code self-reports; a debugging allocator in production;
  an unpinned Zig toolchain; the ongoing implication in `docs/abi.md` and
  `DESIGN.md` that Kurotty has a native core, which shapes decisions that then
  rest on nothing.

---

## 8. Recommendation

**Rust is not the right answer for any component of Kurotty today. Neither is
Zig, as currently deployed.**

1. **Delete `core.feed` from the output path now.** It is the single largest
   measured cost on that path, and its result is discarded. This is a
   performance fix that requires no design work. `TerminalSurfaceView.swift:1859`
   and the six call sites in `TerminalInputView.swift`.
2. **Take option A.** Port the Zig VT corpus onto `interpreter.interpret` first
   — it is the one asset in `src/` and `tests/` worth keeping, and roadmap item 5
   asks for the same port for independent reasons. Then delete the core, the ABI,
   the dylib and the Zig steps in CI and packaging.
3. **Spend the recovered budget on the Swift representation, not on a language.**
   Two changes, in order of measured payoff:
   - Iterate `text.utf8` rather than `Character` in `interpret`, handling
     grapheme clustering only where combining marks appear. Measured headroom:
     25× on the inner loop.
   - Flatten `[[TerminalScreenCell]]` to a single POD array with an out-of-line
     side table for `linkURL` and multi-scalar graphemes. 96 bytes and two ARC
     fields per cell is the one place where the current design carries a genuine
     language-level cost — and Swift can fix it in Swift.
4. **Before either, add measurement.** `os_signpost` intervals around
   `interpret`, `updateRendererFrame`, `rebuildAtlasBuffers` and the draw, plus a
   dropped-frame counter, plus real timing in `bench/main.zig` for as long as it
   survives. Every number in this document is a first measurement on one machine;
   none of them should be load-bearing for long. Note that CI runs the Zig suite
   at Debug while releases ship `ReleaseFast` — the shipped configuration is
   currently never tested, which is exactly how a `DebugAllocator` reaches
   production unnoticed.

### If you do not want to delete it

Then option B, not C. Replace `src/abi.zig:4` with `std.heap.smp_allocator`
today — one line, 5× on plain output and 49× on coloured, verified — add an
`abi_version` export, and put a lock behind `CoreBridge`. That makes the core
merely inert rather than actively expensive, and buys time to decide properly.
It is strictly better than the status quo under every option below.

### Evidence that would change this

- **A measured hot path that is allocation-free, cache-bound, and still too
  slow in Swift.** Nothing found here is; every one is dominated by a
  representation or algorithm choice. If profiling after step 3 shows the
  flattened Swift screen still losing to a native core on a real workload, the
  argument reopens — for Zig first, on ecosystem grounds.
- **`libghostty-vt` reaching stability and being adopted by Ghostty's own Swift
  app.** That would make "adopt a proven VT core" a linking decision rather than
  a rewrite, and would settle the VT-correctness gaps in section 4 of the
  roadmap wholesale. It is the only scenario in which a non-Swift core clearly
  earns its place — and it is Zig.
- **A component appearing that is genuinely compute-bound, batch-shaped and
  ABI-thin.** None exists today. The transcript scanner, the session index and
  the context forecast are all I/O-bound. If Kurotty ever grows something like
  local embedding or search over very large scrollback, revisit — but note the
  bar: it must be worth a third toolchain, and it must not need a chatty
  boundary.

### If Rust makes sense anywhere

It does not, today. The closest candidate is a VT parser built on `vte`, and it
is named here so it can be rejected on the record: the crate is genuinely better
than what Kurotty has, and the boundary is genuinely wrong for it. `vte`'s value
is a Rust trait with per-sequence callbacks against a grid on the same side of
the boundary. Kurotty's grid is on the Swift side and will stay there as long as
Swift owns Metal. Put the grid behind an FFI and the Ghostty design is the one
that works — and Ghostty is Zig.
