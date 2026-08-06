# Kurotty improvement roadmap

An audit of Kurotty across five axes — AI-agent story, visual design, everyday
usability, architecture, and engineering health — plus a recommendation for what
to ship next and why.

Claims are marked **[verified]** when something was run and its output observed,
and **[read]** when they rest on reading the code. Anything unmarked is a
judgement call, not a finding.

---

## 0. The headline: a remote-triggerable abort, now fixed

`\e[99999m` killed the app.

Any CSI parameter of 65536 or more overflowed the `u16` parse at
`src/parser.zig:231`. The overflow propagated out of `Parser.feed`, whose
`errdefer` handed `events.items` — a borrowed, length-sized slice of a
capacity-sized allocation — to `freeEvents`, which frees it as if it owned it.
The production allocator is a `DebugAllocator` (`src/abi.zig:4`), so it panics.

`CoreBridge.feed` sits on the PTY output path next to the interpreter that
actually renders (`TerminalSurfaceView.swift:1805`), so every byte a child
process writes reaches this parser. `printf 'x\e[99999m'`, or `cat` of any log
containing those bytes, aborted the app. No privileges, no interaction beyond
viewing output.

**[verified]** Reproduced against the dylib installed at
`/Applications/kurotty.app/Contents/Resources/libkurotty_core.dylib` — SIGABRT,
exit 134, on the first feed. After the fix the same harness prints `SURVIVED`,
exit 0.

Two things kept this hidden, and both are worth more attention than the bug:

1. **Every parser test uses an `ArenaAllocator`, whose `free` is a no-op.** The
   test suite could not observe an invalid free by construction. Production uses
   `DebugAllocator`. New tests use the testing allocator.
2. **A test asserted the crashing behavior.** `"parser rejects overflowing CSI
   parameters instead of silently defaulting"` required `error.Overflow`. The
   intent — don't let an oversized parameter silently become 0 — was right; the
   mechanism made a routine byte sequence fatal. Clamping per ECMA-48 keeps the
   intent.

---

## 1. Shipped in this pass

| Fix | Why it mattered |
|---|---|
| Escape sequences leaking into command history | Arrow keys recorded as `[A` / `OA`, mid-line recall spliced into words (`ssOAOBh-real`), pastes recorded their bracketed-paste guards |
| Invisible close button closing tabs | Hover is `.activeInKeyWindow`, so in a background window the close button stays at alpha 0 — and the first click to focus a tab closed it |
| `\e[99999m` abort | Above |

Each landed with tests. Full suite green: 1517 Swift, Zig suite exit 0
**[verified]**.

### Still open on command history

The recorder reconstructs commands by echoing keystrokes, so it cannot see text
the *shell* supplied: history recall, tab completion, `Ctrl-R`. Those now record
nothing rather than garbage, which is better but still wrong. The real fix is for
the shell integration to report the command line from `preexec` — zsh gets `$1`,
bash has `$BASH_COMMAND`, fish has `$argv[1]` — as an OSC 133 payload extension.
That is a protocol change and deserves its own change.

---

## 2. What to build next, and why

The audit produced far more work than can be sequenced at once, so this is the
recommendation, not a menu.

### The bet: make Kurotty the terminal that runs your agents

The strongest asset here is not a plan — it is code that already exists and is
not connected.

- `AIAgentActionApproval.swift` + `AIAgentActionApprovalModel.swift` +
  `AICommandContextBridge.swift` + `AIContextLayer.swift` — roughly 1,250 lines
  implementing a full request → evaluate → approve → dispatch → audit pipeline,
  with fingerprint replay protection, redacted previews, and persistence scopes.
  **Three test files. Zero call sites in `Sources/`.** `DESIGN.md:313-332`
  specifies the panel it was built for; that panel does not exist.
- A Claude Code hook installer that already writes `UserPromptSubmit` /
  `Notification` / `Stop` hooks, marker-scoped with a backup so uninstall cannot
  eat user hooks.
- A session vault that parses Claude and Codex transcripts, a context-window
  forecast that returns `nil` rather than guessing an unknown model's limit, and
  per-file provenance joining edits back to the prompt that caused them.

**Recommendation: native permission approvals.** Claude Code's approval prompt is
a TUI dialog inside the pane. Kurotty owns the PTY, so it alone can surface that
as a real macOS sheet — with cwd, target pane, and a remembered scope — and write
the answer back. It combines the hook work with the approval pipeline as
designed, and no Electron wrapper can do it without reimplementing a terminal.

It is also the demo: a ten-second GIF of an agent's permission prompt becoming a
native sheet is a launch post on its own.

**Ship alongside it (small, and the actual daily win):** route
`waitingForInput` / `blocked` into the notification path that already delivers
OSC 9/777/1337. Today agent status reaches only a status-bar dot, so an agent
silently blocked on a permission prompt in an unfocused pane is the single
highest-frequency cost of running agents all day.

**Then:** a cross-pane agent overview — every pane, its agent, state,
context-window fill, tokens, worktree. Every data source already exists and is
indexed. Orca needs a whole application for this; Kurotty needs one view.

### But do not launch onto a leaky bucket

If the bet works, new users arrive — and several of the findings below will
bounce them on day one. These are mostly small, and they should land first.

| # | Problem | Effort |
|---|---|---|
| 1 | **Command-finish notifications have no filter.** Any unfocused pane finishing `ls` fires a macOS banner. Users mute Kurotty within a day, killing the whole notification pipeline. Ghostty and kitty gate this on a duration threshold | S |
| 2 | **A dead shell leaves a frozen pane.** `onExit` has exactly one subscriber, which forwards to tmux and nothing else. No exit code, no message, no restart | S |
| 3 | **No PTY backpressure. [verified]** `ShellSession` calls `.resume()` twice and `.suspend()` never, draining to `EAGAIN` with no cap — the child never blocks on `write(2)`, so the OS's free flow control is defeated. `yes` grows memory without bound. `DESIGN.md:419` names `yes` as an explicit target; no throughput test exists | M |
| 4 | **Scrollback defaults to the maximum. [verified]** `AppSettings.swift:44` sets `scrollbackLines = maximumScrollbackRows` — 1,000,000 rows. With no backpressure, a multi-GB ceiling by default | S |
| 5 | **Links steal plain left-click and confirm every time.** You cannot drag-select a URL out of a log. All four reference terminals require a modifier | S |
| 6 | **No font-size zoom.** No `Cmd +/-/0`; the only path is the Preferences window | S |
| 7 | **Mouse wheel is dead in `less` / `man` / `git log`.** DEC mode 1007 alternate-scroll is unimplemented | S |
| 8 | **Search misses matches across a soft wrap.** Rows are matched individually, and `grep` output wraps constantly. A silently wrong result is worse than a missing feature — and the link path already solves the same problem | M |
| 9 | **No keybinding customization.** Every shortcut is a literal. This is the top reason power users bounce off a new terminal. `TerminalWindowCommandID` is already the right seam | L |

---

## 3. Design

The design system is genuinely good — better than most shipping apps. Across 170
files there are 8 raw `NSColor` component constructors, 7 of them inside
`DesignTokens.swift`; exactly one stray point size and one stray corner radius
outside the token file. `Typography.Role` bundles size, weight, line-height,
tracking and design together so call sites cannot pass a rogue weight.

The scale itself is already competitive. Measured against Orca:

| | Kurotty | Orca |
|---|---|---|
| Row title | 12pt / 16 | 13px card, 11px agent row |
| Secondary | 11pt / 15 | 11.5px |
| Timestamp / badge | 10pt / 14 | 10px |
| Row height | 26px | 24px |
| Panel width | 350 (200–460) | left 280 (220–500), right 350 |

**What is missing is not craft, it is surface area.** The token layer is a
well-built house with no plumbing to the OS.

1. **The app never reads system appearance.** Theme is inferred from terminal
   background luminance and force-pinned onto every window;
   `viewDidChangeEffectiveAppearance` appears zero times. A Light Mode user gets
   a dark app forever. Make theme a `{light, dark}` pair with a follow-system
   default — this also fixes the palette clashes below. **(M)**
2. **No transparency or blur.** `NSVisualEffectView` appears zero times;
   everything is explicitly opaque. The most-requested aesthetic feature in
   macOS terminals, and the thing every screenshot comparison loses on. **(M)**
3. **Bold is a brightness hack, italic is silently dropped.** The glyph atlas key
   has no weight or slant field — and the correct composite key already exists in
   `TerminalGlyphRun.swift`, a 991-line file with zero production call sites.
   Every prompt, `man` page and `git log` renders flat. **(M)**
4. **One cursor shape, DECSCUSR ignored.** vim's insert/normal indicator does
   nothing. **(M)**
5. **Two scrollbars drawn on top of each other. (S)** A legacy `NSScroller`
   draws its own track and knob, with a hand-rolled thumb stacked over it. Never
   auto-hides, permanently occupies 12pt, and the thumb is theme-blind — on the
   light theme it measures about 1.3:1 against white.
6. **Light-theme muted text fails the contrast target `DESIGN.md:62` claims.**
   Measured 3.41–3.82 against a stated WCAG AA bar of 4.5. Fix the ramp and add a
   test asserting every text × surface pair. **(S)**
7. **Accessibility is a stated goal with no implementation.** `TerminalMetalView`
   — the actual content — has zero accessibility calls, so VoiceOver cannot read
   the terminal. `reduce-motion`, `increase-contrast` and
   `differentiateWithoutColor` appear zero times repo-wide, against
   `DESIGN.md:63-66`. **(M–L)**
8. **Font family is a hardcoded five-name allowlist**, one of which won't resolve
   on most systems. JetBrains Mono or Fira Code require hand-editing JSON. **(S)**
9. **Two built-in themes, in a popup.** The import machinery for iTerm2 and
   Ghostty formats is solid and well tested — discovery is what's missing. Vendor
   a scheme corpus, swap the popup for a swatch grid. **(S)**

---

## 4. Architecture and engineering health

### The through-line

This codebase repeatedly **builds the right thing and never connects it**: the
Zig core, `TerminalGlyphRun`'s composite atlas key, `src/scrollback.zig`, the
latency metric, `PressureLevel`, `TmuxBoundedOutputHistory`, and the entire AI
approval pipeline. Before writing new subsystems, spend a sprint connecting the
ones that exist. It is the cheapest quality available.

### Ranked

1. **`main` is not protected. [verified]** `gh api .../branches/main/protection`
   returns 404; rulesets are `[]`. Every CI gate is advisory. Two minutes, and
   without it nothing else holds. **(S)**
2. **Decide the Zig core's fate, in writing. (M)** It is currently a shadow
   parser: `copyRow`, `copyStyledRow` and `cellAt` have no non-test callers, the
   damage tracker is a no-op, and `CoreBridge` self-reports
   `screenMutationOwner: .swiftScaffold`. It renders nothing and costs main-thread
   time on every output chunk. Either give it ownership behind a real ABI — which
   means replacing `DebugAllocator`, making thread-safety real, and adding an
   `abi_version` export — or delete `src/` down to the metrics shim.
3. **GPU/CPU data race in the Metal renderer. [verified]** No `DispatchSemaphore`,
   `maxBuffersInFlight`, or `waitUntilCompleted` anywhere in `Sources/` — the one
   semaphore in the tree is in `AppSettings`. `updateSharedBuffer` memcpys into
   shared-storage buffers the GPU may still be reading; `addCompletedHandler` is
   the presented callback, not a reuse fence. Intermittent glyph corruption under
   fast output — the "flaky rendering, can't reproduce" bug class. **(S)**
4. **No ABI thread-safety or version contract. (S)** `CoreBridge` is
   `@unchecked Sendable` with no lock, while `Grid.resize` frees `self.cells`;
   `symbol` does `unsafeBitCast` with no signature check. `repositoryRootURL()`
   bakes `#filePath` — the developer's absolute path — into the shipped binary.
5. **Source-text assertions. (M)** `GlyphRenderingRegressionTests.swift` is 3,278
   lines with 1,595 assertions, 285 of which read a source file as text and
   assert substrings **[verified count]**. They are worse than brittle — they are
   misleading. `testEraseLineUsesActiveStyleForClearedCells` never erases a line;
   it asserts that a string appears in the interpreter's source. REP, ECH and
   DECSTBM are "covered" the same way, so VT features are reported as tested by
   name while remaining unexercised.

   Exhibit A, from this session: fixing three real bugs broke exactly four
   assertions, **all four of them source-string checks, and none of them a
   behavioral regression**. The suite penalized the fixes and caught nothing.

   Delete them and port the Zig corpus — which tests fragmented CSI/OSC/DCS
   reassembly, overflow resync, CJK wide cells, combining marks, and UTF-8 split
   across writes — onto `interpreter.interpret`. Same project, not two.
6. **Damage tracking does not reduce CPU. (M)** `rebuildAtlasBuffers` walks every
   cell ignoring `dirtyRows`, and instances are re-encoded once per scissor rect
   — with a 64-rect budget, partial redraw can be slower than full, with no
   area-crossover heuristic. It is a fragment-count optimization presented as a
   damage model.
7. **Diagnostics in the per-glyph hot loop. (S)** `diagnosticDirtyRectPixels`
   allocates per glyph, plus a pixel probe read only by a debug log — roughly
   10k dead allocations per full-damage frame, in shipping builds.
8. **Nothing measures performance. (M)** `bench/main.zig` has no timing — it
   prints counters, so `zig build bench` can only fail on a crash. CI runs Zig
   tests at Debug while releases ship `ReleaseFast`, so the shipped configuration
   is never tested. `CoreBridge.lastLatencyMicros()` computes a correct number
   with zero call sites; there is no `os_signpost` and no dropped-frame counter.
9. **God objects. (L)** `TerminalSurfaceView` is 3,158 lines with 66 stored
   properties and is not injectable — 21 tests each spin up a real MTKView. The
   first seam is `TerminalFrameBuilder`: `updateRendererFrame` plus its decoration
   helpers is already a pure function of (rows, metrics, selection, matches,
   links, marked text) → `TerminalFrame`. Then `GlyphAtlas` and
   `TerminalDamagePlanner` out of `TerminalMetalView`, and the three interleaved
   state machines out of `TmuxControlModeDriver`. `TerminalWindowController` is
   *not* a god object — it is already split across eight extension files.

### VT correctness gaps

Against the Swift interpreter, which is the real render path.

| Gap | Breaks |
|---|---|
| Bold and italic never render | Every prompt, `man`, `git log`, `bat` |
| DCS/APC/PM payloads print literally | neovim's capability probes dump `$q"p` on screen; sixel dumps megabytes |
| Alt screen writes to scrollback | `less`, `htop`, `vim` pollute scrollback with every repaint |
| No charset designation / DEC Special Graphics | `dialog`, `mc`, `nmtui` draw borders as `lqqqk` |
| Erase fills with the full SGR pen, not background-only | `less` and `vim` status lines turn the rest of the line inverse |
| No soft reset (`CSI ! p`) | `reset` / `tput init` leaves the scroll region wedged |
| No DECSCUSR, no synchronized output (2026) | neovim's bar cursor absent; fzf and neovim tear |
| Underline styles collapsed to one Bool; `wcwidth` misses U+1F680–1F6FF and CJK Ext B/C | Undercurl wrong; column drift on emoji |

---

## 5. Suggested sequence

**Now** — branch protection; notification filter; child-exit banner; scrollback
default; `Cmd +/-/0`; alternate-scroll; Cmd-click for links. Almost all S, and
they are what a new user hits in the first ten minutes.

**Next** — the frame semaphore and PTY backpressure, because they are the
difference between a fast terminal and one that corrupts and grows without
bound. Then delete the source-string assertions and port the Zig corpus, because
every refactor after this is gated on having a suite that can tell a rename from
a regression.

**Then the bet** — native permission approvals, agent-waiting notifications, and
the cross-pane agent overview. Alongside it, a README that mentions the agent
features at all: it currently contains zero occurrences of "AI", "agent",
"Claude", or "Codex", so six shipped features are invisible to anyone evaluating
the project.

**Ongoing** — system appearance, background opacity, real bold and italic, cursor
shapes. These are the design gap, and they compound.
