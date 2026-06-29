import XCTest
@testable import KurottyApp

final class AppSettingsBehaviorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    @MainActor
    func testSaveLoadMigratesMissingShellSettingsToHomeDirectory() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: legacySettingsJSON(shell: nil))
        let settings = try store.load()

        XCTAssertEqual(settings.schemaVersion, AppSettings.default.schemaVersion)
        XCTAssertEqual(settings.shell.workingDirectory, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testShellWorkingDirectoryNormalizationExpandsTildeAndRejectsInvalidPaths() throws {
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory("~"),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(""),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(settingsURL().path),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(temporaryDirectory.path),
            temporaryDirectory.path
        )
    }

    func testBundleDisplayVersionUsesInfoDictionaryAndDevelopmentFallback() throws {
        let releaseBundle = try makeBundle(
            named: "ReleaseFixture.bundle",
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "45",
            ]
        )
        XCTAssertEqual(AppConstants.Bundle.displayVersion(bundle: releaseBundle), "1.2.3 (45)")

        let developmentBundle = try makeBundle(named: "DevelopmentFixture.bundle", infoDictionary: [:])
        XCTAssertEqual(AppConstants.Bundle.displayVersion(bundle: developmentBundle), "0.1.0-alpha.2 (dev)")
    }

    @MainActor
    func testSaveLoadPersistsValidShellWorkingDirectory() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: legacySettingsJSON(shell: #","shell":{"workingDirectory":"\#(temporaryDirectory.path)"}"#))
        let settings = try store.load()

        XCTAssertEqual(settings.shell.workingDirectory, temporaryDirectory.path)
    }

    @MainActor
    func testSaveLoadPreservesInvalidShellWorkingDirectoryForLaunchTimeValidation() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())
        let invalidPath = temporaryDirectory.appendingPathComponent("missing").path

        try store.save(rawJSON: legacySettingsJSON(shell: #","shell":{"workingDirectory":"\#(invalidPath)"}"#))
        let settings = try store.load()

        XCTAssertEqual(settings.shell.workingDirectory, invalidPath)
        XCTAssertEqual(
            ShellSettings.normalizedWorkingDirectory(settings.shell.workingDirectory),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    @MainActor
    func testExistingSettingsFileLoadsWithoutResettingToDefaults() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())
        let expectedFontSize = 18.0
        let expectedScrollbackLines = 12_345
        let expectedWindowWidth = 900.0
        let expectedWindowHeight = 640.0

        try store.save(rawJSON: settingsJSON(
            schemaVersion: 5,
            theme: TerminalThemePreset.customName,
            colors: customColorsJSON(),
            fontName: "Monaco",
            fontSize: expectedFontSize,
            scrollbackLines: expectedScrollbackLines,
            windowWidth: expectedWindowWidth,
            windowHeight: expectedWindowHeight,
            shell: #","shell":{"workingDirectory":"\#(temporaryDirectory.path)"}"#
        ))
        let settings = try store.load()

        XCTAssertEqual(settings.terminal.fontName, "Monaco")
        XCTAssertEqual(settings.terminal.fontSize, expectedFontSize)
        XCTAssertEqual(settings.terminal.scrollbackLines, expectedScrollbackLines)
        XCTAssertEqual(settings.window.width, expectedWindowWidth)
        XCTAssertEqual(settings.window.height, expectedWindowHeight)
        XCTAssertEqual(settings.shell.workingDirectory, temporaryDirectory.path)
    }

    @MainActor
    func testPresetThemeNameDoesNotResetCustomColorsDuringSettingsMigration() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: settingsJSON(
            schemaVersion: 4,
            theme: TerminalThemePreset.darkName,
            colors: customColorsJSON()
        ))
        let settings = try store.load()

        XCTAssertEqual(settings.terminal.theme, TerminalThemePreset.customName)
        XCTAssertEqual(settings.terminal.colors.foreground, "#111111")
        XCTAssertEqual(settings.terminal.colors.background, "#222222")
        XCTAssertEqual(settings.terminal.colors.cursor, "#333333")
        XCTAssertEqual(settings.terminal.colors.ansi.first, "#000001")
        XCTAssertEqual(settings.terminal.colors.ansi.last, "#000010")
    }

    @MainActor
    func testNotificationPrivacyDefaultsDoNotExposeBackgroundTaskOutput() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: settingsJSON(
            schemaVersion: 5,
            theme: TerminalThemePreset.darkName,
            colors: defaultColorsJSON()
        ))
        let settings = try store.load()

        XCTAssertEqual(settings.schemaVersion, AppSettings.default.schemaVersion)
        XCTAssertFalse(settings.notifications.exposeBackgroundTaskOutputSummary)
    }

    @MainActor
    func testNotificationPrivacyOptInIsPreserved() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: settingsJSON(
            schemaVersion: 6,
            theme: TerminalThemePreset.darkName,
            colors: defaultColorsJSON(),
            notifications: #","notifications":{"exposeBackgroundTaskOutputSummary":true}"#
        ))
        let settings = try store.load()

        XCTAssertTrue(settings.notifications.exposeBackgroundTaskOutputSummary)
    }

    private func settingsURL() -> URL {
        temporaryDirectory.appendingPathComponent("settings.json")
    }

    private func makeBundle(named name: String, infoDictionary: [String: String]) throws -> Bundle {
        let bundleURL = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        try (infoDictionary as NSDictionary).write(to: infoURL)
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func legacySettingsJSON(shell: String?) -> String {
        settingsJSON(
            schemaVersion: 4,
            theme: TerminalThemePreset.darkName,
            colors: defaultColorsJSON(),
            shell: shell
        )
    }

    private func settingsJSON(
        schemaVersion: Int,
        theme: String,
        colors: String,
        fontName: String = "Menlo",
        fontSize: Double = 15,
        scrollbackLines: Int = 1000,
        windowWidth: Double = 1100,
        windowHeight: Double = 720,
        shell: String? = nil,
        notifications: String? = nil
    ) -> String {
        """
        {
          "schemaVersion": \(schemaVersion),
          "terminal": {
            "theme": "\(theme)",
            "fontName": "\(fontName)",
            "fontSize": \(fontSize),
            "scrollbackLines": \(scrollbackLines),
            "colors": \(colors)
          },
          "window": {
            "width": \(windowWidth),
            "height": \(windowHeight)
          }\(shell ?? "")\(notifications ?? "")
        }
        """
    }

    private func defaultColorsJSON() -> String {
        """
        {
          "foreground": "#E6EDF3",
          "background": "#0B1020",
          "cursor": "#7DD3FC",
          "ansi": [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"
          ]
        }
        """
    }

    private func customColorsJSON() -> String {
        """
        {
          "foreground": "#111111",
          "background": "#222222",
          "cursor": "#333333",
          "ansi": [
            "#000001", "#000002", "#000003", "#000004",
            "#000005", "#000006", "#000007", "#000008",
            "#000009", "#00000A", "#00000B", "#00000C",
            "#00000D", "#00000E", "#00000F", "#000010"
          ]
        }
        """
    }
}
