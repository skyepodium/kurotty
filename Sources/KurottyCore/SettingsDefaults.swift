import Foundation

public enum SettingsDefaults {
    public static let schemaVersion = 18
    public static let commandHistoryEnabled = true
    /// Live-applied. Raw value of the app-side command-finish notification mode;
    /// anything else in the file falls back to this. `unfocused` by default
    /// because a banner for a command the user is watching is pure noise, and a
    /// user who mutes the app loses every OSC notification with it.
    public static let notifyOnCommandFinish = "unfocused"
    /// Live-applied. Commands shorter than this never raise a banner: the point
    /// of the notification is "you walked away and it finished", and a command
    /// that returns in a second was never worth walking away from. A completion
    /// that reports no duration at all is treated as too short.
    public static let minimumCommandDurationSeconds = 10.0
    /// Bounds on what `terminal.minimumCommandDurationSeconds` may contain. Zero
    /// means "notify for every command"; the upper bound is an hour, past which
    /// the mode switch is the honest way to say "never".
    public static let minimumAllowedCommandDurationSeconds = 0.0
    public static let maximumAllowedCommandDurationSeconds = 3_600.0
    /// Live-applied and on by default. The window's bottom status bar is passive
    /// chrome; turning it off collapses the strip to zero height and stops the
    /// resource sampler entirely, so no timer and no `libproc` call remains.
    public static let statusBarEnabled = true
    /// Launch-only and on by default. Restoring stored scrollback only repaints
    /// the screen model; it never writes to a PTY and never runs a command, so
    /// it stays separate from the command-replay opt-in.
    public static let restoreScrollbackOnLaunch = true

    /// The editor is sized for prose-length lines, the terminal for a cell
    /// grid, so the two font sizes are separate settings.
    public static let codeEditorFontSizePT = 13.0
    public static let minimumCodeEditorFontSizePT = 8.0
    public static let maximumCodeEditorFontSizePT = 32.0
    /// Off: long lines scroll horizontally instead of folding, which is what
    /// wide tables and long string literals want.
    public static let codeEditorWrapsLines = false
    /// Live-applied and on by default. A paste that spans more than one line
    /// can execute every line it contains, so it asks for confirmation first.
    public static let confirmMultilinePaste = true
    /// Live-applied and on by default. Closing a tab or window kills every
    /// process its shells are running, so a close that would terminate a
    /// running child process (an editor, ssh, a build) asks first. A pane whose
    /// shell is idle closes without a prompt.
    public static let confirmCloseRunningProcess = true
    /// Live-applied. What a pane does once its own child process has already
    /// ended. `onCleanExit` matches the shell contract users expect: `exit`
    /// takes the pane with it, while a crash or a nonzero status keeps the
    /// pane and its scrollback on screen behind the exit banner. Unrelated to
    /// `confirmCloseRunningProcess`, which only guards a close the user asks
    /// for while a process is still running.
    public static let closeOnChildExit = TerminalCloseOnChildExitMode.onCleanExit
    /// On by default. Indexing reads the user's AI agent transcripts, so the
    /// Settings checkbox must always be able to turn it off; when disabled no
    /// scan runs at all and no index is retained.
    public static let agentSessionIndexEnabled = true
    /// Live-applied. Hides the mouse pointer while the user types into a
    /// terminal surface; the pointer returns on the next mouse move.
    public static let hideMouseCursorWhileTyping = true
    /// Next-session. Derives a per-project `HISTFILE` for new shells. An
    /// inherited `HISTFILE` always wins regardless of this setting.
    public static let perProjectHistoryEnabled = true
    /// On by default, because agent status is most of what the status bar is
    /// for and agents that do not emit OSC 9999 need the hook to report at all.
    /// The default only expresses intent: writing Kurotty's entries into the
    /// user's own `~/.claude/settings.json` still waits for the one-time consent
    /// recorded in `agentStatusHookConsent`.
    public static let agentStatusHooksEnabled = true
    /// Raw value of the app-side hook consent record. `unasked` means the first
    /// install attempt must ask; the answer is stored so it is asked once, ever.
    public static let agentStatusHookConsent = "unasked"
    public static let terminalFontName = "Menlo"
    public static let terminalFontSizePT = 15.0
    public static let maximumScrollbackRows = 1_000_000
    public static let minimumScrollbackRows = 1_000
    /// Rows a new install keeps, well below `maximumScrollbackRows`: scrollback
    /// is held in memory and there is no PTY backpressure, so defaulting to the
    /// cap hands every fresh pane a multi-gigabyte ceiling nobody asked for.
    public static let defaultScrollbackRows = 10_000
    public static let defaultWindowWidthPX = 1100.0
    public static let defaultWindowHeightPX = 720.0
    public static let minimumWindowWidthPX = 320.0
    public static let maximumWindowWidthPX = 4_000.0
    public static let minimumWindowHeightPX = 240.0
    public static let maximumWindowHeightPX = 3_000.0
    public static let minimumTerminalFontSizePT = 8.0
    public static let maximumTerminalFontSizePT = 48.0

    public static var shellWorkingDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}

public enum TerminalColorDefaults {
    public static let foregroundHex = "#E5E7EB"
    public static let backgroundHex = "#22252B"
    public static let cursorHex = "#D7C6F4"

    public static let foreground = SIMD4<Float>(229.0 / 255.0, 231.0 / 255.0, 235.0 / 255.0, 1)
    public static let background = SIMD4<Float>(34.0 / 255.0, 37.0 / 255.0, 43.0 / 255.0, 1)
    public static let cursor = SIMD4<Float>(215.0 / 255.0, 198.0 / 255.0, 244.0 / 255.0, 1)

    public static let ansiHex = [
        "#2F333A",
        "#FF5F67",
        "#5FD38D",
        "#E5C07B",
        "#61AFEF",
        "#C792EA",
        "#56B6C2",
        "#D7DAE0",
        "#60646C",
        "#FF7B86",
        "#8EE8A3",
        "#F0D28A",
        "#7AB7FF",
        "#D7A8FF",
        "#7FDCE3",
        "#F5F7FA",
    ]
}
