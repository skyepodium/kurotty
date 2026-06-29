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
        XCTAssertEqual(AppConstants.Bundle.displayVersion(bundle: developmentBundle), "development (dev)")
    }

    @MainActor
    func testFirstInstallCreatesKurottyThemeSettings() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        let settings = try store.load()

        XCTAssertEqual(settings.terminal.theme, TerminalThemePreset.kurottyName)
        XCTAssertEqual(settings.terminal.colors, .default)
        XCTAssertEqual(settings.terminal.colors.background, "#24272E")
        XCTAssertEqual(settings.terminal.colors.foreground, "#E5E7EB")
        XCTAssertEqual(settings.terminal.colors.cursor, "#D7C6F4")
    }

    @MainActor
    func testOldDefaultDarkThemeMigratesToKurottyTheme() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: settingsJSON(
            schemaVersion: 6,
            theme: TerminalThemePreset.darkName,
            colors: oldDefaultColorsJSON()
        ))
        let settings = try store.load()

        XCTAssertEqual(settings.schemaVersion, AppSettings.default.schemaVersion)
        XCTAssertEqual(settings.terminal.theme, TerminalThemePreset.kurottyName)
        XCTAssertEqual(settings.terminal.colors, .default)
    }

    @MainActor
    func testExplicitKurottyThemeAppliesPresetColorsOverExistingThemeColors() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: settingsJSON(
            schemaVersion: 7,
            theme: TerminalThemePreset.kurottyName,
            colors: lighttyColorsJSON()
        ))
        let settings = try store.load()

        XCTAssertEqual(settings.terminal.theme, TerminalThemePreset.kurottyName)
        XCTAssertEqual(settings.terminal.colors, .default)
    }

    func testTmuxConstantsUseDefaultPrefixAndSessionCommands() throws {
        XCTAssertEqual(AppConstants.Tmux.prefix, "\u{2}")
        XCTAssertEqual(AppConstants.Tmux.newWindowSequence, "\u{2}c")
        XCTAssertEqual(AppConstants.Tmux.splitHorizontallySequence, "\u{2}\"")
        XCTAssertEqual(AppConstants.Tmux.splitVerticallySequence, "\u{2}%")
        XCTAssertEqual(AppConstants.Tmux.previousWindowSequence, "\u{2}p")
        XCTAssertEqual(AppConstants.Tmux.nextWindowSequence, "\u{2}n")
        XCTAssertEqual(AppConstants.Tmux.detachClientSequence, "\u{2}d")
        XCTAssertEqual(AppConstants.Tmux.attachOrCreateSessionCommand, "tmux new-session -A -s kurotty\r")
        XCTAssertEqual(AppConstants.Tmux.listSessionsCommand, "tmux list-sessions\r")
        XCTAssertTrue(AppConstants.Tmux.applyKurottyThemeCommand.contains("tmux set-option status-style bg=colour99,fg=colour255"))
        XCTAssertTrue(AppConstants.Tmux.applyKurottyThemeCommand.contains("tmux set-option window-status-current-style bg=colour135,fg=colour255,bold"))
        XCTAssertTrue(AppConstants.Tmux.applyKurottyThemeCommand.contains("tmux set-option status-justify left"))
        XCTAssertTrue(AppConstants.Tmux.applyKurottyThemeCommand.contains("tmux set-option window-status-format ''"))
        XCTAssertTrue(AppConstants.Tmux.applyKurottyThemeCommand.contains("tmux set-option status-left '[#S] #{window_index}:#{window_name}#{window_flags} '"))
        XCTAssertTrue(AppConstants.Tmux.applyKurottyThemeCommand.contains("tmux set-option status-right ' %H:%M '"))
        XCTAssertFalse(AppConstants.Tmux.applyKurottyThemeCommand.contains("set-option -g"))
        XCTAssertTrue(AppConstants.Tmux.applyKurottyThemeCommand.hasSuffix("\r"))
    }

    func testRepeatPrecedingGraphicCharacterCopiesCellAndStyleForTmuxStatusRedraws() throws {
        var screen = TerminalScreen(rows: 1, columns: 6)
        let style = TerminalTextStyle(
            foreground: SIMD4<Float>(1, 1, 1, 1),
            background: SIMD4<Float>(0.35, 0.2, 0.9, 1)
        )

        screen.set(character: "0", row: 0, column: 0, width: 1, style: style)
        let written = screen.repeatPrecedingGraphicCharacter(row: 0, column: 1, count: 3)

        XCTAssertEqual(written, 3)
        XCTAssertEqual(String(screen.cells[0][0].character), "0")
        XCTAssertEqual(String(screen.cells[0][1].character), "0")
        XCTAssertEqual(String(screen.cells[0][2].character), "0")
        XCTAssertEqual(String(screen.cells[0][3].character), "0")
        XCTAssertEqual(screen.cells[0][1].style, style)
        XCTAssertEqual(screen.cells[0][3].style, style)
    }

    func testPrintableSpaceOverwritesPreviousGlyphForColumnAlignedOutput() throws {
        var screen = TerminalScreen(rows: 1, columns: 12)
        let promptStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(1, 1, 1, 1),
            background: SIMD4<Float>(0.35, 0.2, 0.9, 1)
        )
        for (column, character) in Array("Package.swift").enumerated() {
            screen.set(character: character, row: 0, column: column, width: 1, style: promptStyle)
        }

        for (column, character) in Array("AGENTS.md   ").enumerated() {
            screen.set(character: character, row: 0, column: column, width: 1, style: .default)
        }

        XCTAssertEqual(String(screen.cells[0].map(\.character)), "AGENTS.md   ")
        XCTAssertEqual(screen.cells[0][9].style, .default)
        XCTAssertEqual(screen.cells[0][10].style, .default)
        XCTAssertEqual(screen.cells[0][11].style, .default)
    }

    func testEraseCharacterClearsOnlyRequestedCellsWithCurrentStyle() throws {
        var screen = TerminalScreen(rows: 1, columns: 10)
        let statusStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(1, 1, 1, 1),
            background: SIMD4<Float>(0.35, 0.2, 0.9, 1)
        )
        for (column, character) in Array("02:18xxxxx").enumerated() {
            screen.set(character: character, row: 0, column: column, width: 1, style: .default)
        }

        screen.clear(row: 0, from: 5, through: 9, style: statusStyle)

        XCTAssertEqual(String(screen.cells[0].map(\.character)), "02:18     ")
        XCTAssertEqual(screen.cells[0][4].style, .default)
        XCTAssertEqual(screen.cells[0][5].style, statusStyle)
        XCTAssertEqual(screen.cells[0][9].style, statusStyle)
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
          "foreground": "#E5E7EB",
          "background": "#24272E",
          "cursor": "#D7C6F4",
          "ansi": [
            "#2F333A", "#FF5F67", "#5FD38D", "#E5C07B",
            "#61AFEF", "#C792EA", "#56B6C2", "#D7DAE0",
            "#60646C", "#FF7B86", "#8EE8A3", "#F0D28A",
            "#7AB7FF", "#D7A8FF", "#7FDCE3", "#F5F7FA"
          ]
        }
        """
    }

    private func oldDefaultColorsJSON() -> String {
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

    private func lighttyColorsJSON() -> String {
        """
        {
          "foreground": "#202124",
          "background": "#FFFFFF",
          "cursor": "#111111",
          "ansi": [
            "#AFA7F5", "#AB4634", "#55C236", "#9A4DB4",
            "#3347C3", "#B445B8", "#4FC3C7", "#C9C9C9",
            "#666666", "#D47D78", "#55B94A", "#A452BD",
            "#5B5AA2", "#CF75D3", "#35B9BD", "#FFFFFF"
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
