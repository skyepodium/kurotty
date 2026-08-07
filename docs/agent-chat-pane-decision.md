# Should Kurotty become a two-pane agent client?

The question: the Claude Code desktop app shows a conversation on the left, a
rendered document on the right, and a project sidebar. Should Kurotty work like
that instead of being "a tty grid", and is there a fast path?

This document decides that. It is not a survey.

Claims are marked **[verified]** when something was run and its output observed,
and **[read]** when they rest on reading the code. **[unverified]** marks
something that could not be established from a primary source and is stated as
unknown rather than smoothed over. Anything unmarked is a judgement call.

---

## 0. Four prior claims, checked

The proposal arrived with four assertions attached. Three survive with
corrections; one is not verifiable and the reasoning behind it has to be
replaced.

| Claim | Verdict |
|---|---|
| The desktop app is not a terminal — no VT parser, no cell grid — so a terminal cannot be turned into it | **Conclusion holds, stated evidence does not.** See below |
| Kurotty already hosts non-terminal tabs, so the hosting seam exists | **Verified.** The seam is real and better than described |
| Kurotty already reads agent transcripts read-only, so the right-hand document pane is closer than the left | **Half wrong.** True for data, false for rendering — and the gap is on the side that was called "closer" |
| Driving an agent without a PTY needs `stream-json` or an API, and is weeks of work | **Verified in direction, wrong about the floor.** The one-shot floor is much lower than "weeks". The weeks are in the ceiling |

### On the first claim

Anthropic documents the desktop app's *features* but publishes nothing about its
internals — implementation language, whether it drives the CLI as a subprocess or
links the Agent SDK, how it renders. **[unverified]** Community write-ups exist;
none are Anthropic. So "it has no VT parser and no cell grid" is not a fact this
document can assert, and it should not be argued from.

The conclusion survives anyway, on evidence from Kurotty's side of the boundary,
which is the side that matters: **nothing in that screenshot is produced by
anything Kurotty already has.** Kurotty's rendering path is PTY bytes → Zig
parser → cell grid → Metal glyph atlas (`AGENTS.md:8-11`). A message bubble, a
proportional-font heading, a laid-out table, and a wrapped code block are none of
them cells. The terminal stack contributes zero to that picture, regardless of
what Anthropic's app is built from. The absence of a fast path is a fact about
Kurotty, not a fact about the screenshot.

---

## 1. What the screenshot actually is

Break it into parts and price each one against this tree. The parts are not
remotely equal, and the disparity is the whole decision.

| Part | Status here | Cost |
|---|---|---|
| Project sidebar | Exists | Free |
| Non-terminal center tab | Exists | Free |
| Conversation list with roles, tool rows, expand-in-place | Exists | Free |
| Live tail of an in-flight session | Exists | Free |
| Rendered Markdown — headings, tables, code blocks | Absent | Expensive |
| Input box that sends a prompt and streams a reply | Absent, and deliberately so | Most expensive |

### The cheap parts are genuinely already built

**The sidebar.** `TerminalWindowController.swift:50-56` owns a left sidebar
split hosting `TerminalLeftSidebarPanelView`, which switches between a
command-history section and `agentSessionPanel`. Sessions group by project, by
parent folder, or by agent (`README.md:127`). **[read]**

**The tab seam.** `TerminalWindowEditorTabs.swift` puts non-terminal views into
ordinary `NSTabViewItem`s next to terminal tabs — a code editor at line 77-99 and
a transcript at line 119-131. The containment contract is written down at
lines 51-56: every controller path that needs a terminal already guards on
`item.view as? SplitTerminalView`, so a non-terminal tab falls through those
paths as a harmless no-op. This is a better seam than "it exists" suggests. Two
different non-terminal view types already live in it, and the reason it does not
leak is documented rather than accidental. **[read]**

**The conversation list.** `AgentSessionTranscriptView.swift` is already an
`NSTableView` of typed rows — turn headers with role and timestamp, text,
collapsed tool runs that expand in place into input, a synthesized diff, and
output (lines 239-280). `AgentSessionTranscriptController.swift:77-86` paints a
bounded tail and then tail-follows the file, coalescing watcher noise
(lines 132-177) and capping retention at 4,000 messages (line 37) while telling
the user it is holding records back (`AgentSessionTranscriptView.swift:28-30`).
**[read]**

That is most of the left pane's *appearance*, already shipped. What it does not
have is an input box, and that is not an oversight — see section 5.

### The expensive parts

Everything the screenshot does that Kurotty does not comes down to two things:
**rendering Markdown**, and **sending a turn**.

---

## 2. What the transcript viewer renders today

Plain strings in `NSTextField`. Nothing else.

Every text row, tool-run row, tool-input row and tool-output row is built by
`makeLabelView` (`AgentSessionTranscriptView.swift:298-323`), which wraps a
`String` in `NSTextField(wrappingLabelWithString:)` at line 310 and sets one
font and one color for the whole thing. **[read]**

There is exactly one attributed-text case in the file: the synthesized diff at
lines 325-353, which builds an `NSMutableAttributedString` and colors removed
lines red and added lines green (lines 333-339). That is the ceiling of rich
rendering in the transcript today: two colors, per line, monospaced. **[read]**

So an assistant turn containing `## Plan`, a table, and a fenced Swift block
renders today as those literal characters in a single proportional font. No
heading, no table, no code block.

There is a second constraint that matters more than it looks. The model
deliberately throws structure away at decode time:

> Tool inputs are flattened into display strings at decode time rather than
> carried as loose JSON: the viewer is read-only, so nothing downstream needs
> the structured payload
> — `AgentSessionTranscriptModel.swift:14-18`

`AgentTranscriptToolCall` stores `preview` and `detail` as pre-rendered `String`
(lines 34-50). That is the right call for a read-only viewer and the wrong shape
for anything interactive, which needs the structured input back to render an
approval or a typed tool card. Any interactive pane pays to undo this. **[read]**

### What rendering the screenshot's quality would take

The parser is free. The renderer is the work — and that split is the single most
useful fact in this document.

**[verified]** Running Foundation's `AttributedString(markdown:)` with
`interpretedSyntax: .full` on a document containing a heading, bold, inline code,
a GFM table and a fenced Swift block returns every one of them correctly
classified:

```
TEXT: Heading        INTENT: [header 1 (id 1)]
TEXT: bold           INLINE: NSInlinePresentationIntent(rawValue: 2)
TEXT: a              INTENT: [tableCell 0 (id 5), tableHeaderRow (id 4),
                              table [TableColumn(alignment: left), ...] (id 3)]
TEXT: let x = 1\n    INTENT: [codeBlock 'swift' (id 10)]
```

Tables come back with per-column alignment. Code blocks come back with the
language hint. This is a full block-level Markdown parse, in Foundation, on
macOS 14, with no dependency.

What it does **not** give you is any of the following, all of which is layout you
write yourself:

- Block structure arrives as `presentationIntent` *metadata*, carrying no visual
  attributes at all — no font, no size, no color. A heading is a run tagged
  `header 1`; making it look like a heading is your code.
- The runs carry no separators between blocks. Concatenating them naively
  produces run-together text. Paragraph breaks are something you re-derive from
  intent ids.
- A table arrives as a flat sequence of cell runs tagged with row and column ids.
  Laying them into an aligned grid that survives resizing is an entire component.
- Code blocks need a background, a monospaced font, horizontal scrolling, and
  ideally highlighting.

On that last point there is a real asset and a real limit. Kurotty has a syntax
highlighter (`TerminalCodeSyntaxHighlighter.swift`) that returns typed tokens and
is already driven by the code editor (`TerminalCodeEditorView.swift:489-497`).
Its Markdown support, however, is explicitly source-view highlighting only:

> `// MARK: - Markdown (headers and code fences only)` — `TerminalCodeSyntaxHighlighter.swift:242`

That highlights Markdown *as source text*. It does not render it. The two are
unrelated jobs, and it is worth not confusing them when scoping. **[read]**

Diffs are the one place where quality is nearly free. The decoder already
synthesizes a diff from `Edit` / `Write` / `MultiEdit` inputs
(`AgentSessionTranscriptDecoder.swift:153-215`), honestly labelled:

> This is not a real diff algorithm: `Edit` already carries the exact old and new
> text, so the removed and added blocks are simply the two sides. Anything more
> would need the file contents, which a read-only viewer must not read.
> — `AgentSessionTranscriptModel.swift:62-66`

Getting to screenshot-quality diffs means intra-line highlighting and hunk
context, which means reading the file — and that is precisely what the viewer's
safety contract forbids. Better diffs are not a rendering change; they are a
change to what the viewer is allowed to touch. **[read]**

### The dependency question, answered

**No Markdown renderer is in the tree.** **[verified]** — grep across `Sources/`,
`Package.swift` and `Package.resolved` finds only the syntax highlighter above
and a Markdown *emitter* for diagnostics reports
(`TerminalDiagnosticsReport.swift:124-141`). Nothing renders.

`Package.swift:14-16` has exactly one dependency, Sparkle. Adding a second is a
real decision.

**It does not have to be made.** Foundation's parser is good enough that the
choice is not "vendor swift-markdown or MarkdownUI" but "write the layout on top
of a free parser". That keeps the dependency count at one and keeps the renderer
matched to `DesignTokens`, which a third-party SwiftUI renderer would fight. The
cost moves from a dependency decision to a component you own — which, for a repo
with this much invested in its token layer, is the better trade.

---

## 3. What Claude Code actually offers a host program

Verified against Anthropic's current documentation, cited inline. The
distinctions here decide whether the left pane is a weekend or a quarter.

**Headless output works and is documented.** `claude -p` / `--print` with
`--output-format` accepting `text`, `json`, or `stream-json`
(https://code.claude.com/docs/en/headless.md). `stream-json` emits
newline-delimited events wrapping the raw Claude API streaming protocol:
`message_start`, `content_block_start`, `content_block_delta` carrying
`text_delta` for token text and `input_json_delta` for streaming tool input,
`content_block_stop`, `message_delta`, `message_stop`, plus a `system`/`init`
event carrying `session_id`, `model`, and the tool list
(https://code.claude.com/docs/en/agent-sdk/streaming-output.md).

**Kurotty already decodes this vocabulary.** `ClaudeTranscriptDecoder`
(`AgentSessionTranscriptDecoder.swift:220-343`) handles exactly `text`,
`thinking`, `tool_use` with `name` / `input`, and `tool_result` with `is_error`
(lines 239-248, 313-342). Those are the same content blocks the stream carries.
The decode layer for a live stream is substantially already written, which is the
single strongest argument that this is cheaper than it looks. It also already
degrades correctly on schema drift — unknown record types decode to `nil` rather
than throwing, documented at lines 6-8 — which matters because **no stability
guarantee is published for the `stream-json` schema** **[unverified]**; the
events mirror the API streaming protocol, but nothing promises they will not move.

**Session continuity is documented.** `--continue`, `--resume <session-id>`, and
the `session_id` returned in `--output-format json`
(https://code.claude.com/docs/en/sessions.md). Transcripts live at
`~/.claude/projects/<project>/<session-id>.jsonl` — the exact path
`ClaudeSessionScanner` already walks (`AgentSessionScanner.swift:184`,
`AppConstants.swift:164`). Anthropic describes that JSONL as internal to Claude
Code, not a stable API, which is a standing risk Kurotty has already accepted.

**Multi-turn input is where it gets thin.** `--input-format stream-json` appears
in the CLI reference, but the documentation does not describe how a host feeds
successive turns into one long-lived process. **[unverified]** What *is*
documented is one-shot: each `-p` invocation answers and exits, and follow-ups
come from a fresh invocation with `--resume`. That works, and it is much simpler
than a persistent protocol — but it means a "conversation" is N processes, and
per-turn startup and context reload is the cost.

**There is no Swift SDK.** Official Agent SDKs exist for Python and TypeScript
only (https://code.claude.com/docs/en/agent-sdk/overview.md). A Swift host spawns
the CLI and parses JSON itself. Kurotty already spawns subprocesses in three
places — `TerminalGitStatusService`, `TerminalGitWorktreeService`,
`TerminalNotifier` **[verified]** — so the mechanism is familiar, but every SDK
convenience (turn management, cancellation, permission callbacks) is something
you write.

**Permissions are the trap, and they cut against this whole direction.**
`--permission-mode` offers `default`, `acceptEdits`, `plan`, `auto`, `dontAsk`
and `bypassPermissions`, plus `--allowedTools` pre-approval
(https://code.claude.com/docs/en/permission-modes.md). But headless mode has no
interactive prompt to intercept: in `dontAsk` an unpermitted call is auto-denied
and the session aborts, and in `auto` repeated blocks pause and abort because no
prompt is available. A `--permission-prompt-tool` flag is listed in the CLI
reference, but **no documentation explains how a host renders an approval UI and
answers back** **[unverified]**. Section 5 is about why that specific gap is
disqualifying here.

**One genuine advantage.** Driving the CLI needs no API key and no networking:
Claude Code owns authentication. There is no `URLSession` anywhere in `Sources/`
**[verified]**, and this path does not add one.

### So: is a prompt-and-stream left pane reachable without reimplementing an agent client?

Yes, and the prior claim of "weeks" overstated the floor. A pane that spawns
`claude -p --output-format stream-json`, decodes events through machinery that
already exists, appends rows to a table that already exists, in a tab that
already exists, is a small amount of new code.

The weeks are all in the second 20%, and they are not optional for anything
shippable: cancellation and process lifecycle, `--resume` threading so turn two
knows about turn one, backpressure on a fast stream, error and rate-limit
surfaces, restoring structured tool inputs the model currently discards, and
above all permissions — because a coding agent that cannot ask permission is
either useless or dangerous, and headless mode gives no documented way to ask.

There is also a much cheaper thing that already exists and should be named,
because it makes the "no send path" story more nuanced than it sounds. The
session panel already composes `cd '<cwd>' && claude --resume <id>` and inserts
it at the active prompt — deliberately with no trailing newline, and with no
execute path at all (`README.md:127`, `AgentSessionIndex.swift:340-350`).
`ShellSession.write(_:)` at line 172 is a perfectly good text path into a live
agent. Kurotty can already put words in front of an agent. What it refuses to do
is press Return. That refusal is a policy, not a missing feature
(`DESIGN.md:313-332`).

---

## 4. Three options

### Option A — a conversation tab that drives an agent

A new center tab with a composer that spawns `claude -p --output-format
stream-json`, streams events into transcript-style rows, and threads `--resume`
across turns.

**Build:** process lifecycle and cancellation; a stream-event decoder alongside
the existing JSONL decoder; a composer with history and multi-line editing; turn
threading and session-id capture; backpressure and truncation for fast streams;
error, interrupt and rate-limit surfaces; structured tool inputs restored to the
model (`AgentSessionTranscriptModel.swift:14-18`); a permission story that the
documented interface does not currently support; and a Markdown renderer, because
a chat pane that shows raw `##` is worse than the terminal it replaced.

**Payoff:** the screenshot. A place agent work happens that is not a TUI.

**Forecloses:** the roadmap's actual bet. `docs/improvement-roadmap.md:92-96`
recommends native permission approvals on the grounds that Kurotty owns the PTY
and "no Electron wrapper can do it without reimplementing a terminal." In
headless mode there is no prompt in a pane to intercept. Option A spends the
budget building the wrapper the roadmap says Kurotty is positioned to beat, and
does it with no Swift SDK, a schema carrying no stability promise, and no
documented approval callback. It also competes directly with a first-party app
that will always ship features first.

### Option B — render the document pane properly

Keep the viewer read-only. Give it a real Markdown renderer over Foundation's
parser: headings, lists, block quotes, tables with column alignment, code blocks
with the existing highlighter, and typed tool cards. Optionally split the tab so
a file an agent is editing renders beside the conversation.

**Build:** a `PresentationIntent` → row-model pass; row views per block type; a
table layout; code-block views wired to `TerminalCodeSyntaxHighlighter`; token
mappings in `DesignTokens`. No dependency, no process, no protocol, no new
security surface. Every piece is a pure function over decoded text, which is how
this codebase already tests its transcript layer.

**Payoff:** the half of the screenshot users actually look at. It improves every
existing surface at once — live transcripts, the session panel, and any future
pane — because it is a renderer, not a feature.

**Forecloses:** nothing. This is strictly a prerequisite for Option A, which is
the main reason to do it first.

### Option C — do not do it

Stay a terminal. Spend the budget on the roadmap: native permission approvals,
agent status into the notification path, the cross-pane agent overview
(`docs/improvement-roadmap.md:92-108`).

**Payoff:** the differentiated thing. Nobody else can intercept an agent's
permission prompt, because nobody else owns the PTY.

**Forecloses:** the screenshot, and a demo that reads as modern. Also leaves the
transcript viewer rendering `##` as `##` forever, which is a visible quality gap
independent of any strategy.

---

## 5. Recommendation

**Option B. Not A, and not C either — C leaves real quality on the table.**

The reasoning is that Option B is the only one whose cost is bounded by things
already verified, and it is a strict prerequisite for A. If the owner eventually
wants A, he needs B first; if he never wants A, B was still worth it. Very few
decisions in this document are reversible in that direction, and this one is.

The specific findings that drive it:

1. The parser is free and good — headings, GFM tables with alignment, and
   language-tagged code blocks all come back correctly from Foundation
   **[verified]**. The feared dependency decision does not have to be made.
2. The seam is real. Two non-terminal view types already live in center tabs with
   a documented containment contract (`TerminalWindowEditorTabs.swift:51-56`).
3. The gap is exactly where the prior claim said it was not. The right-hand
   document pane was called "closer" than the left. For *data* that is right —
   tail-follow, decoding and fold state are all shipped. For *rendering* it is
   wrong: the viewer draws plain `NSTextField` strings
   (`AgentSessionTranscriptView.swift:310`) with a single two-color exception for
   diffs (lines 331-339). The document pane is closer in plumbing and further in
   pixels, and pixels are what the screenshot is.
4. Option A's blocking problem is not effort, it is the permission interface.
   Headless mode has no documented way for a host to render an approval and
   answer back **[unverified]**, and both non-interactive fallbacks abort rather
   than ask.

**What would change this recommendation:** if Anthropic documents
`--permission-prompt-tool` such that a host can render an approval sheet and
return a decision, Option A stops being a wrapper and starts being the thing the
roadmap wanted — an agent client with native macOS approvals, from a vendor that
also owns the PTY for everything the agent shells out to. That single missing
piece of documentation is the hinge. It is worth re-checking before any large
commitment, and worth nothing until it exists.

---

## 6. What would have to be true for Option A

Answer these before spending weeks. Each is cheap to test and each can kill it.

1. **Can a host answer a permission prompt?** Whether `--permission-prompt-tool`
   lets an external program render an approval and return a decision. If no,
   Option A ships either an agent that cannot edit files or one that never asks.
   This is the question; the rest are details.
2. **Is one-shot resume good enough?** Time `claude -p --resume` on a real
   session. If per-turn startup and context reload is visible next to the TUI,
   the pane feels worse than the terminal it replaced, and no rendering fixes it.
3. **Can a persistent process take multiple turns?** Whether
   `--input-format stream-json` actually supports feeding successive turns to one
   long-lived process. Documented as a flag, not as a workflow. If it works, the
   previous question dissolves. Test it rather than assuming either way.
4. **How much drift does the schema take?** The decoder degrades gracefully by
   design (`AgentSessionTranscriptDecoder.swift:6-8`), but a live pane that
   silently drops the block type carrying the answer is worse than a viewer that
   drops a row. With no published stability guarantee, decide what breakage
   looks like before shipping.
5. **Would the owner use it?** He has Claude Code and a terminal that runs it
   well. If the honest answer is that he would keep using the TUI, that is the
   finding.

---

## 7. The risk nobody mentions

**Kurotty's thesis is that it owns the PTY. A chat client does not own anything.**

The roadmap states this plainly: Claude Code's approval prompt is a TUI dialog
inside the pane, and Kurotty "alone can surface that as a real macOS sheet — with
cwd, target pane, and a remembered scope — and write the answer back … no
Electron wrapper can do it without reimplementing a terminal"
(`docs/improvement-roadmap.md:92-96`).

Every capability in that sentence is a consequence of being the process on the
other end of the file descriptor. Give that up and the following go with it,
none of which are recoverable by rendering nicer:

- **Approval interception disappears.** The prompt Kurotty is uniquely placed to
  intercept only exists in interactive mode. Headless mode replaces it with
  auto-deny or abort. The differentiator is not degraded; it is absent.
- **The agent's own tools stop being observable.** When an agent runs `npm test`
  in a Kurotty pane, Kurotty sees the bytes — `TerminalShellIntegration` owns
  OSC 7 / OSC 133 command-span state (`DESIGN.md:305`), which is where cwd, exit
  codes and command boundaries come from. Inside `-p`, that all happens in a
  subprocess Kurotty spawned but does not instrument. The richest signal in the
  building goes dark exactly when the agent is most active.
- **The unwired approval pipeline loses its purpose.** Roughly 1,250 lines of
  request → evaluate → approve → dispatch → audit exist with three test files and
  zero call sites in `Sources/` (`AIAgentActionApproval.swift:259`,
  `docs/improvement-roadmap.md:79-84`) **[verified]**. It was built for the panel
  in `DESIGN.md:313-332`. That panel presumes agent actions arriving through an
  app-layer request that Kurotty can gate. Headless mode has no such request.
- **Kurotty starts competing where it is weakest.** As a terminal it competes on
  PTY correctness, IME, and rendering — things it is demonstrably good at. As a
  chat client it competes with Anthropic's own app on feature velocity, and will
  be second to every feature, permanently.
- **The read-only guarantee becomes negotiable.** Today it is absolute and
  written down three times: no composer, no send button, no PTY handle
  (`AgentSessionTranscriptView.swift:3-7`); no send path of any kind
  (`AgentSessionTranscriptController.swift:11-12`); no execute path at all in the
  panel (`README.md:127`). That is a design position, not an unfinished feature —
  `AgentSessionIndex.swift:340-350` builds a resume command and
  `ShellSession.write(_:)` would happily send it, and the code deliberately stops
  short of pressing Return. Once a composer exists, "does this send?" becomes a
  question a user has to ask, and every future feature relitigates it.

The safe version of that last point is the reason Option B is drawn the way it
is. **A renderer changes how bytes look. It never changes what can be sent.**
Option B keeps every one of those guarantees intact, keeps the dependency count
at one, and leaves Option A available on the day the permission interface is
documented.

The terminal is the asset. The screenshot is a rendering problem wearing an
architecture problem's clothes — and only the rendering half is worth buying now.
