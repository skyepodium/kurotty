import AppKit
import XCTest
@testable import KurottyApp
@testable import KurottyCore

/// Kurotty had presets and a hand-edited custom palette but no way to bring in
/// an existing scheme. The importer reads the two dominant theme ecosystems —
/// iTerm2 `.itermcolors` property lists and Ghostty's plain-text theme files —
/// and lands the result as the `custom` theme.
final class TerminalThemeImportTests: XCTestCase {
    // MARK: - Ghostty theme format

    /// Shape taken from Ghostty's bundled `themes/Dracula` file.
    private let ghosttyDraculaTheme = """
    palette = 0=#21222c
    palette = 1=#ff5555
    palette = 2=#50fa7b
    palette = 3=#f1fa8c
    palette = 4=#bd93f9
    palette = 5=#ff79c6
    palette = 6=#8be9fd
    palette = 7=#f8f8f2
    palette = 8=#6272a4
    palette = 9=#ff6e6e
    palette = 10=#69ff94
    palette = 11=#ffffa5
    palette = 12=#d6acff
    palette = 13=#ff92df
    palette = 14=#a4ffff
    palette = 15=#ffffff
    background = #282a36
    foreground = #f8f8f2
    cursor-color = #f8f8f2
    cursor-text = #282a36
    selection-background = #44475a
    selection-foreground = #f8f8f2
    """

    func testGhosttyThemeImportsAllColors() throws {
        let colors = try TerminalThemeImporter.theme(fromGhosttyTheme: ghosttyDraculaTheme)

        XCTAssertEqual(colors.background, "#282A36")
        XCTAssertEqual(colors.foreground, "#F8F8F2")
        XCTAssertEqual(colors.cursor, "#F8F8F2")
        XCTAssertEqual(colors.ansi.count, TerminalColorSettings.requiredAnsiColorCount)
        XCTAssertEqual(colors.ansi[0], "#21222C")
        XCTAssertEqual(colors.ansi[1], "#FF5555")
        XCTAssertEqual(colors.ansi[15], "#FFFFFF")
    }

    func testGhosttyExtended256PaletteEntriesAreIgnoredNotFatal() throws {
        // Ghostty configs can carry the whole 256-color cube; only 0-15 map to
        // Kurotty's ANSI contract.
        let theme = ghosttyDraculaTheme + "\npalette = 16=#000000\npalette = 231=#ffffff"
        let colors = try TerminalThemeImporter.theme(fromGhosttyTheme: theme)
        XCTAssertEqual(colors.ansi.count, TerminalColorSettings.requiredAnsiColorCount)
    }

    func testGhosttyHexWithoutHashAndCommentsAndBlankLinesParse() throws {
        var lines = (0..<16).map { "palette = \($0)=aabb\(String(format: "%02x", $0))" }
        lines.insert("# a comment line", at: 0)
        lines.append("")
        lines.append("background = 112233")
        lines.append("foreground = 445566")
        let colors = try TerminalThemeImporter.theme(fromGhosttyTheme: lines.joined(separator: "\n"))

        XCTAssertEqual(colors.background, "#112233")
        XCTAssertEqual(colors.ansi[3], "#AABB03")
    }

    func testGhosttyMissingCursorFallsBackToForeground() throws {
        let theme = ghosttyDraculaTheme
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("cursor-color") }
            .joined(separator: "\n")
        let colors = try TerminalThemeImporter.theme(fromGhosttyTheme: theme)
        XCTAssertEqual(colors.cursor, colors.foreground)
    }

    func testGhosttyIncompletePaletteThrows() {
        let theme = """
        palette = 0=#21222c
        background = #282a36
        foreground = #f8f8f2
        """
        XCTAssertThrowsError(try TerminalThemeImporter.theme(fromGhosttyTheme: theme)) { error in
            XCTAssertEqual(error as? TerminalThemeImportError, .incompletePalette)
        }
    }

    func testUnrecognizedTextThrowsUnrecognizedFormat() {
        XCTAssertThrowsError(
            try TerminalThemeImporter.importTheme(from: Data("not a theme at all".utf8))
        ) { error in
            XCTAssertEqual(error as? TerminalThemeImportError, .unrecognizedFormat)
        }
    }

    // MARK: - iTerm2 .itermcolors

    private func itermColorsPlist(
        includeCursor: Bool = true,
        ansiCount: Int = 16
    ) throws -> Data {
        func colorDictionary(red: Double, green: Double, blue: Double) -> [String: Any] {
            [
                "Color Space": "sRGB",
                "Red Component": red,
                "Green Component": green,
                "Blue Component": blue,
                "Alpha Component": 1,
            ]
        }
        var plist: [String: Any] = [
            "Foreground Color": colorDictionary(red: 1, green: 1, blue: 1),
            "Background Color": colorDictionary(red: 0, green: 0, blue: 0),
        ]
        if includeCursor {
            plist["Cursor Color"] = colorDictionary(red: 0.5, green: 0.5, blue: 0.5)
        }
        for index in 0..<ansiCount {
            plist["Ansi \(index) Color"] = colorDictionary(
                red: Double(index) / 15,
                green: 0,
                blue: 1
            )
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    func testITermColorsImportsAllColors() throws {
        let colors = try TerminalThemeImporter.importTheme(from: itermColorsPlist())

        XCTAssertEqual(colors.foreground, "#FFFFFF")
        XCTAssertEqual(colors.background, "#000000")
        XCTAssertEqual(colors.cursor, "#808080")
        XCTAssertEqual(colors.ansi.count, TerminalColorSettings.requiredAnsiColorCount)
        XCTAssertEqual(colors.ansi[0], "#0000FF")
        XCTAssertEqual(colors.ansi[15], "#FF00FF")
    }

    func testITermColorsBinaryPlistAlsoImports() throws {
        let xml = try itermColorsPlist()
        let object = try PropertyListSerialization.propertyList(from: xml, format: nil)
        let binary = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .binary,
            options: 0
        )
        let colors = try TerminalThemeImporter.importTheme(from: binary)
        XCTAssertEqual(colors.foreground, "#FFFFFF")
    }

    func testITermColorsMissingCursorFallsBackToForeground() throws {
        let colors = try TerminalThemeImporter.importTheme(
            from: itermColorsPlist(includeCursor: false)
        )
        XCTAssertEqual(colors.cursor, colors.foreground)
    }

    func testITermColorsIncompletePaletteThrows() throws {
        let data = try itermColorsPlist(ansiCount: 8)
        XCTAssertThrowsError(try TerminalThemeImporter.importTheme(from: data)) { error in
            XCTAssertEqual(error as? TerminalThemeImportError, .incompletePalette)
        }
    }

    // MARK: - Landing in settings

    func testImportedColorsSurviveNormalizationAsCustomTheme() throws {
        // The point of importing: the normalizer must not snap the palette back
        // to a preset, which is exactly what it does to unknown theme names
        // unless the theme is `custom`.
        let colors = try TerminalThemeImporter.theme(fromGhosttyTheme: ghosttyDraculaTheme)
        var settings = AppSettings.default
        settings.terminal.theme = TerminalThemePreset.customName
        settings.terminal.colors = colors

        let normalized = AppSettingsNormalizer.normalized(settings)

        XCTAssertEqual(normalized.terminal.theme, TerminalThemePreset.customName)
        XCTAssertEqual(normalized.terminal.colors, colors)
    }

    @MainActor
    func testPreferencesApplyImportedThemeColorsPersistsAsCustom() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-theme-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = AppSettingsStore(
            settingsURL: temporaryDirectory.appendingPathComponent("settings.json")
        )
        try store.save(.default)
        let view = PreferencesView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Component.preferencesWidthPX,
                height: DesignTokens.Component.preferencesHeightPX
            ),
            store: store
        )
        let colors = try TerminalThemeImporter.theme(fromGhosttyTheme: ghosttyDraculaTheme)

        view.applyImportedThemeColors(colors)

        XCTAssertEqual(view.settingsForTesting.terminal.theme, TerminalThemePreset.customName)
        XCTAssertEqual(view.settingsForTesting.terminal.colors, colors)
    }
}
