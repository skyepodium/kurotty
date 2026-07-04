# Kurotty Alert / Notification Analysis

This document compares alert, notification, bell, activity, and command-completion behavior in terminal projects available beside Kurotty. Kurotty itself is excluded from the comparative source analysis, then evaluated separately for implementation.

## Problem Observed In Kurotty

The current notification UX can show generic macOS banners such as:

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

For Codex/agent workflows, the only acceptable fallback is a narrow agent-output
extractor that selects the latest assistant answer block and rejects prompt,
tool/status, and UI chrome lines. Longer term, Kurotty should prefer explicit
agent events over text extraction.

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

### Before This Change

- `TerminalNotifier.notifyItermOsc9(message:)` delivered title `Alert` and raw body.
- `TerminalNotifier.notifyBackgroundTaskCompleted(body:)` delivered title `Alert` and a single body string.
- `TerminalSurfaceView` built body from recent output or submitted input fallback.
- A shell prompt `%` could become the entire notification body.
- `UNMutableNotificationContent.subtitle` was unused.

### Applied Change

Kurotty now has `TerminalBackgroundTaskNotificationContent`:

- `title`
- `subtitle`
- `body`

Rules added:

- submitted command becomes subtitle, for example `codex`
- Codex success title: `Codex task finished`
- Codex failure title: `Codex task failed`
- Codex input/approval title: `Codex needs input`
- generic background task title: `Task finished`
- OSC9 placeholder prompt payloads such as `%`, `$`, `#` are ignored
- notification body extraction can preserve multi-paragraph meaningful output and avoids trailing shell prompts
- macOS notification subtitle is populated
- logs still record lengths only, not raw terminal content

### Follow-up Fix For Codex TUI Output

The screenshot after the first fix exposed a sharper bug:

- submitted input such as `hello` became the subtitle correctly
- but the notification body included Codex UI chrome:
  - color-control leftovers such as `38;2;200;169;238;49m`
  - approval/status text from the bottom bar
  - tool trace blocks such as `Explored` / `Read SKILL.md`
  - inline TUI repaint suffixes such as `Worki55`

The corrected rule is:

- if output looks like Codex/agent TUI output, prefer the latest assistant
  answer line/block
- ignore prompt lines, status bars, usage bars, tool trace headings, and
  decorative separators
- strip terminal controls and common TUI repaint suffix fragments
- use generic output summarization only as a fallback for non-agent commands

This still remains a compatibility heuristic. The target architecture is an
explicit agent-event payload:

```text
agent.notification {
  agent: "codex",
  state: "finished" | "failed" | "needs_input",
  task: "user-submitted prompt or command",
  summary: "assistant final answer or approval request",
  paneID,
  commandID,
  createdAt
}
```

## Recommended Kurotty Alert Architecture

### Event Sources

- `bell`: BEL / terminal bell
- `oscNotification`: OSC 9 / iTerm2 / Kitty-style explicit notification
- `commandStarted`: OSC 133 C or shell integration start
- `commandFinished`: OSC 133 D or fallback idle output completion
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

- Replace generic background-task notification body-only API with structured content.
- Use Codex-specific titles for finished/failed/input-needed cases.
- Populate macOS notification subtitle.
- Filter `%` prompt-only notification payloads.
- Preserve meaningful multi-line output for Codex completion.
- Add regression tests for the screenshot-class failure.

### Next Iteration

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
