import AppKit
import XCTest

@testable import KurottyApp

/// The spacing, radius, and type scales are the layer everything else in the
/// chrome is expressed in, so they are pinned here rather than left implicit in
/// each call site.
@MainActor
final class DesignTokenScaleTests: XCTestCase {
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
            "sectionHeaderTopGap": DesignTokens.Component.commandHistorySectionHeaderTopGapPX,
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

    func testTypeRampRolesMatchTheSpecifiedSizesAndWeights() {
        let expected: [(String, DesignTokens.Typography.Role, CGFloat, NSFont.Weight)] = [
            ("windowTitle", DesignTokens.Typography.windowTitle, 13, .semibold),
            ("tabLabel", DesignTokens.Typography.tabLabel, 12, .medium),
            ("tabLabelSel", DesignTokens.Typography.tabLabelSel, 12, .semibold),
            ("sectionHeader", DesignTokens.Typography.sectionHeader, 11, .semibold),
            ("rowTitle", DesignTokens.Typography.rowTitle, 12, .regular),
            ("rowTitleSel", DesignTokens.Typography.rowTitleSel, 12, .medium),
            ("rowSecondary", DesignTokens.Typography.rowSecondary, 11, .regular),
            ("badge", DesignTokens.Typography.badge, 10, .medium),
            ("statusBar", DesignTokens.Typography.statusBar, 11, .regular),
            ("statusBarNum", DesignTokens.Typography.statusBarNum, 11, .medium),
            ("monoBody", DesignTokens.Typography.monoBody, 12, .regular),
            ("paneHeader", DesignTokens.Typography.paneHeader, 11, .medium),
        ]
        for (name, role, sizePT, weight) in expected {
            XCTAssertEqual(role.sizePT, sizePT, "\(name) size")
            XCTAssertEqual(role.weight, weight, "\(name) weight")
            XCTAssertGreaterThan(role.lineHeightPX, role.sizePT, "\(name) needs leading")
        }
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
