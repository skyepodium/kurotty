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
    ///
    /// The primary and secondary numbers are rank floors: they are well above
    /// AA and exist so the three ranks cannot collapse into each other. The
    /// tertiary number *is* AA — it is the rank with no headroom, so it is the
    /// one that decides whether DESIGN.md's contrast promise holds.
    private enum ContrastFloor {
        static let textPrimaryRATIO = 11.7
        static let textSecondaryRATIO = 4.6
        static let textTertiaryRATIO = WCAG.normalTextAARATIO
    }

    private enum WCAG {
        /// 1.4.3 Contrast (Minimum), normal-size text.
        static let normalTextAARATIO = 4.5
        /// 1.4.11 Non-text Contrast, for controls and meaningful graphics.
        static let nonTextRATIO = 3.0
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

    /// Source-over composite. A translucent token is not the color the user
    /// reads: what reaches the eye is the token blended onto whatever it sits
    /// on, and that blend is what has to clear the floor.
    private func composited(_ color: NSColor, over surface: NSColor) throws -> NSColor {
        let foreground = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let background = try XCTUnwrap(surface.usingColorSpace(.sRGB))
        let alpha = foreground.alphaComponent
        func blend(_ front: CGFloat, _ back: CGFloat) -> CGFloat {
            front * alpha + back * (1 - alpha)
        }
        return NSColor(
            srgbRed: blend(foreground.redComponent, background.redComponent),
            green: blend(foreground.greenComponent, background.greenComponent),
            blue: blend(foreground.blueComponent, background.blueComponent),
            alpha: 1
        )
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

    private func themes() -> [(String, DesignTokens.ChromeTheme)] {
        [("dark", .dark), ("light", .light)]
    }

    // MARK: - Tests

    /// DESIGN.md promises "WCAG AA-equivalent contrast". This is that promise,
    /// enumerated: every text rank the ramp defines, on every surface the ramp
    /// defines, in both themes.
    ///
    /// The four surfaces are the complete set of backgrounds a chrome label can
    /// land on — `surfaceCanvas` (window body), `surfaceChrome` (top bar,
    /// inactive tab, pane header), `surfaceSidebar` (panel body, hovered tab),
    /// `surfaceRaised` (selected tab, search pill) — and every legacy role alias
    /// resolves onto one of them, so the cross product is the real pairing set
    /// rather than a sample of it.
    ///
    /// Selected rows used to be out of scope here, because selection was a
    /// translucent accent wash: it composited over the surface, cost up to a
    /// full ratio point, and could not be fixed without lifting `textTertiary`
    /// until it swallowed `textSecondary`. It is now an opaque `surfaceRaised`
    /// pill, which is one of the four surfaces below, so a selected row's text
    /// is covered by this cross product rather than exempted from it —
    /// `testSelectedRowPillIsARampSurfaceAndItsTextClearsAA` is what holds the
    /// pill to that surface.
    ///
    /// Still out of scope: hover and press, which remain translucent washes.
    func testEveryTextRankClearsWCAGAAOnEverySurfaceInBothThemes() throws {
        var checkedPairCount = 0
        for (themeName, theme) in themes() {
            for (text, _) in textRanks(of: theme) {
                for surface in surfaces(of: theme) {
                    let ratio = try contrastRatio(text.color, surface.color)
                    checkedPairCount += 1
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        WCAG.normalTextAARATIO,
                        "\(themeName) \(text.name) on \(surface.name) measured \(ratio):1, AA floor \(WCAG.normalTextAARATIO):1"
                    )
                }
            }
        }
        // Guards the enumeration itself: a rank or a surface quietly dropped
        // from the fixtures would otherwise make this test pass by testing less.
        XCTAssertEqual(checkedPairCount, 24)
    }

    /// The elevated selected row is a new *object*, not a new surface.
    ///
    /// That distinction is the whole reason the count above is still 24: the
    /// pill is painted in `surfaceRaised`, opaque, so its text lands on a
    /// background the cross product already measures. This test is what makes
    /// that claim load-bearing — if the pill ever takes a colour of its own, or
    /// a translucent one, it fails here rather than quietly shipping a fifth
    /// unmeasured surface.
    func testSelectedRowPillIsARampSurfaceAndItsTextClearsAA() throws {
        var checkedPairCount = 0
        for (themeName, theme) in themes() {
            let states = [
                ("active", TerminalSidebarRowHighlight.State(isSelected: true, isWindowActive: true)),
                ("inactive", TerminalSidebarRowHighlight.State(isSelected: true)),
            ]
            for (stateName, state) in states {
                let pill = try XCTUnwrap(
                    TerminalSidebarRowHighlight.appearance(for: state, theme: theme).fill
                )
                XCTAssertEqual(
                    pill.alphaComponent,
                    1,
                    "\(themeName) \(stateName) selection must be a surface, not a wash over one"
                )
                XCTAssertEqual(
                    pill,
                    theme.surfaceRaised,
                    "\(themeName) \(stateName) selection must reuse a ramp surface"
                )
                for (text, _) in textRanks(of: theme) {
                    let ratio = try contrastRatio(text.color, pill)
                    checkedPairCount += 1
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        WCAG.normalTextAARATIO,
                        "\(themeName) \(text.name) on the \(stateName) selected pill measured \(ratio):1"
                    )
                }
            }
        }
        // Two themes x two selection states x three text ranks.
        XCTAssertEqual(checkedPairCount, 12)
    }

    /// The pill's hairline and its accent rail are meaningful graphics, so they
    /// answer to the non-text floor. The rail in particular used to be accent
    /// drawn on an accent wash, which is close to 1:1 against its own fill.
    func testSelectedRowPillOutlineAndRailClearNonTextContrast() throws {
        for (themeName, theme) in themes() {
            let resolved = TerminalSidebarRowHighlight.appearance(
                for: .init(isSelected: true, isWindowActive: true),
                theme: theme
            )
            let pill = try XCTUnwrap(resolved.fill)
            let rail = try XCTUnwrap(resolved.rail)
            let railRatio = try contrastRatio(rail, pill)
            XCTAssertGreaterThanOrEqual(
                railRatio,
                WCAG.nonTextRATIO,
                "\(themeName) selection rail measured \(railRatio):1 against its own pill"
            )
            // The hairline separates the pill from the panel behind it, so it
            // is measured against that panel, not against the pill.
            let border = try XCTUnwrap(resolved.border)
            let borderRatio = try contrastRatio(border, theme.surfaceChrome)
            XCTAssertGreaterThan(
                borderRatio,
                1.2,
                "\(themeName) selection hairline measured \(borderRatio):1 against the panel"
            )
        }
    }

    /// An empty sidebar section is the one moment its copy is the only text on
    /// screen, so it cannot be the least readable text in the app.
    ///
    /// The label used to be `textTertiary` at 0.72 alpha, which composites to
    /// roughly 2.8:1 — opacity multiplies straight through the contrast ratio,
    /// so no ramp value can rescue a label that is faded after the fact. The
    /// icon beside it keeps its alpha: it is decorative, the label carries the
    /// whole message, and a redundant graphic is exempt from 1.4.11.
    func testSidebarEmptyStateCopyClearsWCAGAAOnEverySurface() throws {
        let labelAlpha = DesignTokens.Component.sidebarEmptyStateLabelAlphaRATIO
        for (themeName, theme) in themes() {
            let label = theme.textMuted.withAlphaComponent(labelAlpha)
            for surface in surfaces(of: theme) {
                let ratio = try contrastRatio(try composited(label, over: surface.color), surface.color)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    WCAG.normalTextAARATIO,
                    "\(themeName) empty-state label on \(surface.name) measured \(ratio):1"
                )
            }
        }
    }

    /// The scrollback indicator is a control, so it answers to the non-text
    /// floor. It used to be one fixed gray for both themes, which measured
    /// about 1.4:1 on the light canvas.
    func testScrollbackIndicatorThumbClearsNonTextContrastInBothThemes() throws {
        for (themeName, theme) in themes() {
            let states = [
                NamedColor(name: "scrollerThumb", color: theme.scrollerThumb),
                NamedColor(name: "scrollerThumbHover", color: theme.scrollerThumbHover),
                NamedColor(name: "scrollerThumbActive", color: theme.scrollerThumbActive),
            ]
            for state in states {
                let ratio = try contrastRatio(
                    try composited(state.color, over: theme.surfaceCanvas),
                    theme.surfaceCanvas
                )
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    WCAG.nonTextRATIO,
                    "\(themeName) \(state.name) measured \(ratio):1 on surfaceCanvas"
                )
            }
            // Each state must also be louder than the one below it, or hover
            // and drag stop being readable as feedback.
            XCTAssertGreaterThan(theme.scrollerThumbHover.alphaComponent, theme.scrollerThumb.alphaComponent)
            XCTAssertGreaterThan(theme.scrollerThumbActive.alphaComponent, theme.scrollerThumbHover.alphaComponent)
        }
        XCTAssertNotEqual(DesignTokens.ChromeTheme.dark.scrollerThumb, DesignTokens.ChromeTheme.light.scrollerThumb)
    }

    /// The three ranks have to stay distinguishable from each other, not just
    /// from the surface behind them. Raising a rank to clear AA is only a fix if
    /// it does not swallow its neighbour.
    func testTextRanksStayDistinctFromEachOtherInBothThemes() throws {
        let rankSeparationRATIO = 1.15
        for (themeName, theme) in themes() {
            let primaryToSecondary = try contrastRatio(theme.textPrimary, theme.textSecondary)
            let secondaryToTertiary = try contrastRatio(theme.textSecondary, theme.textTertiary)
            XCTAssertGreaterThanOrEqual(
                primaryToSecondary,
                rankSeparationRATIO,
                "\(themeName) primary and secondary measured \(primaryToSecondary):1 apart"
            )
            XCTAssertGreaterThanOrEqual(
                secondaryToTertiary,
                rankSeparationRATIO,
                "\(themeName) secondary and tertiary measured \(secondaryToTertiary):1 apart"
            )
        }
    }

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
        let expectedDarkCanvasHex: [CGFloat] = [0x16, 0x16, 0x18]
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
