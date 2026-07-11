import Foundation

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
        static let cursorWidthPX: Float = 2
        static let cursorBlinkIntervalSeconds: TimeInterval = 0.55
        static let minimumCellWidthPX: CGFloat = 8
    }

    enum Settings {
        static let fileName = "settings.json"
        static let directoryName = "Kurotty"
        static let minimumTerminalFontSizePT = 8.0
        static let maximumTerminalFontSizePT = 48.0
        static let defaultWindowWidthPX = 1100.0
        static let defaultWindowHeightPX = 720.0
        static let minimumWindowWidthPX = 320.0
        static let maximumWindowWidthPX = 4_000.0
        static let minimumWindowHeightPX = 240.0
        static let maximumWindowHeightPX = 3_000.0
    }

    enum Shell {
        static let term = "xterm-256color"
        static let colorTerm = "truecolor"
        static let termProgram = "Kurotty"
        static let prompt = "%F{cyan}%n%f %F{green}%~%f "
        static let childExecFailureStatusCode: Int32 = 127
        static let signalExitStatusBase: Int32 = 128
        static let ptyWriteRetryDelayMicros: useconds_t = 1_000
        static let inputDrainRetryDelaysMS = [4, 8, 16, 32, 64, 120]
        static let ptyReadBufferSizeBytes = 8192
        static let maximumUTF8ScalarBytes = 4
    }

    enum Rendering {
        static let visibleCellReserveDivisor = 2
        static let forceFullModelRedrawUntilDamageIsVerified = false
    }

    enum Tmux {
        private static let themeStatusBackgroundColor = "colour99"
        private static let themeStatusForegroundColor = "colour255"
        private static let themeStatusMutedForegroundColor = "colour189"
        private static let themeCurrentWindowBackgroundColor = "colour135"
        private static let themeStatusLeftLengthColumns = 48
        private static let themeStatusRightLengthColumns = 8

        static let prefix = "\u{2}"
        static let newWindowSequence = "\u{2}c"
        static let splitHorizontallySequence = "\u{2}\""
        static let splitVerticallySequence = "\u{2}%"
        static let previousWindowSequence = "\u{2}p"
        static let nextWindowSequence = "\u{2}n"
        static let detachClientSequence = "\u{2}d"
        static let attachOrCreateSessionCommand = "tmux new-session -A -s kurotty\r"
        static let listSessionsCommand = "tmux list-sessions\r"
        static let applyKurottyThemeCommand = [
            "tmux set-option status on",
            "tmux set-option status-style bg=\(themeStatusBackgroundColor),fg=\(themeStatusForegroundColor)",
            "tmux set-option status-left-style bg=\(themeStatusBackgroundColor),fg=\(themeStatusForegroundColor)",
            "tmux set-option status-right-style bg=\(themeStatusBackgroundColor),fg=\(themeStatusForegroundColor)",
            "tmux set-option window-status-style bg=\(themeStatusBackgroundColor),fg=\(themeStatusMutedForegroundColor)",
            "tmux set-option window-status-current-style bg=\(themeCurrentWindowBackgroundColor),fg=\(themeStatusForegroundColor),bold",
            "tmux set-option status-left-length \(themeStatusLeftLengthColumns)",
            "tmux set-option status-right-length \(themeStatusRightLengthColumns)",
            "tmux set-option status-justify left",
            "tmux set-option window-status-format ''",
            "tmux set-option window-status-current-format ''",
            "tmux set-option status-left '[#S] #{window_index}:#{window_name}#{window_flags} '",
            "tmux set-option status-right ' %H:%M '",
        ].joined(separator: "; ") + "\r"

        static let menuTitle = "Tmux"
        static let attachOrCreateSessionMenuTitle = "Attach or Create Tmux Session"
        static let listSessionsMenuTitle = "List Tmux Sessions"
        static let applyKurottyThemeMenuTitle = "Apply Kurotty Tmux Theme"
        static let newWindowMenuTitle = "New Tmux Window"
        static let splitHorizontallyMenuTitle = "Split Tmux Horizontally"
        static let splitVerticallyMenuTitle = "Split Tmux Vertically"
        static let previousWindowMenuTitle = "Previous Tmux Window"
        static let nextWindowMenuTitle = "Next Tmux Window"
        static let detachClientMenuTitle = "Detach Tmux Client"
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
    }
}
