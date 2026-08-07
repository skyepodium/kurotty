import Foundation
import KurottyCore

enum AppConstants {
    enum Application {
        static let initialNotificationDelaySeconds: TimeInterval = 1
    }

    enum Bundle {
        static let displayName = "kurotty"
        static let iconResourceName = "kurotty"
        static let iconResourceExtension = "png"
        static let installedIconExtension = "icns"
        static let applicationIconSizePT: CGFloat = 50
        static let developmentVersion = "development"
        static let developmentBuild = "dev"
        static let sparkleFeedURL = "https://github.com/skyepodium/kurotty/releases/latest/download/appcast.xml"
        static let sparklePublicKeyInfoKey = "SUPublicEDKey"
        static let sparklePublicKeyEnvironmentName = "KUROTTY_SPARKLE_PUBLIC_KEY"
        static let sparkleFeedURLEnvironmentName = "KUROTTY_SPARKLE_FEED_URL"
        static let sparkleDebugUpdatesEnvironmentName = "KUROTTY_DEBUG_UPDATES"
        static let sparkleDebugUpdatesArgument = "--debug-updates"

        static var currentVersion: String {
            nonEmpty(Foundation.Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? developmentVersion
        }

        static func displayVersion(bundle: Foundation.Bundle = .main) -> String {
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let displayVersion = nonEmpty(version) ?? developmentVersion
            guard let displayBuild = nonEmpty(build) ?? (version == nil ? developmentBuild : nil) else {
                return displayVersion
            }
            return "\(displayVersion) (\(displayBuild))"
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    enum Terminal {
        static let defaultColumns = 120
        static let defaultRows = 40
        static let tabWidthColumns = 8
        static let maxScrollbackRows = 1_000_000
        static let minimumScrollbackRows = 1_000
        static let maximumSearchMatchCount = 50_000
        /// How many soft-wrapped rows search will join into one logical line.
        /// A 100MB minified file printed with no newlines is one wrapped line
        /// as far as the terminal is concerned; joining it whole would build a
        /// position map the size of the scrollback. Past this bound the line is
        /// treated as ending, which can miss a match straddling the split.
        static let maximumSearchWrappedRowJoinCount = 512
        static let searchInputDebounceNanoseconds: UInt64 = 20_000_000
        static let searchContentRefreshDebounceNanoseconds: UInt64 = 35_000_000
        static let cursorWidthPX: Float = 2
        static let cursorBlinkIntervalSeconds: TimeInterval = 0.55
        static let minimumCellWidthPX: CGFloat = 8
    }

    /// Domain values behind the bottom status bar. These are thresholds, units,
    /// and traversal/timing bounds — not design tokens — so they are kept out of
    /// `DesignTokens.Component.StatusBar`, which carries only the bar's geometry
    /// and type.
    enum StatusBar {
        /// Percent thresholds for value coloring.
        static let warningPercentRATIO: Double = 80
        static let errorPercentRATIO: Double = 92
        static let maximumCPUPercentRATIO: Double = 100
        static let bytesPerKilobyteRATIO: Double = 1024
        /// Bound on how deep a pane's process subtree is walked per sample.
        static let processTreeMaximumDepthCOUNT = 6
        static let processTreeMaximumProcessCOUNT = 256
        static let samplingIntervalSeconds: TimeInterval = 2.0
        /// How long a process tree is given to exit after `SIGTERM` before it is
        /// force-quit.
        static let killGracePeriodSeconds: TimeInterval = 3.0

        /// Universal symbols and unit abbreviations. These are not translated:
        /// `%`, `·`, `—`, and the SI-style byte units read the same in every
        /// language Kurotty ships.
        static let memoryColumnLabel = "RSS"
        static let memorySummaryLabel = "Σ RSS"
        static let memoryPrefix = "RAM"
        static let cpuPrefix = "CPU"
        static let summarySeparator = "·"
        static let labelSeparator = "·"
        static let detailSeparator = "—"
        static let unavailableValue = "—"
        static let kilobyteUnit = "KB"
        static let megabyteUnit = "MB"
        static let gigabyteUnit = "GB"
        static let percentUnit = "%"
    }

    enum GitWorktree {
        /// Upper bound on `git status` invocations per worktree refresh. One
        /// process per checkout is acceptable for the handful of worktrees a
        /// person runs agents in; a repository with dozens of them must not
        /// turn one refresh into dozens of processes.
        static let dirtyCheckMaximumCOUNT = 12
        /// Universal marker for "has uncommitted changes", matching the
        /// convention shell prompts already use. Not translated.
        static let dirtyMarker = "*"
    }

    enum FileExplorer {
        /// Filesystem events arrive in bursts; the tree is rebuilt once the
        /// burst settles rather than per event.
        static let watcherDebounceMS = 300
    }

    /// Project file palette: how much of a checkout is enumerated, and how much
    /// of the result is put on screen.
    enum ProjectFiles {
        /// Upper bound on paths held for one open of the palette. Ranking is
        /// linear in this number and runs on every keystroke, so it is the knob
        /// that decides whether typing stays responsive in a monorepo. A
        /// hundred thousand paths is roughly a 6 MB index and still ranks in a
        /// few milliseconds.
        static let resultMaximumCOUNT = 100_000
        /// Files the fallback walk will collect. Lower than the ripgrep cap on
        /// purpose: without ignore rules the walk is spending its budget on
        /// build output as often as on sources, and a bigger number would only
        /// buy more of that.
        static let walkResultMaximumCOUNT = 20_000
        /// Directory entries the fallback walk will look at, files and
        /// directories together. This is the real bound — the file cap alone
        /// would let a tree of empty directories run forever.
        static let walkVisitedEntryMaximumCOUNT = 60_000
        /// Rows the palette shows. The list is keyboard-driven and nobody
        /// arrows past the first screen; anything beyond this is answered by
        /// typing another character, not by scrolling.
        static let visibleResultMaximumCOUNT = 50
        /// Query characters past which nothing is ranked. A pasted file's worth
        /// of text cannot match a path, and ranking it against every entry is
        /// the one way this palette can be made to stall.
        static let queryMaximumCharacterCOUNT = 256
    }

    /// Single source of truth for where Kurotty stores anything on disk.
    ///
    /// Settings, shell history, and scrollback snapshots all live under the same
    /// `Application Support/Kurotty` root, so the directory name is named once
    /// here instead of being repeated per feature.
    enum Storage {
        static let applicationSupportDirectoryName = "Kurotty"
        /// macOS directory names used only when `FileManager` cannot resolve the
        /// Application Support URL and the path has to be built by hand.
        static let libraryDirectoryName = "Library"
        static let systemApplicationSupportDirectoryName = "Application Support"
    }

    enum Settings {
        static let fileName = "settings.json"
        static let directoryName = Storage.applicationSupportDirectoryName
        static let minimumTerminalFontSizePT = 8.0
        static let maximumTerminalFontSizePT = 48.0
        static let defaultWindowWidthPX = 1100.0
        static let defaultWindowHeightPX = 720.0
        static let minimumWindowWidthPX = 320.0
        static let maximumWindowWidthPX = 4_000.0
        static let minimumWindowHeightPX = 240.0
        static let maximumWindowHeightPX = 3_000.0
    }

    /// Workspace snapshot identity. Layout identifiers are positional so a
    /// restored window lines up with the slots the panes occupied last launch.
    enum Workspace {
        static let fileName = "workspace.json"
        static let defaultWindowIdentifier = "window-main"
        static let tabIdentifierPrefix = "tab-"
    }

    enum CommandHistory {
        static let fileName = "command-history.json"
        static let maximumEntryCount = 1_000
        static let saveDebounceSeconds: TimeInterval = 1
        static let persistenceQueueLabel = "dev.kurotty.command-history.persistence"
        // Versioned: the autosaved widths win over the default tokens, so a
        // changed default only reaches existing installs under a fresh name.
        static let splitViewAutosaveName = "dev.kurotty.command-history.split.v3"
    }

    /// Read-only index of AI coding-agent transcripts the agents themselves
    /// wrote. Kurotty never creates or modifies files under these roots.
    enum AgentSessions {
        static let claudeProjectsRelativePath = ".claude/projects"
        static let codexSessionsRelativePath = ".codex/sessions"
        static let transcriptFileExtension = "jsonl"
        static let codexRolloutFileNamePrefix = "rollout-"
        static let maximumSessionCount = 500
        static let maximumScannedFileCount = 4_000
        /// Transcripts larger than this are ignored entirely.
        static let maximumTranscriptBytes = 64 * 1024 * 1024
        /// At or below this size a transcript is read whole.
        static let fullReadThresholdBytes = 512 * 1024
        /// Head and tail window size used for larger transcripts.
        static let boundedReadWindowBytes = 128 * 1024
        static let maximumJSONSearchDepth = 4
        static let maximumTitleCharacters = 120
        static let maximumPromptCharacters = 400
    }

    /// Attribution of working-tree files to the agent session and prompt that
    /// wrote them, derived from the same transcripts `AgentSessions` indexes.
    enum AgentProvenance {
        /// Newest touches kept across every indexed session. A developer's
        /// transcript history reaches tens of thousands of file writes, and the
        /// index exists to answer "who changed this recently", not to be an
        /// archive.
        static let maximumTouchCount = 20_000
        /// History depth kept per file, newest first.
        static let maximumTouchesPerFile = 20
        /// How recently an agent must have written a file for the explorer to
        /// mark it.
        static let recentTouchWindowSeconds: TimeInterval = 24 * 60 * 60
    }

    /// Bounded reads for the JSONL transcript viewer. The reader never loads a
    /// transcript whole: it walks backwards in `tailChunkBytes` steps and drops
    /// any single record above `maximumRecordBytes`.
    enum AgentTranscript {
        /// Backward read granularity. A 200 MB transcript opens by touching a
        /// few of these instead of the whole file.
        static let tailChunkBytes = 64 * 1024
        /// A single record above this is dropped rather than buffered.
        /// Transcripts can contain a pasted binary blob; one bad record must not
        /// blow up memory.
        static let maximumRecordBytes = 2 * 1024 * 1024
        /// Records decoded for the initial paint.
        static let initialTailRecordCount = 400
        /// Messages handed to the UI per batch during tail-follow.
        static let appendBatchMessageCount = 40
    }

    /// Per-pane scrollback snapshots under
    /// `Application Support/Kurotty/terminal-scrollback`.
    ///
    /// The store budget bounds what one pane may write to disk; the replay
    /// budget bounds what is read back and fed to the screen model at launch.
    /// They are deliberately separate so restoring a window never stalls on the
    /// full stored file.
    enum TerminalScrollbackSnapshots {
        static let directoryName = "terminal-scrollback"
        /// Largest snapshot written for one pane.
        static let storeBytesPerPane = 5 * 1024 * 1024
        /// Largest snapshot replayed into one pane at restore.
        static let replayBytesPerPane = 512 * 1024
        /// Largest total size of the snapshot directory. Pruning drops the least
        /// recently modified files until the directory fits.
        static let totalStoreBytes = 64 * 1024 * 1024
        /// Trailing rows copied out of a live pane at capture time. Bounds the
        /// main-actor copy and the serialized string before the byte budgets
        /// apply.
        static let maximumCapturedRowCount = 5_000
    }

    /// Out-of-band agent activity channel. Status is only ever accepted from an
    /// explicit protocol (OSC 9999) or from an authenticated loopback hook post.
    /// It is never inferred from window titles or rendered rows.
    enum AgentStatus {
        /// `ESC ] 9999 ; <json> BEL` (ST terminator `ESC \` also accepted).
        static let oscNumber = "9999"
        /// Largest sequence Kurotty will buffer across PTY chunks before it
        /// gives up and discards bytes up to the next terminator.
        static let maximumSequenceBytes = 4 * 1024
        static let maximumAgentNameCharacters = 40
        static let maximumDetailCharacters = 200
        static let maximumHistoryCountPerPane = 20
        static let maximumTrackedPaneCount = 64

        /// Staleness policy. A status that is not refreshed within its window is
        /// cleared so a killed agent cannot leave a stuck spinner.
        static let workingStaleAfterSeconds: TimeInterval = 300
        static let waitingForInputStaleAfterSeconds: TimeInterval = 1_800
        static let blockedStaleAfterSeconds: TimeInterval = 1_800
        static let doneStaleAfterSeconds: TimeInterval = 600

        /// Environment contract injected into the PTY for hook-based reporting.
        static let paneIdentifierEnvironmentName = "KUROTTY_PANE_ID"
        static let hookPortEnvironmentName = "KUROTTY_HOOK_PORT"
        static let hookTokenEnvironmentName = "KUROTTY_HOOK_TOKEN"

        /// Loopback hook server.
        static let hookLoopbackHost = "127.0.0.1"
        static let hookRequestPath = "/agent-status"
        static let hookTokenHeaderName = "X-Kurotty-Hook-Token"
        static let hookTokenByteCount = 32
        static let hookMaximumRequestBytes = 8 * 1024
        static let hookMaximumBodyBytes = 4 * 1024
        static let hookQueueLabel = "dev.kurotty.agent-status.hook-server"
        static let hookRequestTimeoutSeconds = 2

        /// Agent hook installation. Claude Code and Codex use the same document
        /// shape — a `hooks` object keyed by event name, each event holding
        /// matcher objects with their own `hooks` array of `{type, command}`
        /// entries — so one set of key names serves both files.
        static let claudeSettingsRelativePath = ".claude/settings.json"
        static let codexHooksRelativePath = ".codex/hooks.json"
        /// Codex is only written to when this directory already exists. Creating
        /// it would plant a configuration file for a program the user may not
        /// have installed, and would raise a consent prompt about a product they
        /// do not run.
        static let codexConfigurationDirectoryRelativePath = ".codex"
        /// Top-level keys Codex accepts in `hooks.json`, verified against
        /// codex-cli 0.146.1, which reports `unknown field '<key>', expected
        /// 'description' or 'hooks'` and then refuses the entire file. Kurotty
        /// declines to rewrite a document whose top level it does not recognize;
        /// a future Codex key therefore costs status reporting until this list
        /// is updated, which is the failure direction that cannot eat someone
        /// else's configuration.
        static let codexPermittedTopLevelKeys: Set<String> = ["description", "hooks"]
        /// Appended to the configuration file name to form its backup.
        static let backupFileNameSuffix = ".kurotty-backup"
        static let hookDocumentHooksKey = "hooks"
        static let hookDocumentMatcherKey = "matcher"
        static let hookDocumentEntryListKey = "hooks"
        static let hookDocumentTypeKey = "type"
        static let hookDocumentCommandKey = "command"
        static let hookDocumentCommandType = "command"
        /// Names reported in the status payload, and the product names shown in
        /// the consent prompt. The payload names are what a pane displays, so
        /// they match the short names an OSC 9999 producer would send for the
        /// same agent rather than the product's full title.
        static let claudeReportedAgentName = "claude"
        static let codexReportedAgentName = "codex"
        static let claudeProductName = "Claude Code"
        static let codexProductName = "Codex"
        /// Marker embedded in every command Kurotty writes. Uninstall removes
        /// only entries carrying this marker; all other keys are preserved.
        static let managedCommandMarker = "kurotty-agent-status-hook"
        static let hookCurlExecutablePath = "/usr/bin/curl"
        static let settingsKeyPath = "terminal.agentStatusHooksEnabled"
        /// On by default, but the default alone never edits an agent's
        /// configuration: `AgentStatusHookConsentPolicy` still requires a
        /// one-time yes per agent before the first write.
        static let hooksEnabledDefault = SettingsDefaults.agentStatusHooksEnabled
        /// One recorded answer per agent: the prompt names the file it is about,
        /// so a yes for one agent's configuration is not a yes for another's.
        static let claudeHookConsentSettingsKeyPath = "terminal.agentStatusHookConsent"
        static let codexHookConsentSettingsKeyPath = "terminal.agentStatusCodexHookConsent"
    }

    /// Per-project shell history derivation. Everything here is a filesystem
    /// name or a bound; the policy lives in `TerminalShellHistoryEnvironment`.
    enum ShellHistory {
        static let environmentKey = "HISTFILE"
        static let applicationSupportDirectoryName = Storage.applicationSupportDirectoryName
        static let historyDirectoryName = "shell-history"
        static let projectHashLengthCharacters = 16
        static let gitDirectoryName = ".git"
        /// Bounds the upward `.git` walk so a pathological path cannot loop.
        static let maximumGitRootWalkDepth = 64
        /// Preserved fallback when no project identity is available.
        static let globalFallbackHistoryFileName = ".zsh_history"
        static let zshHistoryFileName = "zsh_history"
        static let bashHistoryFileName = "bash_history"
        /// Shell history is sensitive; keep the per-project tree owner-only.
        static let directoryPermissions: mode_t = 0o700
    }

    /// File-path link detection and its bounded existence cache.
    enum TerminalLinks {
        /// Minimum retained path length; a stray `/` or `./` must not become a
        /// link.
        static let minimumPathTextLengthCharacters = 2
        /// Bounded because terminal output can contain unbounded unique paths
        /// over a long session; eviction is strict least-recently-used.
        static let pathExistsCacheMaximumEntryCount = 512
        static let pathExistsProbeQueueLabel = "dev.kurotty.terminal-path-exists-probe"
    }

    /// User-authored quick commands: dispatch protocol values, storage, and the
    /// bounds that keep a settings file inside a safe envelope.
    ///
    /// The limits mirror the Orca reference implementation
    /// (`src/shared/terminal-quick-commands.ts`) so a file written by either
    /// product stays valid. The agent-prompt cap is deliberately larger than the
    /// terminal cap: prompts are pasted into a running agent, terminal text
    /// becomes one shell command list.
    enum QuickCommands {
        static let maximumCommandCount = 40
        static let maximumIdentifierCharacterCount = 80
        static let maximumNameCharacterCount = 80
        static let maximumShortcutCharacterCount = 40
        static let maximumDirectoryPathCharacterCount = 200
        static let maximumAgentNameCharacterCount = 80
        static let maximumTerminalTextCharacterCount = 4_000
        static let maximumAgentPromptCharacterCount = 6_000

        /// What the Return key writes to a PTY. Quick commands that execute
        /// append exactly this; quick commands that only insert never contain it.
        static let enterSequence = "\r"
        /// `"\r\n"` is a single Swift `Character` (one grapheme cluster), so it
        /// has to be listed alongside the bare carriage return and line feed or
        /// a CRLF terminal text would never be recognized as multi-line.
        static let lineBreakCharacters: Set<Character> = ["\r", "\n", "\r\n"]
        /// Multi-line terminal text is joined into a single shell command list.
        /// Raw newlines written into a PTY while a foreground program is running
        /// are consumed as that program's stdin instead of as commands.
        static let shellCommandListSeparator = "; "
        /// Agent prompts keep their words but never carry a line break, because
        /// a newline inside an agent TUI submits the prompt early.
        static let agentPromptLineSeparator = " "

        static let storageFileName = "quick-commands.json"
        static let storageSchemaVersion = 1
        static let persistenceQueueLabel = "dev.kurotty.quick-commands.persistence"
        static let saveDebounceSeconds: TimeInterval = 1
        static let didChangeNotificationName = "dev.kurotty.quickCommands.didChange"

        static let identifierPrefix = "quick-command-"
        static let paletteIdentifierPrefix = "quickCommand."

        static let globalScopeRawValue = "global"
        static let directoryScopeRawValue = "directory"
        static let terminalCommandActionRawValue = "terminal-command"
        static let agentPromptActionRawValue = "agent-prompt"

        /// Longest "Quick Commands" context submenu Kurotty will build.
        static let contextMenuCommandLimitCount = 12
    }

    enum Shell {
        /// Where the user's login shell is read from, and what to use when the
        /// variable is absent. macOS has shipped zsh as the default login shell
        /// since Catalina, so the fallback is the one that is almost certainly
        /// right rather than the historical `/bin/sh`.
        static let pathEnvironmentName = "SHELL"
        static let defaultPath = "/bin/zsh"
        static let term = "xterm-256color"
        static let colorTerm = "truecolor"
        static let termProgram = "Kurotty"
        static let prompt = "%F{cyan}%n%f %F{green}%~%f "
        static let childExecFailureStatusCode: Int32 = 127
        static let ptyWriteRetryDelayMicros: useconds_t = 1_000
        static let inputDrainRetryDelaysMS = [4, 8, 16, 32, 64, 120]
        static let ptyReadBufferSizeBytes = 8192
        static let maximumUTF8ScalarBytes = 4
        /// PTY output flow control. `outputHighWaterMarkBytes` is many read
        /// buffers' worth, so an interactive burst never suspends the reader,
        /// but a `yes` firehose crosses it within a frame and the child goes
        /// back to blocking in `write(2)` where the OS wanted it.
        static let outputHighWaterMarkBytes = 256 * 1024
        /// Resume well below the high mark so suspend/resume does not toggle on
        /// every chunk.
        static let outputLowWaterMarkBytes = 64 * 1024
        static let outputMaximumBytesPerDrain = 128 * 1024
        /// Backstop for the undecoded byte buffer. Flow control should keep it
        /// near zero; this only caps the damage if a consumer wedges.
        static let pendingOutputByteLimit = 4 * 1024 * 1024
    }

    enum Rendering {
        static let visibleCellReserveDivisor = 2
        static let forceFullModelRedrawUntilDamageIsVerified = false
    }

    enum Notifications {
        static let categoryIdentifier = "dev.kurotty.terminal"
        static let osc9IdentifierPrefix = "dev.kurotty.terminal.osc9"
        static let osc777IdentifierPrefix = "dev.kurotty.terminal.osc777"
        static let osc1337IdentifierPrefix = "dev.kurotty.terminal.osc1337"
        static let bridgeIdentifierPrefix = "dev.kurotty.terminal.bridge"
        static let bellIdentifierPrefix = "dev.kurotty.terminal.bell"
        static let commandCompletionIdentifierPrefix = "dev.kurotty.terminal.command-completion"
        static let defaultTitle = "Kurotty"
        static let terminalNotificationTitle = "Terminal notification"
        static let terminalAlertTitle = "Alert"
        static let commandFinishedTitle = "Command finished"
        static let commandFailedTitle = "Command failed"
        static let defaultProgramTitle = "Terminal"
        static let defaultDirectoryTitle = "Session"
        static let testBody = "Kurotty test notification."
        static let bellBody = "Check your terminal."
        static let commandInputCaptureMaxCharacters = 4096
        static let commandSummaryMaxCharacters = 180
        static let terminalNotificationMaxCharacters = 512
        static let developmentNotificationExecutablePath = "/usr/bin/osascript"
        static let bridgeSocketEnvironmentName = "KUROTTY_NOTIFY_SOCKET"
        static let bridgeCommandEnvironmentName = "KUROTTY_NOTIFY_COMMAND"
        static let bridgeSocketFileName = "notify.sock"
        static let bridgeSocketBacklog: Int32 = 8
        static let bridgePayloadMaxBytes = 64 * 1024
        static let bridgeSocketPermissions = 0o600
        static let bridgeSocketDirectoryPermissions = 0o700
        static let bridgeClaimRetryIntervalSeconds: TimeInterval = 1
    }

    enum Diagnostics {
        static let ptyRawLogPrefix = "Kurotty PTY raw"
        static let notificationSkippedPrefix = "Kurotty notification skipped outside app bundle"
        static let notificationEnqueuePrefix = "Kurotty notification enqueue"
        /// Paste logging is redacted by construction: only counts and modes are
        /// ever formatted behind this prefix, never clipboard content.
        static let pasteLogPrefix = "Kurotty paste"
        static let diagnosticsReportPrefix = "Kurotty diagnostics report"
    }
}
