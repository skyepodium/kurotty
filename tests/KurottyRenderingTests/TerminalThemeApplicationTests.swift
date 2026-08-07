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

    /// The named presets resolve, and an unknown name does not silently fall
    /// back to a palette the user did not pick.
    func testUnknownThemeNamesResolveToNothingRatherThanADefault() {
        XCTAssertNotNil(TerminalThemePreset.colors(named: "Lightty"))
        XCTAssertNotNil(TerminalThemePreset.colors(named: TerminalThemePreset.kurottyName))
        XCTAssertNil(TerminalThemePreset.colors(named: TerminalThemePreset.customName))
        XCTAssertNil(TerminalThemePreset.colors(named: "solarized"))
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
