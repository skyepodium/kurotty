import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class PreferencesValidationPresenterTests: XCTestCase {
    func testValidJSONReportsValidStatus() throws {
        let status = PreferencesValidationPresenter.status(
            for: try rawJSON(for: .default),
            directoryExists: { _ in true }
        )

        XCTAssertEqual(status.kind, .valid)
        XCTAssertEqual(status.message, "Settings valid.")
        XCTAssertTrue(status.issues.isEmpty)
    }

    func testValidationWarningsAreUserFacingAndSaveable() throws {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion - 1
        settings.shell.workingDirectory = "/missing-kurotty-preferences-validation"

        let status = PreferencesValidationPresenter.status(
            for: try rawJSON(for: settings),
            directoryExists: { _ in false }
        )

        XCTAssertEqual(status.kind, .warnings)
        XCTAssertTrue(status.canSave)
        XCTAssertTrue(status.message.hasPrefix("Warnings: "))
        XCTAssertTrue(status.message.contains("will migrate"))
        XCTAssertTrue(status.message.contains("does not exist"))
    }

    func testValidationErrorsAreUserFacingAndBlockSave() throws {
        var settings = AppSettings.default
        settings.terminal.fontSize = SettingsDefaults.minimumTerminalFontSizePT - 1
        settings.terminal.colors.foreground = "not-a-color"

        let status = PreferencesValidationPresenter.status(
            for: try rawJSON(for: settings),
            directoryExists: { _ in true }
        )

        XCTAssertEqual(status.kind, .errors)
        XCTAssertFalse(status.canSave)
        XCTAssertTrue(status.message.hasPrefix("Errors: "))
        XCTAssertTrue(status.message.contains("terminalFontSize"))
        XCTAssertTrue(status.message.contains("foreground"))
    }

    func testMalformedJSONReportsDecodeErrorAndBlocksSave() {
        let status = PreferencesValidationPresenter.status(
            for: "{",
            directoryExists: { _ in true }
        )

        XCTAssertEqual(status.kind, .errors)
        XCTAssertFalse(status.canSave)
        XCTAssertTrue(status.message.hasPrefix("Errors: Settings JSON is invalid: "))
    }

    private func rawJSON(for settings: AppSettings) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
