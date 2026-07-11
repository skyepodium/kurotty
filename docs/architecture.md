# Kurotty Architecture

Kurotty is a macOS-first terminal emulator with a Swift/AppKit application shell, a Swift terminal rendering model, a Metal renderer, and an optional Zig terminal-core dynamic library. The current production ownership is intentionally conservative: Swift owns the visible terminal state and rendering pipeline, while Zig is loaded through a narrow C ABI for incremental parser, grid, metrics, damage, and migration work.

## Repository layout

```text
Sources/KurottyApp/       macOS app, windows, panes, PTY, input, settings, notifications, Metal renderer
Sources/KurottyCore/      Shared terminal model and render-frame types used by app code and tests
src/                      Zig terminal core modules and exported C ABI
tests/KurottyRenderingTests/
                          Swift tests for rendering, settings, input, commands, OSC, snapshots, diagnostics
tests/*.zig               Zig unit and leak tests
docs/                     Developer documentation
```

`docs/` is the right home for architecture notes because the repository already uses it for developer-facing ABI documentation. The root `README.md` should stay product-oriented and link here instead of carrying implementation detail.

## Top-level components

```mermaid
flowchart TB
    User[User and macOS events]
    App[KurottyApp<br/>AppKit application layer]
    UI[Windows, tabs, panes<br/>TerminalWindowController<br/>SplitTerminalView<br/>TerminalPaneView]
    Surface[TerminalSurfaceView<br/>terminal state owner]
    Session[TerminalSession<br/>DarwinPTYTerminalSession]
    Shell[Child shell in forkpty]
    CoreTypes[KurottyCore<br/>screen, styles, render frames]
    Renderer[TerminalAppKitRenderer<br/>TerminalMetalView]
    Metal[Metal drawable]
    Bridge[CoreBridge<br/>optional Zig dylib bridge]
    Zig[Zig core<br/>parser, grid, metrics, renderer orchestrator]
    Notifications[OSC and bridge notifications<br/>TerminalNotifier]
    Settings[Settings and workspace snapshots]

    User --> App
    App --> UI
    UI --> Surface
    Surface <--> Session
    Session <--> Shell
    Surface --> CoreTypes
    Surface --> Renderer
    Renderer --> Metal
    Surface --> Bridge
    Bridge -. dlopen C ABI .-> Zig
    Surface --> Notifications
    App --> Settings
    Settings --> UI
    Settings --> Surface
```

## Runtime ownership model

The most important boundary is ownership of terminal state.

| Area | Current owner | Notes |
| --- | --- | --- |
| App lifecycle, menus, windows, tabs, panes | `KurottyApp` | `AppDelegate`, `MainMenu`, `TerminalWindowController`, and `SplitTerminalView` own AppKit composition. |
| Shell process and PTY IO | `DarwinPTYTerminalSession` | Uses `forkpty`, nonblocking master FD IO, resize ioctl, and child-process observation. |
| Visible terminal screen, scrollback, parser state, selection, cursor, IME state | `TerminalSurfaceView` | Swift currently mutates the visible model and schedules render frames. |
| Shared terminal data structures | `KurottyCore` | Provides screen cells, styles, frame types, damage metadata, and renderer protocols. |
| GPU presentation | `TerminalMetalView` | Implements `TerminalAppKitRenderer` and consumes immutable `TerminalFrame` values. |
| Zig parser/grid/metrics/damage migration path | `CoreBridge` plus `src/*.zig` | Loaded dynamically when `libkurotty_core.dylib` is present. Swift remains the mutation owner today. |
| Notifications | `TerminalOSCDispatcher`, `KurottyNotificationBridgeServer`, `TerminalNotifier` | Converts OSC or external bridge payloads into macOS notifications. |
| Settings and layout snapshots | `AppSettingsStore`, `WorkspaceSnapshotCoordinator` | Settings are normalized and live-applied where supported; workspace snapshots are currently layout-only. |

`CoreBridge` exposes diagnostics that make this ownership explicit. When the Zig library is loaded, Zig participates in feed, metrics, damage, and row-copy APIs, but Swift still owns parser mutation, screen mutation, and render mutation for the visible terminal surface.

## Application lifecycle

```mermaid
sequenceDiagram
    participant main as main.swift
    participant App as AppDelegate
    participant Bridge as KurottyNotificationBridgeServer
    participant Menu as MainMenu
    participant Window as TerminalWindowController
    participant Surface as TerminalSurfaceView
    participant Session as TerminalSession

    main->>App: install NSApplication delegate
    main->>App: app.run()
    App->>App: install icon and request notification authorization
    App->>Bridge: start Unix-domain notification bridge
    App->>Menu: install application menu
    App->>Window: openNewWindow()
    Window->>Surface: create first terminal pane
    Surface->>Session: start(workingDirectory)
```

On startup, the app handles bridge-only command-line invocations first. Normal GUI startup then creates the AppKit application, starts the notification bridge, installs menus, opens a terminal window, and starts a shell for the first terminal surface.

## Window, tab, and pane composition

`TerminalWindowController` owns one AppKit window and an `NSTabView`. Each tab contains a `SplitTerminalView`. Split views recursively contain either `TerminalPaneView` leaves or nested split views. A pane wraps chrome and one `TerminalSurfaceView`.

```mermaid
flowchart LR
    Window[TerminalWindowController]
    Tabs[NSTabView]
    Split[SplitTerminalView]
    Pane[TerminalPaneView]
    Surface[TerminalSurfaceView]

    Window --> Tabs
    Tabs --> Split
    Split --> Pane
    Split --> Split
    Pane --> Surface
```

This keeps layout concerns outside the terminal emulator core. Pane splitting, focus movement, pane drag/detach, tab labels, and layout-only workspace descriptors live at the window/pane layer. Terminal escape parsing and rendering stay inside `TerminalSurfaceView` and renderer types.

## Input and PTY flow

```mermaid
sequenceDiagram
    participant User
    participant Surface as TerminalSurfaceView
    participant Router as TerminalTextInputRouter
    participant Encoder as TerminalKeyEncoder
    participant Core as TerminalCore
    participant Session as DarwinPTYTerminalSession
    participant Shell

    User->>Surface: keyDown / IME / paste
    Surface->>Core: recordKeyEvent()
    Surface->>Router: offer text event to AppKit IME when appropriate
    Router->>Encoder: encode terminal control sequences
    Surface->>Session: write(text or escape sequence)
    Session->>Shell: nonblocking PTY write
```

`TerminalSurfaceView` is the active `NSTextInputClient`. It lets AppKit own IME composition, normalizes committed text, encodes terminal control keys through `TerminalKeyEncoder`, and writes final bytes to the PTY session. Command-key window shortcuts are routed through `TerminalCommandDispatcher` and `TerminalCommandRegistry` instead of being sent to the shell.

## Output, screen, and rendering flow

```mermaid
sequenceDiagram
    participant Shell
    participant Session as DarwinPTYTerminalSession
    participant Surface as TerminalSurfaceView
    participant OSC as TerminalOSCDispatcher
    participant Screen as TerminalScreen / scrollback
    participant Frame as TerminalFrame
    participant Renderer as TerminalMetalView
    participant GPU as Metal

    Shell->>Session: PTY output bytes
    Session->>Surface: onOutput(text)
    Surface->>Surface: parse stream state, CSI, OSC, printable text
    Surface->>OSC: dispatch OSC commands
    Surface->>Screen: mutate cells, cursor, style, scrollback
    Surface->>Frame: build immutable render frame with dirty rows/rects
    Frame->>Renderer: update(frame)
    Renderer->>GPU: draw glyphs, backgrounds, cursor, decorations
    Renderer->>Surface: onPresented
```

Output is coalesced on the main actor before screen mutation and rendering. The Swift screen model tracks visible cells, alternate screen state, scrollback, cursor, selection, links, marked text, dirty rows, and full-damage fallbacks. The renderer receives a `TerminalFrame`, not direct mutable terminal state.

`TerminalMetalView` handles glyph atlas rendering, backgrounds, cursor, underline, strikethrough, box/block decorations, damage diagnostics, and scissor planning. `TerminalFrame` carries enough metadata for full redraw fallback or partial redraw with stable pixel bounds.

## Zig core and ABI boundary

The Zig core is built by `build.zig` as both static and dynamic libraries. Swift uses the dynamic library through `CoreBridge`, which loads `libkurotty_core.dylib` from the app bundle or development build paths.

```mermaid
flowchart LR
    Swift[CoreBridge.swift]
    ABI[src/abi.zig<br/>C exports]
    Parser[src/parser.zig]
    Grid[src/grid.zig]
    Scrollback[src/scrollback.zig]
    Metrics[src/metrics.zig]
    Render[src/renderer.zig]

    Swift -. dlopen / dlsym .-> ABI
    ABI --> Parser
    ABI --> Grid
    ABI --> Scrollback
    ABI --> Metrics
    ABI --> Render
```

The ABI is deliberately narrow:

- create and destroy a terminal handle
- feed bytes into the Zig parser/grid path
- record key and frame-presentation timestamps
- read last input-to-present latency
- resize the Zig grid
- mark damage and frame boundaries
- query or copy compact row data

This lets Zig evolve behind a stable C boundary while Swift keeps UI responsiveness and AppKit integration simple. The current row-copy API is compact byte storage, not a complete styled Unicode cell ABI.

## OSC, shell integration, and notifications

Notifications are modeled as typed events with explicit source semantics. Kurotty does not have a Codex path, Grok path, or Claude path. A producer is supported because it emits a standard terminal protocol, not because its name appears in the source code.

### Producer and consumer boundary

The **producer** is the child program that writes notification bytes to the PTY. Grok Build, Codex, a shell script, and any other CLI/TUI can be producers. Kurotty is the **consumer**: it parses those bytes, applies presentation policy, and submits the resulting fields to macOS.

```mermaid
flowchart LR
    Producer["Producer: CLI or TUI"]
    PTY["PTY byte stream"]
    Kurotty["Kurotty parser and policy"]
    macOS["macOS notification center"]

    Producer -->|"OSC with title/body, or BEL without payload"| PTY
    PTY --> Kurotty
    Kurotty --> macOS
```

This boundary determines what Kurotty can display:

- OSC 9 supplies a message body.
- OSC 777 `notify;title;body` supplies a title and body.
- Supported rich OSC 1337 supplies named fields such as title, subtitle, and message.
- BEL is one byte (`0x07`) and supplies no title, body, event kind, program identity, or completion semantics. Kurotty presents the deliberately generic `Kurotty` / `Check your terminal.` fallback when unfocused; it does not treat that text as producer-supplied data.

Kurotty cannot reconstruct a missing response payload without scraping rendered output. It therefore preserves explicit fields and uses only the fixed generic BEL fallback, without claiming to know the missing response text.

### Producer-side terminal detection: Grok Build 0.2.93

Grok Build chooses its notification protocol before Kurotty receives anything. Its installed user guide documents `method = "auto"` as terminal-brand detection with this support matrix:

| Detected terminal | Auto protocol | Focus tracking | Progress bar |
| --- | --- | --- | --- |
| iTerm2 | OSC 9 | Yes | Yes |
| Kitty | OSC 99 | Yes | No |
| Ghostty | OSC 777 | Yes | Yes |
| WezTerm | OSC 9 | Yes | Yes |
| Warp | OSC 9 | Yes | No |
| Alacritty | BEL | Yes | No |
| VS Code family | BEL | Yes | No |
| Apple Terminal | BEL | No | No |
| VTE family | OSC 777 | Yes | No |
| Grok Desktop | Native | N/A | N/A |
| Unknown | BEL | No | No |

The broader Grok detection list includes Apple Terminal, Ghostty, iTerm2, Warp, WezTerm, Kitty, Alacritty, Rio, foot, VS Code, Cursor, Windsurf, Zed, JetBrains terminals, Grok Desktop, VTE terminals such as GNOME Terminal/GNOME Console/Tilix, and Windows Terminal.

Evidence for the installed Grok version is local to the Grok distribution:

- `~/.grok/docs/user-guide/05-configuration.md`, “Notifications” and “Terminal Support Matrix”
- `~/.grok/docs/user-guide/21-terminal-support.md`, “Detected Terminals”
- Grok Build `0.2.93 (f00f96316d4b)`

Kurotty exports `TERM_PROGRAM=Kurotty`. Grok 0.2.93 does not list Kurotty, so `auto` classifies it as Unknown and selects BEL. Consequently, Kurotty can show only its generic BEL fallback; the producer's actual response is unavailable because no OSC title/body was emitted. Kurotty must not export `TERM_PROGRAM=ghostty` or `TERM_PROGRAM=iTerm.app`; that would be terminal-identity impersonation and would couple compatibility to another product's name. A durable rich-notification fix requires the producer to recognize Kurotty and select a supported OSC protocol, or a future producer-neutral capability negotiation mechanism.

### Source model and precedence

| Priority | Source | Data authority | Intended behavior |
| --- | --- | --- | --- |
| 1 | OSC 9, OSC 777, supported rich OSC 1337 | Producer-supplied protocol fields | Parse into a typed desktop-notification event and preserve the supplied message. |
| 2 | Kurotty Unix-socket/CLI bridge | Producer-supplied versioned JSON or text | Deliver through the same app-owned notifier when the producer cannot write to the PTY. |
| 3 | OSC 133 shell integration | Command boundary metadata | Represent ordinary command completion using cwd, exit status, and duration; it does not invent an interactive-program response. |
| 4 | BEL | No text payload | Ring the terminal bell and, while unfocused, show `Kurotty` / `Check your terminal.` without scraping screen content. |

OSC 0/1/2 sequences update titles only. A BEL byte may terminate an OSC sequence, but it does not turn that title sequence into a completion notification. Numeric OSC 9 progress forms such as `9;4;...` remain progress events.

This follows Ghostty's protocol boundary: its OSC parser emits `show_desktop_notification`, its stream handler copies the parsed `title` and `body` into a desktop-notification message, and the platform layer presents that message. Ghostty does not recover an OSC notification body by scraping rendered rows, and neither does Kurotty.

```mermaid
flowchart LR
    PTY[PTY byte stream]
    Parser[Terminal parser]
    OSC[TerminalOSCDispatcher]
    Typed[Typed notification event]
    Surface[TerminalSurfaceView]
    Bridge[KurottyNotificationBridgeServer]
    Notifier[TerminalNotifier]
    macOS[UNUserNotificationCenter]

    PTY --> Parser
    Parser -->|OSC 9 / 777 / 1337| OSC
    OSC --> Typed
    Typed --> Notifier
    PTY --> Surface
    Surface -->|BEL fallback| Notifier
    Bridge --> Notifier
    Notifier --> macOS
```

### Explicit OSC path

`TerminalOSCDispatcher` classifies supported OSC sequences before presentation:

- OSC 9, OSC 777 `notify;title;body`, and supported rich OSC 1337 become typed notification payloads.
- OSC 7 updates `TerminalShellIntegration` and the surface-owned working directory.
- OSC 133 updates prompt/command boundaries and command spans.
- OSC 52 is evaluated by `TerminalOSC52Policy` before clipboard interaction.
- DECSET 1004 focus reporting emits standard xterm focus-in/focus-out responses so applications can apply their own unfocused-notification policy.

The explicit path never reads the rendered screen to reconstruct fields. If a producer sends a body such as `Release notes are ready.`, that exact semantic field is the notification body, subject only to bounded presentation length and safe whitespace normalization.

### Producer-neutral external bridge

`KurottyNotificationBridgeServer` serves producers that cannot reliably emit bytes into the terminal PTY. It listens on a user-scoped Unix-domain socket under Application Support and exports `KUROTTY_NOTIFY_SOCKET` and `KUROTTY_NOTIFY_COMMAND` into child shells. The path therefore comes from the running installed bundle and current user environment; no username, checkout path, `/Applications` path, or guessed TTY is stored in the implementation.

The bridge accepts plain text or versioned JSON containing `version`, `event`, `session_id`, `duration_ms`, `title`, `subtitle`, and `body`. Legacy message aliases are normalized at the bridge boundary. If no live Kurotty bridge exists, the client does not impersonate Kurotty by creating a notification from an unrelated helper process.

### Why rendered output is not a completion source

A full-screen interactive program can pause output many times while it is still working. Output byte counts, cursor state, rendered rows, and a quiet timer therefore cannot prove that an internal turn completed. Kurotty previously treated 1.5 seconds of quiet output as completion; this could notify on a warning or status repaint and then ignore the actual response that arrived later. That path is intentionally absent.

For a long-running TUI, an exact response notification requires an explicit in-band OSC 9/777/1337 event or the versioned bridge. If neither is emitted, Kurotty does not invent a completion event. Shell OSC 133 remains useful for ordinary commands that actually return to the prompt, but it carries command metadata rather than an AI response body.

### Notification field resolution

Notifications use the following field contract:

| Field | Resolution order | Fallback |
| --- | --- | --- |
| Title | Explicit OSC/bridge title; shell-completion status for OSC 133 | Protocol-defined default |
| Subtitle | Explicit protocol subtitle; otherwise the current surface title | Empty string |
| Body | Exact explicit OSC/bridge message; command metadata for OSC 133 | `Check your terminal.` for payload-free BEL; otherwise no invented message |

`DarwinPTYTerminalSession.foregroundProcessName()` asks the Kurotty PTY for its foreground process group. `TerminalProcessArguments` then reads the process argument vector and uses the basename of `argv[0]`. This preserves the command the user invoked: `codex` displays as `Codex` even when the internal binary is named `codex-aarch64-apple-darwin`. The implementation does not maintain a list of products, CPU architectures, operating systems, or suffixes to remove. Kernel executable metadata is only a fallback when the invocation name is unavailable.

The subtitle uses the working directory owned by the same `TerminalSurfaceView`. It must never query a globally active tmux pane, because that pane can belong to another terminal or directory. Only the final path component is exposed to macOS notifications.

Example explicit notification:

```text
Title:    Example-runner
Subtitle: dev
Body:     Release notes are ready.
```

Rendered response text is not promoted into a notification. The producer must send `Hello. What should I do for you?` as an explicit OSC or bridge body for Kurotty to present it exactly.

### Shell integration and portability

Direct zsh, bash, and fish sessions receive bundled integration resolved through `Bundle.module`. The bootstrap preserves the user's environment, emits standard OSC 7 and OSC 133 metadata, never edits startup files, and falls back to the original interactive shell when a supported resource is unavailable. The app bundle therefore carries the integration needed on another Mac without relying on the developer's home directory or configuration.

### Notification verification

Verification is layered because no single fixture proves the full path:

- raw parser tests prove OSC classification and field preservation;
- dispatcher tests prove typed event routing and numeric progress exclusion;
- regression tests prove ordinary rendered output and output quiescence do not synthesize completion notifications;
- process metadata tests prove `argv[0]` wins over a platform-qualified internal executable name;
- full `swift test` and `git diff --check` protect cross-feature regressions;
- the production `.app` must be built, installed, code-signature verified, relaunched, and smoke-tested because debug execution does not reproduce the complete UserNotifications and LaunchServices environment.

Compatibility must not be claimed from a synthetic notification alone. When a producer-specific report is being investigated, capture whether it emitted explicit OSC/bridge data or only BEL, then verify the resulting fields at the installed-app boundary.

## Settings and workspace snapshots

`AppSettings` is a portable Codable settings model. The settings path is normalized through `AppSettingsNormalizer` and checked by `AppSettingsValidation`.

Settings have explicit lifecycle semantics:

- live-applied: terminal theme, font, scrollback, colors, and window dimensions
- launch-only: schema version and shell working directory for new shell sessions

Workspace snapshots are intentionally layout-only today. `TerminalWindowController` asks panes and split views for descriptors, then `WorkspaceSnapshotCoordinator` writes window, tab, split, and pane layout metadata. It does not persist live shell processes or terminal scrollback.

## Diagnostics and tests

The codebase has diagnostics around PTY reads, resize, dirty rects, renderer damage, runtime ownership, scrollback, terminal events, and pixel probing. Tests are split by runtime:

- Swift rendering and app behavior tests live under `tests/KurottyRenderingTests`.
- Zig parser, grid, ABI, leak, benchmark, and stress checks live under `tests/`, `bench/`, and `stress/`.

Useful validation commands:

```sh
swift test
zig build test
zig build leak-check
zig build bench
```

## Architectural direction

The current architecture favors a safe migration path over a premature full rewrite:

- Keep AppKit, IME, windowing, settings, notification, and Metal presentation in Swift.
- Keep `KurottyCore` as the shared Swift contract for render frames and terminal data structures.
- Move parser/grid/scrollback/metrics responsibilities into Zig only behind explicit ABI additions.
- Avoid dual mutation ownership. When a responsibility moves to Zig, Swift should consume snapshots or events from Zig rather than mutating the same state in parallel.
- Keep renderer input immutable. `TerminalMetalView` should continue to render `TerminalFrame` values rather than reaching back into live terminal state.

The clean target is one visible terminal-state owner per subsystem, explicit handoff points, and small data contracts between layers.
