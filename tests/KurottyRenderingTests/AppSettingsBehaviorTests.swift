import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class AppSettingsBehaviorTests: XCTestCase {
    private var temporaryDirectory: URL!
    private static let appSettingsSourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/KurottyApp/AppSettings.swift")
    private static let settingsDefaultsSourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/KurottyCore/SettingsDefaults.swift")

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

    func testMainActorSettingsStoreDoesNotPerformDiskIO() throws {
        let source = try String(contentsOf: Self.appSettingsSourceURL, encoding: .utf8)
        let storeBody = try XCTUnwrap(Self.typeBody(named: "AppSettingsStore", in: source))
        let persistenceBody = try XCTUnwrap(Self.typeBody(named: "AppSettingsPersistence", in: source))

        XCTAssertTrue(source.contains("@MainActor\nfinal class AppSettingsStore"))
        XCTAssertFalse(storeBody.contains("fileExists(atPath:"))
        XCTAssertFalse(storeBody.contains("createDirectory("))
        XCTAssertFalse(storeBody.contains("Data(contentsOf:"))
        XCTAssertFalse(storeBody.contains(".write(to:"))
        XCTAssertTrue(source.contains("struct AppSettingsPersistence"))
        XCTAssertTrue(persistenceBody.contains("DispatchQueue"))
        XCTAssertFalse(persistenceBody.contains("queue.sync"))
        XCTAssertTrue(persistenceBody.contains("queue.async"))
        XCTAssertTrue(persistenceBody.contains("DispatchSemaphore"))
    }

    func testSettingsNormalizationIsSeparatedFromMainActorStore() throws {
        let source = try String(contentsOf: Self.appSettingsSourceURL, encoding: .utf8)
        let defaultsSource = try String(contentsOf: Self.settingsDefaultsSourceURL, encoding: .utf8)
        let portableValuesSection = try XCTUnwrap(Self.sectionBody(
            from: "// MARK: - Portable Settings Values",
            to: "// MARK: - Portable Settings Normalization",
            in: source
        ))
        let normalizerBody = try XCTUnwrap(Self.typeBody(named: "AppSettingsNormalizer", in: source))
        let storeBody = try XCTUnwrap(Self.typeBody(named: "AppSettingsStore", in: source))

        XCTAssertTrue(source.contains("// MARK: - Portable Settings Values"))
        XCTAssertTrue(source.contains("// MARK: - Portable Settings Normalization"))
        XCTAssertTrue(source.contains("// MARK: - App-Side Settings Store"))
        XCTAssertTrue(source.contains("struct AppSettingsNormalizer"))
        XCTAssertTrue(defaultsSource.contains("public enum SettingsDefaults"))
        XCTAssertTrue(defaultsSource.contains("public enum TerminalColorDefaults"))
        XCTAssertFalse(portableValuesSection.contains("DesignTokens"))
        XCTAssertFalse(portableValuesSection.contains("AppConstants"))
        XCTAssertFalse(normalizerBody.contains("DesignTokens"))
        XCTAssertFalse(normalizerBody.contains("AppConstants"))
        XCTAssertFalse(normalizerBody.contains("FileManager"))
        XCTAssertFalse(normalizerBody.contains("NotificationCenter"))
        XCTAssertFalse(storeBody.contains("migrateLegacyDefaults"))
        XCTAssertFalse(storeBody.contains("normalizeTheme"))
        XCTAssertTrue(storeBody.contains("AppSettingsNormalizer.normalized"))
    }

    @MainActor
    func testFirstInstallCreatesKurottyThemeSettings() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        let settings = try store.load()

        XCTAssertEqual(settings.terminal.theme, TerminalThemePreset.kurottyName)
        XCTAssertEqual(settings.terminal.colors, .default)
        XCTAssertEqual(settings.terminal.colors.background, "#22252B")
        XCTAssertEqual(settings.terminal.colors.foreground, "#E5E7EB")
        XCTAssertEqual(settings.terminal.colors.cursor, "#D7C6F4")
    }

    @MainActor
    func testPreviousKurottyDefaultMigratesToRetunedKurottyTheme() throws {
        let store = AppSettingsStore(settingsURL: settingsURL())

        try store.save(rawJSON: settingsJSON(
            schemaVersion: 7,
            theme: TerminalThemePreset.kurottyName,
            colors: previousKurottyColorsJSON()
        ))
        let settings = try store.load()

        XCTAssertEqual(settings.schemaVersion, AppSettings.default.schemaVersion)
        XCTAssertEqual(settings.terminal.theme, TerminalThemePreset.kurottyName)
        XCTAssertEqual(settings.terminal.colors, .default)
        XCTAssertEqual(settings.terminal.colors.background, "#22252B")
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
        var screen = KurottyCore.TerminalScreen(rows: 1, columns: 6)
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
        var screen = KurottyCore.TerminalScreen(rows: 1, columns: 12)
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
        var screen = KurottyCore.TerminalScreen(rows: 1, columns: 10)
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

    func testThemeReloadRemapsOnlyCellsUsingPreviousDefaultStyle() throws {
        let previousDefaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.9, 0.9, 0.9, 1),
            background: SIMD4<Float>(0.1, 0.1, 0.1, 1)
        )
        let nextDefaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.1, 0.1, 0.1, 1),
            background: SIMD4<Float>(1, 1, 1, 1)
        )
        let explicitStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.2, 0.7, 0.8, 1),
            background: SIMD4<Float>(0.4, 0.2, 0.9, 1)
        )
        var screen = KurottyCore.TerminalScreen(rows: 1, columns: 3)
        screen.set(character: "a", row: 0, column: 0, width: 1, style: previousDefaultStyle)
        screen.set(character: "b", row: 0, column: 1, width: 1, style: explicitStyle)
        screen.set(character: "c", row: 0, column: 2, width: 1, style: previousDefaultStyle)

        screen.remapStyle(from: previousDefaultStyle, to: nextDefaultStyle)

        XCTAssertEqual(screen.cells[0][0].style, nextDefaultStyle)
        XCTAssertEqual(screen.cells[0][1].style, explicitStyle)
        XCTAssertEqual(screen.cells[0][2].style, nextDefaultStyle)
    }

    func testThemeReloadRemapsPreviousPaletteColorsByForegroundAndBackgroundRole() throws {
        let previousDefaultStyle = TerminalTextStyle(
            foreground: TerminalColorSettings.lightty.foregroundColor,
            background: TerminalColorSettings.lightty.backgroundColor
        )
        let nextDefaultStyle = TerminalTextStyle(
            foreground: TerminalColorSettings.default.foregroundColor,
            background: TerminalColorSettings.default.backgroundColor
        )
        let previousAnsiColors = TerminalColorSettings.lightty.ansi.map {
            ColorHexParser.parse($0, fallback: TerminalColorDefaults.foreground)
        }
        let nextAnsiColors = TerminalColorSettings.default.ansi.map {
            ColorHexParser.parse($0, fallback: TerminalColorDefaults.foreground)
        }
        let colorMap = TerminalStyleColorMap(
            previousDefaultStyle: previousDefaultStyle,
            nextDefaultStyle: nextDefaultStyle,
            previousAnsiColors: previousAnsiColors,
            nextAnsiColors: nextAnsiColors
        )
        var screen = KurottyCore.TerminalScreen(rows: 1, columns: 3)
        let lighttyWhite = TerminalColorSettings.lightty.backgroundColor
        let promptStyle = TerminalTextStyle(
            foreground: lighttyWhite,
            background: previousAnsiColors[5]
        )
        let customStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.12, 0.34, 0.56, 1),
            background: SIMD4<Float>(0.65, 0.43, 0.21, 1)
        )
        screen.set(character: "a", row: 0, column: 0, width: 1, style: previousDefaultStyle)
        screen.set(character: "b", row: 0, column: 1, width: 1, style: promptStyle)
        screen.set(character: "c", row: 0, column: 2, width: 1, style: customStyle)

        screen.remapColors(colorMap)

        XCTAssertEqual(screen.cells[0][0].style.background, nextDefaultStyle.background)
        XCTAssertEqual(screen.cells[0][1].style.foreground, nextAnsiColors[15])
        XCTAssertEqual(screen.cells[0][1].style.background, nextAnsiColors[5])
        XCTAssertEqual(screen.cells[0][2].style, customStyle)
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

    private func settingsURL() -> URL {
        temporaryDirectory.appendingPathComponent("settings.json")
    }

    private static func typeBody(named typeName: String, in source: String) -> String? {
        let classRange = source.range(of: "final class \(typeName)")
        let structRange = source.range(of: "struct \(typeName)")
        guard let typeRange = classRange ?? structRange else {
            return nil
        }
        guard let openingBrace = source[typeRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func sectionBody(from startMarker: String, to endMarker: String, in source: String) -> String? {
        guard let start = source.range(of: startMarker)?.upperBound,
              let end = source[start...].range(of: endMarker)?.lowerBound
        else {
            return nil
        }
        return String(source[start..<end])
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
          "background": "#22252B",
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

    private func previousKurottyColorsJSON() -> String {
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
