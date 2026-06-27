import Foundation

enum AppConstants {
    enum Bundle {
        static let displayName = "kurotty"
        static let iconResourceName = "kurotty"
        static let iconResourceExtension = "png"
        static let applicationIconSizePT: CGFloat = 50
    }

    enum Terminal {
        static let defaultColumns = 120
        static let defaultRows = 40
        static let tabWidthColumns = 8
        static let maxScrollbackRows = 1_000_000
        static let cursorWidthPX: Float = 2
        static let minimumCellWidthPX: CGFloat = 8
    }

    enum Settings {
        static let fileName = "settings.json"
        static let directoryName = "Kurotty"
    }

    enum Shell {
        static let term = "xterm-256color"
        static let colorTerm = "truecolor"
        static let defaultWorkingDirectory = FileManager.default.currentDirectoryPath
        static let prompt = "%F{cyan}%n%f %F{green}%~%f "
    }

    enum Notifications {
        static let categoryIdentifier = "dev.kurotty.terminal"
        static let shellExitIdentifierPrefix = "dev.kurotty.terminal.shell-exit"
        static let osc9IdentifierPrefix = "dev.kurotty.terminal.osc9"
        static let defaultTitle = "Kurotty"
        static let shellExitTitle = "Terminal finished"
        static let shellExitSuccessBody = "Shell exited successfully."
        static let shellExitFailureBodyPrefix = "Shell exited with status"
    }
}
