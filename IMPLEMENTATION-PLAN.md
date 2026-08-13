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
- `[~]` in progress on a branch
- `[x]` merged to `develop`

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

Kurotty has already shipped one remote abort through this surface (`\e[99999m`,
`docs/improvement-roadmap.md` §0). Escape-sequence buffers still accumulate
without a cap.

- [ ] Cap OSC, CSI, and string-control (DCS/SOS/PM/APC) accumulation
- [ ] On overflow, discard the sequence and resync to the normal state — never
      truncate-and-execute, never paint the payload as text
- [ ] Cap per-cell combining-mark accumulation
- [ ] Limits as named constants in `AppConstants`, each with a stated reason,
      set above real OSC 8 / OSC 52 payload sizes
- [ ] Same audit on `src/parser.zig`; Zig tests must use the testing allocator,
      never an arena — an arena's no-op `free` cannot observe an invalid free
- [ ] Behavioral tests: oversized payload split across feeds, nothing painted,
      state resynced, a following sequence still parses

### 0.3 Title reports stay opt-in `[ ]`

*From ghostty `terminal: require opt-in for title reports`.*

Kurotty does not implement title reports at all, which makes this free today and
expensive later: a default-on title report lets screen content be replayed into
the shell as typed input.

- [ ] Add `terminal.titleReportsEnabled`, default `false`
- [ ] Record the rule in `AGENTS.md`: reports off by default, and control
      characters stripped from any title that is ever reported back

### 0.4 Clipboard and hyperlink trust `[ ]`

*From ghostty `macos: defer OSC52 clipboard read confirmations until focused`
and `macos: handled untrusted OSC8 hyperlinks more carefully`.*

- [ ] Queue OSC 52 confirmation sheets while the window is unfocused, present on
      focus return
- [ ] Tag link records with their provenance (OSC 8 payload vs. text scan) and
      always show the real target URL for the untrusted tier

---

## Tier 1 — Korean input

### 1.1 Compose decomposed Hangul `[~] feat/korean-input-fixes`

*From iTerm2 `Compose decomposed Hangul instead of splitting jamo` (issue
3063).*

macOS filesystems emit NFD, so every `ls` and `git log` of a Korean filename
arrives as separate jamo, renders scattered, and miscounts columns.

- [ ] Compose jamo sequences into precomposed U+AC00 syllables at the point
      scalars become cells; width 2
- [ ] Handle jamo split across PTY chunks, and a final consonant that arrives
      after the syllable was already placed
- [ ] Use the same normalization in the scrollback serializer and in terminal
      search, or searching a Korean filename silently misses
- [ ] Display side only — never normalize bytes sent back to the shell
- [ ] Tests: NFD filename cells and column advance, jamo split across two feeds

### 1.2 Korean Won key → backquote `[~] feat/korean-input-fixes`

*From orca `#13104`.*

- [ ] Map the physical backquote key to a backtick under the Korean layout,
      keyed on `keyCode`, not on the produced character
- [ ] A genuine `₩` from IME or paste must not be rewritten

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

- [ ] Route `waitingForInput` / `blocked` into the existing typed notification
      path rather than a second delivery mechanism
- [ ] Fire on transition into the state, only while unfocused, debounced per
      pane, withdrawn when the state clears
- [ ] Payload from hooks/OSC only; identify the pane, never the vendor
      (`AGENTS.md`: producer-neutral)
- [ ] Decision logic in a pure policy type, mirroring
      `TerminalCommandFinishNotificationPolicy`

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
  animation framework. Kurotty's renderer still has no GPU/CPU reuse fence
  (`docs/improvement-roadmap.md` §4.3); a frame semaphore and background opacity
  buy the same visual credibility for a fraction of the cost. Revisit after the
  renderer is fenced.
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
