import AppKit
import XCTest

@testable import KurottyApp

/// The spacing, radius, and type scales are the layer everything else in the
/// chrome is expressed in, so they are pinned here rather than left implicit in
/// each call site.
@MainActor
final class DesignTokenScaleTests: XCTestCase {
    /// The UI text scale is process-wide state that the tokens read on every
    /// build, so a test that moves it has to put it back or it leaks into every
    /// test that runs after it.
    override func tearDown() {
        DesignTokens.UIScale.setPercent(DesignTokens.UIScale.defaultPercent)
        super.tearDown()
    }

    // MARK: - Spacing

    func testSpacingScaleIsTheSixDocumentedSteps() {
        XCTAssertEqual(DesignTokens.Space.x1PX, 4)
        XCTAssertEqual(DesignTokens.Space.x2PX, 6)
        XCTAssertEqual(DesignTokens.Space.x3PX, 8)
        XCTAssertEqual(DesignTokens.Space.x4PX, 12)
        XCTAssertEqual(DesignTokens.Space.x5PX, 16)
        XCTAssertEqual(DesignTokens.Space.x6PX, 24)
    }

    func testSpacingScaleIsStrictlyIncreasing() {
        let steps = [
            DesignTokens.Space.x1PX,
            DesignTokens.Space.x2PX,
            DesignTokens.Space.x3PX,
            DesignTokens.Space.x4PX,
            DesignTokens.Space.x5PX,
            DesignTokens.Space.x6PX,
        ]
        XCTAssertEqual(steps, steps.sorted())
        XCTAssertEqual(Set(steps).count, steps.count)
    }

    /// The terminal content insets are cell-grid alignment, not layout rhythm.
    /// They are deliberately exempt and must keep their own values even though
    /// two of them happen to coincide with a step.
    func testTerminalContentInsetsStayExemptFromTheScale() {
        XCTAssertEqual(DesignTokens.Space.terminalTopPX, 8)
        XCTAssertEqual(DesignTokens.Space.terminalLeftPX, 6)
        XCTAssertEqual(DesignTokens.Space.terminalBottomPX, 8)
        XCTAssertEqual(DesignTokens.Space.terminalRightPX, 6)
    }

    /// Every sidebar, tab, pane, and status-bar metric has to resolve onto a
    /// step. A token that drifts off the scale is exactly the regression the
    /// scale exists to catch.
    func testChromeMetricsResolveOntoSpacingSteps() {
        let steps: Set<CGFloat> = [
            DesignTokens.Space.x1PX,
            DesignTokens.Space.x2PX,
            DesignTokens.Space.x3PX,
            DesignTokens.Space.x4PX,
            DesignTokens.Space.x5PX,
            DesignTokens.Space.x6PX,
        ]
        let metrics: [String: CGFloat] = [
            "tabStackGap": DesignTokens.Component.terminalTabStackGapPX,
            "tabStackInsetLeft": DesignTokens.Component.terminalTabStackInsetLeftPX,
            "tabTitleLeading": DesignTokens.Component.terminalTabTitleLeadingPX,
            "tabTitleCloseGap": DesignTokens.Component.terminalTabTitleCloseGapPX,
            "tabCloseTrailing": DesignTokens.Component.terminalTabCloseTrailingPX,
            "historyPanelInsetX": DesignTokens.Component.commandHistoryPanelInsetXPX,
            "historyRowGap": DesignTokens.Component.commandHistoryRowGapPX,
            "historyRowInsetX": DesignTokens.Component.commandHistoryRowInsetXPX,
            "historyOutlineIndent": DesignTokens.Component.commandHistoryOutlineIndentationPX,
            "sidebarPanelBandGap": DesignTokens.Component.sidebarPanelBandGapPX,
            "searchPillTextInset": DesignTokens.Component.sidebarSearchPillTextInsetXPX,
            "searchIconGap": DesignTokens.Component.sidebarSearchIconGapPX,
            "sectionStripTopInset": DesignTokens.Component.leftSidebarSectionStripTopInsetPX,
            "sectionStripInsetX": DesignTokens.Component.leftSidebarSectionStripInsetXPX,
            "sectionStripBottomGap": DesignTokens.Component.leftSidebarSectionStripBottomGapPX,
            "explorerControlGap": DesignTokens.Component.fileExplorerControlGapPX,
            "paneChromeDotInset": DesignTokens.Component.terminalPaneChromeDotInsetXPX,
            "statusBarHorizontalInset": DesignTokens.Component.StatusBar.horizontalInsetPX,
            "statusBarSegmentPadding": DesignTokens.Component.StatusBar.segmentPaddingXPX,
        ]
        for (name, value) in metrics {
            XCTAssertTrue(steps.contains(value), "\(name) = \(value) is off the spacing scale")
        }
    }

    // MARK: - Radius

    func testRadiusScaleIsTheFiveDocumentedSteps() {
        XCTAssertEqual(DesignTokens.Radius.xsPX, 4)
        XCTAssertEqual(DesignTokens.Radius.smPX, 6)
        XCTAssertEqual(DesignTokens.Radius.mdPX, 8)
        XCTAssertEqual(DesignTokens.Radius.lgPX, 12)
        XCTAssertEqual(DesignTokens.Radius.fullPX, 999)
    }

    func testSidebarRowAndSegmentRadiiComeFromTheRadiusScale() {
        XCTAssertEqual(
            DesignTokens.Component.sidebarRowHighlightCornerRadiusPX,
            DesignTokens.Radius.smPX
        )
        XCTAssertEqual(DesignTokens.Component.StatusBar.segmentCornerRadiusPX, DesignTokens.Radius.xsPX)
        // Re-pointed 2026-08: `Component.radiusSmallPX` was a temporary alias
        // onto `Radius.smPX` kept only while `ChromeIconButton` and the search
        // bar were owned by another change. Both now read `Radius` directly, so
        // the assertion follows them there rather than being deleted.
        XCTAssertEqual(DesignTokens.Component.sidebarSearchPillFocusRingWidthPX, 2)
        XCTAssertEqual(DesignTokens.Radius.lgPX, 12)
    }

    // MARK: - Type ramp

    /// Pins the ramp as specified. `baseSizePT` is the spec and is independent
    /// of the UI text scale; `sizePT` is what call sites read, and at 100% the
    /// two have to agree — a ramp whose unscaled and default sizes differ is a
    /// ramp nobody can reason about.
    func testTypeRampRolesMatchTheSpecifiedSizesAndWeights() {
        DesignTokens.UIScale.setPercent(DesignTokens.UIScale.defaultPercent)
        let expected: [(String, DesignTokens.Typography.Role, CGFloat, NSFont.Weight)] = [
            ("windowTitle", DesignTokens.Typography.windowTitle, 13, .semibold),
            ("tabLabel", DesignTokens.Typography.tabLabel, 13, .medium),
            ("tabLabelSel", DesignTokens.Typography.tabLabelSel, 13, .semibold),
            ("sectionHeader", DesignTokens.Typography.sectionHeader, 12, .semibold),
            ("rowTitle", DesignTokens.Typography.rowTitle, 13, .regular),
            ("rowTitleSel", DesignTokens.Typography.rowTitleSel, 13, .medium),
            ("rowSecondary", DesignTokens.Typography.rowSecondary, 12, .regular),
            ("badge", DesignTokens.Typography.badge, 11, .medium),
            ("statusBar", DesignTokens.Typography.statusBar, 12, .regular),
            ("statusBarNum", DesignTokens.Typography.statusBarNum, 12, .medium),
            ("monoBody", DesignTokens.Typography.monoBody, 13, .regular),
            ("paneHeader", DesignTokens.Typography.paneHeader, 12, .medium),
        ]
        for (name, role, sizePT, weight) in expected {
            XCTAssertEqual(role.baseSizePT, sizePT, "\(name) spec size")
            XCTAssertEqual(role.sizePT, sizePT, "\(name) size at 100%")
            XCTAssertEqual(role.weight, weight, "\(name) weight")
            XCTAssertGreaterThan(role.lineHeightPX, role.sizePT, "\(name) needs leading")
        }
    }

    // MARK: - UI text scale

    func testScaleMultipliesEveryRungOfTheRampAndTheFontItBuilds() {
        DesignTokens.UIScale.setPercent(150)

        XCTAssertEqual(DesignTokens.Typography.rowTitle.sizePT, 19.5, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.Typography.badge.sizePT, 16.5, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.Typography.prefsTitle.sizePT, 30, accuracy: 0.001)
        // The font is what actually reaches the screen, so the multiply has to
        // survive as far as `NSFont`, not only as far as the token.
        XCTAssertEqual(DesignTokens.Typography.rowTitle.font.pointSize, 19.5, accuracy: 0.001)
        XCTAssertEqual(
            DesignTokens.Typography.statusBarNum.font.pointSize,
            18,
            accuracy: 0.001
        )
        // The spec is untouched: only the reading of it moves.
        XCTAssertEqual(DesignTokens.Typography.rowTitle.baseSizePT, 13)
    }

    /// Tracking is a point value like the size, so scaled caps must not keep
    /// the letter spacing they had at 100%.
    func testScaleMovesTrackingWithTheTypeItSeparates() {
        DesignTokens.UIScale.setPercent(150)

        XCTAssertEqual(DesignTokens.Typography.sectionHeader.tracking, 0.825, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.Typography.rowTitle.tracking, 0)
    }

    func testScaleClampsToTheDocumentedRangeAndRejectsNonFiniteValues() {
        XCTAssertEqual(DesignTokens.UIScale.clamped(50), DesignTokens.UIScale.minimumPercent)
        XCTAssertEqual(DesignTokens.UIScale.clamped(1_000), DesignTokens.UIScale.maximumPercent)
        XCTAssertEqual(DesignTokens.UIScale.clamped(120), 120)
        XCTAssertEqual(DesignTokens.UIScale.clamped(.nan), DesignTokens.UIScale.defaultPercent)
        XCTAssertEqual(DesignTokens.UIScale.clamped(.infinity), DesignTokens.UIScale.defaultPercent)

        // The installer clamps too, so a value that got past the settings file
        // still cannot reach the tokens.
        DesignTokens.UIScale.setPercent(10)
        XCTAssertEqual(DesignTokens.UIScale.percent, DesignTokens.UIScale.minimumPercent)
    }

    /// The floor exists because the ramp's quietest rung is 11pt. If the floor
    /// ever drops far enough to push that rung below 9pt the sidebar stops
    /// being readable, which is the whole reason the range is not Orca's.
    func testTheFloorKeepsTheQuietestRungReadable() {
        DesignTokens.UIScale.setPercent(DesignTokens.UIScale.minimumPercent)

        XCTAssertGreaterThanOrEqual(DesignTokens.Typography.badge.sizePT, 9)
        XCTAssertGreaterThanOrEqual(DesignTokens.Typography.prefsCaption.sizePT, 9)
        XCTAssertGreaterThanOrEqual(DesignTokens.Typography.monoGutter.sizePT, 9)
    }

    /// A box that holds type has to grow with it or the type clips; a stroke, a
    /// status dot, a radius, or a spacing step does not, because none of them
    /// contains anything.
    func testTypeCoupledMetricsGrowWithTheScaleAndFixedOnesDoNot() {
        let component = DesignTokens.Component.self
        // Read through closures, not values: the whole point of the change is
        // that these tokens are computed, so a test that snapshots them once
        // would pass no matter what the scale did.
        let typeCoupled: [(String, () -> CGFloat)] = [
            ("historyCommandRow", { component.commandHistoryCommandRowHeightPX }),
            ("historyBadge", { component.commandHistoryBadgeHeightPX }),
            ("agentSessionRow", { component.agentSessionRowHeightPX }),
            ("explorerRow", { component.fileExplorerRowHeightPX }),
            ("searchPill", { component.sidebarSearchPillHeightPX }),
            ("sectionStrip", { component.leftSidebarSectionStripHeightPX }),
            ("tabBar", { component.terminalTabBarHeightPX }),
            ("tab", { component.terminalTabHeightPX }),
            ("paneHeader", { component.terminalPaneChromeHeightPX }),
            ("statusBar", { component.StatusBar.heightPX }),
            ("statusBarBadge", { component.StatusBar.badgeHeightPX }),
            ("prefsHeader", { component.preferencesHeaderHeightPX }),
            ("prefsNavRow", { component.preferencesNavRowHeightPX }),
            ("prefsLabelColumn", { component.preferencesLabelColumnWidthPX }),
            ("historyPanelInsetX", { component.commandHistoryPanelInsetXPX }),
            ("paletteRow", { component.commandPaletteRowHeightPX }),
            ("searchBar", { component.terminalSearchHeightPX }),
            ("editorPathBar", { component.codeEditorPathBarHeightPX }),
        ]
        let fixed: [(String, () -> CGFloat)] = [
            ("hairline", { component.hairlinePX }),
            ("historyStatusDot", { component.commandHistoryStatusDotSizePX }),
            ("statusBarDot", { component.StatusBar.dotSizePX }),
            ("paneHeaderDot", { component.terminalPaneChromeDotSizePX }),
            ("gitDot", { component.fileExplorerGitDotSizePX }),
            ("rowHighlightRadius", { component.sidebarRowHighlightCornerRadiusPX }),
            ("selectionRail", { component.sidebarRowSelectionRailWidthPX }),
            ("tabTopRail", { component.terminalTabTopRailHeightPX }),
            ("searchPillFocusRing", { component.sidebarSearchPillFocusRingWidthPX }),
            ("trafficLightClearance", { component.terminalTrafficLightClearancePX }),
            ("prefsButtonHeight", { component.preferencesButtonHeightPX }),
            ("contextMeterHeight", { component.agentContextMeterHeightPX }),
            ("spacingStep", { DesignTokens.Space.x4PX }),
            ("radiusStep", { DesignTokens.Radius.mdPX }),
        ]
        let before = (typeCoupled + fixed).map { ($0.0, $0.1()) }

        DesignTokens.UIScale.setPercent(DesignTokens.UIScale.maximumPercent)

        let previous = Dictionary(uniqueKeysWithValues: before)
        for (name, read) in typeCoupled {
            XCTAssertGreaterThan(
                read(),
                previous[name]!,
                "\(name) holds type and has to grow with it"
            )
        }
        for (name, read) in fixed {
            XCTAssertEqual(
                read(),
                previous[name]!,
                "\(name) contains no type and must not move"
            )
        }
    }

    /// The line that decides whether a metric scales is "does type sit inside
    /// it", so a row height at 175% must still clear the row title it holds.
    func testAScaledRowStillClearsTheTypeItHolds() {
        DesignTokens.UIScale.setPercent(DesignTokens.UIScale.maximumPercent)

        XCTAssertGreaterThan(
            DesignTokens.Component.commandHistoryCommandRowHeightPX,
            DesignTokens.Typography.rowTitle.sizePT
        )
        XCTAssertGreaterThan(
            DesignTokens.Component.sidebarSearchPillHeightPX,
            DesignTokens.Typography.rowTitle.lineHeightPX
        )
        XCTAssertGreaterThan(
            DesignTokens.Component.StatusBar.heightPX,
            DesignTokens.Typography.statusBar.lineHeightPX
        )
        XCTAssertGreaterThan(
            DesignTokens.Component.commandHistoryBadgeHeightPX,
            DesignTokens.Typography.badge.sizePT
        )
    }

    /// Chrome glyphs sit beside chrome type, so the icon ramp follows the same
    /// scale while keeping its spec sizes.
    func testIconRampFollowsTheScaleWithoutLosingItsSpec() {
        DesignTokens.UIScale.setPercent(150)

        XCTAssertEqual(Icon.SizeClass.small.pointSizePT, 16.5, accuracy: 0.001)
        XCTAssertEqual(Icon.SizeClass.regular.pointSizePT, 19.5, accuracy: 0.001)
        XCTAssertEqual(Icon.SizeClass.small.basePointSizePT, 11)
        XCTAssertEqual(Icon.SizeClass.regular.basePointSizePT, 13)
    }

    /// Terminal and editor content have their own sizes and their own zoom, so
    /// the chrome scale must not reach them.
    func testTerminalAndEditorContentSizesIgnoreTheChromeScale() {
        let terminalBefore = DesignTokens.Typography.terminalFontSizePT
        let editorBefore = DesignTokens.Typography.codeEditorFontSizePT

        DesignTokens.UIScale.setPercent(DesignTokens.UIScale.maximumPercent)

        XCTAssertEqual(DesignTokens.Typography.terminalFontSizePT, terminalBefore)
        XCTAssertEqual(DesignTokens.Typography.codeEditorFontSizePT, editorBefore)
    }


    func testOnlySectionHeaderCarriesTracking() {
        XCTAssertEqual(DesignTokens.Typography.sectionHeader.tracking, 0.55)
        for role in [
            DesignTokens.Typography.rowTitle,
            DesignTokens.Typography.rowSecondary,
            DesignTokens.Typography.badge,
            DesignTokens.Typography.statusBar,
            DesignTokens.Typography.monoBody,
            DesignTokens.Typography.paneHeader,
        ] {
            XCTAssertEqual(role.tracking, 0)
        }
    }

    func testFontDesignsAreCarriedByTheRoleNotTheCallSite() {
        XCTAssertEqual(DesignTokens.Typography.monoBody.design, .monospaced)
        XCTAssertEqual(DesignTokens.Typography.statusBarNum.design, .monospacedDigit)
        XCTAssertEqual(DesignTokens.Typography.rowTitle.design, .system)
        XCTAssertTrue(DesignTokens.Typography.monoBody.font.fontName.contains("Mono"))
    }

    /// A role with tracking cannot be expressed by `NSTextField.font` alone, so
    /// applying it must produce an attributed string carrying the kern.
    func testApplyingATrackedRoleSetsKernOnTheLabel() {
        let label = NSTextField(labelWithString: "HISTORY")
        DesignTokens.Typography.sectionHeader.apply(to: label, color: .white)
        let kern = label.attributedStringValue.attribute(
            .kern,
            at: 0,
            effectiveRange: nil
        ) as? CGFloat
        XCTAssertEqual(kern, DesignTokens.Typography.sectionHeader.tracking)
    }

    func testApplyingAnUntrackedRoleSetsFontAndColorOnly() {
        let label = NSTextField(labelWithString: "kurotty")
        DesignTokens.Typography.rowTitle.apply(to: label, color: .red)
        XCTAssertEqual(label.font, DesignTokens.Typography.rowTitle.font)
        XCTAssertEqual(label.textColor, .red)
    }
}
