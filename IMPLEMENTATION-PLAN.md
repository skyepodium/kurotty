# Kurotty implementation plan — features ported from other terminals

A ranked plan for what to bring into Kurotty from the terminals tracked alongside
it, derived from an upstream sweep on 2026-08-13 covering the commits landed in
kitty, ghostty, iTerm2, tmux, orca, and cmux since early August. Alacritty had no
new commits in the window.

Every item names the upstream change it comes from, so the original
implementation can be read before ours is written.

## How this was ranked

Three axes, multiplied:

1. **Does it serve the bet?** Kurotty's bet is *the terminal that runs your
   agents*. Work that makes running Claude Code / Codex all day better outranks
   work that does not.
2. **Is it felt daily by the people who actually use this build?** Korean input
   on macOS is the clearest example — it is hit every hour and is invisible to
   most upstreams.
3. **Cost.** An S-sized change that removes a daily irritation beats an L-sized
   change that wins a screenshot comparison.

Items already shipped in Kurotty were dropped from the candidate list during the
sweep: alternate scroll (mode 1007), the command-finish notification filter,
font-size zoom, the OSC 9;4 progress bar, DCS/APC/PM consumption, and pane
drag-and-drop reordering all exist today.

## Status legend

- `[ ]` not started
- `[~]` implemented on a branch, not yet merged to `develop`
- `[x]` done

## Branches in flight

All five branch off `develop` at `14097c9`. Each carries its own tests and each
kept the full Swift suite green on its own branch.

| Branch | Item | Commit |
|---|---|---|
| `feat/terminal-file-drop` | 0.1, plus this plan | `42e25e1` |
| `feat/parser-resource-limits` | 0.2 | `245a62b` |
| `feat/korean-input-fixes` | 1.1, 1.2 | `dd7004f` |
| `feat/agent-waiting-notifications` | 2.1 | `9002cae` |
| `feat/decscusr-cursor-shapes` | 3.3 | `321e3e3` |

Merge order matters in two places: `feat/agent-waiting-notifications` is the only
branch that changes `AppSettings.swift` (schema 22 → 23), and it shares
`AppConstants.swift` with `feat/parser-resource-limits`. Land the parser branch
first and the settings branch second, and the rest are disjoint.

---

## Tier 0 — Foundations

Nothing else should land on top of these.

### 0.1 Terminal file drop — insert dropped paths at the cursor `[~] feat/terminal-file-drop`

Dragging a file from Finder onto a pane does nothing today: the only registered
drag destination is `TerminalPaneDropTargetView`, and it accepts only Kurotty's
own pane-drag pasteboard type. Dropping a path into the terminal is baseline
behavior in Terminal.app, iTerm2, kitty, and ghostty.

- [x] `TerminalFileDropFormatter` — pure, Foundation-only: URLs + style → text
- [x] POSIX single-quote quoting, with `'` escaped as `'\''`; quote only when the
      path contains anything outside a conservative safe set
- [x] Modifier styles: default = absolute path, Option = file name only,
      Shift = path relative to the pane's working directory when it is under it
      (`TerminalFileDropModifiers`; Option wins when both are held)
- [x] Multiple files joined by a space, one trailing space after the last path
- [x] Do **not** normalize the path's Unicode form — macOS hands out NFD and the
      filesystem bytes are authoritative. Rendering decomposed Hangul correctly
      is `1.1`'s job, not this one's
- [x] Register `.fileURL` on `TerminalSurfaceView` so the drop lands on the pane
      under the pointer; Kurotty's own pane-drag type stays unregistered there,
      so pane drags still resolve to the window's drop target
- [x] Route the text through the existing paste pipeline
      (`TerminalPastePlanner` → `TerminalPasteExecutor`) so bracketed paste,
      size limits, and backpressure pacing all apply for free — a file name may
      legally contain a newline, so a drop can also earn the multi-line paste
      confirmation
- [x] Drop highlight on the receiving pane, reusing the pane-drop design tokens
- [x] Tests: quoting (spaces, apostrophes, `~`, non-ASCII), style selection,
      relative-path fallback, sibling-prefix directories, multi-file joining,
      empty drop, NFD pass-through asserted on scalars — Swift's `==` compares
      canonical equivalence and would not have caught a normalizing regression
- [ ] Remaining: installed-app smoke check (drag a file from Finder onto a pane,
      a split, and an SSH pane). Unit tests cannot exercise AppKit's drag
      session

### 0.2 Parser resource limits `[~] feat/parser-resource-limits`

*From ghostty `terminal: bound OSC and grapheme allocations`,
`terminal/kitty: limit png decoder allocations`.*

The premise this item was written on was half stale: CSI and OSC bounds already
landed with the `\e[99999m` fix (`maximumCsiParameterBytes`,
`maximumStringPayloadBytes`, and the `.csiDiscard` / `.oscDiscard` resync
states). Two accumulations on the same path were genuinely unbounded.

- [x] Bound the DCS/SOS/PM/APC consumption path. Nothing is buffered there, so
      the exposure is not memory: a string control whose `ESC \` never arrives
      swallows every byte the child writes for the rest of the session, and a
      program killed between `ESC P` and `ESC \` reaches it
- [x] Cap per-cell combining-mark accumulation at the Stream-Safe Text Format
      bound (UAX #15): 30 non-starters plus a base
- [x] Limits as named constants in `AppConstants`, each with its reasoning
- [x] Mirror the string-control bound in `src/parser.zig`; its grid stores one
      combining mark per cell, so grapheme growth there was already bounded
- [x] Behavioral tests: payloads split across feeds, nothing painted, state
      resynced, a following sequence still parses. Zig tests use
      `std.testing.allocator` — an arena's no-op `free` cannot observe an
      invalid free
- [x] Verified red-first: with the bounds neutered, 4 of the 9 Swift cases and
      the Zig case fail
- [ ] **Open divergence found here:** the Swift OSC bound is 1 MiB and
      `src/parser.zig`'s is 4096, which would truncate a real OSC 52 clipboard
      write. Harmless while Zig is not the render path; it becomes a bug the day
      it is. Belongs with `docs/improvement-roadmap.md` §4.2, "decide the Zig
      core's fate"
- [ ] **Trade-off to revisit:** an over-long string control resyncs to normal,
      so a payload Kurotty does not render anyway (a >4 MiB sixel frame) prints
      its tail as text. Ghostty keeps consuming to ST instead

### 0.3 Title reports stay opt-in `[ ]`

*From ghostty `terminal: require opt-in for title reports`.*

Kurotty does not implement title reports at all, which makes this free today and
expensive later: a default-on title report lets screen content be replayed into
the shell as typed input.

- [ ] Add `terminal.titleReportsEnabled`, default `false`
- [ ] Record the rule in `AGENTS.md`: reports off by default, and control
      characters stripped from any title that is ever reported back

### 0.4 Clipboard and hyperlink trust `[~] feat/clipboard-link-trust`

*From ghostty `macos: defer OSC52 clipboard read confirmations until focused`
and `macos: handled untrusted OSC8 hyperlinks more carefully`.*

- [x] Queue OSC 52 confirmation sheets while the window is unfocused, present on
      focus return. `TerminalClipboardConfirmationQueue` is a pure value type;
      the surface only presents what it hands back
- [x] **Coalescing rule: newest wins.** At most one request is ever pending and a
      newer one replaces it. The pasteboard holds a single value, so approving a
      superseded write would leave stale text on it while the program that sent
      the *last* write believes that one took; and returning to a stack of sheets
      is the failure the queue exists to prevent. The queue also refuses to open
      a second sheet while one is up, and drains when it closes
- [x] A held request dies with its pane: `cancelPending()` on child exit and on
      `viewWillMove(toWindow: nil)`
- [x] Focus comes from `TerminalCursorPresentationPolicy.isFocusedForUser`
      through the surface's existing `isTerminalFocusedForUser`; the queue takes
      it as a parameter rather than defining a second rule
- [x] Tag link records with their provenance (OSC 8 payload vs. text scan) and
      always show the real target URL for the untrusted tier
- [x] Untrusted tiers: OSC 8 whose visible text is not its target, a scheme
      outside http/https/file/mailto, `user:pass@host`, control characters or a
      newline in the target, an unparsable target. The tier only ever *narrows*
      `TerminalSecurityPolicy` — it downgrades a silent open to a confirmation
      and never promotes a refused scheme into a question
- [x] The confirmation prints `safeTarget`, never the raw payload: control
      characters removed, userinfo redacted, and the real host on its own line.
      What opens keeps the userinfo, because dropping it would open a different
      address than the one shown
- [x] No new prompt for the honest case. A scanned URL is its own display text,
      so it keeps opening on the ⌘-click alone; so does an OSC 8 link whose label
      *is* its target, which used to be indistinguishable from a mismatched one
- [ ] **Found while wiring this:** an OSC 52 write evaluated `ask` was previously
      dropped in silence — there was no confirmation UI at all, only the `allow`
      path. It now presents. Reachability is unchanged for now: the surface
      classifies every OSC as `origin: .local` because session transport
      awareness does not exist yet, and a local write is `allow`. The sheet
      becomes live the day remote-origin classification lands
- [ ] OSC 52 *read* (`52;c;?`) is still ignored rather than answered. Replying
      would be a new outbound clipboard-to-PTY capability, not a deferral, so it
      stays out of this change

---

## Tier 1 — Korean input

### 1.1 Compose decomposed Hangul `[~] feat/korean-input-fixes`

*From iTerm2 `Compose decomposed Hangul instead of splitting jamo` (issue
3063).*

macOS filesystems emit NFD, so every `ls` and `git log` of a Korean filename
arrives as separate jamo, renders scattered, and miscounts columns.

- [x] Compose jamo sequences into precomposed U+AC00 syllables at the point
      scalars become cells; width 2
- [x] Handle jamo split across PTY chunks: write immediately and rewrite the
      cell in place rather than buffering. A PTY has no flush signal, so a
      buffered syllable would hold a Korean prompt's last character back
      indefinitely
- [x] Guard the rewrite: the cursor must still sit after the pending cell, the
      cell must still hold what was written, and only a write that *arrived* as
      conjoining jamo becomes pending
- [x] Normalize the search query too — `NSString.range(of:)` folds NFD onto NFC
      under canonical equivalence but `NSRegularExpression` compares scalars, so
      a decomposed regex query silently found nothing
- [x] Scrollback serializer deliberately unchanged: cells already hold composed
      characters, and composing joined row text would merge two standalone jamo
      that are legitimately two columns
- [x] Display side only — never normalize bytes sent back to the shell
- [x] Tests assert scalar signatures, not `==`: Swift's `==` compares canonical
      equivalence, so the naive assertions pass with or without the fix

Two findings worth keeping: the real column bug was the chunk split (a lone
initial jamo is wide, a lone medial is not, so a split syllable claimed four
columns), and `precomposedStringWithCanonicalMapping` does **not** compose
`U+AC00 U+11A8` — exactly the cross-chunk case — which is why the arithmetic is
hand-rolled.

### 1.2 Korean Won key → backquote `[~] feat/korean-input-fixes`

*From orca `#13104`.*

- [x] Map the physical backquote key to a backtick under the Korean layout,
      keyed on `keyCode`, not on the produced character
- [x] A genuine `₩` from IME or paste must not be rewritten. Shipped without a
      setting: it fires only on keyCode 50 **and** a produced `₩` **and** no
      modifiers, so there is nothing left for a setting to guard
- [ ] Unverified: keyCode 50 is the ANSI/ISO backquote position, not checked on
      JIS-physical hardware. And with marked text active the router offers the
      event to `NSTextInputContext` first, so IMK commits the syllable and then
      sends `₩` rather than a backquote — left as-is rather than reordering the
      IME boundary

### 1.3 Kitty keyboard protocol (CSI-u) `[ ]`

*From orca `#13310` (IME commits encoded as CSI-u under the all-keys flag).*

Kurotty has xterm `modifyOtherKeys` (`TerminalKeyEncoder.extendedKeyFormat`) but
not the kitty protocol. Agent TUIs increasingly assume it.

- [ ] Flag stack and query responses (`CSI > flags u`, `CSI < u`, `CSI ? u`)
- [ ] Flag 1 (disambiguate) encoding — this alone covers most real TUIs
- [ ] Flags 2 / 4 / 8 as separate commits
- [ ] IME commits as CSI-u, gated on the all-keys flag; ungated, this breaks
      Hangul input in every program that does not support the protocol
- [ ] Reflect the negotiated state in `TmuxPaneSnapshot` on attach

---

## Tier 2 — The agent bet

### 2.1 Waiting / blocked agent notifications `[~] feat/agent-waiting-notifications`

*From orca Prime Agent status hooks (`#13384`, `#13430`), cmux
`ingest native agent hooks losslessly`. Also `docs/improvement-roadmap.md` §2,
which calls this "the actual daily win".*

- [x] Route `waitingForInput` / `blocked` into the existing typed notification
      path rather than a second delivery mechanism
- [x] Fire on transition into the state, only while unfocused, debounced per
      pane (10 s), withdrawn when the state clears, when the user reaches the
      pane, when the setting is turned off, and on pane teardown
- [x] A focused pane records the transition without notifying, so alt-tabbing
      away later does not fire retroactively
- [x] Payload from hooks/OSC only; identify the pane, never the vendor
      (`AGENTS.md`: producer-neutral)
- [x] Decision logic in a pure policy type, mirroring
      `TerminalCommandFinishNotificationPolicy`
- [x] `terminal.notifyOnAgentWaiting`, default on; settings schema 22 → 23
- [ ] Not proven: a real agent driven into a waiting state in an unfocused pane,
      with the banner observed appearing and then being withdrawn. Unit tests
      and a signed `.app` smoke test are not that gate

### 2.2 Link action popover `[ ]`

*From orca `#13414` (anchored link action popovers) and `#13857` (copy action).*

Fixes the audit's finding that links steal plain left-click and re-confirm every
time, which makes a URL in a log impossible to drag-select.

- [ ] Cmd-click opens immediately; plain click opens a popover with open / copy
      URL / paste path / open in editor
- [ ] Resolve file-path links against the OSC 7 working directory
- [ ] Match links and search hits across soft wraps — same root cause as the
      audit's "search misses matches across a soft wrap"

### 2.3 Cross-pane agent overview `[ ]`

*From orca's experimental agent map view (`#12168`).*

Every data source already exists and is indexed; this is a view, not a subsystem.

- [ ] Sidebar panel: pane, agent, state, context fill, tokens, worktree
- [ ] Read existing indexes only — no new collectors
- [ ] Row click focuses the pane

### 2.4 SSH and remote host identity `[ ]`

*From orca `#14177` (identify SSH and remote hosts) and `#12396` (inline SSH
reconnect on workspace cards).*

- [ ] Pane badge from the OSC 7 host field
- [ ] Inline reconnect affordance in the sidebar

---

## Tier 3 — Protocol interop

### 3.1 Kitty drag-and-drop, OSC 72 — accept side `[ ]`

*From iTerm2's phases 0–4b (the protocol went from nothing to shipping in ~96
commits this window; kitty supports it on the other end).*

Half of iTerm2's commits were review hardening, so the hardening belongs in the
first implementation, not a follow-up.

- [ ] Phase 0: wire layer, parse only
- [ ] Phase 1: deliver to the session
- [ ] Phase 2: accept-drop controller
- [ ] Phase 3: route window drops to the program
- [ ] Included from the start: same-window cross-pane self-drag refused with
      `EPERM`, protocol state reset at a new shell prompt and on terminal reset,
      machine-id validation, bounded payloads
- [ ] Out of scope for this branch: drag-out (`t=k`), cross-machine in-band
      transfer
- [ ] Port iTerm2's manual harness (`tests/kitty-dnd/`) for conformance runs

### 3.2 Kitty graphics protocol `[ ]`

Kurotty already swallows the `ESC _ G` envelope safely, so this is purely
additive. Ghostty's hardening pass this window is the specification for what to
get right on the first try.

- [ ] Validate and restrict image file paths; validate shared-memory ranges
- [ ] Bound PNG decoder allocations
- [ ] Placement geometry, deletion by point (`d=p`, `d=c`), eviction, and pin
      release — every one of these was a bug ghostty fixed this window
- [ ] Clear placements on image retransmit

---

### 3.3 Cursor shapes and synchronized output `[~] feat/decscusr-cursor-shapes`

Baseline in ghostty and kitty, and every agent TUI sits on top of both.

- [x] DECSCUSR (`CSI Ps SP q`): block / underline / bar, blinking and steady,
      classified off the space intermediate on the raw parameter buffer the same
      way `TerminalCapabilityReplies` reads DECRQM's `$`, which is what keeps
      DECSCA, XTVERSION, and DECLL out of the cursor path
- [x] An undefined `Ps` leaves the cursor alone rather than clamping
- [x] `Ps = 0` means *this terminal's* default, as ghostty and kitty read it.
      Kurotty's rendered default is a blinking bar, so `\e[0 q` gives that back
      instead of silently switching every user to a block
- [x] One `cursorPointRect` anchors all three shapes; the Metal instance, the
      CoreGraphics fallback, and the coordinate diagnostics stopped each
      rebuilding the rect
- [x] No new blink timer: a steady style renders immediately instead of at the
      next timer edge, and spends no full-surface redraw per tick
- [x] tmux: `listPaneState` asks for `cursor_shape` and `cursor_blinking`
      (verified against a live tmux 3.7b, not from memory) and the reattach
      replay emits `CSI Ps SP q` after `?25h`; an older tmux replays `CSI 0 SP q`
- [ ] Synchronized output (mode 2026) **not implemented, and nothing advertises
      it.** The blocker is not the missing frame fence the roadmap describes —
      see the correction below. It is that the only presentation choke point,
      `updateRendererFrame()`, has 26 call sites, and holding it needs a
      surface-owned timeout timer with a cleanup contract plus a decision on
      whether user-driven presents freeze during a hold. Its natural test is
      timer-driven, which `AGENTS.md` warns against as a release gate
- [ ] Still no DECSTR (`CSI ! p`); the shape restores on RIS only. VT510 and
      xterm disagree on whether DECSTR resets DECAWM, and guessing wrong there
      regresses wraparound

## Tier 4 — Window and shell UX

Each of these is roughly half a day.

- [ ] **Pane title rename with `T`** and a `pane_private_modes`-style mode list
      in the tmux control-mode integration — *tmux, this window*
- [ ] **Restore sessions whose working directory is gone** — *iTerm2, issue
      12955*
- [ ] **Metal and font warmup at app creation** — *ghostty
      `renderer/metal: warm up command queue and shader pipelines`,
      `font: support warmup threads`*
- [ ] **Move tab to new window; drag splits across the tree** — *ghostty
      `move_tab_to_new_window`, `gtk: implement drag-to-move for splits`*
- [ ] **Scrollable tab bar; `drag-handle` setting** — *iTerm2 `#721`, ghostty
      `config: add drag-handle`*

---

## Deliberately not ported

- **Kitty's custom shader pipeline** — roughly half of kitty's commits this
  window, and it needs the Slang toolchain, a pipeline definition format, and an
  animation framework. Background opacity and blur buy most of the same visual
  credibility for a fraction of the cost, and Kurotty has neither yet.

  *Correction:* the first draft justified this by saying the renderer has no
  GPU/CPU reuse fence, citing `docs/improvement-roadmap.md` §4.3. That is stale.
  `TerminalMetalView` has `inFlightSemaphore = DispatchSemaphore(value: 3)` with
  slot rotation and a completion-handler signal. The audit finding was fixed and
  the roadmap was not updated — worth a pass over §4 before trusting its other
  rows.
- **cmux's iOS app, remote daemon, and generated SDKs** — different product.
- **orca's stacked pull requests and Bitbucket integration** — workspace manager
  features, not terminal features.

---

## Sequencing note

Tier 2 is the strategic priority, but Tier 0 goes first and costs one to two
days. Growing the user base while a `cat` of the wrong log file can still exhaust
memory makes every later success more expensive, and 0.1 is baseline behavior
users notice missing within a minute of trying the app.

The one debatable call is placing Tier 1 ahead of Tier 2. Public impact favors
the agent notifications; daily lived cost for this build's actual users favors
Korean input. If the ordering needs to change, move only 2.1 forward — it is S-
sized — and leave the rest of Tier 2 where it is.
