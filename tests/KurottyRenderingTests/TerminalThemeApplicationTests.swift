import AppKit
import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// What changing the theme does to a terminal that already has content on
/// screen, and what the light preset actually is.
///
/// These replace part of `testSettingsOwnWindowSizeAndMenuDoesNotDuplicateSettings`,
/// which asserted the lightty preset by matching its hex literals in
/// `AppSettings.swift` and the remap by matching `"screen.remapColors(colorMap)"`.
/// Neither noticed whether a single cell changed colour.
@MainActor
final class TerminalThemeApplicationTests: XCTestCase {
    /// The light preset is a shipped product decision, so it is pinned as
    /// values. A palette edit should be a deliberate change to this list.
    func testLightPresetPinsItsShippedPalette() throws {
        let lightty = try XCTUnwrap(TerminalThemePreset.colors(named: TerminalThemePreset.lighttyName))

        XCTAssertEqual(lightty.foreground, "#202124")
        XCTAssertEqual(lightty.background, "#FFFFFF")
        XCTAssertEqual(lightty.cursor, "#111111")
        // The old source-text form asserted eight hex strings appeared somewhere
        // in AppSettings.swift. Four of them were from the bright half, so the
        // normal ramp was never actually pinned in order.
        XCTAssertEqual(lightty.ansi, [
            "#AFA7F5", "#AB4634", "#55C236", "#9A4DB4",
            "#3347C3", "#B445B8", "#4FC3C7", "#C9C9C9",
            "#666666", "#D47D78", "#55B94A", "#A452BD",
            "#5B5AA2", "#CF75D3", "#35B9BD", "#FFFFFF",
        ])
        XCTAssertEqual(lightty, TerminalColorSettings.lightty)
    }

    /// Nacre is likewise pinned as values. `TerminalThemePaletteContrastTests`
    /// measures what these numbers have to satisfy; this is the list itself, so
    /// a palette edit shows up as a diff of the shipped product rather than as
    /// a contrast test that still happens to pass.
    func testNacrePresetPinsItsShippedPalette() throws {
        let nacre = try XCTUnwrap(TerminalThemePreset.colors(named: TerminalThemePreset.nacreName))

        XCTAssertEqual(nacre.foreground, "#2E2D40")
        XCTAssertEqual(nacre.background, "#F8F6FC")
        XCTAssertEqual(nacre.cursor, "#6A4BC8")
        XCTAssertEqual(nacre.ansi, [
            "#1F1D29", "#A43F3C", "#3B6D2F", "#755E2D",
            "#465F97", "#8F4099", "#3A6969", "#706E77",
            "#49535E", "#D72935", "#248119", "#8D6B17",
            "#306FC9", "#B92ACC", "#247D7D", "#948C96",
        ])
        XCTAssertEqual(nacre, TerminalColorSettings.nacre)
    }

    /// The named presets resolve, and an unknown name does not silently fall
    /// back to a palette the user did not pick.
    func testUnknownThemeNamesResolveToNothingRatherThanADefault() {
        XCTAssertNotNil(TerminalThemePreset.colors(named: "Lightty"))
        XCTAssertNotNil(TerminalThemePreset.colors(named: TerminalThemePreset.kurottyName))
        XCTAssertNotNil(TerminalThemePreset.colors(named: "  Nacre  "))
        XCTAssertNil(TerminalThemePreset.colors(named: TerminalThemePreset.customName))
        XCTAssertNil(TerminalThemePreset.colors(named: "solarized"))
    }

    /// Picking Nacre in the popup is index -> name -> palette, and the chrome
    /// follows in the same step. The popup itself only ever hands out an index.
    func testSelectingNacreInThePopupAppliesItsPaletteAndItsChrome() throws {
        let index = PreferencesThemePopup.index(ofPresetName: TerminalThemePreset.nacreName)
        let selected = PreferencesThemePopup.presetName(atIndex: index)
        XCTAssertEqual(selected, TerminalThemePreset.nacreName)

        var settings = AppSettings.default
        settings.terminal.theme = selected
        settings.terminal.colors = try XCTUnwrap(TerminalThemePreset.colors(named: selected))

        XCTAssertEqual(settings.terminal.colors, TerminalColorSettings.nacre)
        XCTAssertEqual(DesignTokens.ChromeTheme.theme(for: settings).surfaceChrome, DesignTokens.Color.Nacre.surfaceChrome)
        XCTAssertNotNil(DesignTokens.ChromeTheme.theme(for: settings).groundGradient)
    }

    /// Chrome cannot be derived from background luminance alone once a theme
    /// carries its own chrome. Nacre's background is light, so the luminance
    /// rule would hand it the neutral light ramp and its tint would never
    /// appear; the same palette stored under any other name still takes that
    /// rule, which is what keeps imported and custom themes working as before.
    func testChromeFollowsTheThemeNameAndFallsBackToLuminance() {
        var nacre = AppSettings.default
        nacre.terminal.theme = TerminalThemePreset.nacreName
        nacre.terminal.colors = .nacre
        XCTAssertNotNil(DesignTokens.ChromeTheme.theme(for: nacre).groundGradient)

        var custom = AppSettings.default
        custom.terminal.theme = TerminalThemePreset.customName
        custom.terminal.colors = .nacre
        let customChrome = DesignTokens.ChromeTheme.theme(for: custom)
        XCTAssertNil(customChrome.groundGradient)
        XCTAssertEqual(customChrome.surfaceChrome, DesignTokens.Color.Light.surfaceChrome)

        var dark = AppSettings.default
        dark.terminal.theme = TerminalThemePreset.kurottyName
        XCTAssertEqual(
            DesignTokens.ChromeTheme.theme(for: dark).surfaceChrome,
            DesignTokens.Color.Dark.surfaceChrome
        )
    }

    /// Round trip through the on-disk format. A preset that survives encoding
    /// but not normalization comes back as "custom" with the right colors,
    /// which looks correct in the terminal and wrong in the popup.
    func testNacreSurvivesASaveAndLoadThroughTheSettingsStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-nacre-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AppSettingsStore(settingsURL: directory.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.terminal.theme = TerminalThemePreset.nacreName
        settings.terminal.colors = .nacre
        try store.save(settings)

        let loaded = try store.load()
        XCTAssertEqual(loaded.terminal.theme, TerminalThemePreset.nacreName)
        XCTAssertEqual(loaded.terminal.colors, TerminalColorSettings.nacre)
    }

    /// A settings file that names no theme but carries the Nacre palette is
    /// recognised as Nacre rather than demoted to custom. That inference is
    /// what stops an older file, or one written by hand, from losing the chrome
    /// half of the theme while keeping the grid half.
    func testAPaletteWithNoThemeNameIsInferredBackToNacre() {
        var settings = AppSettings.default
        settings.terminal.theme = ""
        settings.terminal.colors = .nacre

        let normalized = AppSettingsNormalizer.normalized(settings)
        XCTAssertEqual(normalized.terminal.theme, TerminalThemePreset.nacreName)
        XCTAssertEqual(normalized.terminal.colors, TerminalColorSettings.nacre)
    }

    /// Rows already on screen are remapped when the theme changes. Without it,
    /// switching to the light theme leaves the existing transcript in the dark
    /// palette — black text on a black background for everything written before
    /// the switch.
    func testSwitchingThemeRepaintsRowsThatArePlainDefaultStyle() throws {
        let session = ThemeStubSession()
        let surface = TerminalSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 200),
            session: session
        )
        surface.consumeTmuxRestoreOutputForTesting(Data("plain text".utf8))

        var settings = AppSettings.default
        settings.terminal.theme = TerminalThemePreset.lighttyName
        settings.terminal.colors = TerminalColorSettings.lightty
        // The surface takes settings only through the store's notification, so
        // this also covers that it is still subscribed to it.
        NotificationCenter.default.post(
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared,
            userInfo: [AppSettingsStore.notificationSettingsKey: settings]
        )

        // The surface paints its own layer from the default style, so the layer
        // is the readable witness that the style followed the settings.
        let background = try XCTUnwrap(surface.layer?.backgroundColor)
        let components = try XCTUnwrap(background.components)
        XCTAssertGreaterThan(components[0], 0.9)
        XCTAssertGreaterThan(components[1], 0.9)
        XCTAssertGreaterThan(components[2], 0.9)
    }

    /// A light background needs the 256-colour greys inverted, or a TUI that
    /// paints "dim grey on white" paints white on white.
    func testLightBackgroundsRemapTheHighGreyRamp() {
        let dark = TerminalTextStyle(foreground: .zero, background: SIMD4<Float>(0, 0, 0, 1))
        let light = TerminalTextStyle(foreground: .zero, background: SIMD4<Float>(1, 1, 1, 1))

        XCTAssertFalse(dark.isLightBackground)
        XCTAssertTrue(light.isLightBackground)
    }
}

private final class ThemeStubSession: TerminalSession {
    var onOutput: ((String) -> Void)?
    var onRawOutput: ((Data) -> Void)?
    var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
    var onExit: ((TerminalChildExit) -> Void)?

    func start(workingDirectory: String) {}
    func write(_ text: String) {}
    func foregroundProcessName() -> String? { nil }
    func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
    func resize(columns: Int, rows: Int) {}
    func stop() {}
}
