import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class AppSettingsValidationTests: XCTestCase {
    func testDefaultSettingsValidateWithoutIssues() throws {
        let report = AppSettingsValidation.report(for: .default) { _ in true }

        XCTAssertEqual(report.sourceSchemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(report.currentSchemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertFalse(report.requiresMigration)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testInvalidColorCountAndHexShapeReportIssues() throws {
        var settings = AppSettings.default
        settings.terminal.colors.foreground = "112233"
        settings.terminal.colors.background = "#12345G"
        settings.terminal.colors.cursor = "#1234567"
        settings.terminal.colors.ansi = ["#000000", "blue"]

        let report = AppSettingsValidation.report(for: settings) { _ in true }

        XCTAssertEqual(
            Set(report.issues.map(\.key)),
            [
                .terminalColorsForeground,
                .terminalColorsBackground,
                .terminalColorsCursor,
                .terminalColorsAnsi,
            ]
        )
        XCTAssertTrue(report.issues.allSatisfy { $0.severity == .error })
        XCTAssertTrue(report.issues.allSatisfy { $0.lifecycle == .liveApplied })
        XCTAssertTrue(report.issues.contains {
            $0.key == .terminalColorsAnsi
                && $0.code == .invalidAnsiColorCount
                && $0.message.contains("16")
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .terminalColorsAnsi
                && $0.code == .invalidHexColor
                && $0.message.contains("ansi[1]")
        })
    }

    func testSettingKeysClassifyLifecycle() throws {
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .terminalFontSize), .liveApplied)
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .terminalScrollbackLines), .liveApplied)
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .windowWidth), .liveApplied)
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .windowHeight), .liveApplied)
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .shellWorkingDirectory), .launchOnly)
        XCTAssertEqual(AppSettingsValidation.lifecycle(for: .notificationsExposeBackgroundTaskOutputSummary), .liveApplied)
    }

    func testMigrationAndSchemaVersionAreReportedWithoutChangingSettingsShape() throws {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion - 1
        settings.terminal.fontSize = SettingsDefaults.minimumTerminalFontSizePT - 1
        settings.terminal.scrollbackLines = SettingsDefaults.maximumScrollbackRows + 1
        settings.window.width = SettingsDefaults.minimumWindowWidthPX - 1
        settings.window.height = SettingsDefaults.maximumWindowHeightPX + 1
        settings.shell.workingDirectory = "  ~/missing-kurotty-validation-fixture  "

        let report = AppSettingsValidation.report(for: settings) { _ in false }

        XCTAssertEqual(report.sourceSchemaVersion, SettingsDefaults.schemaVersion - 1)
        XCTAssertEqual(report.currentSchemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertTrue(report.requiresMigration)
        XCTAssertEqual(
            report.normalizedWorkingDirectory,
            NSString(string: settings.shell.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        )

        XCTAssertTrue(report.issues.contains {
            $0.key == .schemaVersion
                && $0.lifecycle == .launchOnly
                && $0.severity == .warning
                && $0.code == .schemaMigrationAvailable
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .terminalFontSize
                && $0.lifecycle == .liveApplied
                && $0.code == .valueOutOfRange
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .terminalScrollbackLines
                && $0.lifecycle == .liveApplied
                && $0.code == .valueOutOfRange
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .windowWidth
                && $0.lifecycle == .liveApplied
                && $0.code == .valueOutOfRange
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .windowHeight
                && $0.lifecycle == .liveApplied
                && $0.code == .valueOutOfRange
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .shellWorkingDirectory
                && $0.lifecycle == .launchOnly
                && $0.code == .workingDirectoryNormalized
        })
        XCTAssertTrue(report.issues.contains {
            $0.key == .shellWorkingDirectory
                && $0.lifecycle == .launchOnly
                && $0.code == .workingDirectoryMissing
        })

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNil(decoded?["validation"])
        XCTAssertNil(decoded?["lifecycle"])
        XCTAssertNil(decoded?["issues"])
    }
}
