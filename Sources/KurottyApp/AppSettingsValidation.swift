import Foundation
import KurottyCore

enum AppSettingLifecycle: String, Codable, Equatable {
    case liveApplied
    case nextSession
    case launchOnly
}

enum AppSettingIssueSeverity: String, Codable, Equatable {
    case info
    case warning
    case error
}

enum AppSettingKey: String, Codable, Hashable {
    case schemaVersion
    case terminalTheme
    case terminalFontName
    case terminalFontSize
    case terminalScrollbackLines
    case terminalColorsForeground
    case terminalColorsBackground
    case terminalColorsCursor
    case terminalColorsAnsi
    case windowWidth
    case windowHeight
    case shellWorkingDirectory
}

enum AppSettingsValidationIssueCode: String, Codable, Equatable {
    case schemaMigrationAvailable
    case valueOutOfRange
    case invalidHexColor
    case invalidAnsiColorCount
    case workingDirectoryNormalized
    case workingDirectoryMissing
}

struct AppSettingsValidationIssue: Codable, Equatable {
    var key: AppSettingKey
    var lifecycle: AppSettingLifecycle
    var severity: AppSettingIssueSeverity
    var code: AppSettingsValidationIssueCode
    var message: String
}

struct AppSettingsValidationReport: Codable, Equatable {
    var sourceSchemaVersion: Int
    var currentSchemaVersion: Int
    var requiresMigration: Bool
    var normalizedWorkingDirectory: String
    var issues: [AppSettingsValidationIssue]
}

enum AppSettingsValidation {
    static func lifecycle(for key: AppSettingKey) -> AppSettingLifecycle {
        switch key {
        case .schemaVersion, .shellWorkingDirectory:
            return .launchOnly
        case .terminalTheme,
             .terminalFontName,
             .terminalFontSize,
             .terminalScrollbackLines,
             .terminalColorsForeground,
             .terminalColorsBackground,
             .terminalColorsCursor,
             .terminalColorsAnsi,
             .windowWidth,
             .windowHeight:
            return .liveApplied
        }
    }

    static func report(
        for settings: AppSettings,
        directoryExists: (String) -> Bool = defaultDirectoryExists
    ) -> AppSettingsValidationReport {
        let sourceSchemaVersion = settings.schemaVersion ?? 0
        let currentSchemaVersion = AppSettings.default.schemaVersion ?? SettingsDefaults.schemaVersion
        let normalizedWorkingDirectory = normalizedWorkingDirectory(settings.shell.workingDirectory)
        var issues: [AppSettingsValidationIssue] = []

        if sourceSchemaVersion < currentSchemaVersion {
            issues.append(issue(
                key: .schemaVersion,
                severity: .warning,
                code: .schemaMigrationAvailable,
                message: "Settings schema \(sourceSchemaVersion) will migrate to \(currentSchemaVersion)."
            ))
        }

        validateRange(
            key: .terminalFontSize,
            value: settings.terminal.fontSize,
            minimum: SettingsDefaults.minimumTerminalFontSizePT,
            maximum: SettingsDefaults.maximumTerminalFontSizePT,
            unit: "pt",
            issues: &issues
        )
        validateRange(
            key: .terminalScrollbackLines,
            value: settings.terminal.scrollbackLines,
            minimum: SettingsDefaults.minimumScrollbackRows,
            maximum: SettingsDefaults.maximumScrollbackRows,
            unit: "rows",
            issues: &issues
        )
        validateRange(
            key: .windowWidth,
            value: settings.window.width,
            minimum: SettingsDefaults.minimumWindowWidthPX,
            maximum: SettingsDefaults.maximumWindowWidthPX,
            unit: "px",
            issues: &issues
        )
        validateRange(
            key: .windowHeight,
            value: settings.window.height,
            minimum: SettingsDefaults.minimumWindowHeightPX,
            maximum: SettingsDefaults.maximumWindowHeightPX,
            unit: "px",
            issues: &issues
        )

        validateHex(settings.terminal.colors.foreground, key: .terminalColorsForeground, label: "foreground", issues: &issues)
        validateHex(settings.terminal.colors.background, key: .terminalColorsBackground, label: "background", issues: &issues)
        validateHex(settings.terminal.colors.cursor, key: .terminalColorsCursor, label: "cursor", issues: &issues)
        validateAnsiColors(settings.terminal.colors.ansi, issues: &issues)

        if normalizedWorkingDirectory != settings.shell.workingDirectory {
            issues.append(issue(
                key: .shellWorkingDirectory,
                severity: .info,
                code: .workingDirectoryNormalized,
                message: "Shell workingDirectory normalizes to \(normalizedWorkingDirectory)."
            ))
        }
        if !directoryExists(normalizedWorkingDirectory) {
            issues.append(issue(
                key: .shellWorkingDirectory,
                severity: .warning,
                code: .workingDirectoryMissing,
                message: "Shell workingDirectory does not exist: \(normalizedWorkingDirectory)."
            ))
        }

        return AppSettingsValidationReport(
            sourceSchemaVersion: sourceSchemaVersion,
            currentSchemaVersion: currentSchemaVersion,
            requiresMigration: sourceSchemaVersion < currentSchemaVersion,
            normalizedWorkingDirectory: normalizedWorkingDirectory,
            issues: issues
        )
    }

    private static func validateRange(
        key: AppSettingKey,
        value: Double,
        minimum: Double,
        maximum: Double,
        unit: String,
        issues: inout [AppSettingsValidationIssue]
    ) {
        guard value < minimum || value > maximum else {
            return
        }
        issues.append(issue(
            key: key,
            severity: .error,
            code: .valueOutOfRange,
            message: "\(key.rawValue) must be between \(minimum) and \(maximum) \(unit)."
        ))
    }

    private static func validateRange(
        key: AppSettingKey,
        value: Int,
        minimum: Int,
        maximum: Int,
        unit: String,
        issues: inout [AppSettingsValidationIssue]
    ) {
        guard value < minimum || value > maximum else {
            return
        }
        issues.append(issue(
            key: key,
            severity: .error,
            code: .valueOutOfRange,
            message: "\(key.rawValue) must be between \(minimum) and \(maximum) \(unit)."
        ))
    }

    private static func validateAnsiColors(_ colors: [String], issues: inout [AppSettingsValidationIssue]) {
        if colors.count != TerminalColorSettings.requiredAnsiColorCount {
            issues.append(issue(
                key: .terminalColorsAnsi,
                severity: .error,
                code: .invalidAnsiColorCount,
                message: "terminal.colors.ansi must contain \(TerminalColorSettings.requiredAnsiColorCount) colors."
            ))
        }

        for (index, color) in colors.enumerated() where !isHexColor(color) {
            issues.append(issue(
                key: .terminalColorsAnsi,
                severity: .error,
                code: .invalidHexColor,
                message: "terminal.colors.ansi[\(index)] must be #RRGGBB."
            ))
        }
    }

    private static func validateHex(
        _ value: String,
        key: AppSettingKey,
        label: String,
        issues: inout [AppSettingsValidationIssue]
    ) {
        guard !isHexColor(value) else {
            return
        }
        issues.append(issue(
            key: key,
            severity: .error,
            code: .invalidHexColor,
            message: "terminal.colors.\(label) must be #RRGGBB."
        ))
    }

    private static func issue(
        key: AppSettingKey,
        severity: AppSettingIssueSeverity,
        code: AppSettingsValidationIssueCode,
        message: String
    ) -> AppSettingsValidationIssue {
        AppSettingsValidationIssue(
            key: key,
            lifecycle: lifecycle(for: key),
            severity: severity,
            code: code,
            message: message
        )
    }

    private static func isHexColor(_ value: String) -> Bool {
        guard value.count == 7, value.first == "#" else {
            return false
        }
        return value.dropFirst().unicodeScalars.allSatisfy { hexDigits.contains($0) }
    }

    private static let hexDigits = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")

    private static func normalizedWorkingDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ShellSettings.default.workingDirectory
        }
        return NSString(string: trimmed).expandingTildeInPath
    }

    private static func defaultDirectoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
