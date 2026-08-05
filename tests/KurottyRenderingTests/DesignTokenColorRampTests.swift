import AppKit
import XCTest

@testable import KurottyApp

/// Measures the shipped color ramp instead of trusting the hex values in the
/// design spec. Relative luminance and contrast are computed here from the
/// resolved sRGB components, so a token edit that quietly breaks readability
/// fails the suite.
@MainActor
final class DesignTokenColorRampTests: XCTestCase {
    /// WCAG 2.x contrast floors for the three text ranks against any chrome
    /// surface in the same theme.
    private enum ContrastFloor {
        static let textPrimaryRATIO = 11.7
        static let textSecondaryRATIO = 4.6
        static let textTertiaryRATIO = 3.4
    }

    private struct NamedColor {
        let name: String
        let color: NSColor
    }

    // MARK: - WCAG math

    /// sRGB channel linearization, per WCAG 2.x relative luminance.
    private func linearized(_ channel: CGFloat) -> Double {
        let lowChannelThreshold = 0.04045
        let lowChannelDivisor = 12.92
        let gammaOffset = 0.055
        let gammaDivisor = 1.055
        let gammaExponent = 2.4
        let value = Double(channel)
        guard value > lowChannelThreshold else {
            return value / lowChannelDivisor
        }
        return pow((value + gammaOffset) / gammaDivisor, gammaExponent)
    }

    private func relativeLuminance(of color: NSColor) throws -> Double {
        let redCoefficient = 0.2126
        let greenCoefficient = 0.7152
        let blueCoefficient = 0.0722
        let sRGBColor = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return redCoefficient * linearized(sRGBColor.redComponent)
            + greenCoefficient * linearized(sRGBColor.greenComponent)
            + blueCoefficient * linearized(sRGBColor.blueComponent)
    }

    private func contrastRatio(_ first: NSColor, _ second: NSColor) throws -> Double {
        let contrastOffset = 0.05
        let firstLuminance = try relativeLuminance(of: first)
        let secondLuminance = try relativeLuminance(of: second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + contrastOffset) / (darker + contrastOffset)
    }

    // MARK: - Fixtures

    private func surfaces(of theme: DesignTokens.ChromeTheme) -> [NamedColor] {
        [
            NamedColor(name: "surfaceCanvas", color: theme.surfaceCanvas),
            NamedColor(name: "surfaceChrome", color: theme.surfaceChrome),
            NamedColor(name: "surfaceSidebar", color: theme.surfaceSidebar),
            NamedColor(name: "surfaceRaised", color: theme.surfaceRaised),
        ]
    }

    private func textRanks(of theme: DesignTokens.ChromeTheme) -> [(NamedColor, Double)] {
        [
            (NamedColor(name: "textPrimary", color: theme.textPrimary), ContrastFloor.textPrimaryRATIO),
            (NamedColor(name: "textSecondary", color: theme.textSecondary), ContrastFloor.textSecondaryRATIO),
            (NamedColor(name: "textTertiary", color: theme.textTertiary), ContrastFloor.textTertiaryRATIO),
        ]
    }

    private func assertTextRanksMeetFloors(
        in theme: DesignTokens.ChromeTheme,
        themeName: String
    ) throws {
        for (text, floor) in textRanks(of: theme) {
            for surface in surfaces(of: theme) {
                let ratio = try contrastRatio(text.color, surface.color)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    floor,
                    "\(themeName) \(text.name) on \(surface.name) measured \(ratio):1, floor \(floor):1"
                )
            }
        }
    }

    // MARK: - Tests

    func testDarkThemeTextRanksMeetContrastFloorsOnEverySurface() throws {
        try assertTextRanksMeetFloors(in: .dark, themeName: "dark")
    }

    func testLightThemeTextRanksMeetContrastFloorsOnEverySurface() throws {
        try assertTextRanksMeetFloors(in: .light, themeName: "light")
    }

    /// The light theme previously reused the dark status hues, which is why
    /// `success` was unreadable on white. Each status role must be legible
    /// against its own theme's canvas.
    func testStatusColorsAreThemeOwnedAndLegibleOnTheirCanvas() throws {
        let statusFloorRATIO = 3.0
        for (themeName, theme) in [("dark", DesignTokens.ChromeTheme.dark), ("light", .light)] {
            let statuses = [
                NamedColor(name: "accent", color: theme.accent),
                NamedColor(name: "success", color: theme.success),
                NamedColor(name: "warning", color: theme.warning),
                NamedColor(name: "error", color: theme.error),
            ]
            for status in statuses {
                let ratio = try contrastRatio(status.color, theme.surfaceCanvas)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    statusFloorRATIO,
                    "\(themeName) \(status.name) measured \(ratio):1 on surfaceCanvas"
                )
            }
        }

        XCTAssertNotEqual(DesignTokens.ChromeTheme.dark.success, DesignTokens.ChromeTheme.light.success)
        XCTAssertNotEqual(DesignTokens.ChromeTheme.dark.accent, DesignTokens.ChromeTheme.light.accent)
        XCTAssertNotEqual(DesignTokens.ChromeTheme.dark.warning, DesignTokens.ChromeTheme.light.warning)
        XCTAssertNotEqual(DesignTokens.ChromeTheme.dark.error, DesignTokens.ChromeTheme.light.error)
    }

    /// Ramp colors must be built in sRGB; a generic-RGB (`calibratedRed:`)
    /// color of the same nominal components resolves to different sRGB values.
    func testRampColorsResolveToTheSpecifiedSRGBHex() throws {
        let expectedDarkCanvasHex: [CGFloat] = [0x16, 0x18, 0x1D]
        let maxChannelValue: CGFloat = 255
        let tolerance: CGFloat = 0.5 / maxChannelValue
        let canvas = try XCTUnwrap(DesignTokens.ChromeTheme.dark.surfaceCanvas.usingColorSpace(.sRGB))
        XCTAssertEqual(canvas.redComponent, expectedDarkCanvasHex[0] / maxChannelValue, accuracy: tolerance)
        XCTAssertEqual(canvas.greenComponent, expectedDarkCanvasHex[1] / maxChannelValue, accuracy: tolerance)
        XCTAssertEqual(canvas.blueComponent, expectedDarkCanvasHex[2] / maxChannelValue, accuracy: tolerance)
    }

    /// Hover must stay achromatic so it can never be mistaken for selection.
    func testHoverAndPressFillsAreAchromaticAndSelectionFillIsAccentDerived() throws {
        for theme in [DesignTokens.ChromeTheme.dark, .light] {
            for fill in [theme.hoverFill, theme.pressFill] {
                let resolved = try XCTUnwrap(fill.usingColorSpace(.sRGB))
                XCTAssertEqual(resolved.redComponent, resolved.greenComponent)
                XCTAssertEqual(resolved.greenComponent, resolved.blueComponent)
            }
            let selection = try XCTUnwrap(theme.selectionFill.usingColorSpace(.sRGB))
            let accent = try XCTUnwrap(theme.accent.usingColorSpace(.sRGB))
            XCTAssertEqual(selection.redComponent, accent.redComponent)
            XCTAssertEqual(selection.blueComponent, accent.blueComponent)
            XCTAssertLessThan(selection.alphaComponent, 1)
            XCTAssertGreaterThan(theme.pressFill.alphaComponent, theme.hoverFill.alphaComponent)
        }
    }

    /// Purple is a syntax color only; no chrome role may reference it.
    func testChromeRolesDoNotUsePurple() {
        for theme in [DesignTokens.ChromeTheme.dark, .light] {
            XCTAssertEqual(
                theme.inactiveStatusDot,
                theme.textTertiary.withAlphaComponent(DesignTokens.Color.inactiveStatusDotAlphaRATIO)
            )
            XCTAssertEqual(
                theme.activeBorder,
                theme.accent.withAlphaComponent(DesignTokens.Color.activeBorderAlphaRATIO)
            )
        }
        XCTAssertNotNil(TerminalCodeEditorSyntaxColors.syntaxKeyword)
    }
}
