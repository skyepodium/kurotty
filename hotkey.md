# Terminal Hotkey Input Analysis and Plan

## Goal

Kurotty should treat common terminal hotkeys as terminal input, not as one-off app shortcuts. Plain and modified navigation keys, Tab/Backtab, delete/insert/page keys, and function keys need a central encoder that turns AppKit key events into PTY byte sequences.

## Findings From Reference Terminals

### Shared legacy behavior

- `Shift+Tab` is a legacy backtab sequence: `ESC [ Z`.
- Modified arrows use xterm-style CSI modifier parameters:
  - `Shift+Up` -> `ESC [ 1 ; 2 A`
  - `Shift+Down` -> `ESC [ 1 ; 2 B`
  - `Shift+Right` -> `ESC [ 1 ; 2 C`
  - `Shift+Left` -> `ESC [ 1 ; 2 D`
- Modifier values are xterm-style: Shift `2`, Alt/Option `3`, Shift+Alt `4`, Control `5`, Shift+Control `6`, Alt+Control `7`, Shift+Alt+Control `8`.
- Plain arrows use legacy cursor sequences. Application cursor mode changes plain cursor keys from `ESC [ A/B/C/D` to `ESC O A/B/C/D`; modified cursor keys stay CSI modifier sequences.
- Home/End/PageUp/PageDown/Delete/Insert and F-keys use the same legacy family, with modifier suffixes where supported.

### iTerm2

- Keyboard handling is stateful: terminal key reporting flags can switch the mapper to modern CSI-u behavior; otherwise mappers use standard, termkey, raw, or modifyOtherKeys paths.
- Legacy `Shift+Tab` stays `ESC [ Z`.
- Modified arrows/Home/End use `ESC [ 1 ; <modifier> final`.
- PageUp/PageDown/Delete use `ESC [ 5/6/3 ; <modifier> ~`; Insert differs by mapper but termkey/modifyOtherKeys support modifier suffixes.
- Function keys use `ESC O P/Q/R/S` for F1-F4 and `ESC [ 15~` style for F5-F12, with modifier suffixes in modifier-aware paths.

### Alacritty

- Default bindings hard-code `Shift+Tab` as `ESC [ Z`.
- Bundled terminfo advertises modified arrows such as `kUP=\E[1;2A`, `kDN=\E[1;2B`, `kLFT=\E[1;2D`, `kRIT=\E[1;2C`.
- Kitty keyboard protocol is supported, but legacy xterm-compatible encoding remains the default unless negotiated protocol flags require the Kitty path.

### Kitty

- Separates application hotkey handling from bytes sent to child processes.
- Legacy compatibility is the default: `Shift+Tab` is `ESC [ Z`; modified arrows use xterm CSI modifier forms.
- Kitty keyboard protocol is a per-screen flag stack and changes encoding only after protocol negotiation.

### Ghostty

- Uses a dedicated key encoder with platform normalization, terminal-state snapshot, protocol selection, and table-driven serialization.
- Cursor key mode, keypad mode, modifyOtherKeys, Kitty keyboard protocol, and Option-as-Alt are explicit encoder inputs, not scattered view special cases.

## Kurotty Current Gap

- Kurotty advertises `TERM=xterm-256color`.
- There is no central `TerminalKeyEncoder`.
- `TerminalTextInputRouter`, `TerminalSurfaceView`, and `TerminalInputView` each own fragments of terminal key encoding.
- `Shift+arrow` is currently consumed as app-local keyboard selection in `TerminalSurfaceView` instead of being sent to the PTY.
- `Shift+Tab` has no backtab mapping.
- Existing tests assert that `ESC [ 1 ; 2 A/B/C/D` is absent, which locks in the wrong behavior for terminal compatibility.

## Architecture Plan

1. Add `TerminalKeyEncoder`.
   - Input: `NSEvent` plus a small `State` snapshot.
   - Output: optional PTY `String`.
   - Initial state fields:
     - `applicationCursorKeys`
   - Future state fields:
     - application keypad mode
     - xterm modifyOtherKeys mode
     - Kitty keyboard protocol flags
     - Option-as-Alt policy

2. Move terminal key byte generation out of views.
   - `TerminalTextInputRouter.terminalControlText(for:)` delegates to `TerminalKeyEncoder`.
   - `TerminalSurfaceView.doCommand(by:)` uses selector fallback sequences from `TerminalKeyEncoder` for AppKit command selectors.
   - `TerminalInputView.doCommand(by:)` uses the same selector fallback sequences.

3. Preserve app shortcuts only for explicit app-level commands.
   - `Command` shortcuts remain handled by `TerminalCommandDispatcher`.
   - Plain, Shift, Control, and Option terminal keys should default to PTY encoding unless a deliberate app mode owns them.

4. Implement xterm legacy first.
   - Tab and Shift+Tab.
   - Plain and modified arrows.
   - Home/End/PageUp/PageDown/Delete/Insert.
   - F1-F12.
   - Control character fallback for common shell shortcuts.

5. Add protocol-state follow-up.
   - Track DECCKM/application cursor mode from `CSI ? 1 h/l`.
   - Track keypad mode from DEC keypad sequences.
   - Add xterm modifyOtherKeys and Kitty keyboard protocol negotiation after the legacy encoder is stable.

## Initial Regression Matrix

- `Tab` -> `\t`
- `Shift+Tab` -> `ESC [ Z`
- Plain arrows -> `ESC [ D/C/B/A`
- Application cursor plain arrows -> `ESC O D/C/B/A`
- Shift arrows -> `ESC [ 1 ; 2 D/C/B/A`
- Control arrows -> `ESC [ 1 ; 5 D/C/B/A`
- Shift+Control arrows -> `ESC [ 1 ; 6 D/C/B/A`
- PageUp/PageDown/Delete/Insert modified variants
- F1-F12 plain and Shift variants
- Existing IME tests must keep marked text from being sent before commit.

## Stop Condition

The first implementation pass is complete when:

- `TerminalKeyEncoder` owns xterm legacy encoding.
- `Shift+Tab` and `Shift+arrows` produce the same legacy sequences as iTerm2/Alacritty/Kitty.
- `TerminalSurfaceView` and `TerminalInputView` both use the shared encoder path for AppKit selectors.
- Targeted Swift tests pass.

