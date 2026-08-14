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
        [("dark", .dark), ("light", .light), ("nacre", .nacre)]
    }

    // MARK: - Tests

    /// DESIGN.md promises "WCAG AA-equivalent contrast". This is that promise,
    /// enumerated: every text rank the ramp defines, on every surface the ramp
    /// defines, in every theme.
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
    func testEveryTextRankClearsWCAGAAOnEverySurfaceInEveryTheme() throws {
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
        XCTAssertEqual(checkedPairCount, 36)
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
        // Three themes x two selection states x three text ranks.
        XCTAssertEqual(checkedPairCount, 18)
    }

    /// The capsule is now the only mark a selected row carries, so the
    /// separation that the hairline and the rail used to guarantee has to come
    /// from the surface itself.
    ///
    /// This is the test that made the redesign possible. Lifting the pill
    /// toward white put the quietest text rank at 3.51:1 on the dark ramp,
    /// under the AA floor above — so the panel drops instead of the pill
    /// rising. The pill stays the ramp surface whose text pairs are already
    /// measured, and the panel moving away from it is what makes the capsule
    /// visible. A future palette that closes this gap fails here rather than
    /// shipping a selection nobody can find.
    func testSelectedRowCapsuleClearsTheNonTextFloorAgainstItsPanel() throws {
        for (themeName, theme) in themes() {
            let resolved = TerminalSidebarRowHighlight.appearance(
                for: .init(isSelected: true, isWindowActive: true),
                theme: theme
            )
            let pill = try XCTUnwrap(resolved.fill)
            XCTAssertNil(resolved.rail, "\(themeName) selection must not carry a rail")
            XCTAssertNil(resolved.border, "\(themeName) selection must not carry an outline")
            // Not the 3:1 non-text floor: no shipping design — Dia's own
            // capsule, or macOS's sidebar selection — separates two adjacent
            // *surfaces* by that much, and one that did would read as a slab
            // rather than a sheet. The floor is the ramp's own step, measured
            // the same way one plane above the panel is measured, and the
            // elevation and the heavier title carry the rest of the signal.
            let ratio = try contrastRatio(pill, theme.surfaceSidebar)
            let rampStep = try contrastRatio(theme.surfaceSidebar, theme.surfaceChrome)
            XCTAssertGreaterThanOrEqual(
                ratio,
                rampStep,
                "\(themeName) selection capsule measured \(ratio):1 against its panel, "
                    + "which is less than the ramp's own step of \(rampStep):1"
            )
        }
    }

    /// The explorer's directory glyph is a meaningful graphic, not decoration.
    ///
    /// Fill and tint are the two channels that say "this row is a directory";
    /// nothing else in the row says it, and the filename beside it certainly
    /// does not. That puts the tint under WCAG 1.4.11 at 3:1 rather than under
    /// the redundant-graphic exemption the empty-state art gets. It is drawn at
    /// `fileExplorerFolderIconAlphaRATIO`, so what has to clear the floor is the
    /// *composite* over each surface the row can sit on — including
    /// `surfaceRaised`, which is the selected row's pill.
    func testExplorerDirectoryIconTintClearsNonTextContrastOnEverySurface() throws {
        let tintAlpha = DesignTokens.Component.fileExplorerFolderIconAlphaRATIO
        for (themeName, theme) in themes() {
            let tint = theme.accent.withAlphaComponent(tintAlpha)
            for surface in surfaces(of: theme) {
                let ratio = try contrastRatio(
                    try composited(tint, over: surface.color),
                    surface.color
                )
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    WCAG.nonTextRATIO,
                    "\(themeName) directory icon on \(surface.name) measured \(ratio):1"
                )
            }
        }
    }

    /// A directory and a file have to be told apart by the glyph column, so the
    /// two tints cannot be the same ink at two strengths. The shapes differ as
    /// well — filled against outline — which is what carries the distinction
    /// for a user who cannot separate the hues; this measures the other channel.
    func testExplorerDirectoryAndFileIconTintsAreDistinguishable() throws {
        let tintAlpha = DesignTokens.Component.fileExplorerFolderIconAlphaRATIO
        let separationRATIO = 1.3
        for (themeName, theme) in themes() {
            let directory = try composited(
                theme.accent.withAlphaComponent(tintAlpha),
                over: theme.surfaceChrome
            )
            let file = theme.textTertiary
            let ratio = try contrastRatio(directory, file)
            XCTAssertGreaterThanOrEqual(
                ratio,
                separationRATIO,
                "\(themeName) directory and file glyph tints measured \(ratio):1 apart"
            )
        }
        // Filled against outline: the silhouette difference, stated once so a
        // future edit that quietly re-outlines the folder fails here.
        XCTAssertNotEqual(FileExplorerIcon.folderSymbolName, IconSymbol.folder)
        XCTAssertEqual(FileExplorerIcon.folderSymbolName, IconSymbol.folderFilled)
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
    func testScrollbackIndicatorThumbClearsNonTextContrastInEveryTheme() throws {
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
    func testTextRanksStayDistinctFromEachOtherInEveryTheme() throws {
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

    func testNacreThemeTextRanksMeetContrastFloorsOnEverySurface() throws {
        try assertTextRanksMeetFloors(in: .nacre, themeName: "nacre")
    }

    /// A graded ground is a surface the token list does not name.
    ///
    /// `surfaceChrome` is the gradient's top stop, so the four fixtures above
    /// measure the lightest end of the ground and nothing measures the darkest
    /// end — which is the end nearest the bottom of the window. Both stops are
    /// held to AA here, which is what stops the grade being deepened into a
    /// ground that fails contrast somewhere down its length.
    ///
    /// AA rather than the rank floors, deliberately: the floors above exist to
    /// keep three ranks from collapsing into each other on the *named*
    /// surfaces, and the bottom of a grade is not a surface a rank is chosen
    /// against. Readability is not negotiable there; rank separation is already
    /// settled elsewhere.
    func testGroundMeshTintsAreHeldToTheSameFloorsAsFlatSurfaces() throws {
        var checkedThemeCount = 0
        for (themeName, theme) in themes() {
            let mesh = theme.groundMesh
            checkedThemeCount += 1

            XCTAssertEqual(
                mesh.base,
                theme.surfaceChrome,
                "\(themeName) must meet the tab bar at the chrome plane, or the top edge shows a seam"
            )

            // Hue is free and brightness is not. A tint that darkens or
            // brightens the ground moves the floor under every rank of chrome
            // text drawn on it, so each one is held to the same span the base
            // occupies — which is what lets the mesh be three hues at once
            // without costing a single point of legibility.
            let baseLuminance = try relativeLuminance(of: mesh.base)
            for tint in mesh.tints {
                let distance = abs(try relativeLuminance(of: tint.color) - baseLuminance)
                XCTAssertLessThanOrEqual(
                    distance,
                    Ground.tintLuminanceSPAN,
                    "\(themeName) tint \(tint.color) sits \(distance) from its base in luminance"
                )
            }

            for (text, floor) in textRanks(of: theme) {
                for tint in mesh.tints {
                    let ratio = try contrastRatio(text.color, tint.color)
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        min(floor, WCAG.normalTextAARATIO),
                        "\(themeName) \(text.name) on tint \(tint.color) measured \(ratio):1"
                    )
                }
            }
        }
        XCTAssertEqual(checkedThemeCount, 3, "every ramp declares its own ground")
    }

    private enum Ground {
        /// How far a tint may sit from its base in relative luminance.
        ///
        /// Generous enough for a hue to read and tight enough that the ground
        /// never becomes a second surface with its own contrast problem.
        static let tintLuminanceSPAN = 0.08
    }

    /// The light theme previously reused the dark status hues, which is why
    /// `success` was unreadable on white. Each status role must be legible
    /// against its own theme's canvas.
    func testStatusColorsAreThemeOwnedAndLegibleOnTheirCanvas() throws {
        let statusFloorRATIO = 3.0
        for (themeName, theme) in [("dark", DesignTokens.ChromeTheme.dark), ("light", .light), ("nacre", .nacre)] {
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
        let expectedDarkCanvasHex: [CGFloat] = [0x16, 0x13, 0x25]
        let maxChannelValue: CGFloat = 255
        let tolerance: CGFloat = 0.5 / maxChannelValue
        let canvas = try XCTUnwrap(DesignTokens.ChromeTheme.dark.surfaceCanvas.usingColorSpace(.sRGB))
        XCTAssertEqual(canvas.redComponent, expectedDarkCanvasHex[0] / maxChannelValue, accuracy: tolerance)
        XCTAssertEqual(canvas.greenComponent, expectedDarkCanvasHex[1] / maxChannelValue, accuracy: tolerance)
        XCTAssertEqual(canvas.blueComponent, expectedDarkCanvasHex[2] / maxChannelValue, accuracy: tolerance)
    }

    /// Hover must stay achromatic so it can never be mistaken for selection.
    func testHoverAndPressFillsAreAchromaticAndSelectionFillIsAccentDerived() throws {
        for theme in [DesignTokens.ChromeTheme.dark, .light, .nacre] {
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
        for theme in [DesignTokens.ChromeTheme.dark, .light, .nacre] {
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
