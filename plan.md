# kurotty에 반영할 기능 제안

이 문서는 로컬 소스 `ghostty`, `iTerm2`, `kitty`, `alacritty`, `tmux`, `cmux`, `kurotty`를 read-only로 병렬 분석한 결과를 `kurotty` 개발 이슈로 바로 쪼갤 수 있게 정리한 실행 계획이다.

목표는 기능 복제가 아니라 오래 쓸 수 있는 터미널 구조를 만드는 것이다. 판단 기준은 다음과 같다.

- 렌더링보다 먼저 screen model 정확성.
- UI보다 먼저 PTY, parser, resize, IME 안정성.
- AI 기능은 terminal core 밖의 별도 context layer.
- Ghostty는 구조적 boundary, Alacritty는 단순성과 damage/resize, Kitty는 shell integration/확장성/GPU, iTerm2는 macOS UX/session, tmux/cmux는 workspace/pane/agent orchestration 참고.

## 0. 작업 상태 요약

마지막 업데이트: 2026-07-05

표기:

- `[x]` 완료: 구현, 테스트, PR까지 진행된 항목.
- `[~]` 부분 완료: 기반/브리지/진단은 들어갔지만 runtime 완성 또는 UX polish가 남은 항목.
- `[ ]` 남음: 아직 본격 구현 전인 항목.

완료된 PR 기준:

- [x] PR #40: terminal diagnostics, shell context, AI context 기반.
- [x] PR #41: command registry, pixel probe, security policy, workspace snapshot model, glyph run, PTY boundary 기반.
- [x] PR #42: runtime tooling foundation, settings validation, command palette model, OSC52 policy, snapshot store, shell command spans/history, scrollback pressure diagnostics.
- [x] PR #43: preferences validation UI, command palette window/menu, layout-only workspace snapshot save, live OSC dispatcher hook, AI command context bridge, scrollback diagnostics bridge.
- [x] PR #44: resize ledger, event ledger, segmented scrollback store, command history navigator/fold state, AI action approval model, DESIGN.md product UX 정리.
- [x] PR #45: resize diagnostics adapter, event ledger batch/summary bridge, BoundedScrollbackRows segmented storage integration, shell history navigator reuse, AI approval metadata bridge, runtime foundation docs.
- [x] PR #46: runtime timeline metadata foundations, render frame/pixel-probe verification docs, OSC shell command span metadata, AI context/approval metadata.
- [x] PR #47: develop runtime foundation updates promoted.
- [x] PR #48: core/render/shell/UI diagnostics promoted.
  - source-of-truth diagnostics: Swift scaffold와 Zig core truth boundary를 더 명확하게 드러내는 metadata/verification.
  - render coalescing/damage: renderer dirty-region, scissor, frame coalescing evidence를 production path 쪽으로 좁히기.
  - shell opt-in metadata: passive OSC 7/133 기반 위에 opt-in shell capability/session metadata를 구분.
  - command UX: command palette, command spans, search/copy/replay 후보가 같은 app command surface를 쓰도록 정리.
  - AI agent action API: redacted context, approval, action dispatch 경계를 terminal core 밖에서 고정.
- [x] PR #49: 비-UI runtime foundation next slice.
  - source-of-truth trace: PTY/parser/screen/render event ledger와 resize ledger를 연계하는 correlation/source summary 추가.
  - render/glyph diagnostics: damage/scissor fallback reason, stable pixel bounds, glyph shaping/fallback/atlas diagnostic contract 추가.
  - scrollback backend: segmented store retained-row summary, absolute/visible coordinate helper, 대용량 stress 기준 보강.
  - shell backend: OSC evidence와 command span fold/replay/search metadata를 descriptor와 분리.
  - AI backend: action approval을 action id, kind, immutable fingerprint, current policy re-evaluation에 묶어 같은 id 재사용 공격 차단.
- [x] PR #53: runtime follow-up 병렬 작업.
  - trace timeline: correlation report에서 production-friendly metadata-only timeline summary를 노출.
  - renderer damage: redraw/coalescing policy를 `TerminalRenderFrame` contract로 이동해 production diagnostics가 같은 정책을 사용.
  - scrollback export: raw row materialization 없이 export window summary를 계산해 copy/search/AI 참조 준비.
  - AI command reference: command span snapshot에 raw output 없는 copyable locator metadata 추가.
- [x] PR #54: UI 제외 backend/runtime 병렬 작업.
  - trace source-of-truth: PTY/parser/screen/render stage completeness와 missing stage metadata를 raw payload 없이 노출.
  - resize ledger: PTY winsize, screen grid, renderer grid, drawable/frame size와 disagreeing participant metadata를 한 summary로 연결.
  - shell evidence: passive OSC baseline과 per-session opt-in/installed integration evidence를 분리.
  - command backend: fold/search/copy-reference/replay command-span action vocabulary와 approval policy를 command registry에 추가.
  - glyph contract: shaping/fallback/atlas/clipping readiness summary를 `TerminalGlyphRun` backend contract로 추가.
  - scrollback live access: search/copy/AI context reference window availability를 raw row text 없이 metadata로 분류.

현재 남은 큰 축:

- [~] Swift scaffold와 Zig terminal core의 단일 source-of-truth 통합: compatibility diagnostics와 runtime mutation-owner metadata는 보강됨. 실제 runtime mutation path 통합은 남음.
- [~] 실제 PTY/parser/screen/render event ledger를 하나의 디버깅 타임라인으로 묶기: correlation report, timeline summary, source-of-truth completeness, live PTY read metadata producer, parser/render metadata producer와 bounded surface ledger wiring은 완료. screen mutation live producer와 viewer는 남음.
- [~] renderer damage/scissor 최적화를 production path에서 완성: redraw/coalescing policy contract, stable partial damage rect scheduling/coalescing measurement, scissor readiness plan은 완료. 실제 Metal scissor command path와 live overlay polish는 남음.
- [~] glyph shaping/fallback/font atlas contract의 full implementation: backend readiness contract와 CoreText 기반 fallback/atlas-key slice는 완료. Metal atlas production integration은 남음.
- [~] segmented scrollback store와 대용량 stress/performance 기준: retained range/coordinate/stress/export-window/live-access, codable segment persistence metadata, live read-window descriptor 기준은 보강됨. 실제 disk-backed/off-main-thread store는 남음.
- [~] shell integration opt-in script, command folding/replay/search UX: backend metadata, evidence 분리, command action vocabulary, install-free onboarding descriptor, palette presentation metadata, AppKit palette command-span rows는 완료. 실제 selected command-span runtime wiring은 남음.
- [~] browser-like UI polish, non-developer onboarding, DESIGN.md 업데이트: install-free onboarding model, HTML-like link hover/underline affordance, tab/split chrome button hover affordance는 추가됨. 실제 toolbar/search/copy mode 화면 polish는 남음.
- [~] AI agent UX layer: secret-safe backend action API, command span locator, context reference display rows, approval presentation model은 강화됨. 실제 AppKit approval/context UI rendering은 남음.

## 1. 바로 넣어야 할 것

### 1.1 단일 Screen Model 고정

- 참고한 터미널: Ghostty, Alacritty
- 왜 중요한지: `kurotty`는 현재 Swift screen/parser scaffold와 Zig core가 공존한다. 이 상태에서 renderer, shell integration, AI 기능을 얹으면 PTY가 받은 상태, parser event, screen state, renderer frame이 서로 달라져 디버깅이 어려워진다.
- kurotty에 어떻게 구현할지:
  - PTY bytes, parser events, screen mutations, render frames를 독립 로그로 남긴다.
  - parser는 event만 만들고 screen mutation을 직접 수행하지 않는다.
  - screen model이 visible cells, alt screen, scroll margins, placeholder blanks, wide continuations, cursor, style의 유일한 source of truth가 된다.
  - Swift renderer는 `TerminalRenderFrame`만 소비한다.
- 예상 난이도: 높음
- 리스크: 이중 truth 제거 중 기존 Swift rendering tests가 흔들릴 수 있다. 단계별 compatibility adapter가 필요하다.

### 1.2 Resize Ledger

- 참고한 터미널: Ghostty `Surface.sizeCallback -> termio resize`, Alacritty `SizeInfo -> PTY resize -> Term.resize -> renderer`
- 왜 중요한지: resize 시 PTY size와 renderer size가 어긋나면 TUI bottom bar, prompt, split viewport가 쉽게 깨진다.
- kurotty에 어떻게 구현할지:
  - `PtyResizeTrace`를 도입한다.
  - 한 resize cycle마다 viewport px, drawable px, cell px, cols/rows, PTY winsize, screen size, render frame size, timestamp, source를 기록한다.
  - 적용 순서는 `viewport measurement -> cols/rows derivation -> PTY winsize -> screen resize -> renderer frame invalidation`으로 고정한다.
- 예상 난이도: 중간
- 리스크: resize coalescing을 과하게 하면 PTY가 늦게 따라오고, 너무 즉시 처리하면 flicker와 redundant layout이 늘어난다.

### 1.3 IME Composition Layer 분리

- 참고한 터미널: Ghostty preedit dirty state, kurotty `TerminalInputView`/`TerminalTextInputRouter`
- 왜 중요한지: 한글 조합 중 글자가 깨지는 문제는 preedit를 committed cell처럼 다룰 때 반복된다.
- kurotty에 어떻게 구현할지:
  - `setMarkedText`는 renderer overlay만 갱신하고 PTY write와 screen mutation을 하지 않는다.
  - `insertText`에서만 committed text를 PTY에 보낸다.
  - marked text overlay는 cursor cell, selected range, grapheme bounds, pixel rect를 debug log에 남긴다.
  - 테스트 케이스: `d` 입력 후 Korean IME로 `안녕`, composition 중 backspace, composition 중 resize, Korean input source에서 command shortcut.
- 예상 난이도: 높음
- 리스크: AppKit/IMK event ordering은 bundled app과 `swift run`에서 다를 수 있으므로 installed app smoke가 필요하다.

### 1.4 Glyph Shaping / Fallback / Atlas Contract

- 참고한 터미널: Kitty glyph cache + HarfBuzz/Freetype, Ghostty `CodepointResolver`/`Atlas`
- 왜 중요한지: wide char, emoji, ligature, fallback font, narrow cell clipping은 cell width와 glyph bounds가 섞이면 해결하기 어렵다.
- kurotty에 어떻게 구현할지:
  - `GlyphRun` contract를 둔다: source grapheme cluster, terminal width, fallback font id, glyph ids, advances, pixel bounds, atlas keys.
  - atlas slot은 renderer-private이고 screen model은 glyph cache id를 알지 않는다.
  - glyph overhang margin과 cell clipping margin을 분리한다.
  - fallback font resolution은 style, emoji presentation, CJK coverage를 key로 캐시한다.
- 예상 난이도: 높음
- 리스크: CoreText, Metal atlas, cell metrics가 한 번에 바뀌면 regression surface가 크다.

### 1.5 Damage 기반 repaint와 frame coalescing

- 참고한 터미널: Alacritty `DamageTracker`, Ghostty renderer thread/generic dirty logic
- 왜 중요한지: 빠른 출력에서 매번 full repaint하면 `yes`, `cat large.log`, `docker logs -f`, AI agent transcript에서 밀림과 깜빡임이 생긴다.
- kurotty에 어떻게 구현할지:
  - screen damage와 renderer dirty rect를 분리한다.
  - frame마다 dirty rows/rects를 consume하고, 다음 frame damage를 별도로 유지한다.
  - PTY read batch와 parser batch를 묶고 render는 display refresh cadence에 coalesce한다.
  - debug flag로 full redraw fallback과 scissor disable을 비교할 수 있게 한다.
- 예상 난이도: 중간
- 리스크: dirty rect가 너무 좁으면 stale pixels, 너무 넓으면 성능 저하가 난다.

### 1.6 기본 보안 정책

- 참고한 터미널: Ghostty clipboard read ask/write allow, Kitty remote-control gating
- 왜 중요한지: 터미널은 shell, ssh, env, secret, clipboard, AI context를 다룬다.
- kurotty에 어떻게 구현할지:
  - OSC 52 read: 기본 ask.
  - OSC 52 write: local shell allow, remote/ssh unknown context ask 또는 indicator.
  - URL/file link open: scheme allowlist, modifier/open confirmation, suspicious path prompt.
  - remote title/notification/clipboard manipulation: profile policy로 제한.
  - AI context export: raw output opt-in, secret masking default on.
- 예상 난이도: 중간
- 리스크: 너무 엄격하면 terminal compatibility가 나빠지고, 너무 느슨하면 secret leak 경로가 된다.

## 2. 넣으면 강력한 것

### 2.1 Workspace / Session Snapshot

- 참고한 터미널: iTerm2 session restore, Ghostty restorable state, cmux `SessionPersistence.swift`
- 제안:
  - window, top tabs, split tree, focused pane, pane title, cwd, profile, shell command, scrollback summary, agent resume metadata를 snapshot으로 저장한다.
  - 저장은 atomic write + previous backup 방식.
  - restore는 layout 먼저, process resume은 명시 정책에 따라 뒤에서 수행한다.
- MVP 이후 우선순위: 높음

### 2.2 Command Palette

- 참고한 터미널: Kitty command palette kitten, cmux command palette
- 제안:
  - 모든 UI action을 command registry로 노출한다.
  - 사용자 입력은 fuzzy search로 command, pane, workspace, recent command를 찾는다.
  - AI/automation도 view mutation이 아니라 command dispatch만 사용한다.
- MVP 이후 우선순위: 높음

### 2.3 Shell Integration v1

- 참고한 터미널: Ghostty automatic shell integration, Kitty shell integration, iTerm2 marks/command execution
- 제안:
  - 자동 감지: OSC 7 cwd, OSC 133 command start/end/prompt.
  - opt-in script: bash/zsh/fish에서 command line, exit code, duration, cwd, prompt/output ranges.
  - command spans는 fold/search/replay/AI reference의 기본 단위가 된다.
- MVP 이후 우선순위: 높음

### 2.4 AI Context Layer

- 참고한 터미널/도구: cmux agent workflows, iTerm2 AI/session status
- 제안:
  - terminal core 밖에 `AIContextLayer`를 둔다.
  - command span, output chunk, pane metadata, cwd, git branch, running process, notification state를 redacted event log로 제공한다.
  - AI는 terminal buffer를 직접 수정하지 않고 command API 또는 user-approved paste/send-text API를 사용한다.
- MVP 이후 우선순위: 높음

### 2.5 Browser-like UI

- 참고한 터미널/도구: iTerm2 native macOS UX, cmux browser/workspace UI
- 제안:
  - 상단 tab bar는 브라우저처럼 직관적이어야 한다.
  - tab 안에 split pane tree를 둔다.
  - quick terminal, search UI, copy mode, command palette를 non-developer도 찾을 수 있게 메뉴/toolbar에 노출한다.
  - 고급 사용자는 keyboard-first로 쓸 수 있게 한다.
- MVP 이후 우선순위: 중간

## 3. 지금 넣으면 위험한 것

- 완전한 plugin/remote-control ecosystem: 보안 모델, permission, audit log 없이 도입하면 위험하다.
- shell integration 강제 설치: 초기 사용 허들을 만든다.
- AI가 screen buffer나 PTY를 직접 mutate하는 기능: terminal correctness를 깨뜨린다.
- 과한 브랜드 캐릭터 UI: 귀엽지만 장난감처럼 보이면 안 된다.
- renderer micro-optimization 선행: screen model과 resize가 불안정하면 최적화가 버그를 가린다.
- config format 대규모 변경: 현재 kurotty는 versioned JSON 방향이 있으므로 TOML 전환은 migration 설계 후에 한다.

## 4. kurotty 추천 아키텍처

### PTY Adapter

- 책임: spawn, read/write, winsize, env/cwd, process lifecycle, file descriptor cleanup.
- 입력: profile launch config, resize request, input bytes.
- 출력: PTY byte batches, exit events, resize ack/failure.
- 디버깅: raw bytes는 기본 비활성. metadata-only byte count, timing, resize trace는 기본 debug 가능.

### Escape Parser

- 책임: bytes를 `Printable`, `Control`, `CSI`, `OSC`, `DCS`, `APC` event로 변환.
- 입력: PTY byte batch.
- 출력: parser events with raw sequence id.
- 규칙: private CSI와 SGR을 구분하고, colon subparameters를 보존한다.

### Screen Model

- 책임: parser event를 terminal state로 적용한다.
- 데이터: cells, styles, cursor, modes, scroll margins, main/alt screen, placeholder/content blank, wide lead/continuation.
- 출력: screen mutations, damage regions, render snapshot.

### Scrollback Store

- 책임: bounded scrollback, segment/ring storage, visible origin, search/copy ranges.
- 데이터: immutable-ish line segments, metadata, command span anchors.
- 성능 기준: million-line stress에서 memory 폭증이 없어야 한다.

### Selection Model

- 책임: cell/scrollback 좌표 기반 selection.
- 모드: simple, block, line, semantic word, copy mode cursor.
- 규칙: wide continuation과 synthetic placeholders를 정확히 처리한다.

### Renderer

- 책임: frame scheduling, shaping, glyph atlas, background/cursor/decoration/glyph passes, scissor/damage.
- 입력: `TerminalRenderFrame`.
- 출력: presented frame metrics.
- 금지: renderer가 terminal protocol semantics를 추측하지 않는다.

### Input Method / IME Layer

- 책임: AppKit `NSTextInputClient`, marked text overlay, commit/cancel lifecycle.
- 입력: key events, marked text updates.
- 출력: committed text PTY writes, preedit render overlay.
- 규칙: marked text는 screen model을 mutate하지 않는다.

### Window / Tab / Split Manager

- 책임: windows, top tabs, split tree, focus, pane resize, pane title, session restore.
- 데이터: `WorkspaceSnapshot`, `TabSnapshot`, `PaneSnapshot`, `SplitTree`.
- UX: browser-like tabs + keyboard-first pane focus.

### Config Manager

- 책임: versioned JSON load/save, validation, migration, hot reload.
- 정책: beginner는 GUI, advanced는 file editing.
- lifecycle: live-applied, next-session, launch-only를 키마다 명시한다.

### Theme Manager

- 책임: palette, font, fallback, opacity, blur, tab/split active state tokens.
- 브랜드: cat/kurotty는 app icon, empty state, subtle command palette accent까지. 터미널 viewport에는 장식 금지.

### Shell Integration

- 책임: command start/end, cwd, exit code, prompt/output range, command duration.
- 기본: OSC 7/133 자동 감지.
- 고급: opt-in shell snippets.

### AI Context Layer

- 책임: agent-readable context, command output references, redaction, event log, session status.
- 입력: command spans, pane metadata, notifications, shell integration events.
- 출력: redacted context bundles, user-approved actions.
- 금지: terminal core direct mutation.

## 5. 디버깅 인프라 제안

### PTY resize mismatch

- 로그:
  - trace id
  - old/new viewport px
  - cell width/height
  - derived cols/rows
  - PTY winsize rows/cols/xpixel/ypixel
  - screen rows/cols
  - renderer drawable size
  - coalescing delay
- 테스트:
  - rapid window resize
  - split drag resize
  - font size increase/decrease
  - fullscreen toggle
  - alt screen TUI during resize

### 한글 IME composition 깨짐

- 로그:
  - keyDown metadata
  - `setMarkedText`, `insertText`, `unmarkText`
  - marked text string length/scalars
  - cursor cell and overlay rect
  - PTY write bytes only after commit
- 테스트:
  - English `d` then Korean `안녕`
  - composition backspace
  - composition cancel
  - resize during composition
  - Korean input source command shortcuts

### wide character cell width 오류

- 로그:
  - grapheme cluster
  - Unicode scalars
  - computed terminal width
  - lead/continuation cells
  - fallback font
  - glyph bounds
- 테스트:
  - Hangul
  - CJK ideographs
  - emoji ZWJ
  - combining marks
  - ligatures on/off

### renderer clipping

- 로그:
  - cell rect
  - glyph bounds
  - atlas slot
  - overhang margin
  - scissor rect
  - dirty rect
- 테스트:
  - narrow cells
  - italic/bold overhang
  - box drawing at split boundaries
  - underline/strikethrough
  - emoji clipping

### ANSI escape parser 오류

- 로그:
  - raw sequence id
  - raw bytes escaped
  - parser event type
  - private flag
  - colon params
  - screen mutation summary
- 테스트:
  - DECSTBM `CSI r`
  - private CSI final `m`
  - SGR colon params
  - OSC 7 cwd
  - OSC 8 hyperlink
  - OSC 52 clipboard
  - OSC 133 shell integration

### scrollback corruption

- 로그:
  - segment id
  - visible origin
  - scrollback length
  - alt/main screen mode
  - selection remap
  - command span anchors
- 테스트:
  - `yes`
  - `cat large.log`
  - clear scrollback
  - resize wrapped lines
  - search while output streams

### 빠른 출력 시 frame drop

- 로그:
  - bytes read per batch
  - parser events per batch
  - screen mutations per frame
  - dirty rect count
  - frame build time
  - present time
  - coalesced/dropped frames
- 테스트:
  - `yes`
  - `npm install`
  - `docker logs -f`
  - long AI agent transcript

## 6. 구현 순서

1. PTY/parser/screen model 테스트 고정.
2. Swift scaffold와 Zig model의 truth boundary 정리.
3. `PtyResizeTrace`와 resize protocol 추가.
4. renderer clipping/damage 검증.
5. IME composition overlay 분리.
6. glyph shaping/fallback/atlas contract 강화.
7. scrollback segmented store와 stress tests.
8. tab/split/workspace snapshot 안정화.
9. config validation/hot reload/migration.
10. shell integration v1.
11. command palette/search/copy mode.
12. AI context layer와 secret masking.
13. browser-like non-developer UI polish.
14. `kurotty/DESIGN.md` 유지: 가볍고 유려한 네이티브 UI, 귀엽지만 장난감처럼 보이지 않는 브랜드 가이드.

## 7. 코드 탐색 가이드

### Ghostty

- Rendering: `ghostty/src/renderer/Thread.zig`, `ghostty/src/renderer/generic.zig`
- Screen: `ghostty/src/terminal/Screen.zig`, `PageList.zig`, `Terminal.zig`
- Font: `ghostty/src/font/shape.zig`, `CodepointResolver.zig`, `Atlas.zig`
- Resize/PTY: `ghostty/src/Surface.zig`, `ghostty/src/termio/Exec.zig`
- Shell/security: `ghostty/src/termio/shell_integration.zig`, `ghostty/src/config/Config.zig`

### iTerm2

- UX/session: `iTerm2/sources/PTYSession`, `PTYTab`, `Workgroups`, `SessionNotes`, `DVR`
- Shell integration: `iTerm2/sources/ShellIntegration`, `iTerm2/Resources/shell_integration`
- AI/session status 참고: `iTerm2/sources/ClaudeCode`, `iTerm2/sources/CommandExecution`
- 정확 파일명은 일부 추측이다. 위 디렉토리를 먼저 보고 symbol search로 좁혀야 한다.

### Kitty

- Glyph/atlas: `kitty/kitty/glyph-cache.*`, `kitty/kitty/freetype.c`
- Screen/history: `kitty/kitty/screen.*`, `kitty/kitty/history.*`
- Config: `kitty/kitty/options/definition.py`, `kitty/docs/conf.rst`
- Shell: `kitty/kitty/shell_integration.py`, `kitty/docs/shell-integration.rst`
- Splits/palette: `kitty/kitty/layout/splits.py`, `kitty/kittens/command_palette`

### Alacritty

- Core: `alacritty/alacritty_terminal/src/term`, `grid`, `selection`
- Resize: `alacritty/alacritty_terminal/src/grid/resize.rs`
- Renderer/damage: `alacritty/alacritty/src/display`, `renderer`, `display/damage.rs`
- Config: `alacritty/alacritty/src/config`

### tmux

- 참고 목적: native UI가 아니라 durable session/window/pane mental model.
- 정확 파일명은 추가 탐색 필요. repo root C sources에서 `session`, `window`, `pane`, `layout`, `cmd` symbol을 우선 검색한다.

### cmux

- Session restore: `cmux/Sources/SessionPersistence.swift`, `Workspace.swift`
- Pane tree: `cmux/Packages/macOS/CmuxPanes/.../PaneTreeModel.swift`
- Command palette: `cmux/Packages/macOS/CmuxCommandPalette`
- Browser/workbench: `cmux/Sources/BrowserWindowPortal.swift`, `Panels/BrowserPanel.swift`
- Event/audit: `cmux/Sources/CmuxEventBus.swift`, `CmuxEventLogWriter.swift`

## 8. 실행 체크리스트

- [~] `kurotty/src/pty.zig` stub 상태와 Swift `ShellSession` runtime boundary를 정리한다.
  - 완료: PTY boundary/adapter 기반과 metadata 중심 진단 일부 추가.
  - 남음: Swift/Zig runtime ownership을 단일 실행 경로로 정리.
- [~] parser event와 screen mutation을 분리한 테스트 fixture를 추가한다.
  - 완료: screen/escape/parser 관련 regression test와 command/OSC bridge 테스트 일부 추가.
  - 완료: trace correlation report에 metadata-only timeline summary 추가.
  - 완료: PTY bytes -> parser event -> screen mutation -> render frame stage completeness와 missing stage metadata를 raw payload 없이 진단.
  - 남음: Swift scaffold/Zig core source-of-truth 차이를 live runtime fixture로 드러내기.
- [~] `PtyResizeTrace` 구조와 metadata-only logging을 추가한다.
  - 완료: resize diagnostics 기반 일부 추가.
  - 완료: PTY winsize, screen size, renderer grid/drawable/frame size를 한 ledger summary로 연결.
  - 남음: 실제 resize live path에서 해당 summary를 지속적으로 채집.
- [x] IME marked text overlay를 screen mutation과 분리하고 Korean IME test matrix를 문서화한다.
  - 완료: marked text가 PTY/core로 commit 전 전송되지 않는 회귀 테스트와 input router 기반 추가.
- [~] renderer scissor/dirty rect debug overlay와 pixel probe를 추가한다.
  - 완료: pixel probe, clipping diagnostics, full redraw/dirty invalidation 회귀 테스트, redraw/coalescing policy contract, stable partial dirty rect scheduling/coalescing measurement, drawable-clipped scissor readiness plan 추가.
  - 남음: Metal scissor command path 최적화, live debug overlay polish.
- [~] glyph shaping/fallback contract를 설계하고 CoreText/Metal atlas ownership을 문서화한다.
  - 완료: `TerminalGlyphRun` 기반, glyph atlas/fallback/clipping 회귀 테스트 일부 추가.
  - 완료: shaping/fallback/atlas/clipping readiness를 backend contract로 노출.
  - 완료: CoreText run에서 fallback font identity, glyph id/advance, source fingerprint, reserved atlas key, clipping risk를 도출하는 contract slice 추가.
  - 남음: Metal atlas residency/eviction과 renderer production path integration으로 확장.
- [x] shell integration v1에서 OSC 7/133만 먼저 지원한다.
  - 완료: OSC 7 cwd, OSC 133 prompt/command/output/end, exit code, command span/history, live OSC dispatcher hook.
- [x] shell opt-in metadata를 passive OSC metadata와 분리한다.
  - 완료: shell capability descriptors, passive OSC support와 opt-in snippet metadata 구분, OSC 7 path encoding, bash CWD-only conservative capability.
  - 완료: per-session opt-in evidence에서 baseline support와 installed integration을 구분.
  - 완료: raw output 없이 UI/audit/AI surfaces가 소비할 수 있는 metadata-only evidence row로 passive OSC와 opt-in shell integration 구분 노출.
- [x] AI context export는 redaction/audit/log cap 없이 구현하지 않는다.
  - 완료: `AIContextLayer`, secret redaction, capped event log, AI command context bridge, raw output default-off 및 approval gate.
- [x] settings validation을 preferences UI에 연결한다.
  - 완료: `PreferencesValidationPresenter`, invalid JSON/settings error 표시, error 상태 save 차단.
- [x] command palette를 app menu/window에 연결한다.
  - 완료: `CommandPalettePresenter`, AppKit palette window, `Cmd+Shift+P`, command dispatch bridge.
- [~] command UX를 command registry 중심으로 정리한다.
  - 완료: palette aliases/search tokens를 command registry metadata로 이동하고 ambiguous duplicate token 제거.
  - 완료: command spans, search/copy/fold/replay backend commands와 approval policy를 command registry에 추가.
  - 완료: command-span command lookup, palette search model, fold/search/copy-reference/replay dispatch model이 command registry를 공유.
  - 완료: command-span palette subtitle, explicit approval flag, replay-safe search token을 노출.
  - 완료: AppKit command palette에 command-span rows와 별도 span-command handler path 추가.
  - 남음: selected command span과 실제 fold/search/copy/replay 화면 동작 연결.
- [~] workspace/session snapshot을 layout-only로 먼저 저장한다.
  - 완료: `WorkspaceSnapshot`, atomic store, `WorkspaceSnapshotCoordinator`, app menu save flow.
  - 남음: process restore, command replay, session restore UX는 explicit opt-in 이후.
- [x] OSC 52 보안 정책을 runtime OSC 경로에 연결한다.
  - 완료: `TerminalOSC52Policy`, `TerminalOSCDispatcher`, live `TerminalSurfaceView` dispatch hook. Clipboard mutation은 아직 하지 않음.
- [x] scrollback pressure diagnostics를 raw row text 없이 노출한다.
  - 완료: `BoundedScrollbackRows.Diagnostics`, `TerminalScrollbackDiagnosticsSummary`, raw text 미노출 테스트.
- [~] segmented scrollback store와 million-line stress test를 구현한다.
  - 완료: segmented/bounded scrollback 기반, export window metadata summary, million-line stress target.
  - 완료: search/copy/AI context reference live access window availability summary 추가.
  - 완료: disk-backed/off-main 준비용 codable segment persistence metadata와 spill candidate summary 추가.
  - 완료: search/copy mode가 사용할 수 있는 live read-window descriptor와 retained-row live access adapter 추가.
  - 남음: live scrollback path 전체를 segmented store 중심으로 정리하고 UI/search/copy mode와 연결.
- [~] command folding/search/replay UI를 구현한다.
  - 완료: fold/search/replay command-span palette presentation metadata와 approval readiness model 추가.
  - 남음: 실제 fold/search/replay AppKit 화면 동작 연결.
- [~] browser-like toolbar/search/copy mode/quick terminal UX를 다듬는다.
  - 완료: 설치 없는 shell integration onboarding step model 추가.
  - 완료: 터미널 URL 링크를 Cmd 없이도 항상 밑줄/hover/손가락 커서로 표시하고, 실제 열기는 기존 확인 흐름으로 유지.
  - 완료: split pane `x`, tab `x`, tab `+` chrome button에 손가락 커서와 명확한 hover 배경을 적용.
  - 완료: tab/button tracking area 경계에서 발생할 수 있는 hover 배경 깜빡임을 bounds 검사로 안정화.
  - 남음: 실제 toolbar/search/copy mode/quick terminal 화면 polish.
- [~] `kurotty/DESIGN.md`에 native UI, 브랜드, non-developer onboarding 가이드를 업데이트한다.
  - 완료: native UI, command UX, AI action boundary, diagnostics 방향 일부 업데이트.
  - 남음: 실제 toolbar/search/copy mode/quick terminal 화면 설계와 non-developer onboarding polish.
- [~] AI agent approval/action API와 context reference UI를 구현한다.
  - 완료: redacted context references, copyable command span locator, action request/approval metadata, audit metadata, terminal core direct mutation 금지 검증.
  - 완료: visible context reference dialog-flow model, approve/deny decision model, approval-gated action dispatch integration.
  - 완료: approval dialog presentation row model, context reference summary, command-output approval state 표시 metadata 추가.
  - 남음: 실제 AppKit approval dialog presentation과 context reference UI rendering.
