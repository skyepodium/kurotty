import Foundation

enum AppConstants {
    enum Bundle {
        static let displayName = "Kurotty"
        static let iconResourceName = "kurotty"
        static let iconResourceExtension = "png"
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
}
