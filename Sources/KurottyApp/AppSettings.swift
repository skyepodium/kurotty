import Foundation
import KurottyCore
import simd

// MARK: - Portable Settings Values

struct AppSettings: Codable, Equatable {
    var schemaVersion: Int?
    var terminal: TerminalSettings
    var window: WindowSettings
    var shell: ShellSettings

    static let `default` = AppSettings(
        schemaVersion: Defaults.schemaVersion,
        terminal: TerminalSettings(
            theme: TerminalThemePreset.kurottyName,
            fontName: Defaults.fontName,
            fontSize: Defaults.fontSize,
            scrollbackLines: Defaults.scrollbackLines,
            colors: TerminalColorSettings.default,
            commandHistoryEnabled: Defaults.commandHistoryEnabled,
            statusBarEnabled: Defaults.statusBarEnabled,
            statusBarShowsAgent: Defaults.statusBarShowsAgent,
            statusBarShowsWorktree: Defaults.statusBarShowsWorktree,
            statusBarShowsQuota: Defaults.statusBarShowsQuota,
            statusBarShowsResources: Defaults.statusBarShowsResources,
            panePaddingPX: Defaults.panePaddingPX,
            paneBorderStyle: Defaults.paneBorderStyle,
            inactivePaneDimmingEnabled: Defaults.inactivePaneDimmingEnabled,
            preventSystemSleep: Defaults.preventSystemSleep,
            tabGroupsEnabled: Defaults.tabGroupsEnabled,
            screenSnapshotBridgeEnabled: Defaults.screenSnapshotBridgeEnabled,
            kittyIntegrationEnabled: Defaults.kittyIntegrationEnabled,
            osc99NotificationsEnabled: Defaults.osc99NotificationsEnabled,
            confirmMultilinePaste: Defaults.confirmMultilinePaste,
            confirmCloseRunningProcess: Defaults.confirmCloseRunningProcess,
            closeOnChildExit: Defaults.closeOnChildExit,
            agentSessionIndexEnabled: Defaults.agentSessionIndexEnabled,
            hideMouseCursorWhileTyping: Defaults.hideMouseCursorWhileTyping,
            agentStatusHooksEnabled: Defaults.agentStatusHooksEnabled,
            restoreScrollbackOnLaunch: Defaults.restoreScrollbackOnLaunch,
            notifyOnCommandFinish: Defaults.notifyOnCommandFinish,
            minimumCommandDurationSeconds: Defaults.minimumCommandDurationSeconds,
            notifyOnAgentWaiting: Defaults.notifyOnAgentWaiting,
            agentStatusHookConsent: Defaults.agentStatusHookConsent,
            agentStatusCodexHookConsent: Defaults.agentStatusCodexHookConsent,
            uiTextScalePercent: Defaults.uiTextScalePercent,
            commandProgressIndicatorEnabled: Defaults.commandProgressIndicatorEnabled,
            menuBarExtraEnabled: Defaults.menuBarExtraEnabled,
            promptNavigatorRailEnabled: Defaults.promptNavigatorRailEnabled,
            titleReportsEnabled: Defaults.titleReportsEnabled,
            hasSeenGettingStarted: Defaults.hasSeenGettingStarted
        ),
        window: WindowSettings(
            width: Defaults.windowWidth,
            height: Defaults.windowHeight
        ),
        shell: ShellSettings(
            workingDirectory: Defaults.shellWorkingDirectory,
            perProjectHistoryEnabled: Defaults.perProjectHistoryEnabled
        )
    )

    private enum Defaults {
        static let schemaVersion = SettingsDefaults.schemaVersion
        static let fontName = SettingsDefaults.terminalFontName
        static let fontSize = SettingsDefaults.terminalFontSizePT
        static let scrollbackLines = SettingsDefaults.defaultScrollbackRows
        static let windowWidth = SettingsDefaults.defaultWindowWidthPX
        static let windowHeight = SettingsDefaults.defaultWindowHeightPX
        static let shellWorkingDirectory = SettingsDefaults.shellWorkingDirectory
        static let commandHistoryEnabled = SettingsDefaults.commandHistoryEnabled
        static let statusBarEnabled = SettingsDefaults.statusBarEnabled
        static let statusBarShowsAgent = SettingsDefaults.statusBarShowsAgent
        static let statusBarShowsWorktree = SettingsDefaults.statusBarShowsWorktree
        static let statusBarShowsQuota = SettingsDefaults.statusBarShowsQuota
        static let statusBarShowsResources = SettingsDefaults.statusBarShowsResources
        static let panePaddingPX = SettingsDefaults.panePaddingPX
        static let paneBorderStyle = SettingsDefaults.paneBorderStyle
        static let inactivePaneDimmingEnabled = SettingsDefaults.inactivePaneDimmingEnabled
        static let preventSystemSleep = SettingsDefaults.preventSystemSleep
        static let tabGroupsEnabled = SettingsDefaults.tabGroupsEnabled
        static let screenSnapshotBridgeEnabled = SettingsDefaults.screenSnapshotBridgeEnabled
        static let kittyIntegrationEnabled = SettingsDefaults.kittyIntegrationEnabled
        static let osc99NotificationsEnabled = SettingsDefaults.osc99NotificationsEnabled
        static let confirmMultilinePaste = SettingsDefaults.confirmMultilinePaste
        static let confirmCloseRunningProcess = SettingsDefaults.confirmCloseRunningProcess
        static let closeOnChildExit = SettingsDefaults.closeOnChildExit
        static let agentSessionIndexEnabled = SettingsDefaults.agentSessionIndexEnabled
        static let hideMouseCursorWhileTyping = SettingsDefaults.hideMouseCursorWhileTyping
        static let agentStatusHooksEnabled = SettingsDefaults.agentStatusHooksEnabled
        static let perProjectHistoryEnabled = SettingsDefaults.perProjectHistoryEnabled
        static let restoreScrollbackOnLaunch = SettingsDefaults.restoreScrollbackOnLaunch
        static let notifyOnCommandFinish = SettingsDefaults.notifyOnCommandFinish
        static let minimumCommandDurationSeconds = SettingsDefaults.minimumCommandDurationSeconds
        static let notifyOnAgentWaiting = SettingsDefaults.notifyOnAgentWaiting
        static let agentStatusHookConsent = SettingsDefaults.agentStatusHookConsent
        static let agentStatusCodexHookConsent = SettingsDefaults.agentStatusCodexHookConsent
        static let uiTextScalePercent = SettingsDefaults.uiTextScalePercent
        static let commandProgressIndicatorEnabled = SettingsDefaults.commandProgressIndicatorEnabled
        static let menuBarExtraEnabled = SettingsDefaults.menuBarExtraEnabled
        static let promptNavigatorRailEnabled = SettingsDefaults.promptNavigatorRailEnabled
        static let titleReportsEnabled = SettingsDefaults.titleReportsEnabled
        static let hasSeenGettingStarted = SettingsDefaults.hasSeenGettingStarted
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case terminal
        case window
        case shell
    }

    init(
        schemaVersion: Int?,
        terminal: TerminalSettings,
        window: WindowSettings,
        shell: ShellSettings
    ) {
        self.schemaVersion = schemaVersion
        self.terminal = terminal
        self.window = window
        self.shell = shell
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        terminal = try container.decode(TerminalSettings.self, forKey: .terminal)
        window = try container.decodeIfPresent(WindowSettings.self, forKey: .window) ?? .default
        shell = try container.decodeIfPresent(ShellSettings.self, forKey: .shell) ?? .default
    }
}

/// Live-applied to existing terminal surfaces when settings change.
/// `commandHistoryEnabled` is live-applied: recording starts or stops as soon
/// as the setting changes; already-recorded entries are kept on disk.
/// `agentSessionIndexEnabled` is live-applied and defaults on: it gates whether
/// Kurotty reads the AI agent transcripts already stored under the user's home
/// directory. When it is off, no scan runs at all and no index is retained.
/// The index is metadata held in memory only; transcript content is never
/// copied into Kurotty's own storage regardless of this setting.
/// `hideMouseCursorWhileTyping` is live-applied and defaults on.
/// `confirmMultilinePaste` is live-applied and defaults **on**: a paste that
/// spans more than one line asks before any byte reaches the PTY, because the
/// shell would otherwise execute every line the clipboard carried.
/// `confirmCloseRunningProcess` is live-applied and defaults **on**: closing a
/// tab or window kills every process its shells are running, so a close that
/// would terminate a running child process asks first. An idle shell closes
/// without a prompt.
/// `closeOnChildExit` is live-applied and defaults to `onCleanExit`: a pane
/// whose child left with status 0 goes away, and any other outcome — a nonzero
/// status or a signal — keeps the pane and its scrollback behind the exit
/// banner. It never overlaps `confirmCloseRunningProcess`: that setting guards
/// a user-initiated close while a process still runs, this one only applies
/// once the process has already ended, so no close is ever governed by both.
/// `agentStatusHooksEnabled` is live-applied and defaults **on**, but on its own
/// it never edits anything: it starts a loopback listener and expresses intent,
/// while the first write of Kurotty-marked entries into the user's own agent
/// hook configuration waits for the one-time answer recorded in
/// `agentStatusHookConsent` for Claude Code and `agentStatusCodexHookConsent`
/// for Codex — one answer per agent, because the prompt names the file it is
/// about. A denied answer leaves that agent's file untouched forever, and the
/// visible checkbox only goes off once every agent on the machine is refused.
/// `statusBarEnabled` is live-applied and defaults on: the bottom status bar is
/// passive chrome, so turning it off collapses it to zero height and stops the
/// resource sampler entirely rather than only hiding a view.
/// `restoreScrollbackOnLaunch` is **launch-only** and defaults on: it is read
/// once while a workspace is restored. Restored scrollback is display-only —
/// bytes go into the screen model and nothing is written to the shell — so it is
/// deliberately independent of the command-replay opt-in.
/// `notifyOnCommandFinish` and `minimumCommandDurationSeconds` are live-applied
/// and gate command-finish banners together: without them every background `ls`
/// in an unfocused pane raised one, and a user who answers that by muting
/// Kurotty loses the OSC 9/777/1337 notifications too.
/// `notifyOnAgentWaiting` is live-applied and defaults **on**. It is the same
/// bargain as `notifyOnCommandFinish` for a different event: a coding agent that
/// reports it has stopped and needs the user raises one banner per transition
/// into that state, only while the user is looking elsewhere, and the banner is
/// withdrawn as soon as the state clears or the user reaches the pane. Nothing
/// fires for a producer that never reports its state, so an install that gains
/// the key gains no banners it did not already have a reporter for.
/// `uiTextScalePercent` is live-applied and defaults to 100: it scales Kurotty's
/// own chrome and never terminal or editor content. It lives under `terminal`
/// rather than in a section of its own because that is where every other
/// app-behavior key already sits — `statusBarEnabled` and `codeEditorFontSize`
/// are no more "terminal" than this one — and `window` is strictly the
/// launch-size pair.
/// `commandProgressIndicatorEnabled` is live-applied and defaults **on**: the
/// per-pane progress bar is ambient status with no dismiss affordance, so the
/// switch is the only way to refuse it, and turning it off takes down a bar that
/// is on screen at that moment rather than waiting for the next command.
/// `menuBarExtraEnabled` is live-applied and defaults **on**. It is the one
/// switch here that governs a surface outside Kurotty's window — a slot in the
/// system menu bar, which is shared and finite — so turning it off gives the
/// slot back immediately rather than leaving a zero-width item behind, and
/// turning it on takes one immediately rather than waiting for a relaunch.
struct TerminalSettings: Codable, Equatable {
    var theme: String
    var fontName: String
    var fontSize: Double
    var scrollbackLines: Int
    var colors: TerminalColorSettings
    var commandHistoryEnabled: Bool
    var statusBarEnabled: Bool
    var statusBarShowsAgent: Bool
    var statusBarShowsWorktree: Bool
    var statusBarShowsQuota: Bool
    var statusBarShowsResources: Bool
    var panePaddingPX: Double
    var paneBorderStyle: String
    var inactivePaneDimmingEnabled: Bool
    var preventSystemSleep: Bool
    var tabGroupsEnabled: Bool
    var screenSnapshotBridgeEnabled: Bool
    var kittyIntegrationEnabled: Bool
    var osc99NotificationsEnabled: Bool
    var confirmMultilinePaste: Bool
    var confirmCloseRunningProcess: Bool
    var closeOnChildExit: TerminalCloseOnChildExitMode
    var agentSessionIndexEnabled: Bool
    var hideMouseCursorWhileTyping: Bool
    var agentStatusHooksEnabled: Bool
    var restoreScrollbackOnLaunch: Bool
    /// Point size for the code editor tabs. Separate from `fontSize`: the
    /// terminal is sized for a cell grid and the editor for prose-length lines,
    /// so one number cannot serve both.
    var codeEditorFontSize: Double
    /// Soft-wraps editor lines to the pane width. Off means long lines scroll
    /// horizontally, which is what code with wide tables or long strings wants.
    var codeEditorWrapsLines: Bool
    /// Raw value of `TerminalCommandFinishNotificationMode`. Kept a string for
    /// the same reason `theme` is: an unknown value normalizes to the default
    /// instead of making the whole settings file undecodable.
    var notifyOnCommandFinish: String
    /// Commands that finish faster than this never notify, in either mode.
    var minimumCommandDurationSeconds: Double
    /// Raises a banner for a pane whose coding agent reported that it has
    /// stopped and needs the user. Independent of `notifyOnCommandFinish`: that
    /// one is about a command that ended, this one is about a turn that cannot
    /// end until someone answers it.
    var notifyOnAgentWaiting: Bool
    /// Raw value of `AgentStatusHookConsent`: the user's one-time answer to
    /// "may Kurotty write its hook entries into your Claude Code settings?".
    /// Recorded rather than toggled — Preferences shows `agentStatusHooksEnabled`,
    /// this only remembers that the question was already answered.
    var agentStatusHookConsent: String
    /// The same answer for Codex's `~/.codex/hooks.json`. Separate because the
    /// prompt names the file, and that file is commonly owned by third-party
    /// tooling, so a yes about Claude Code's settings says nothing about it.
    var agentStatusCodexHookConsent: String
    /// Percentage applied to the chrome type ramp and to the boxes that hold it.
    /// Stored as a percentage rather than as a multiplier so the settings file
    /// and the Settings readout say the same thing.
    var uiTextScalePercent: Double
    /// Shows the per-pane command progress bar. Independent of
    /// `notifyOnCommandFinish`: that one is about a command the user walked away
    /// from, this one is about the wait they are sitting through.
    var commandProgressIndicatorEnabled: Bool
    /// Puts Kurotty's mark in the system menu bar with a small menu behind it.
    /// Unrelated to `statusBarEnabled` despite the similar sound: that one is
    /// the bar along the bottom of Kurotty's own window.
    var menuBarExtraEnabled: Bool
    /// Draws the prompt navigator rail on the terminal's trailing edge. Distinct
    /// from the scrollback indicator sharing that edge: the indicator says where
    /// the viewport is, the rail says where the commands are.
    var promptNavigatorRailEnabled: Bool
    /// Answers `CSI 21 t` and `CSI 20 t`, which ask the terminal to report the
    /// window and icon titles back on the shell's *input* stream. Off by
    /// default: a program sets the title too, so the pair lets it type whatever
    /// it likes at the prompt. Even on, a reported title is control-stripped
    /// and length-capped.
    var titleReportsEnabled: Bool
    /// Whether the Getting Started tab has already been shown once. A record of
    /// an event, not a preference: it is written by the app rather than by the
    /// user, and no Settings control reads it.
    var hasSeenGettingStarted: Bool

    var commandFinishNotificationMode: TerminalCommandFinishNotificationMode {
        TerminalCommandFinishNotificationMode.parse(notifyOnCommandFinish) ?? .default
    }

    var paneBorderStyleValue: TerminalPaneBorderStyle {
        TerminalPaneBorderStyle(rawValue: paneBorderStyle) ?? .default
    }

    func agentStatusHookConsentChoice(for target: AgentStatusHookTarget) -> AgentStatusHookConsent {
        AgentStatusHookConsent.parse(rawAgentStatusHookConsent(for: target)) ?? .default
    }

    mutating func setAgentStatusHookConsent(_ consent: AgentStatusHookConsent, for target: AgentStatusHookTarget) {
        switch target {
        case .claudeCode:
            agentStatusHookConsent = consent.rawValue
        case .codex:
            agentStatusCodexHookConsent = consent.rawValue
        }
    }

    private func rawAgentStatusHookConsent(for target: AgentStatusHookTarget) -> String {
        switch target {
        case .claudeCode:
            return agentStatusHookConsent
        case .codex:
            return agentStatusCodexHookConsent
        }
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case fontName
        case fontSize
        case scrollbackLines
        case colors
        case commandHistoryEnabled
        case statusBarEnabled
        case statusBarShowsAgent
        case statusBarShowsWorktree
        case statusBarShowsQuota
        case statusBarShowsResources
        case panePaddingPX
        case paneBorderStyle
        case inactivePaneDimmingEnabled
        case preventSystemSleep
        case tabGroupsEnabled
        case screenSnapshotBridgeEnabled
        case kittyIntegrationEnabled
        case osc99NotificationsEnabled
        case confirmMultilinePaste
        case confirmCloseRunningProcess
        case closeOnChildExit
        case agentSessionIndexEnabled
        case hideMouseCursorWhileTyping
        case agentStatusHooksEnabled
        case restoreScrollbackOnLaunch
        case codeEditorFontSize
        case codeEditorWrapsLines
        case notifyOnCommandFinish
        case minimumCommandDurationSeconds
        case notifyOnAgentWaiting
        case agentStatusHookConsent
        case agentStatusCodexHookConsent
        case uiTextScalePercent
        case commandProgressIndicatorEnabled
        case menuBarExtraEnabled
        case promptNavigatorRailEnabled
        case titleReportsEnabled
        case hasSeenGettingStarted
    }

    init(
        theme: String,
        fontName: String,
        fontSize: Double,
        scrollbackLines: Int,
        colors: TerminalColorSettings,
        commandHistoryEnabled: Bool = SettingsDefaults.commandHistoryEnabled,
        statusBarEnabled: Bool = SettingsDefaults.statusBarEnabled,
        statusBarShowsAgent: Bool = SettingsDefaults.statusBarShowsAgent,
        statusBarShowsWorktree: Bool = SettingsDefaults.statusBarShowsWorktree,
        statusBarShowsQuota: Bool = SettingsDefaults.statusBarShowsQuota,
        statusBarShowsResources: Bool = SettingsDefaults.statusBarShowsResources,
        panePaddingPX: Double = SettingsDefaults.panePaddingPX,
        paneBorderStyle: String = SettingsDefaults.paneBorderStyle,
        inactivePaneDimmingEnabled: Bool = SettingsDefaults.inactivePaneDimmingEnabled,
        preventSystemSleep: Bool = SettingsDefaults.preventSystemSleep,
        tabGroupsEnabled: Bool = SettingsDefaults.tabGroupsEnabled,
        screenSnapshotBridgeEnabled: Bool = SettingsDefaults.screenSnapshotBridgeEnabled,
        kittyIntegrationEnabled: Bool = SettingsDefaults.kittyIntegrationEnabled,
        osc99NotificationsEnabled: Bool = SettingsDefaults.osc99NotificationsEnabled,
        confirmMultilinePaste: Bool = SettingsDefaults.confirmMultilinePaste,
        confirmCloseRunningProcess: Bool = SettingsDefaults.confirmCloseRunningProcess,
        closeOnChildExit: TerminalCloseOnChildExitMode = SettingsDefaults.closeOnChildExit,
        agentSessionIndexEnabled: Bool = SettingsDefaults.agentSessionIndexEnabled,
        hideMouseCursorWhileTyping: Bool = SettingsDefaults.hideMouseCursorWhileTyping,
        agentStatusHooksEnabled: Bool = SettingsDefaults.agentStatusHooksEnabled,
        restoreScrollbackOnLaunch: Bool = SettingsDefaults.restoreScrollbackOnLaunch,
        codeEditorFontSize: Double = SettingsDefaults.codeEditorFontSizePT,
        codeEditorWrapsLines: Bool = SettingsDefaults.codeEditorWrapsLines,
        notifyOnCommandFinish: String = SettingsDefaults.notifyOnCommandFinish,
        minimumCommandDurationSeconds: Double = SettingsDefaults.minimumCommandDurationSeconds,
        notifyOnAgentWaiting: Bool = SettingsDefaults.notifyOnAgentWaiting,
        agentStatusHookConsent: String = SettingsDefaults.agentStatusHookConsent,
        agentStatusCodexHookConsent: String = SettingsDefaults.agentStatusCodexHookConsent,
        uiTextScalePercent: Double = SettingsDefaults.uiTextScalePercent,
        commandProgressIndicatorEnabled: Bool = SettingsDefaults.commandProgressIndicatorEnabled,
        menuBarExtraEnabled: Bool = SettingsDefaults.menuBarExtraEnabled,
        promptNavigatorRailEnabled: Bool = SettingsDefaults.promptNavigatorRailEnabled,
        titleReportsEnabled: Bool = SettingsDefaults.titleReportsEnabled,
        hasSeenGettingStarted: Bool = SettingsDefaults.hasSeenGettingStarted
    ) {
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
        self.scrollbackLines = scrollbackLines
        self.colors = colors
        self.commandHistoryEnabled = commandHistoryEnabled
        self.statusBarEnabled = statusBarEnabled
        self.statusBarShowsAgent = statusBarShowsAgent
        self.statusBarShowsWorktree = statusBarShowsWorktree
        self.statusBarShowsQuota = statusBarShowsQuota
        self.statusBarShowsResources = statusBarShowsResources
        self.panePaddingPX = panePaddingPX
        self.paneBorderStyle = paneBorderStyle
        self.inactivePaneDimmingEnabled = inactivePaneDimmingEnabled
        self.preventSystemSleep = preventSystemSleep
        self.tabGroupsEnabled = tabGroupsEnabled
        self.screenSnapshotBridgeEnabled = screenSnapshotBridgeEnabled
        self.kittyIntegrationEnabled = kittyIntegrationEnabled
        self.osc99NotificationsEnabled = osc99NotificationsEnabled
        self.confirmMultilinePaste = confirmMultilinePaste
        self.confirmCloseRunningProcess = confirmCloseRunningProcess
        self.closeOnChildExit = closeOnChildExit
        self.agentSessionIndexEnabled = agentSessionIndexEnabled
        self.hideMouseCursorWhileTyping = hideMouseCursorWhileTyping
        self.agentStatusHooksEnabled = agentStatusHooksEnabled
        self.restoreScrollbackOnLaunch = restoreScrollbackOnLaunch
        self.codeEditorFontSize = codeEditorFontSize
        self.codeEditorWrapsLines = codeEditorWrapsLines
        self.notifyOnCommandFinish = notifyOnCommandFinish
        self.minimumCommandDurationSeconds = minimumCommandDurationSeconds
        self.notifyOnAgentWaiting = notifyOnAgentWaiting
        self.agentStatusHookConsent = agentStatusHookConsent
        self.agentStatusCodexHookConsent = agentStatusCodexHookConsent
        self.uiTextScalePercent = uiTextScalePercent
        self.commandProgressIndicatorEnabled = commandProgressIndicatorEnabled
        self.menuBarExtraEnabled = menuBarExtraEnabled
        self.promptNavigatorRailEnabled = promptNavigatorRailEnabled
        self.titleReportsEnabled = titleReportsEnabled
        self.hasSeenGettingStarted = hasSeenGettingStarted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? ""
        fontName = try container.decode(String.self, forKey: .fontName)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        scrollbackLines = try container.decode(Int.self, forKey: .scrollbackLines)
        colors = try container.decode(TerminalColorSettings.self, forKey: .colors)
        commandHistoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .commandHistoryEnabled)
            ?? SettingsDefaults.commandHistoryEnabled
        // Absent in schema versions below 15; those files fall back to the
        // current default rather than failing to decode.
        statusBarEnabled = try container.decodeIfPresent(Bool.self, forKey: .statusBarEnabled)
            ?? SettingsDefaults.statusBarEnabled
        statusBarShowsAgent = try container.decodeIfPresent(Bool.self, forKey: .statusBarShowsAgent)
            ?? SettingsDefaults.statusBarShowsAgent
        statusBarShowsWorktree = try container.decodeIfPresent(Bool.self, forKey: .statusBarShowsWorktree)
            ?? SettingsDefaults.statusBarShowsWorktree
        statusBarShowsQuota = try container.decodeIfPresent(Bool.self, forKey: .statusBarShowsQuota)
            ?? SettingsDefaults.statusBarShowsQuota
        statusBarShowsResources = try container.decodeIfPresent(Bool.self, forKey: .statusBarShowsResources)
            ?? SettingsDefaults.statusBarShowsResources
        panePaddingPX = try container.decodeIfPresent(Double.self, forKey: .panePaddingPX)
            ?? SettingsDefaults.panePaddingPX
        paneBorderStyle = try container.decodeIfPresent(String.self, forKey: .paneBorderStyle)
            ?? SettingsDefaults.paneBorderStyle
        inactivePaneDimmingEnabled = try container.decodeIfPresent(Bool.self, forKey: .inactivePaneDimmingEnabled)
            ?? SettingsDefaults.inactivePaneDimmingEnabled
        preventSystemSleep = try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep)
            ?? SettingsDefaults.preventSystemSleep
        tabGroupsEnabled = try container.decodeIfPresent(Bool.self, forKey: .tabGroupsEnabled)
            ?? SettingsDefaults.tabGroupsEnabled
        screenSnapshotBridgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .screenSnapshotBridgeEnabled)
            ?? SettingsDefaults.screenSnapshotBridgeEnabled
        kittyIntegrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .kittyIntegrationEnabled)
            ?? SettingsDefaults.kittyIntegrationEnabled
        osc99NotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .osc99NotificationsEnabled)
            ?? SettingsDefaults.osc99NotificationsEnabled
        confirmMultilinePaste = try container.decodeIfPresent(Bool.self, forKey: .confirmMultilinePaste)
            ?? SettingsDefaults.confirmMultilinePaste
        // Absent in schema versions below 17; those files fall back to the
        // current default rather than failing to decode.
        confirmCloseRunningProcess = try container.decodeIfPresent(Bool.self, forKey: .confirmCloseRunningProcess)
            ?? SettingsDefaults.confirmCloseRunningProcess
        // Absent in schema versions below 18. Decoded through its raw string
        // rather than as the enum itself: a hand-edited file with an unknown
        // mode must fall back to the default, not make the whole settings
        // document fail to decode and reset every other key with it.
        closeOnChildExit = TerminalCloseOnChildExitMode(
            rawValue: try container.decodeIfPresent(String.self, forKey: .closeOnChildExit) ?? ""
        ) ?? SettingsDefaults.closeOnChildExit
        // Absent in schema versions below 11; those files fall back to the
        // current default rather than failing to decode.
        agentSessionIndexEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentSessionIndexEnabled)
            ?? SettingsDefaults.agentSessionIndexEnabled
        // Absent in schema versions below 12; those files fall back to the
        // current defaults rather than failing to decode.
        hideMouseCursorWhileTyping = try container.decodeIfPresent(Bool.self, forKey: .hideMouseCursorWhileTyping)
            ?? SettingsDefaults.hideMouseCursorWhileTyping
        agentStatusHooksEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentStatusHooksEnabled)
            ?? SettingsDefaults.agentStatusHooksEnabled
        // Absent in schema versions below 14; those files fall back to the
        // current default rather than failing to decode.
        restoreScrollbackOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .restoreScrollbackOnLaunch)
            ?? SettingsDefaults.restoreScrollbackOnLaunch
        // Absent in schema versions below 16; those files fall back to the
        // current defaults rather than failing to decode.
        codeEditorFontSize = try container.decodeIfPresent(Double.self, forKey: .codeEditorFontSize)
            ?? SettingsDefaults.codeEditorFontSizePT
        codeEditorWrapsLines = try container.decodeIfPresent(Bool.self, forKey: .codeEditorWrapsLines)
            ?? SettingsDefaults.codeEditorWrapsLines
        // Absent in schema versions below 18; those files fall back to the
        // current defaults rather than failing to decode.
        notifyOnCommandFinish = try container.decodeIfPresent(String.self, forKey: .notifyOnCommandFinish)
            ?? SettingsDefaults.notifyOnCommandFinish
        minimumCommandDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .minimumCommandDurationSeconds)
            ?? SettingsDefaults.minimumCommandDurationSeconds
        // Absent in schema versions below 23; those files fall back to the
        // current default rather than failing to decode.
        notifyOnAgentWaiting = try container.decodeIfPresent(Bool.self, forKey: .notifyOnAgentWaiting)
            ?? SettingsDefaults.notifyOnAgentWaiting
        agentStatusHookConsent = try container.decodeIfPresent(String.self, forKey: .agentStatusHookConsent)
            ?? SettingsDefaults.agentStatusHookConsent
        agentStatusCodexHookConsent = try container
            .decodeIfPresent(String.self, forKey: .agentStatusCodexHookConsent)
            ?? SettingsDefaults.agentStatusCodexHookConsent
        // Absent in schema versions below 19; those files fall back to 100,
        // which is the size every existing install is already running at.
        uiTextScalePercent = try container.decodeIfPresent(Double.self, forKey: .uiTextScalePercent)
            ?? SettingsDefaults.uiTextScalePercent
        // Absent in schema versions below 19; those files fall back to the
        // current default rather than failing to decode.
        commandProgressIndicatorEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .commandProgressIndicatorEnabled
        ) ?? SettingsDefaults.commandProgressIndicatorEnabled
        // Absent in schema versions below 20; those files fall back to the
        // current default rather than failing to decode.
        menuBarExtraEnabled = try container.decodeIfPresent(Bool.self, forKey: .menuBarExtraEnabled)
            ?? SettingsDefaults.menuBarExtraEnabled
        // Absent in schema versions below 22; those files fall back to the
        // current default rather than failing to decode.
        promptNavigatorRailEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .promptNavigatorRailEnabled
        ) ?? SettingsDefaults.promptNavigatorRailEnabled
        // Absent in schema versions below 24; those files fall back to the
        // current default, which is off. A file that predates the key was
        // written by an install whose `CSI 21 t` answered nothing, so the
        // fallback and the migration below both say what was already true.
        titleReportsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .titleReportsEnabled
        ) ?? SettingsDefaults.titleReportsEnabled
        // Absent in schema versions below 22. The fallback is `false` — "not
        // shown yet" — and the migration below is what stops an existing
        // install from being told it is new.
        hasSeenGettingStarted = try container.decodeIfPresent(Bool.self, forKey: .hasSeenGettingStarted)
            ?? SettingsDefaults.hasSeenGettingStarted
    }
}

enum TerminalPaneBorderStyle: String, Codable, CaseIterable, Equatable {
    case none
    case hairline
    case active

    static let `default` = TerminalPaneBorderStyle(rawValue: SettingsDefaults.paneBorderStyle) ?? .none
}

/// Launch/default-window size; existing windows may apply it when settings are reloaded.
struct WindowSettings: Codable, Equatable {
    var width: Double
    var height: Double

    static let `default` = WindowSettings(
        width: SettingsDefaults.defaultWindowWidthPX,
        height: SettingsDefaults.defaultWindowHeightPX
    )
}

/// Launch-only defaults for new shell sessions; filesystem validation happens at
/// shell launch. `perProjectHistoryEnabled` is next-session: already-running
/// shells keep the `HISTFILE` they were spawned with.
struct ShellSettings: Codable, Equatable {
    var workingDirectory: String
    var perProjectHistoryEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case workingDirectory
        case perProjectHistoryEnabled
    }

    static let `default` = ShellSettings(
        workingDirectory: SettingsDefaults.shellWorkingDirectory
    )

    init(
        workingDirectory: String,
        perProjectHistoryEnabled: Bool = SettingsDefaults.perProjectHistoryEnabled
    ) {
        self.workingDirectory = workingDirectory
        self.perProjectHistoryEnabled = perProjectHistoryEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        // Absent in schema versions below 12; those files take the default.
        perProjectHistoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .perProjectHistoryEnabled)
            ?? SettingsDefaults.perProjectHistoryEnabled
    }

    static func normalizedWorkingDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.default.workingDirectory
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return Self.default.workingDirectory
        }
        return expanded
    }
}

struct TerminalColorSettings: Codable, Equatable {
    static let requiredAnsiColorCount = 16

    var foreground: String
    var background: String
    var cursor: String
    var ansi: [String]

    static let `default` = TerminalColorSettings(
        foreground: Defaults.foreground,
        background: Defaults.background,
        cursor: Defaults.cursor,
        ansi: Defaults.ansi
    )

    private enum Defaults {
        static let foreground = TerminalColorDefaults.foregroundHex
        static let background = TerminalColorDefaults.backgroundHex
        static let cursor = TerminalColorDefaults.cursorHex
        static let ansi = TerminalColorDefaults.ansiHex
    }

    var foregroundColor: SIMD4<Float> {
        ColorHexParser.parse(foreground, fallback: TerminalColorDefaults.foreground)
    }

    var backgroundColor: SIMD4<Float> {
        ColorHexParser.parse(background, fallback: TerminalColorDefaults.background)
    }

    var cursorColor: SIMD4<Float> {
        ColorHexParser.parse(cursor, fallback: TerminalColorDefaults.cursor)
    }
}

enum TerminalThemePreset {
    static let kurottyName = "kurotty"
    static let darkName = "kuro-dark"
    static let lighttyName = "lightty"
    static let nacreName = "nacre"
    static let customName = "custom"

    static func colors(named name: String) -> TerminalColorSettings? {
        switch canonicalName(name) {
        case kurottyName:
            return .default
        case darkName:
            return .default
        case lighttyName:
            return .lightty
        case nacreName:
            return .nacre
        default:
            return nil
        }
    }

    static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension TerminalColorSettings {
    /// Lightty draws on a white ground, and its palette was a dark-theme ramp
    /// with the background flipped: nine of its sixteen slots sat under 4.5:1,
    /// slot 15 was `#FFFFFF` on `#FFFFFF` -- contrast 1.00, invisible -- and
    /// the yellow slot held a purple one step from magenta. A shell prompt
    /// writes ordinary text in slots 7 and 15, so the terminal rendered blank.
    ///
    /// Recut against the floors Nacre is held to. Every slot clears 4.5:1 on
    /// the background; the six hue families sit far enough apart to keep
    /// `git diff` and `ls --color` legible; each bright variant goes darker and
    /// more chromatic than its normal, because "brighter" on a white ground
    /// cannot mean lighter without leaving the readable band.
    ///
    /// This reaches existing installs without a schema migration: a settings
    /// file that names a preset has that preset's colors reapplied on load, so
    /// the fix arrives with the build. `AppSettingsBehaviorTests` pins that
    /// path, since it is what makes the migration unnecessary.
    static let lightty = TerminalColorSettings(
        foreground: "#1D2228",
        background: "#FFFFFF",
        cursor: "#111111",
        ansi: [
            "#070B11",
            "#C05053",
            "#2E8441",
            "#996C1B",
            "#1877C9",
            "#AA569D",
            "#008283",
            "#4E545D",
            "#30353C",
            "#A92735",
            "#006A1E",
            "#7D5100",
            "#005DB8",
            "#933186",
            "#00676A",
            "#6D7580",
        ]
    )

    /// Nacre — a pale, low-chroma light palette.
    ///
    /// Every value here was solved, not picked. The generator worked in CIELCh
    /// against this background and the numbers it had to satisfy are pinned by
    /// `TerminalThemePaletteContrastTests`:
    ///
    /// - `foreground` clears 12.5:1 on `background` (AAA, not just AA).
    /// - Each of the twelve chromatic slots clears AA 4.5:1 on `background`.
    ///   The normal half sits at ~5.8:1 and the bright half at ~4.6:1, and both
    ///   halves are held at one lightness so no ANSI color is systematically
    ///   harder to read than its neighbours.
    /// - No two of the sixteen are closer than 8 CIEDE2000, and no two
    ///   *different* chromatic slots are closer than 20 — that second number is
    ///   what stops red and magenta from both landing on pale pink.
    ///
    /// The thing that makes this read pastel is the ground, not the ink. On a
    /// light background "pastel" has to mean low chroma at a readable
    /// lightness; raising lightness instead is what produces the pale-on-pale
    /// theme that photographs well and cannot be used. So the normal half is
    /// muted (62% of the available chroma at its lightness) and the bright half
    /// earns its "bright" from saturation (88%) rather than from being lighter,
    /// which is also the only way both halves clear AA at once.
    ///
    /// The four neutral slots are a deliberate ordered value ramp — black,
    /// bright black, white, bright white, darkest to lightest — carrying a
    /// faint hue drift so they separate by more than lightness alone.
    ///
    /// Slot 15 clears 4.5:1 like every other slot. It was previously held to
    /// the 3:1 non-text floor on the argument that a readable "bright white"
    /// on a light ground is a contradiction -- but a shell prompt writes
    /// ordinary text in slots 7 and 15 constantly, so that exemption rendered
    /// whole screens unreadable. The ramp is instead cut to fit the band a
    /// white ground actually leaves: slot 15 sits at the darkest point that is
    /// still the lightest step, and the other three are spread below it. All
    /// four are darker than a ramp drawn for a dark background would be.
    static let nacre = TerminalColorSettings(
        foreground: "#1F1E2D",
        background: "#FFFFFF",
        // Violet, at a hue no ANSI slot occupies, so the caret cannot be read
        // as a colored glyph. Lighter than the foreground on purpose: it has to
        // be found without outweighing the text it sits in.
        cursor: "#6A4BC8",
        ansi: [
            "#0C0C12",
            "#A43F3C",
            "#3B6D2F",
            "#755E2D",
            "#465F97",
            "#8F4099",
            "#3A6969",
            "#514F61",
            "#333141",
            "#D72935",
            "#248119",
            "#8D6B17",
            "#306FC9",
            "#B92ACC",
            "#247D7D",
            "#727084",
        ]
    )
}

enum ColorHexParser {
    static let blackHex = "#000000"

    static func parse(_ value: String, fallback: SIMD4<Float>) -> SIMD4<Float> {
        components(value) ?? fallback
    }

    /// `nil` for anything that is not a six-digit triplet. The fallback-taking
    /// overload cannot tell a malformed hex from one that happens to parse to
    /// the fallback, which is exactly the distinction an AppKit call site needs
    /// before it substitutes a system color.
    static func components(_ value: String) -> SIMD4<Float>? {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let raw = Int(hex, radix: 16) else {
            return nil
        }

        let red = Float((raw >> 16) & 0xff) / 255
        let green = Float((raw >> 8) & 0xff) / 255
        let blue = Float(raw & 0xff) / 255
        return SIMD4<Float>(red, green, blue, 1)
    }
}

// MARK: - Portable Settings Normalization

struct AppSettingsNormalizer {
    private enum Migration {
        /// Schema version that introduced `terminal.agentSessionIndexEnabled`.
        static let agentSessionIndexSchemaVersion = 11
        /// Schema version that introduced `terminal.hideMouseCursorWhileTyping`,
        /// `terminal.agentStatusHooksEnabled`, and
        /// `shell.perProjectHistoryEnabled`.
        static let paneBehaviorSchemaVersion = 12
        /// Schema version that introduced `terminal.confirmMultilinePaste`.
        static let multilinePasteConfirmationSchemaVersion = 13
        /// Schema version that introduced `terminal.restoreScrollbackOnLaunch`.
        static let scrollbackRestoreSchemaVersion = 14
        /// Schema version that introduced `terminal.statusBarEnabled`.
        static let statusBarSchemaVersion = 15
        /// Schema version that introduced `terminal.confirmCloseRunningProcess`.
        static let closeConfirmationSchemaVersion = 17
        /// Schema version that introduced `terminal.closeOnChildExit`.
        static let closeOnChildExitSchemaVersion = 18
        /// Schema version that introduced `terminal.notifyOnCommandFinish` and
        /// `terminal.minimumCommandDurationSeconds`. It also introduced
        /// `terminal.agentStatusHookConsent`, which is deliberately absent from
        /// the reset below: it records an answer the user gave, not a preference
        /// with a default worth re-applying.
        static let commandFinishNotificationSchemaVersion = 18
        /// Schema version that introduced `terminal.uiTextScalePercent`.
        static let uiTextScaleSchemaVersion = 19
        /// Schema version that introduced
        /// `terminal.commandProgressIndicatorEnabled`.
        static let commandProgressIndicatorSchemaVersion = 19
        /// Schema version that introduced `terminal.menuBarExtraEnabled`.
        static let menuBarExtraSchemaVersion = 20
        /// Schema version that introduced `terminal.promptNavigatorRailEnabled`.
        /// Both keys landed in 22 together, so the shared version is
        /// deliberate rather than two branches bumping to the same number.
        /// schema-lint: shared-version-ok
        static let promptNavigatorRailSchemaVersion = 22
        /// Schema version that introduced `terminal.hasSeenGettingStarted`.
        /// Both keys landed in 22 together, so the shared version is
        /// deliberate rather than two branches bumping to the same number.
        /// schema-lint: shared-version-ok
        static let gettingStartedSchemaVersion = 22
        /// Schema version that introduced `terminal.notifyOnAgentWaiting`.
        static let agentWaitingNotificationSchemaVersion = 23
        /// Schema version that introduced `terminal.titleReportsEnabled`.
        static let titleReportsSchemaVersion = 24
        /// Schema version that introduced `terminal.statusBarShowsAgent`,
        /// `terminal.statusBarShowsWorktree`, `terminal.statusBarShowsQuota`,
        /// `terminal.statusBarShowsResources`, `terminal.panePaddingPX`,
        /// `terminal.paneBorderStyle`, and
        /// `terminal.inactivePaneDimmingEnabled`. It also introduced
        /// `terminal.preventSystemSleep`, `terminal.tabGroupsEnabled`,
        /// `terminal.screenSnapshotBridgeEnabled`,
        /// `terminal.kittyIntegrationEnabled`, and
        /// `terminal.osc99NotificationsEnabled`.
        static let paneAppearanceSchemaVersion = 25
        // Schema 21 introduced `terminal.agentStatusCodexHookConsent`. It has no
        // migration branch for the same reason `terminal.agentStatusHookConsent`
        // has none: it records an answer the user gave, not a preference with a
        // default worth re-applying, and a file that predates the key has
        // answered nothing — which `unasked` already says.
    }

    static func normalized(_ settings: AppSettings) -> AppSettings {
        var next = settings
        let sourceSchemaVersion = next.schemaVersion ?? 0
        let currentSchemaVersion = AppSettings.default.schemaVersion ?? 1
        next.schemaVersion = currentSchemaVersion
        if sourceSchemaVersion < currentSchemaVersion {
            migrateLegacyDefaults(&next)
        }
        if sourceSchemaVersion < Migration.agentSessionIndexSchemaVersion {
            // Settings written before schema 11 predate the agent-session
            // index, so the key carries no user intent. Migrated files land on
            // the current default instead of inheriting whatever a hand-edited
            // older file might contain; from schema 11 on, an explicit choice
            // in either direction is preserved.
            next.terminal.agentSessionIndexEnabled = SettingsDefaults.agentSessionIndexEnabled
        }
        if sourceSchemaVersion < Migration.paneBehaviorSchemaVersion {
            // Settings written before schema 12 predate these three keys, so
            // they carry no user intent. Migrated files land on the current
            // defaults; from schema 12 on, an explicit choice is preserved.
            next.terminal.hideMouseCursorWhileTyping = SettingsDefaults.hideMouseCursorWhileTyping
            next.terminal.agentStatusHooksEnabled = SettingsDefaults.agentStatusHooksEnabled
            next.shell.perProjectHistoryEnabled = SettingsDefaults.perProjectHistoryEnabled
        }
        if sourceSchemaVersion < Migration.multilinePasteConfirmationSchemaVersion {
            // Settings written before schema 13 predate the multi-line paste
            // confirmation, so the key carries no user intent. Migrated files
            // land on the current default; from schema 13 on, an explicit
            // choice in either direction is preserved.
            next.terminal.confirmMultilinePaste = SettingsDefaults.confirmMultilinePaste
        }
        if sourceSchemaVersion < Migration.scrollbackRestoreSchemaVersion {
            // Settings written before schema 14 predate scrollback restore, so
            // the key carries no user intent. Migrated files land on the current
            // default; from schema 14 on, an explicit choice in either direction
            // is preserved.
            next.terminal.restoreScrollbackOnLaunch = SettingsDefaults.restoreScrollbackOnLaunch
        }
        if sourceSchemaVersion < Migration.statusBarSchemaVersion {
            // Settings written before schema 15 predate the bottom status bar,
            // so the key carries no user intent. Migrated files land on the
            // current default; from schema 15 on, an explicit choice in either
            // direction is preserved.
            next.terminal.statusBarEnabled = SettingsDefaults.statusBarEnabled
        }
        if sourceSchemaVersion < Migration.closeConfirmationSchemaVersion {
            // Settings written before schema 17 predate the close confirmation,
            // so the key carries no user intent. Migrated files land on the
            // current default; from schema 17 on, an explicit choice in either
            // direction is preserved.
            next.terminal.confirmCloseRunningProcess = SettingsDefaults.confirmCloseRunningProcess
        }
        if sourceSchemaVersion < Migration.closeOnChildExitSchemaVersion {
            // Settings written before schema 18 predate child-exit handling, so
            // the key carries no user intent. Migrated files land on the current
            // default; from schema 18 on, an explicit mode is preserved.
            next.terminal.closeOnChildExit = SettingsDefaults.closeOnChildExit
        }
        if sourceSchemaVersion < Migration.commandFinishNotificationSchemaVersion {
            // Settings written before schema 18 predate the command-finish
            // filter, so the keys carry no user intent. Migrated files land on
            // the current defaults; from schema 18 on, an explicit choice in
            // either direction is preserved.
            next.terminal.notifyOnCommandFinish = SettingsDefaults.notifyOnCommandFinish
            next.terminal.minimumCommandDurationSeconds = SettingsDefaults.minimumCommandDurationSeconds
        }
        if sourceSchemaVersion < Migration.uiTextScaleSchemaVersion {
            // Settings written before schema 19 predate the UI text scale, so
            // the key carries no user intent. Migrated files land on 100 — the
            // size they are already running at — rather than inheriting a
            // number a hand-edited older file might contain; from schema 19 on,
            // an explicit scale is preserved.
            next.terminal.uiTextScalePercent = SettingsDefaults.uiTextScalePercent
        }
        if sourceSchemaVersion < Migration.commandProgressIndicatorSchemaVersion {
            // Settings written before schema 19 predate the command progress
            // bar, so the key carries no user intent. Migrated files land on the
            // current default; from schema 19 on, an explicit choice in either
            // direction is preserved.
            next.terminal.commandProgressIndicatorEnabled = SettingsDefaults.commandProgressIndicatorEnabled
        }
        if sourceSchemaVersion < Migration.menuBarExtraSchemaVersion {
            // Settings written before schema 20 predate the menu-bar extra, so
            // the key carries no user intent. Migrated files land on the current
            // default; from schema 20 on, an explicit choice in either direction
            // is preserved.
            //
            // The default flipped from off to on after schema 22, and that flip
            // deliberately did **not** get a branch of its own. A file already
            // at schema 20 or later has `menuBarExtraEnabled` written out, and
            // `false` in such a file is ambiguous by construction: it says the
            // same thing whether the user tried the extra and removed it or
            // never opened Settings at all, because the branch above wrote the
            // then-current default for them. Nothing in the file distinguishes
            // the two, so the only choice is which way to be wrong. Re-applying
            // the new default would put an icon back into the menu bar of the
            // one user who is known to have engaged with the feature — the one
            // who removed it — in a bar Kurotty does not own. Preserving the
            // stored value instead costs a passive user a checkbox they can
            // still find in Settings, and costs them nothing else, because
            // every row the extra offers is reachable from the Dock icon and
            // the main menu bar anyway. So the flip reaches fresh installs and
            // pre-20 files, and leaves stored values alone.
            next.terminal.menuBarExtraEnabled = SettingsDefaults.menuBarExtraEnabled
        }
        if sourceSchemaVersion < Migration.promptNavigatorRailSchemaVersion {
            // Settings written before schema 22 predate the prompt navigator
            // rail, so the key carries no user intent. Migrated files land on
            // the current default, which is on — the rail draws nothing at all
            // in a session without OSC 133, so an install that gains it gains
            // no chrome it did not ask for. From schema 22 on, an explicit
            // choice in either direction is preserved.
            next.terminal.promptNavigatorRailEnabled = SettingsDefaults.promptNavigatorRailEnabled
        }
        if sourceSchemaVersion < Migration.gettingStartedSchemaVersion {
            // The one migration here that does *not* re-apply the default, and
            // deliberately so. `hasSeenGettingStarted` records an event rather
            // than a preference: a settings file that predates schema 22 was
            // written by an install that has been running for a while, so the
            // true statement about it is that first run already happened.
            // Landing it on the default instead would open a "Getting Started"
            // tab in front of an existing user on the upgrade that introduced
            // it, which is exactly the surprise the tab exists to avoid.
            next.terminal.hasSeenGettingStarted = true
        }
        if sourceSchemaVersion < Migration.agentWaitingNotificationSchemaVersion {
            // Settings written before schema 23 predate agent-waiting banners,
            // so the key carries no user intent. Migrated files land on the
            // current default; from schema 23 on, an explicit choice in either
            // direction is preserved.
            next.terminal.notifyOnAgentWaiting = SettingsDefaults.notifyOnAgentWaiting
        }
        if sourceSchemaVersion < Migration.titleReportsSchemaVersion {
            // Settings written before schema 24 predate title reports, so the
            // key carries no user intent — and the install that wrote them
            // answered `CSI 21 t` with nothing, which is exactly what the
            // default says. From schema 24 on, an explicit opt-in is preserved.
            next.terminal.titleReportsEnabled = SettingsDefaults.titleReportsEnabled
        }
        if sourceSchemaVersion < Migration.paneAppearanceSchemaVersion {
            // Settings written before schema 25 predate pane/status appearance
            // tuning, so the keys carry no user intent. Migrated files land on
            // values that match the window they already had; from schema 25 on,
            // explicit display and chrome choices are preserved.
            next.terminal.statusBarShowsAgent = SettingsDefaults.statusBarShowsAgent
            next.terminal.statusBarShowsWorktree = SettingsDefaults.statusBarShowsWorktree
            next.terminal.statusBarShowsQuota = SettingsDefaults.statusBarShowsQuota
            next.terminal.statusBarShowsResources = SettingsDefaults.statusBarShowsResources
            next.terminal.panePaddingPX = SettingsDefaults.panePaddingPX
            next.terminal.paneBorderStyle = SettingsDefaults.paneBorderStyle
            next.terminal.inactivePaneDimmingEnabled = SettingsDefaults.inactivePaneDimmingEnabled
            next.terminal.preventSystemSleep = SettingsDefaults.preventSystemSleep
            next.terminal.tabGroupsEnabled = SettingsDefaults.tabGroupsEnabled
            next.terminal.screenSnapshotBridgeEnabled = SettingsDefaults.screenSnapshotBridgeEnabled
            next.terminal.kittyIntegrationEnabled = SettingsDefaults.kittyIntegrationEnabled
            next.terminal.osc99NotificationsEnabled = SettingsDefaults.osc99NotificationsEnabled
        }
        normalizeTheme(&next, sourceSchemaVersion: sourceSchemaVersion)
        next.terminal.fontName = next.terminal.fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.terminal.fontName.isEmpty {
            next.terminal.fontName = AppSettings.default.terminal.fontName
        }
        next.terminal.fontSize = min(
            SettingsDefaults.maximumTerminalFontSizePT,
            max(SettingsDefaults.minimumTerminalFontSizePT, next.terminal.fontSize)
        )
        next.terminal.scrollbackLines = min(
            SettingsDefaults.maximumScrollbackRows,
            max(SettingsDefaults.minimumScrollbackRows, next.terminal.scrollbackLines)
        )
        // An unrecognized mode is stored back as the canonical default so the
        // saved file says what the app will actually do. An unreadable consent
        // record falls back to `unasked`, which asks again rather than assuming
        // a yes nobody gave.
        next.terminal.notifyOnCommandFinish = next.terminal.commandFinishNotificationMode.rawValue
        for target in AgentStatusHookTarget.allCases {
            next.terminal.setAgentStatusHookConsent(
                next.terminal.agentStatusHookConsentChoice(for: target),
                for: target
            )
        }
        next.terminal.minimumCommandDurationSeconds = min(
            SettingsDefaults.maximumAllowedCommandDurationSeconds,
            max(SettingsDefaults.minimumAllowedCommandDurationSeconds, next.terminal.minimumCommandDurationSeconds)
        )
        // Clamped through the one helper the design tokens also read, so a
        // hand-edited file cannot put the chrome somewhere the Settings slider
        // could not.
        next.terminal.uiTextScalePercent = SettingsDefaults.clampedUITextScalePercent(
            next.terminal.uiTextScalePercent
        )
        next.terminal.panePaddingPX = min(
            SettingsDefaults.maximumPanePaddingPX,
            max(SettingsDefaults.minimumPanePaddingPX, next.terminal.panePaddingPX)
        )
        next.terminal.paneBorderStyle = next.terminal.paneBorderStyleValue.rawValue
        next.window.width = min(
            SettingsDefaults.maximumWindowWidthPX,
            max(SettingsDefaults.minimumWindowWidthPX, next.window.width)
        )
        next.window.height = min(
            SettingsDefaults.maximumWindowHeightPX,
            max(SettingsDefaults.minimumWindowHeightPX, next.window.height)
        )
        if next.terminal.colors.ansi.count < TerminalColorSettings.requiredAnsiColorCount {
            next.terminal.colors.ansi = TerminalColorSettings.default.ansi
        } else if next.terminal.colors.ansi.count > TerminalColorSettings.requiredAnsiColorCount {
            next.terminal.colors.ansi = Array(next.terminal.colors.ansi.prefix(TerminalColorSettings.requiredAnsiColorCount))
        }
        return next
    }

    private static func normalizeTheme(_ settings: inout AppSettings, sourceSchemaVersion: Int) {
        let theme = TerminalThemePreset.canonicalName(settings.terminal.theme)
        if let presetColors = TerminalThemePreset.colors(named: theme) {
            let normalizedPresetName = theme == TerminalThemePreset.darkName
                ? TerminalThemePreset.kurottyName
                : theme
            let currentSchemaVersion = AppSettings.default.schemaVersion ?? 1
            let explicitPresetThemeCanResetColors = sourceSchemaVersion >= 7
            guard explicitPresetThemeCanResetColors || sourceSchemaVersion >= currentSchemaVersion || settings.terminal.colors == presetColors else {
                settings.terminal.theme = TerminalThemePreset.customName
                return
            }
            settings.terminal.theme = normalizedPresetName
            settings.terminal.colors = presetColors
            return
        }

        if theme.isEmpty {
            settings.terminal.theme = inferredThemeName(for: settings.terminal.colors)
            if let presetColors = TerminalThemePreset.colors(named: settings.terminal.theme) {
                settings.terminal.colors = presetColors
            }
            return
        }

        settings.terminal.theme = TerminalThemePreset.customName
    }

    private static func inferredThemeName(for colors: TerminalColorSettings) -> String {
        if colors == .lightty {
            return TerminalThemePreset.lighttyName
        }
        if colors == .nacre {
            return TerminalThemePreset.nacreName
        }
        if colors == .default {
            return TerminalThemePreset.kurottyName
        }
        return TerminalThemePreset.customName
    }

    private static func migrateLegacyDefaults(_ settings: inout AppSettings) {
        guard LegacyDefaults.shouldMigrate(colors: settings.terminal.colors) else {
            return
        }
        settings.terminal.theme = TerminalThemePreset.kurottyName
        settings.terminal.colors.foreground = TerminalColorSettings.default.foreground
        settings.terminal.colors.background = TerminalColorSettings.default.background
        settings.terminal.colors.cursor = TerminalColorSettings.default.cursor
        settings.terminal.colors.ansi = TerminalColorSettings.default.ansi
    }

    private enum LegacyDefaults {
        static let colors = TerminalColorSettings(
            foreground: "#EBEBEB",
            background: "#000000",
            cursor: "#D9D9D9",
            ansi: TerminalColorSettings.default.ansi
        )
        static let oldDefaultColors = TerminalColorSettings(
            foreground: "#E6EDF3",
            background: "#0B1020",
            cursor: "#7DD3FC",
            ansi: [
                "#3B4252",
                "#BF616A",
                "#A3BE8C",
                "#EBCB8B",
                "#81A1C1",
                "#B48EAD",
                "#88C0D0",
                "#E5E9F0",
                "#4C566A",
                "#BF616A",
                "#A3BE8C",
                "#EBCB8B",
                "#81A1C1",
                "#B48EAD",
                "#8FBCBB",
                "#ECEFF4",
            ]
        )
        static let previousKurottyColors = TerminalColorSettings(
            foreground: "#E5E7EB",
            background: "#24272E",
            cursor: "#D7C6F4",
            ansi: TerminalColorSettings.default.ansi
        )

        static func shouldMigrate(colors: TerminalColorSettings) -> Bool {
            colors == Self.colors || colors == Self.oldDefaultColors || colors == Self.previousKurottyColors
        }
    }
}

// MARK: - App-Side Settings Store

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()
    static let didChangeNotification = Notification.Name("dev.kurotty.settings.didChange")

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let persistence: AppSettingsPersistence

    let settingsURL: URL

    private enum Path {
        static let appDirectoryName = AppConstants.Settings.directoryName
        static let settingsFileName = AppConstants.Settings.fileName
        static let libraryDirectoryName = AppConstants.Storage.libraryDirectoryName
        static let applicationSupportDirectoryName = AppConstants.Storage.systemApplicationSupportDirectoryName
    }

    init(fileManager: FileManager = .default, settingsURL: URL? = nil) {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()

        self.settingsURL = settingsURL ?? Self.defaultSettingsURL(fileManager: fileManager)
        persistence = AppSettingsPersistence(fileManager: fileManager, settingsURL: self.settingsURL)
    }

    func loadRawJSON() throws -> String {
        let data = try encoder.encode(load())
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func load() throws -> AppSettings {
        let defaultData = try encoder.encode(AppSettings.default)
        let data = try persistence.loadOrCreateDefaultData(defaultData)
        let settings = AppSettingsNormalizer.normalized(try decoder.decode(AppSettings.self, from: data))
        installChromeScale(settings)
        return settings
    }

    func save(rawJSON: String) throws {
        let data = Data(rawJSON.utf8)
        let settings = AppSettingsNormalizer.normalized(try decoder.decode(AppSettings.self, from: data))
        try save(settings)
    }

    func save(_ settings: AppSettings) throws {
        let settings = AppSettingsNormalizer.normalized(settings)
        let normalizedData = try encoder.encode(settings)
        try persistence.save(normalizedData)
        // Strictly before the notification: every observer re-reads design
        // tokens to lay itself out again, and a scale installed afterwards
        // would leave the whole app one change behind.
        installChromeScale(settings)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.notificationSettingsKey: settings]
        )
    }

    /// Pushes the stored UI text scale into the design tokens. Done here rather
    /// than in each observer because the store is the one place every path —
    /// launch, save, and reload — already funnels through, and because the
    /// ordering guarantee above only exists if there is a single caller.
    private func installChromeScale(_ settings: AppSettings) {
        DesignTokens.UIScale.setPercent(settings.terminal.uiTextScalePercent)
    }

    static let notificationSettingsKey = "settings"

    private static func defaultSettingsURL(fileManager: FileManager) -> URL {
        guard let supportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(Path.libraryDirectoryName)
                .appendingPathComponent(Path.applicationSupportDirectoryName)
                .appendingPathComponent(Path.appDirectoryName)
                .appendingPathComponent(Path.settingsFileName)
        }

        return supportURL
            .appendingPathComponent(Path.appDirectoryName)
            .appendingPathComponent(Path.settingsFileName)
    }
}

// MARK: - App-Side Settings Persistence

struct AppSettingsPersistence: @unchecked Sendable {
    private let fileManager: FileManager
    private let settingsURL: URL
    private let queue = DispatchQueue(label: Queue.label)
    private let queueID = UUID()
    private static let queueKey = DispatchSpecificKey<UUID>()

    private enum Queue {
        static let label = "dev.kurotty.settings.persistence"
    }

    init(fileManager: FileManager, settingsURL: URL) {
        self.fileManager = fileManager
        self.settingsURL = settingsURL
        queue.setSpecific(key: Self.queueKey, value: queueID)
    }

    func loadOrCreateDefaultData(_ defaultData: Data) throws -> Data {
        try performOnPersistenceQueue {
            guard fileManager.fileExists(atPath: settingsURL.path) else {
                try ensureSettingsDirectoryExists()
                try defaultData.write(to: settingsURL, options: .atomic)
                return defaultData
            }

            return try Data(contentsOf: settingsURL)
        }
    }

    func save(_ data: Data) throws {
        try performOnPersistenceQueue {
            try ensureSettingsDirectoryExists()
            try data.write(to: settingsURL, options: .atomic)
        }
    }

    private func performOnPersistenceQueue<T: Sendable>(_ work: @Sendable @escaping () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueID {
            return try work()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = LockedPersistenceResult<T>()
        queue.async {
            let nextResult: Result<T, Error>
            do {
                nextResult = .success(try work())
            } catch {
                nextResult = .failure(error)
            }

            resultBox.set(nextResult)
            semaphore.signal()
        }
        semaphore.wait()

        return try resultBox.get()
    }

    private func ensureSettingsDirectoryExists() throws {
        let directoryURL = settingsURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}

private final class LockedPersistenceResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> Value {
        lock.lock()
        let result = self.result
        lock.unlock()
        return try result!.get()
    }
}
