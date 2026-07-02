# Korean IME Test Matrix

This matrix locks the IME boundary for Korean input. AppKit owns composition through `setMarkedText`; Kurotty must treat marked text as a renderer overlay until `insertText` commits confirmed text. During preedit, there must be no `send`, `shell.write`, or `core.feed` for the marked string.

## Required Logging

For installed-app verification, run Kurotty with input-client logs enabled so the event order is visible:

```sh
launchctl setenv KUROTTY_DEBUG_INPUT_CLIENT 1
./scripts/install-app.sh
open /Applications/kurotty.app
```

Inspect logs for `keyDown`, `setMarkedText`, `insertText`, `unmarkText`, and `ptyWrite source=insertText`. Raw terminal input/output should remain unlogged.

## Cases

| Case | Setup | Action | Expected AppKit/Kurotty path | Expected PTY/Core output |
| --- | --- | --- | --- | --- |
| Initial consonant composition | Empty prompt, Korean 2-set input source | Type initial consonant `ㅇ` | `keyDown` is offered to `NSTextInputContext`; `setMarkedText("ㅇ")` updates overlay and redraws only | No `send`, `shell.write`, or `core.feed` |
| Initial vowel composition | Existing marked `ㅇ` | Type vowel `ㅏ` | Marked text is replaced by `setMarkedText("아")`; screen buffer is unchanged | No PTY/core output before commit |
| Syllable replacement | Existing marked `아` | Type final consonant `ㄴ` | Marked text is replaced by `setMarkedText("안")`; previous preedit glyphs are dirty/redrawn as overlay pixels | No PTY/core output before commit |
| Backspace during composition | Existing marked `안` | Press Backspace before commit | IME consumes or rewrites preedit through `setMarkedText`/`unmarkText`; Kurotty does not synthesize Hangul or repair jamo | No delete byte for IME-owned preedit unless AppKit emits a terminal command after composition ends |
| Commit | Existing marked `안` | Commit with Space/Return or continue typing per Korean IME behavior | `insertText("안")` normalizes committed text, calls `unmarkText`, then sends the committed string | Exactly `안`; no intermediate `ㅇ`, `ㅏ`, `ㄴ`, or compatibility-jamo sequence |
| Wide cursor advance after Hangul | Cursor before composition, grid has room | Commit `안녕`, then start next marked syllable | Commit advances by terminal column width for Hangul syllables; next marked overlay anchor starts after the committed wide cells | Exactly `안녕` for commit; next preedit still produces no PTY/core output |
| Resize during composition | Active marked text overlay | Resize the window or split while preedit is visible | Resize updates metrics and redraws overlay at the current IME anchor; marked text remains overlay-only | No PTY/core output caused by resize |
| Split pane input source change | Two panes open, one has active marked text | Switch input source while focus moves or another pane receives input | Stale marked text may be cleared locally without `discardMarkedText()` re-entry or synthesized replacement text | No replacement text; no compatibility jamo; command shortcuts still route by key equivalent |

## Critical Regression Flow

1. Select English input.
2. Type `d`.
3. Switch to Korean input.
4. Type and commit `안녕`.

Expected PTY text is exactly `d안녕`. Failing outputs include `dㅇㅏㄴ녕`, `dㅏㄴ`, duplicated text, or any committed compatibility-jamo sequence.

## Automated Coverage

`TerminalTextInputRouterTests` covers the local boundary:

- `TerminalInputView.setMarkedText` updates marked state without calling `TerminalCore.feed`.
- `TerminalInputView.insertText` is the first point that feeds committed IME text.
- `TerminalSurfaceView.setMarkedText` is source-shape guarded to update overlay state and renderer damage without `send`, `shell.write`, or `core.feed`.

Manual installed-app verification is still required for user-visible IME fixes because AppKit/IMK event ordering can differ between `swift run` and `/Applications/kurotty.app`.
