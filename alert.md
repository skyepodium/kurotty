# Kurotty Alert / Notification Analysis

This document compares alert, notification, bell, activity, and command-completion behavior in terminal projects available beside Kurotty. Kurotty itself is excluded from the comparative source analysis, then evaluated separately for implementation.

## Historical Problem Observed In Kurotty

An earlier notification implementation could show generic macOS banners such as:

- title: `Alert`
- body: `%`

That fails the product goal. A user cannot tell whether Codex finished, failed, needs approval, or merely printed a shell prompt. The fix should not special-case one screenshot; it should create a durable alert model:

- semantic source: bell, OSC notification, command completion, idle/new output, session ended, agent state
- policy: focused/unfocused, profile settings, privacy, cooldown, dedupe
- presentation: desktop notification, tab indicator, pane badge, dock/taskbar badge, bounce/attention, sound, visual bell
- payload: title, subtitle, body, severity, target pane/session, click action

The important product bug is not just that `%` is a bad body. The deeper bug is
content provenance. Kurotty should not treat arbitrary visible terminal text as
notification truth. Mature terminals either use explicit notification payloads,
shell-integration command metadata, user-configured trigger templates, or fixed
event text. Blindly summarizing the visible screen mixes prompt text, status bars,
ANSI control fragments, tool traces, and assistant output.

For interactive TUI and agent workflows, rendered output is not an acceptable
notification payload source. Kurotty requires explicit terminal,
shell-integration, bridge, or agent events. A payload-free BEL may request user
attention, but it cannot identify the producer, event, result, or response.

The second screenshot-class failure changed the diagnosis. The banner was no
longer showing only `%`, but it still showed unrelated interactive TUI text:
`hello`, `Hello. How can I help?`, and repaint suffix fragments such as `55`.
That means body cleanup alone is not the fix. Kurotty was starting a
background-task notification for every submitted line, including ordinary input
inside an interactive TUI. Mature terminals do not treat "user pressed
Enter in a full-screen/interactive program" as "a background task has started."

The third correction is stricter: Kurotty must not infer a Codex completion title
from app-looking output alone. App-specific completion titles require an explicit
noninteractive task command shape such as `codex exec ...`, shell-integration
command metadata, or a future explicit agent event. A plain interactive TUI
launch is not a finishable background task.

The fourth correction, from the July 5 re-check against iTerm2 and Ghostty, is
the most important architectural rule: an interactive TUI cannot be converted
into reliable app-specific task completion by scraping the rendered screen.
iTerm2 does, however, expose terminal alerts for exactly this
class of interaction: the terminal event is titled `Alert`, and the body is
session-scoped text such as `Session dev (codex) #1: Hi. What would you like to
work on?`. That is not a task-completion signal; it is terminal activity/alert
presentation. Other terminals avoid the false-completion bug by separating event
sources:

- Ghostty parses OSC 9 into `show_desktop_notification` with an empty title and
  explicit body in `ghostty/src/terminal/osc/parsers/osc9.zig`.
- Ghostty parses OSC 777 `notify;Title;Body` into the same explicit desktop
  notification event in `ghostty/src/terminal/osc/parsers/rxvt_extension.zig`.
- Ghostty forwards that typed event through `ghostty/src/termio/stream_handler.zig`
  as `.desktop_notification` and gates delivery in `ghostty/src/Surface.zig`.
- iTerm2 command completion starts from command marks and shell-integration
  boundaries in `iTerm2/sources/VT100Screen/VT100ScreenMutableState.m`, then
  reaches `PTYSession.m` as `screenDidExecuteCommand` /
  `screenCommandDidExitWithCode`.
- iTerm2 notification payloads for command completion carry command, exit code,
  output range, host, directory, and prompt id; idle/new-output/bell are separate
  event streams.
- iTerm2 maps OSC 9 to `ITERM_USER_NOTIFICATION`, filters numeric first
  parameters such as `9;4;...` as progress state, then formats non-rich terminal
  notifications as title `Alert` with body `Session <session> #<tab>: <message>`.

Kurotty therefore treats OSC desktop notification payloads as first-class
`TerminalOSCDispatcher.Event.desktopNotification` values. This mirrors the
Ghostty event boundary and prevents OSC notification body construction from
falling back to arbitrary visible lines. The compatibility fallback for a live
interactive TUI uses only output captured after the submitted input, requires a
trustworthy answer block, and presents as an iTerm2-style terminal `Alert`, not
as task completion.

The fifth correction, from the external-hook failure, is about transport rather
than text cleanup. Codex/OMX notify hooks can run without a controlling terminal.
In that context `/dev/tty` may not exist or may not be writable, and guessing
`/dev/ttys*` or a parent-process TTY is still hardcoding. Even if such a write
succeeds, it is not guaranteed to enter Kurotty's PTY parser for the relevant
pane. The correct model is the one used by cmux/kitty-style control paths:

- PTY OSC 9/777 is accepted only when terminal applications emit it through the
  PTY.
- External hooks use an explicit Kurotty notification bridge, not a guessed TTY.
- The bridge accepts typed JSON or plain text and maps fields such as
  `last-assistant-message`, `title`, `body`, `message`, `summary`, and
  `instruction` into a desktop notification payload.
- Kurotty exports `KUROTTY_NOTIFY_SOCKET` and `KUROTTY_NOTIFY_COMMAND` to child
  shells so tools launched inside Kurotty can notify the running app without
  scraping the screen or writing to `/dev/tty`.

## Ghostty

### Source Areas

- `ghostty/src/terminal/osc.zig`
- `ghostty/src/terminal/osc/parsers/semantic_prompt.zig`
- `ghostty/src/terminal/osc/parsers/osc9.zig`
- `ghostty/src/termio/stream_handler.zig`
- `ghostty/src/Surface.zig`
- `ghostty/src/apprt/surface.zig`
- `ghostty/src/apprt/action.zig`
- `ghostty/src/config/Config.zig`
- `ghostty/src/shell-integration/*`
- `ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`

### Process

Ghostty treats command completion as a semantic event, not as scraped screen text. Shell integrations emit OSC 133 markers:

- `A`: prompt start
- `B`: prompt end
- `C`: command output start
- `D`: command end with exit code

The parser maps OSC 133 into semantic prompt actions. The stream handler converts `C` into `start_command` and `D` into `stop_command`. `Surface.zig` records a command start timestamp, computes duration at stop, then emits `command_finished` with exit code and elapsed time.

OSC 9/777 desktop notifications are parsed separately into explicit `show_desktop_notification` messages. Bell is also separate: BEL becomes `ring_bell`, debounced around 100 ms, then mapped to platform attention/sound behavior.

### Display Content

Command-finished notifications use generated titles such as `Command Succeeded`, `Command Failed`, or `Command Finished`. Body includes duration and exit code. OSC notifications keep terminal-provided title/body but bound payload sizes early.

Ghostty does not scrape the visible terminal buffer to discover "the task
summary." Content comes from:

- explicit OSC 9 / OSC 777 notification payloads
- OSC 133 shell-integration command lifecycle metadata
- generated command-completion text from command state, exit code, and duration
- BEL event state for bell/attention, with no body text

Source references from the local tree:

- `ghostty/src/terminal/osc/parsers/osc9.zig`
- `ghostty/src/terminal/osc/parsers/rxvt_extension.zig`
- `ghostty/src/terminal/stream.zig`
- `ghostty/src/termio/stream_handler.zig`
- `ghostty/src/Surface.zig`
- `ghostty/src/shell-integration/bash/ghostty.bash`
- `ghostty/src/shell-integration/zsh/ghostty-integration`

### Kurotty Takeaways

- Prefer OSC 133/shell-integration command spans over prompt/screen heuristics.
- Keep command-completion, OSC notification, and bell as distinct event types.
- Generate command completion titles from state: success, failure, input-needed, duration, command text.
- Add payload bounds before platform delivery.
- Do not build notification body by scanning rendered cells unless it is an explicitly bounded compatibility fallback.

## iTerm2

### Source Areas

- `iTerm2/sources/VT100Screen/VT100Screen.m`
- `iTerm2/sources/VT100/VT100XtermParser.m`
- `iTerm2/sources/VT100/VT100Terminal.m`
- `iTerm2/sources/VT100Screen/VT100ScreenMutableState+TerminalDelegate.m`
- `iTerm2/sources/PTYSession/PTYSession.m`
- `iTerm2/sources/Notifications/iTermNotificationController.m`
- `iTerm2/sources/TerminalView/PTYTab.m`
- `iTerm2/sources/AppKit/iTermDockBadgeController.swift`
- `iTerm2/sources/Triggers/*`
- `iTerm2/sources/Settings/*`

### Process

iTerm2 has a central notification controller around `UNUserNotificationCenter`. Terminal/session events feed policy first, then delivery. Bell handling runs through session logic that decides audible bell, visual bell, indicator, user notification, dock badge, triggers, and suppression.

It also has separate alert sources:

- bell
- terminal-generated notification
- idle alert
- new output alert
- session-ended alert
- text triggers
- browser notification polyfill

Per-tab/session state prevents repeated idle/new-output spam. Notification clicks reveal the relevant session or perform callback behavior.

OSC 9 follows a specific path:

- `VT100XtermParser.m` maps OSC code `9` to `ITERM_USER_NOTIFICATION`.
- `VT100Terminal.m` calls `terminalPostUserNotification:token.string`.
- `VT100ScreenMutableState+TerminalDelegate.m` treats numeric first parameters as
  extensions. `4` is ConEmu-style progress state, not a user notification.
- `PTYSession.m` calls `iTermNotificationController notify:@"Alert"` and, unless
  simple notifications are enabled, formats the body as `Session %@ #%d: %@`.

### Display Content

iTerm2 payloads are contextual: session, trigger text, URL/callback, idle/new-output state, or session-ended state. Dock badge is another channel, not the same thing as a notification.

iTerm2 does not passively scrape visible output for its core completion/bell/badge
flows. Content source is one of:

- command mark metadata captured from prompt/command ranges
- event trigger metadata, such as command finished or bell received
- explicit terminal-generated notification payload if the profile allows it
- user-configured trigger text or regex capture templates
- fixed event text such as bell/session/mark messages

Regex triggers are the important exception: a user can configure content matching.
That is still an explicit trigger rule, not a generic "summarize whatever is on
screen" path.

The most relevant iTerm2 distinction for Kurotty is command marks. iTerm2 tracks
prompt, command, and output ranges as explicit screen metadata. Command-finished
logic is driven by mark state, command range, exit status, and trigger
evaluation. Idle/new-output notifications are separate activity features and use
fixed contextual text. They are not promoted to "command finished" just because
the screen reached a prompt-looking state.

That difference is exactly what Kurotty was missing. In an interactive agent/TUI,
the visible screen contains:

- prior user prompts
- assistant replies
- status bar state such as model, workspace, approval mode, and readiness
- tool traces such as `Explored` / `Read`
- partial repaint artifacts from terminal control sequences

None of those are a reliable completion payload unless Codex, shell integration,
or a user trigger explicitly marks them as such. Kurotty should therefore avoid
promoting interactive agent output to "Codex task finished/failed/needs input".
For user-visible conversational output, Kurotty can still emit an iTerm2-style
terminal `Alert` by using only the output captured after the submitted input and
filtering prompt/status/tool/chrome lines before delivery.

Source references from the local tree:

- `iTerm2/sources/VT100Screen/VT100ScreenMutableState.m`
- `iTerm2/sources/VT100Screen/VT100ScreenMutableState+TerminalDelegate.m`
- `iTerm2/sources/PTYSession/PTYSession.m`
- `iTerm2/sources/Triggers/iTermEventTriggerEvaluator.swift`
- `iTerm2/sources/Triggers/iTermUserNotificationTrigger.m`
- `iTerm2/sources/Notifications/iTermNotificationController.m`

### Kurotty Takeaways

- Add a central broker eventually: source event -> policy -> channel delivery.
- Include pane/session target metadata so clicking a notification focuses the right pane.
- Add per-event first-hit/cooldown state.
- Keep user preferences per source and per channel.
- If Kurotty adds content triggers, make them explicit user-configured rules with captured payloads.
- Match iTerm2 OSC 9 presentation: title `Alert`, body `Session <title> #<tab>:
  <message>`, and ignore numeric OSC 9 progress/extensions as desktop
  notifications.

## Kitty

### Source Areas

- `kitty/kitty/screen.c`
- `kitty/kitty/window.py`
- `kitty/kitty/notifications.py`
- `kitty/kitty/tabs.py`
- `kitty/kitty/tab_bar.py`
- `kitty/kitty/cocoa_window.m`
- `kitty/kitty/glfw/linux_notify.c`
- `kitty/docs/desktop-notifications.rst`
- `kitty/kitty/options/definition.py`

### Process

Kitty splits alerting into layers:

- C screen layer detects input activity, BEL, and desktop notification escape sequences.
- Python window layer applies focus and command-completion policy.
- `NotificationManager` handles protocol payload assembly, close/update/alive queries, action callbacks, and backend dispatch.
- Platform code performs macOS `UNUserNotificationCenter` or Linux DBus delivery.

Command completion uses `notify_on_cmd_finish`: it can notify, ring bell, or run configured behavior depending on focus and timeout. Activity since last focus marks tabs/windows separately from system notifications.

### Display Content

OSC 9/99/777 notifications support title/body/buttons/icon/action ids, urgency, timeout, close reports, progress, update, and alive/query semantics. Command completion body is generated from command and status.

Kitty is the clearest model for content provenance:

- OSC 9 is treated as explicit raw notification text.
- OSC 99 is Kitty's structured desktop notification protocol, with metadata,
  chunking, update/close/query semantics, icons, urgency, and action payloads.
- OSC 777 is parsed as legacy `notify;title;body`.
- `notify_on_cmd_finish` uses shell-integration watcher marks, especially OSC
  133 command lifecycle markers. It generates text such as command/status
  finished messages from command metadata.
- Bell and activity set state/attention symbols and may request OS attention,
  but do not derive notification bodies from terminal text.

Source references from the local tree:

- `kitty/kitty/vt-parser.c`
- `kitty/kitty/screen.c`
- `kitty/kitty/window.py`
- `kitty/kitty/notifications.py`
- `kitty/shell-integration/bash/kitty.bash`
- `kitty/docs/desktop-notifications.rst`
- `kitty/kitty/options/definition.py`

### Kurotty Takeaways

- Build toward a protocol-aware notification model with id/update/close in the future.
- Separate bell attention from desktop notifications.
- Add tab/pane activity symbols independent of macOS banners.
- Use focus-gating and throttling to avoid false activity.
- Treat OSC 9/99/777 payloads as authoritative content. Treat screen text as untrusted UI material.
- For OSC 9 specifically, copy iTerm2's split between text notifications and
  numeric progress/update extensions so progress state does not become a banner.

## Alacritty

### Source Areas

- `alacritty/alacritty_terminal/src/term/mod.rs`
- `alacritty/alacritty/src/event.rs`
- `alacritty/alacritty/src/display/bell.rs`
- `alacritty/alacritty/src/display/mod.rs`
- `alacritty/alacritty/src/display/window.rs`
- `alacritty/alacritty/src/config/bell.rs`

### Process

Alacritty is intentionally minimal. Terminal core emits `Event::Bell`; UI handles it as:

- urgent hint if unfocused and terminal mode permits
- visual bell animation
- optional external `bell.command`
- cooldown around 100 ms

It does not implement rich desktop notifications or content-aware command completion. Title changes are handled separately through terminal title events and config.

### Display Content

No notification body composition. Alerting is visual/sound/window-attention oriented.

Alacritty is useful as the opposite constraint: the low-level bell event carries
no payload. It sets urgency, triggers visual bell animation, and optionally runs
`bell.command`. It never tries to infer a notification body from terminal output.

Source references from the local tree:

- `alacritty/alacritty_terminal/src/event.rs`
- `alacritty/alacritty_terminal/src/term/mod.rs`
- `alacritty/alacritty/src/event.rs`
- `alacritty/alacritty/src/display/bell.rs`
- `alacritty/alacritty/src/display/window.rs`
- `alacritty/alacritty/src/config/bell.rs`

### Kurotty Takeaways

- Keep the low-level bell path simple and fast.
- Do not mix BEL with command completion.
- If Kurotty adds rich notifications, put them above terminal-core bell events rather than inside the parser/render path.
- Bell should be a state transition, not a text summarizer.

## tmux

### Source Areas

- `tmux/input.c`
- `tmux/window.c`
- `tmux/alerts.c`
- `tmux/options-table.c`
- `tmux/options.c`

### Process

tmux tracks window alert flags:

- `WINDOW_BELL`
- `WINDOW_ACTIVITY`
- `WINDOW_SILENCE`

BEL queues `WINDOW_BELL`. Window output updates activity time and can queue `WINDOW_ACTIVITY` if `monitor-activity` is enabled. Silence timers queue `WINDOW_SILENCE` when no activity happens for the configured period.

Policies are controlled by options such as `bell-action`, `activity-action`, `monitor-activity`, `monitor-silence`, `visual-bell`, and `visual-activity`.

### Display Content

tmux is status-line oriented. It marks windows and displays short messages such as `Bell` or `Activity`; it does not try to summarize terminal output.

tmux does not scrape pane content for alert text. It sets structural flags:

- `WINDOW_BELL`
- `WINDOW_ACTIVITY`
- `WINDOW_SILENCE`
- winlink flags such as `WINLINK_BELL`, `WINLINK_ACTIVITY`, `WINLINK_SILENCE`

Formats such as `window_bell_flag`, `window_activity_flag`,
`window_silence_flag`, `session_alert`, and `window_flags` render those flags as
symbols and styles. Alert messages are fixed strings such as "Bell in window" or
"Activity in window." Hooks such as `alert-bell` and `alert-activity` allow users
to generate their own payloads if they want richer behavior.

Source references from the local tree:

- `tmux/input.c`
- `tmux/alerts.c`
- `tmux/format.c`
- `tmux/window.c`
- `tmux/options-table.c`
- `tmux/status.c`

### Kurotty Takeaways

- Add pane/tab alert flags separate from OS notifications.
- Support activity/silence monitoring for long-running agents and logs.
- Treat visual tab indicators as durable state until focus/read, not transient banners.
- Use flags/styles for attention; require explicit hooks/events for rich text.

## cmux

### Source Areas

- `cmux/Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Notification/ControlCommandCoordinator+Notification.swift`
- `cmux/Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Notification/*`
- `cmux/Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/Surface/*`
- `cmux/Packages/macOS/CmuxWorkspaces/Sources/CmuxWorkspaces/Core/Values/PanelShellActivityState.swift`
- `cmux/cmuxTests/CmuxEventBusTests.swift`

### Process

cmux is closer to an agent/workspace control surface than a traditional terminal. It exposes control commands such as:

- `notification.create`
- `notification.create_for_surface`
- `notification.create_for_target`
- `notification.list`
- `notification.clear`
- `notification.dismiss`
- `notification.mark_read`
- `notification.open`
- `notification.jump_to_unread`

Notifications are targetable to workspace/surface and have read/open lifecycle. Shell activity state can be reported separately for surfaces.

### Display Content

Payloads are structured objects with notification id, target, read state, and open behavior. This is more like an inbox than a transient bell.

cmux uses explicit payload fields and structured context:

- `title`
- `subtitle`
- `body`
- workspace/surface/target metadata
- read/open/dismiss lifecycle
- policy/effect envelopes

Local analysis found notification creation through explicit commands such as
`notification.create`, `notify_target`, `notify_target_async`, and parser paths
that enforce pipe-delimited `title|subtitle|body` fields. Workspace/mobile sync
uses IDs, counts, hashes, and lifecycle events, not raw terminal text.

Source references from the local tree:

- `cmux/CLI/CMUXCLI+Events.swift`
- `cmux/CLI/cmux.swift`
- `cmux/Sources/TerminalController.swift`
- `cmux/Sources/TerminalController+ControlNotificationContext.swift`
- `cmux/Sources/TerminalNotificationStore.swift`
- `cmux/Sources/TerminalNotificationQueue.swift`
- `cmux/Sources/TerminalNotificationPolicy.swift`
- `cmux/Sources/CmuxSocketEventMapper.swift`

### Kurotty Takeaways

- AI-agent notifications should become addressable records, not only OS banners.
- A future Kurotty notification center should support unread/read/open lifecycle.
- Agent panels need targeted delivery and jump-to-pane behavior.
- Agent notifications should be structured records from the agent layer, not inferred terminal snapshots.

## Kurotty Current Implementation

Kurotty keeps notification sources distinct:

- OSC 9, OSC 777 `notify;title;body`, and supported rich OSC 1337 are parsed into
  typed desktop-notification events and preserve producer-supplied fields.
- OSC 133 shell integration represents ordinary command completion from command
  boundaries, working directory, exit status, and duration.
- The versioned Unix-socket/CLI bridge accepts explicit title, subtitle, body,
  event, session, and duration fields without relying on an installation path.
- BEL rings the terminal bell and, while unfocused, shows the fixed
  `Kurotty` / `Check your terminal.` fallback. BEL supplies none of that text and
  does not prove task completion.

Kurotty does not select behavior from executable names and does not promote
submitted input, rendered rows, status bars, warnings, output quietness, or
repaint fragments into notification content. Historical screen-scraping and
idle-completion experiments described in earlier revisions were removed because
they could notify before a turn completed or attach stale content to a later
event.

## Recommended Kurotty Alert Architecture

### Event Sources

- `bell`: BEL / terminal bell
- `oscNotification`: OSC 9 / iTerm2 / Kitty-style explicit notification
- `commandStarted`: OSC 133 C or shell integration start
- `commandFinished`: OSC 133 D, shell integration command end, or explicit noninteractive command lifecycle
- `agentState`: Codex/agent finished, failed, needs input, waiting approval
- `activity`: output in unfocused pane
- `silence`: no output for configured interval
- `sessionEnded`: PTY exit

### Policy Layer

Decide whether and how to alert:

- focused pane: suppress OS banner, update local status only
- unfocused pane: allow banner, tab badge, dock badge
- long command threshold
- failure always more visible than success
- input-required highest priority
- cooldown and identical-content dedupe
- privacy setting for output summaries

### Channels

- macOS Notification Center
- tab activity dot/badge
- pane border or title marker
- dock badge/bounce
- audible bell
- visual bell
- command palette / notification inbox

### Payload Contract

Each alert should carry:

- `id`
- `source`
- `severity`: info, success, warning, failure, inputRequired
- `title`
- `subtitle`
- `body`
- `workspaceID`
- `tabID`
- `paneID`
- `command`
- `exitCode`
- `cwd`
- `createdAt`
- `readAt`

## Implementation Plan From Here

### Already Implemented In This Branch

- Route OSC 9, OSC 777 `notify;title;body`, and supported rich OSC 1337 through
  `TerminalOSCDispatcher.Event.desktopNotification`.
- Preserve explicit protocol fields and ignore numeric OSC 9 progress
  extensions as desktop notifications.
- Deliver explicit desktop-notification payloads through `TerminalNotifier`
  without deriving body text from the rendered screen.
- Remove output-idle, rendered-row, and application-name completion inference.
- Add a producer-neutral Unix-socket/CLI bridge resolved from the running app
  environment rather than a guessed TTY or installation path.
- Use OSC 133 shell-integration boundaries for ordinary command completion.
- Treat BEL as payload-free attention: sound plus the fixed unfocused fallback
  `Kurotty` / `Check your terminal.`

### Next Iteration

- Extend the explicit Kurotty bridge beyond desktop banners into a durable
  agent-event API. It should accept task id, state, prompt, summary, approval
  request, exit/failure state, and pane/session target metadata.
- Wire OSC 133 command spans directly into notification content, including exit code and duration.
- Add pane/tab alert flags for activity, bell, failure, and input-required.
- Add click target metadata so notification activation focuses the originating pane.
- Add dedupe and rate limiting.
- Add settings:
  - notify on command finish: never / unfocused / always
  - command finish threshold seconds
  - channels: banner, sound, dock badge, tab badge, visual bell
  - expose output summary
- Add a notification inbox for AI agent events.
