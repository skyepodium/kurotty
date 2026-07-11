# Kurotty Agent Rules

These rules apply to the whole repository. Follow the closest `AGENTS.md` first if a narrower one is added later.

## Scope

- Kurotty is a macOS Swift/AppKit + Zig + Metal terminal emulator.
- Swift/AppKit owns windows, menus, tabs, splits, keyboard input, IME, pasteboard, shell lifecycle, preferences, and the bridge to Zig.
- Zig owns the target terminal state engine: parser, grid, scrollback, PTY boundary, renderer orchestration, metrics, allocation, and C ABI exports.
- The current AppKit surface still contains a Swift screen/parser scaffold until Zig becomes the live screen source of truth.
- Metal owns GPU rendering: glyph atlas, instance buffers, cell/background/cursor/decoration drawing, and shader behavior.
- Do not edit source code while doing documentation-only work.
- Do not revert user changes. Read the worktree first and keep diffs small.

## Code Style

- Before fixing a bug, identify the root cause with concrete evidence first. Do not patch symptoms with hardcoded strings, app-name checks, screenshot-specific rules, guessed TTY paths, or one-off heuristics when the real protocol, state, lifecycle, or ownership boundary can be fixed.
- Prefer guard clauses and early returns. Handle unsupported state, empty input, missing resources, invalid dimensions, and unavailable GPU/ABI resources at the top of the function.
- Keep the happy path shallow. Split nested parser, rendering, shell, or settings logic into named helpers when branching grows.
- Treat files above roughly 600 lines as split candidates when touching them for behavior work. Do not split only for line count, but avoid growing large renderer, parser, settings, or window-controller files without a staged extraction plan and tests.
- Use direct names. Avoid abbreviations unless they are terminal standards (`CSI`, `OSC`, `PTY`, `SGR`, `ABI`, `IME`, `GPU`).
- Keep AppKit entry points thin. `AppDelegate`, menu wiring, and window controllers should compose services/views instead of owning terminal behavior.
- Keep Zig modules explicit and allocation-aware. Functions that allocate must make ownership and cleanup visible at the call site.
- Keep Metal shader structs and Swift buffer layouts in sync. Any layout change requires a matching regression test or documented manual verification.
- Avoid new global mutable singletons. Long-lived caches, timers, notification observers, dispatch sources, file descriptors, PTYs, Metal resources, and native handles must have a clear owner, cleanup path, and capacity or lifecycle contract.

## Constants And Tokens

- Do not add hardcoded magic values. Put new numeric and string values behind named constants, enums, or token objects before use.
- Include units in names: `*_PX`, `*_MS`, `*_MICROS`, `*_ROWS`, `*_COLUMNS`, `*_BYTES`, `*_COUNT`, `*_RATIO`.
- Keep domain constants separate from design tokens.
- Terminal protocol numbers are allowed only when named by protocol meaning. Examples: SGR color mode, escape byte, delete byte, default cursor movement count.
- UI values such as font sizes, padding, colors, atlas dimensions, cursor thickness, scroll sensitivity, and window sizes belong in design tokens or renderer constants.
- Storage keys, settings keys, bundle resource names, dylib paths, dispatch queue labels, menu titles, and command strings must be named constants.
- Test fixtures may define local named constants. Do not hide unexplained values inside assertions.

## Dependencies

- Prefer Swift/AppKit, Zig stdlib, Metal, and existing repo utilities before adding dependencies.
- A new dependency requires a short written reason covering maintenance health, license, security posture, transitive size, native/bundle impact, and the removal plan if it becomes unmaintained.
- Do not add a dependency only to replace a small standard-library or existing local helper use.

## Settings JSON

- User-editable settings must be modeled as versioned JSON, not scattered `UserDefaults` keys.
- The canonical user settings file is `Application Support/Kurotty/settings.json`.
- Settings need typed defaults, schema versioning, validation, and migration rules before they affect rendering, shell, or PTY behavior.
- Every settings key must declare its lifecycle contract: live-applied, next-session, or launch-only.
- Do not store per-session shell launch state in the global settings JSON unless it is explicitly an app-wide default. Session state belongs with the pane or shell lifecycle.
- Do not perform filesystem existence checks during settings load/save on the main actor. Validation that touches the filesystem must be isolated from UI-thread config serialization or deferred to the launch boundary.
- Keep settings keys stable and documented. Rename keys only with a migration path.
- Do not persist secrets, raw terminal output, pasted text, command history, or environment dumps in settings.

## Project Structure

- `Sources/KurottyApp/`: Swift/AppKit shell, Metal host view, app lifecycle, input, preferences, and Zig bridge.
- `Sources/KurottyApp/Shaders/`: Metal shader source loaded by SwiftPM resources.
- `src/`: Zig terminal core and public module exports.
- `tests/`: Zig core tests and Swift rendering regression tests.
- `bench/`: benchmark smoke checks.
- `stress/`: high-volume stress gates.
- `docs/`: architecture, ABI, testing, and other developer documentation.
- Keep cross-language contracts in docs and tests when changing `src/abi.zig`, `CoreBridge`, shader buffer layouts, or settings schema.
- Keep platform-specific code behind platform adapters. AppKit, Darwin PTY, macOS shell integration, notifications, and Metal setup belong in the macOS app layer; the Zig terminal core and protocol logic must stay portable enough for future Linux and Windows frontends.
- Do not introduce new macOS command-line tool dependencies outside macOS-only scripts or adapters.

## Terminal Protocol And Rendering

- Do not treat every CSI sequence with final byte `m` as SGR. SGR is only the non-private `CSI ... m` family; private CSI variants such as `CSI > 4 ; 2 m` belong to protocols like Kitty keyboard mode and must not mutate text style.
- Preserve CSI parameter structure when parsing. Semicolon-separated parameters and colon subparameters have different meaning. For SGR, keep elements such as `4:0`, `4:3`, and `38:2::r:g:b` intact so underline and color handling cannot be confused with unrelated style codes.
- The Claude Code startup regression was caused by interpreting `ESC[>4;2m` as SGR underline (`4`) plus dim (`2`). The fix is protocol classification: private CSI `m` is ignored by SGR handling, while normal `CSI 4;2m` remains valid SGR.
- Do not special-case applications, versions, prompt text, or art output when fixing terminal protocol behavior. Capture the PTY stream when possible, identify the protocol sequence, and fix the parser/state model generally.
- Screen cells need to distinguish placeholder blanks produced by erase, clear, scroll, insert, or delete operations from printable spaces emitted by the program. Text decorations such as underline, strikethrough, and link hover should render for real content cells, not for placeholder blanks.
- Keep terminal visual state in the screen/model layer, not in renderer-only heuristics. The renderer may skip drawing placeholder decorations, but it should not infer protocol semantics from literal text like `" "` or from a specific TUI layout.
- Rendering regressions involving TUIs should be checked against a reference terminal such as Ghostty and backed by PTY sequence evidence when possible. Avoid relying only on screenshots when escape-sequence classification is in question.
- Regression coverage for protocol/rendering fixes should include executable tests for parsed CSI structure, SGR/private-CSI classification, and cell decoration policy, then broaden to `swift test` and an installed `.app` smoke check for user-visible renderer behavior.

## macOS IME Input

- macOS IME composition belongs to AppKit. Do not manually compose Hangul jamo, normalize partial jamo into syllables, or hide pending jamo in Kurotty code.
- `keyDown` for printable text must offer the event to `NSTextInputContext` first. The required order is `view.inputContext?.handleEvent(event)` and only then a fallback such as `interpretKeyEvents([event])` if AppKit did not handle it.
- Do not send `event.characters` or `charactersIgnoringModifiers` directly to the PTY for printable text when an IME path may own the event.
- PTY writes for text input must come from confirmed `insertText` or from explicit terminal control keys only. `setMarkedText` is preedit state and must not write to the PTY.
- `setMarkedText`/marked text is a visual composition overlay; clear or redraw it without mutating the terminal screen buffer as committed text.
- Input-source changes may discard stale AppKit marked text, but must not synthesize replacement text.
- The critical regression case is: type `d` in English, switch to Korean IME, type `안녕`; PTY output must be `d안녕`, not `dㅇㅏㄴ녕` or any compatibility-jamo sequence.
- IME verification must include real event-flow evidence when possible: `keyDown`, `setMarkedText`, `insertText`, `unmarkText`, and PTY write logs. Source-shape tests alone are not enough to claim an IME fix.
- If `main` and `develop` appear to differ on Korean IME behavior, first compare branch heads and confirm the running binary was rebuilt from the checked-out branch. The 2026-07-01 investigation found `main` and `develop` had identical IME source while stale experimental binaries made behavior appear branch-specific.
- Korean IME behavior must be validated against the installed app bundle, not only `.build/debug/kurotty`. The debug executable is a raw terminal-launched binary, while `/Applications/kurotty.app` runs through LaunchServices with an app bundle, `Info.plist`, bundle identifier, activation policy, code signature, resources, and bundled Zig dylib. AppKit/IMK can produce a different `keyDown`/`setMarkedText`/`insertText` sequence between those contexts.
- For IME debugging, use `./scripts/install-app.sh`, quit any existing Kurotty process, then open `/Applications/kurotty.app`. If input logs are needed for the installed app, export the debug flag into the launch environment before opening it, for example `launchctl setenv KUROTTY_DEBUG_INPUT_CLIENT 1`, then inspect the installed app's event-flow logs.
- Do not revive the old committed-jamo repair from `2225300` (`composingCompatibilityHangulJamo`, `pendingCompatibilityJamo`, or buffering a leading `ㅇ` after `keyboardSelectionDidChangeNotification`) as a first-line fix. That masks AppKit/IMK event ordering by synthesizing Hangul inside Kurotty and previously caused regressions such as `dㅇㅏㄴ`, `dㅏㄴ`, and duplicated text after input-source switches.
- When Korean IME regresses, treat the event-flow log as the source of truth: determine whether AppKit is sending `insertText("안")`, `setMarkedText` preedit updates, or premature compatibility jamo commits before changing code. Fix the routing/lifecycle boundary that makes AppKit emit the wrong event sequence; do not patch the PTY text after the fact unless there is fresh evidence and a written reason.

## macOS Notifications

- Notification support is a Kurotty product feature, not a per-developer workstation setup. A clean install on another Mac must receive notifications emitted through supported terminal protocols without editing tool configuration, shell dotfiles, or third-party installations.
- In this contract, the **producer** is the child application that emits terminal bytes, for example a CLI/TUI emitting OSC 9 or OSC 777. Kurotty is the consumer and presenter. Kurotty cannot preserve a title or response body that the producer did not send.
- The implementation must be producer-neutral. Never branch on names such as Codex, Claude Code, Grok, their executable filenames, model names, greetings, prompt text, or screenshot content.
- Never fix notification behavior by writing `~/.codex/config.toml`, `~/.grok/config.toml`, installing a per-user hook, patching another application, guessing `/dev/tty` or `/dev/ttys*`, or embedding a username, home directory, checkout path, `/Applications` path, PID, socket path, or machine-specific process ancestry.
- Platform suffixes such as `-aarch64-apple-darwin` and `-macos-aarch64` must not be removed with a suffix table. Resolve the producer label from protocol metadata or the foreground process invocation name (`argv[0]`); use the kernel executable basename only as a last-resort fallback.

### Notification source taxonomy and precedence

Keep each source distinct and preserve its semantics:

1. **Explicit terminal notification:** OSC 9, OSC 777 `notify;title;body`, or supported rich OSC 1337. Parse protocol fields into a typed event and deliver those fields without scraping the screen. This is the Ghostty reference model: a parsed OSC command becomes an explicit desktop-notification event.
2. **Producer-neutral bridge notification:** a process that cannot write to the PTY may use Kurotty's documented Unix-socket/CLI bridge and its versioned JSON fields. The bridge must be resolved from the running app environment, never from a hardcoded install path.
3. **Shell command completion:** OSC 133 shell-integration boundaries provide command metadata such as working directory, exit status, and duration. They do not manufacture an AI response body.
4. **BEL:** sound plus a deliberately generic Kurotty fallback notification. BEL carries no title, subtitle, body, task identity, or completion payload, so the fallback must always be `Kurotty` / `Check your terminal.` and must never scrape the screen or claim producer-supplied content or task completion.

Some producers select a protocol from a terminal-brand support table. For example, Grok Build 0.2.93 documents Ghostty as OSC 777, iTerm2 as OSC 9, and unknown terminals as BEL. Because Kurotty identifies itself truthfully as `TERM_PROGRAM=Kurotty`, a producer that does not recognize Kurotty may choose BEL even though Kurotty can parse richer OSC protocols. Do not fix this by impersonating Ghostty/iTerm2, rewriting producer configuration, or treating BEL as a payload-bearing completion event. The durable resolution is producer support for Kurotty or a producer-neutral capability-negotiation standard.

OSC 0/1/2 window-title sequences, including BEL-terminated title sequences, are title metadata and are never completion events. Numeric OSC 9 progress extensions such as OSC `9;4;...` are progress data, not desktop messages.

### Notification presentation contract

- The macOS sender is already Kurotty. Explicit OSC/bridge notifications must not repeat `Kurotty` merely to identify the sender. The payload-free BEL fallback is the deliberate exception and uses the fixed title `Kurotty`.
- **Explicit OSC fields:** preserve the producer-supplied title, subtitle, and body according to that protocol. For OSC 9, the payload is the body and the title is intentionally empty at the protocol boundary, matching Ghostty.
- **Shell completion fields:** use only OSC 133 command metadata such as exit code, duration, command text, and working directory. Never manufacture an interactive-program response from rendered rows.
- Never use submitted input, rendered screen text, a model/status/footer row, prompt, warning, or repaint fragment as an explicit notification body.
- Explicit protocol layouts retain their protocol semantics. In particular, OSC 9 has no producer title field: keep its title empty, use its payload as the body, and let the macOS sender identity plus surface subtitle provide context, as Ghostty does.
- Example: OSC 777 `notify;Example-runner;Release notes are ready.` preserves title `Example-runner` and body `Release notes are ready.`; the surface title supplies subtitle context only when the protocol has no subtitle.

### No screen-quiescence completion inference

- Do not infer an interactive turn completion from output byte counts, timers, a quiet interval, cursor position, or rendered screen rows.
- A long-running TUI can pause many times before its turn is complete. Marking the first pause complete causes premature notifications and discards the later real response.
- If a long-running producer does not emit OSC 9/777/1337 or use the bridge, Kurotty does not possess a trustworthy generic turn-completion event. Preserve that protocol boundary instead of adding product-specific scraping.

### Runtime context rules

- Working directory comes from the Kurotty surface's own OSC 7/shell-integration state. Never query an unrelated globally active tmux pane; it may belong to another terminal and can overwrite the subtitle with the wrong directory.
- Program identity comes from Kurotty's own PTY foreground process. Read `argv[0]` through platform process metadata and use its basename before the internal executable name. For example, invocation `codex` may execute `codex-aarch64-apple-darwin`, but the displayed title is `Codex` because `argv[0]` is `codex`.
- Process metadata is fallback context only. Explicit notification fields remain authoritative.

### Verification requirements

- Parser tests must feed raw OSC bytes for every supported notification protocol and confirm title/body field preservation and progress-sequence exclusion. Surface/notifier regression tests must separately confirm BEL's payload-free generic fallback behavior.
- Regression tests must prove ordinary PTY output and output quiescence do not create desktop notifications.
- Runtime-context tests must prove `argv[0]` wins over an internal platform-qualified executable path and OSC 7 directory basename wins over unrelated external state.
- Run the smallest relevant tests, then `swift test`, `git diff --check`, a production app build/install, `codesign --verify --deep --strict`, and an installed-app smoke test. Unit tests alone do not prove macOS notification presentation.

- `UNUserNotificationCenterDelegate` callbacks are delivered on UserNotifications-owned queues, not the main actor. Do not mark the delegate object itself `@MainActor`.
- Keep notification delegate methods nonisolated and side-effect narrow.
- Do not create Swift concurrency tasks from UserNotifications delegate callbacks to complete the callback on `MainActor`. In release-installed apps this can crash on `com.apple.usernotifications.UNUserNotificationServiceConnection.call-out` with `_swift_task_checkIsolatedSwift` / `dispatch_assert_queue`.
- Call the UserNotifications `completionHandler` exactly once on the callback queue before touching AppKit. For actions that need UI focus, complete the callback first, then use `DispatchQueue.main.async { ... }` for the AppKit work.
- Do not move `completionHandler()` inside `Task { @MainActor in ... }`, `Task { await MainActor.run { ... } }`, or any async path whose executor may differ from the UserNotifications callback queue.
- Regression tests for notification response handling must assert this source shape: nonisolated delegate callback, callback completion before AppKit focus, no `Task { @MainActor in`, no `Task { await MainActor.run`, and an explicit `DispatchQueue.main.async` UI hop.
- Installed app notification fixes must be validated against an `.app` bundle, not only `swift run`, because the development fallback path can hide UserNotifications delegate behavior.

## macOS AppKit / Metal Executor Boundaries

- External framework callbacks are not automatically on the main actor, even when the object that registered them is main-actor isolated. Treat Metal, UserNotifications, dispatch source, PTY, file descriptor, and other system callback queues as nonisolated until proven otherwise.
- Do not pass a closure formed in `@MainActor` context directly to `MTLCommandBuffer.addCompletedHandler`, UserNotifications delegate callbacks, or similar framework-owned completion queues if the closure captures `self`, AppKit objects, renderer state, or any main-actor isolated function.
- Metal command buffer completion handlers run on Metal-owned queues such as `com.Metal.CompletionQueueDispatch`. Calling main-actor isolated code from that handler can crash release-installed apps with `_swift_task_checkIsolatedSwift` / `dispatch_assert_queue`.
- For Metal presentation callbacks, create a nonisolated completion handler that does no AppKit or renderer mutation on the Metal queue. Capture only a sendable handoff wrapper, then use `DispatchQueue.main.async { ... }` for the UI/frame-presented callback.
- Avoid `Task { @MainActor in ... }`, `Task { await MainActor.run { ... } }`, and `MainActor.assumeIsolated { ... }` inside framework-owned callback queues unless there is a written proof that the callback is already executing on the main actor. Prefer explicit `DispatchQueue.main.async` for AppKit UI hops from legacy callback APIs.
- If Swift 6 reports a sendability error for a callback that is intentionally only invoked after a main-queue hop, use a tiny, narrowly named `@unchecked Sendable` wrapper for the handoff closure. Do not mark broad view/controller types as unchecked sendable.
- Regression tests for this class of crash should assert source shape: no direct `[weak self]` capture in Metal completion handlers, completion handler construction is nonisolated, and AppKit/main-actor work is reached only through an explicit main-queue hop.
- Installed app crashes must be diagnosed from the crash queue and binary frame context, not from assumptions based on debug builds. A crash on `com.Metal.CompletionQueueDispatch` points at Metal completion handlers; a crash on `com.apple.usernotifications.UNUserNotificationServiceConnection.call-out` points at notification delegate callbacks.

## Assets

- `kurotty-profile.png` is the source image for the Kurotty cat icon. Preserve it as an input asset and do not overwrite, resize, crop, delete, or regenerate it during icon replacement work.
- Treat `kurotty-profile.png` as the only human-edited source of truth for the app icon. Every shipped icon artifact must be derived from that source through the project scripts, not copied from Finder, Dock, Cmd+Tab/App Switcher, notification screenshots, installed bundles, or previous generated outputs.
- `kurotty.png` and `Sources/KurottyApp/Resources/kurotty.png` are generated icon outputs. They must always contain matching bytes.
- Never regenerate an icon from a previously generated `kurotty.png`. Repeated crop/resize passes compound the scale error and make the cat progressively smaller. Delete generated outputs if needed, then rebuild them exactly once from `kurotty-profile.png`.
- Kurotty app icon PNG outputs must use this contract:
  - PNG canvas: 1024 x 1024 px.
  - Color/alpha: RGBA.
  - Visible icon tile: 825 x 825 px, centered in the 1024 px canvas at offset (99, 99).
  - Transparent padding: everything outside the centered visible tile is transparent.
  - Visible tile content: scale the full square source image uniformly into the 825 x 825 px tile. Do not crop the cat, do not independently scale the foreground cat, and do not add extra internal padding.
  - Visible tile corner radius: preserve the current macOS-style radius ratio, `224 / 1024`; for an 825 px visible tile this is about 180 px.
- The 825 px visible tile is an observed Dock calibration for this project: a full 1024 px visible tile rendered around 65 px in the Dock, while 790 px rendered slightly small; 825 px is the current target for an approximately 50 px perceived Dock icon.
- Dock sizing is a two-part contract: keep the PNG visible tile at 825 px and keep the SwiftPM PNG fallback `NSImage` assigned a 50 x 50 pt logical size before setting `NSApp.applicationIconImage`.
- Do not apply the 50 x 50 pt logical size to the installed `.icns` image. Installed apps must load `kurotty.icns` with its original multi-resolution representations intact; otherwise Settings, Force Quit, Cmd+Tab/App Switcher, and notification surfaces can inherit a tiny app icon even when the `.icns` ladder is correct.
- Keep the cat artwork visually readable inside the icon. If the icon appears too large or too small in the Dock, adjust only the centered visible tile size from `kurotty-profile.png`; never shrink or crop just the cat foreground.
- Keep the README image markup at 400 x 400 unless intentionally changing the README layout.
- Do not ship the installed macOS app with only `kurotty.png` as `CFBundleIconFile`. A single PNG can look acceptable in the Dock but be upscaled or cached poorly in Cmd+Tab/App Switcher and other LaunchServices surfaces.
- Installed `.app` bundles must generate and include `Contents/Resources/kurotty.icns` from the current 1024 x 1024 generated `kurotty.png` during install/package creation.
- The `.icns` must contain the full iconset ladder: `16x16`, `16x16@2x`, `32x32`, `32x32@2x`, `128x128`, `128x128@2x`, `256x256`, `256x256@2x`, `512x512`, and `512x512@2x`.
- `CFBundleIconFile` in the installed app's `Info.plist` must point to `kurotty.icns`, not the raw PNG. Keep the raw PNG only as a resource fallback/readme asset, not as the system app icon file.
- At runtime, `NSApp.applicationIconImage` should prefer the installed main-bundle `kurotty.icns` without resizing it; fall back to the SwiftPM resource PNG only for development/package-resource contexts where the `.icns` is unavailable, and apply the 50 x 50 pt logical size only to that PNG fallback.
- After replacing the source artwork with another image, regenerate the canonical PNG outputs first, then regenerate the `.icns` from that fresh PNG exactly once. Do not create `.icns` files from stale installed bundles, screenshots, Dock/App Switcher captures, or previously downscaled outputs.
- Keep icon replacement one-way and reproducible: source image -> canonical 1024 px PNG outputs -> full `.icns` ladder -> installed app bundle -> runtime load. Do not manually resize the runtime `NSImage` for installed apps, do not hand-edit the iconset, and do not let generated assets become the next source asset.
- Installation scripts should refresh LaunchServices for the installed app after copying the bundle so macOS does not keep showing a stale or low-resolution icon cache.
- `scripts/install-app.sh` must run `scripts/verify-icon-bundle.sh` before reporting success. If that verifier fails, the app is not considered installed correctly even if the bundle exists in `/Applications`.
- After changing icon assets, verify all of the following before handoff:
  - `kurotty-profile.png` still exists and is unchanged unless the user explicitly requested changing the source.
  - `kurotty.png` and `Sources/KurottyApp/Resources/kurotty.png` are byte-identical.
  - Both generated PNGs are 1024 x 1024 px and have alpha.
  - The generated alpha bounding box is exactly 825 x 825 px at `(99, 99, 924, 924)`.
  - The installed app contains `Contents/Resources/kurotty.icns` and `Info.plist` has `CFBundleIconFile` set to `kurotty.icns`.
  - `iconutil -c iconset` on the installed `kurotty.icns` yields every required iconset representation from 16 px through 1024 px.
  - `scripts/verify-icon-bundle.sh /Applications/kurotty.app` passes.
  - `swift build` succeeds and the SwiftPM resource bundle copy of `kurotty.png` matches `Sources/KurottyApp/Resources/kurotty.png`.
  - Reinstall and restart Kurotty after the build so Dock, Cmd+Tab/App Switcher, and LaunchServices use the new bundled `.icns`.

## Release Packaging

- `VERSION` is the single source of truth for the next Kurotty release version.
- Do not hardcode future release numbers such as `.5` in `README.md`, scripts, workflows, tests, or app code. Bump `VERSION` first, then let scripts and docs derive names from it.
- Do not trigger the GitHub Actions release workflow for a release unless the user explicitly asks for workflow-based publishing. If local release credentials or signing materials are present, build, sign, notarize, staple, and upload release assets locally.
- Do not create, move, delete, or re-push release tags as an indirect way to publish when the user asked for local release handling. Tag operations are separate release actions and need explicit instruction.
- The normal public release flow is:
  - land the verified change on `develop`;
  - fast-forward or merge `develop` into `main`;
  - create the tag from `main` as `v$(cat VERSION)`;
  - push `main`, `develop`, and the tag;
  - let the release workflow build the universal app, sign it with Developer ID, notarize it, staple it, generate the Sparkle appcast, and upload release assets.
- Workflow-based publishing depends on repository secrets for Developer ID signing, notarization, and Sparkle signing. Do not print, log, commit, or copy private keys, passwords, API keys, provisioning files, or exported signing identities.
- `scripts/install-app.sh` and `scripts/package-release.sh` must read `VERSION` for `CFBundleShortVersionString` unless a tag/version argument explicitly overrides the release package script.
- The installed app About panel must display the bundle `Info.plist` version generated by the install/package scripts, not a stale development fallback.
- `AppConstants.Bundle.developmentVersion` is only a fallback for `swift run` or non-bundled development contexts. It must not contain an alpha release number.
- Release assets must include the versioned Universal DMG `kurotty-$VERSION-macos-universal.dmg`, the stable direct-download alias `kurotty-macos-universal.dmg`, `SHA256SUMS`, and `appcast.xml`.
- README download links should point at `https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg` so users download the current DMG directly without hardcoding the release version.
- Universal release packages must include both `arm64` and `x86_64` slices for `Contents/MacOS/kurotty` and `Contents/Resources/libkurotty_core.dylib`.
- DMGs must contain `kurotty.app` and an `/Applications` symlink so users can install by dragging the app, matching standard macOS distribution UX.
- Release code must resolve packaged resources through the installed `.app` layout first. Do not rely on SwiftPM build-directory fallbacks to prove a packaged app works; those paths do not exist after Sparkle or DMG installation.
- `scripts/verify-release-artifact.sh` is a mandatory publication gate. It must mount the final DMG, copy `kurotty.app` into a fresh temporary directory outside the repository and SwiftPM build tree, verify the version, signatures, Universal slices, DMG layout, and run the copied executable with `--release-artifact-smoke-test`.
- `--release-artifact-smoke-test` is an app-owned installed-layout contract. It must load the packaged SwiftPM resource bundle, icon, shell integration files, `libkurotty_core.dylib`, Sparkle framework, and bundle version without opening the normal UI. Missing or unreadable release resources must return a nonzero exit status.
- Never weaken the release artifact smoke test to make packaging pass. Fix the app layout, resource lookup, signing, or package construction that violates the contract.
- GitHub Release upload must remain ordered after the packaged-artifact verification step. A failed smoke, structure, signature, architecture, Gatekeeper, notarization, or stapler check must make publishing impossible.
- Tags for public releases must be created from `main` as `v$(cat VERSION)`. The release workflow must reject tags that are not contained in `main`.
- Sparkle automatic updates must use the signed `appcast.xml` from the release assets. The appcast enclosure URL must point to the versioned DMG, not a stale local `dist/` file or a previous release asset.
- Before publishing a new release, remove stale local release outputs or use an isolated work directory so old DMGs, old appcasts, and old signatures cannot be re-uploaded.
- After a workflow release finishes, verify the GitHub release assets instead of trusting local files:
  - download `kurotty-$VERSION-macos-universal.dmg`, `kurotty-macos-universal.dmg`, `SHA256SUMS`, and `appcast.xml` from the release;
  - run `cd <download-dir> && shasum -a 256 -c SHA256SUMS`;
  - run `spctl -a -vvv -t open --context context:primary-signature kurotty-$VERSION-macos-universal.dmg` and confirm it is accepted as a notarized Developer ID artifact;
  - run `xcrun stapler validate kurotty-$VERSION-macos-universal.dmg`;
  - mount the DMG, copy out `kurotty.app`, and run `codesign --verify --deep --strict --verbose=2` plus `spctl -a -vvv -t exec` on the copied app;
  - inspect `appcast.xml` and the public `https://github.com/skyepodium/kurotty/releases/latest/download/appcast.xml` to confirm the current version, versioned DMG URL, and Sparkle EdDSA signature are present.
- After release packaging changes, verify:
  - `swift test` passes.
  - `bash -n scripts/install-app.sh scripts/package-release.sh scripts/verify-release-artifact.sh` passes.
  - `./scripts/package-release.sh` creates `dist/kurotty-$(cat VERSION)-macos-universal.dmg` and `dist/kurotty-macos-universal.dmg`.
  - `cd dist && shasum -a 256 -c SHA256SUMS` passes.
  - `lipo -info` on the packaged app executable and `libkurotty_core.dylib` reports both `x86_64` and `arm64`.
  - Mounting the DMG shows `kurotty.app` and `Applications -> /Applications`.
  - `scripts/verify-icon-bundle.sh` passes on the packaged app.
  - `scripts/verify-release-artifact.sh dist/kurotty-$(cat VERSION)-macos-universal.dmg $(cat VERSION)` passes from the final DMG, not from the intermediate `.build/release-package/kurotty.app`.

## Testing And Verification

- Run the smallest relevant gate first, then broaden before claiming completion.
- Source-shape tests may guard wiring and regressions, but do not prove behavior by themselves. Pair them with executable behavior tests, integration tests, or documented manual evidence before claiming a user-visible fix.
- Zig parser/grid/scrollback/metrics/renderer changes require `zig build test`.
- Zig ABI, build, or package changes require `zig build`.
- Performance-sensitive Zig changes require `zig build bench`; scrollback changes also require `zig build stress-scrollback`.
- Allocation and ownership changes require `zig build leak-check`.
- Swift/AppKit/Metal changes require `swift build` and relevant `swift test` coverage.
- UI or rendering changes require visual evidence when automated screenshot coverage is missing.
- Documentation changes that list commands must use commands that were run successfully in the current branch, or explicitly mark them as unverified.

## Performance

- Preserve low latency and bounded memory as product requirements, not optional cleanup.
- Avoid unnecessary allocations on parser, PTY read, input, frame build, glyph atlas, and draw paths.
- Do not rebuild buffers, textures, glyphs, or screen rows unless input, layout, damage, or settings require it.
- Keep damage tracking narrow. Full-surface redraws need a documented reason and should be treated as scaffold debt.
- Add before/after evidence for performance work: benchmark output, stress result, latency metric, allocation evidence, or frame/render observation.
- Caches and scrollback-like buffers need explicit bounds, eviction behavior, and invalidation keys. Avoid `removeFirst`/front-removal patterns on large arrays in hot paths; prefer ring buffers, indexed windows, or ownership in the Zig core.
- Native bridge calls should keep payloads compact and avoid duplicating parser/grid work without a documented migration reason.
- Release packaging should avoid duplicate assets, unused resources, unstripped binaries, and large transient artifacts unless they are intentionally retained for debugging.

## Security And Privacy

- Treat terminal input, output, pasteboard contents, environment variables, paths, and command history as sensitive.
- Do not log raw terminal streams, pasted text, shell commands, environment dumps, or PII.
- Do not commit secrets, private keys, tokens, provisioning files, or real user settings.
- Sanitize paths and dynamic library loading. Do not add broad search paths or network loading for the Zig core.
- Shell/PTTY code must close file descriptors, clean up child processes, and avoid leaking handles across exec boundaries.
- Entitlements, permissions, sandbox changes, and file access expansion require documentation of purpose and risk.

## Code Review Standards

- Review diffs before handoff. Remove accidental source, generated, build artifact, and cache changes.
- Check public contracts separately: C ABI, settings schema, shader buffer layouts, terminal protocol behavior, and user-visible preferences.
- Every PR summary should include intent, changed files, verification commands, and remaining risk.
- PR descriptions for AI-assisted work should include a short Participants section naming human and AI contributors or agents involved.
- Review comments require technical validation. If a suggestion is not applied, document the reason briefly.
- Do not mix unrelated cleanup with behavior changes.
