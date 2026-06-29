import Foundation

enum AppConstants {
    enum Bundle {
        static let displayName = "kurotty"
        static let iconResourceName = "kurotty"
        static let iconResourceExtension = "png"
        static let installedIconExtension = "icns"
        static let applicationIconSizePT: CGFloat = 50
        static let developmentVersion = "0.1.0-alpha.2"
        static let developmentBuild = "dev"

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
        static let cursorWidthPX: Float = 2
        static let cursorBlinkIntervalSeconds: TimeInterval = 0.55
        static let minimumCellWidthPX: CGFloat = 8
    }

    enum Settings {
        static let fileName = "settings.json"
        static let directoryName = "Kurotty"
    }

    enum Shell {
        static let term = "xterm-256color"
        static let colorTerm = "truecolor"
        static let prompt = "%F{cyan}%n%f %F{green}%~%f "
    }

    enum Notifications {
        static let categoryIdentifier = "dev.kurotty.terminal"
        static let shellExitIdentifierPrefix = "dev.kurotty.terminal.shell-exit"
        static let osc9IdentifierPrefix = "dev.kurotty.terminal.osc9"
        static let codexIdentifierPrefix = "dev.kurotty.terminal.codex"
        static let defaultTitle = "Alert"
        static let shellExitTitle = "Alert"
        static let shellExitSuccessBody = "Shell exited successfully."
        static let shellExitFailureBodyPrefix = "Shell exited with status"
        static let testBody = "Kurotty test notification."
        static let codexTaskCompletedBody = "Codex 작업이 완료되었습니다."
    }
}
