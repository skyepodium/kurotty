import AppKit
import XCTest

@testable import KurottyApp

/// The row-highlight painter resolves state as a pure function, so the whole
/// three-state system is testable without a window or a first responder.
@MainActor
final class TerminalSidebarRowHighlightTests: XCTestCase {
    private let theme = DesignTokens.ChromeTheme.dark

    private func appearance(
        selected: Bool = false,
        hovered: Bool = false,
        pressed: Bool = false,
        windowActive: Bool = true,
        listFocused: Bool = false
    ) -> TerminalSidebarRowHighlight.Appearance {
        TerminalSidebarRowHighlight.appearance(
            for: TerminalSidebarRowHighlight.State(
                isSelected: selected,
                isHovered: hovered,
                isPressed: pressed,
                isWindowActive: windowActive,
                isListFocused: listFocused
            ),
            theme: theme
        )
    }

    // MARK: - State resolution

    func testRestPaintsNothing() {
        let resolved = appearance()
        XCTAssertNil(resolved.fill)
        XCTAssertNil(resolved.rail)
        XCTAssertNil(resolved.focusRing)
        XCTAssertEqual(resolved.titleWeight, .regular)
        XCTAssertEqual(resolved.titleColorRole, .primary)
    }

    func testHoverUsesAchromaticHoverFillAndNoOtherCue() {
        let resolved = appearance(hovered: true)
        XCTAssertEqual(resolved.fill, theme.hoverFill)
        XCTAssertNil(resolved.rail)
        XCTAssertNil(resolved.focusRing)
        XCTAssertEqual(resolved.titleWeight, .regular)
    }

    func testHoverAndSelectionAreDistinctPaint() {
        XCTAssertNotEqual(appearance(hovered: true).fill, appearance(selected: true).fill)
        XCTAssertNil(appearance(hovered: true).rail)
        XCTAssertNotNil(appearance(selected: true).rail)
    }

    func testSelectedInActiveWindowAddsFillRailAndWeight() {
        let resolved = appearance(selected: true)
        XCTAssertEqual(resolved.fill, theme.selectionFill)
        XCTAssertEqual(resolved.rail, theme.accent)
        XCTAssertNil(resolved.focusRing)
        XCTAssertEqual(resolved.titleWeight, .medium)
        XCTAssertEqual(resolved.titleColorRole, .primary)
    }

    func testSelectedInInactiveWindowDropsAccentAndDemotesTitle() {
        let resolved = appearance(selected: true, windowActive: false)
        XCTAssertEqual(
            resolved.fill,
            theme.textPrimary.withAlphaComponent(
                DesignTokens.Component.sidebarRowInactiveSelectionAlphaRATIO
            )
        )
        XCTAssertNil(resolved.rail)
        XCTAssertNil(resolved.focusRing)
        XCTAssertEqual(resolved.titleColorRole, .secondary)
    }

    func testFocusedSelectionAddsRingOnTopOfSelection() {
        let focused = appearance(selected: true, listFocused: true)
        let unfocused = appearance(selected: true)
        XCTAssertEqual(focused.fill, unfocused.fill)
        XCTAssertEqual(focused.rail, unfocused.rail)
        XCTAssertEqual(focused.focusRing, theme.focusRing)
    }

    func testFocusRequiresAKeyWindow() {
        let resolved = appearance(selected: true, windowActive: false, listFocused: true)
        XCTAssertNil(resolved.focusRing)
    }

    func testPressUsesPressFillWhileSelectionCuesSurvive() {
        let unselectedPress = appearance(hovered: true, pressed: true)
        XCTAssertEqual(unselectedPress.fill, theme.pressFill)
        XCTAssertNil(unselectedPress.rail)

        let selectedPress = appearance(selected: true, pressed: true)
        XCTAssertEqual(selectedPress.fill, theme.pressFill)
        XCTAssertEqual(selectedPress.rail, theme.accent)
    }

    func testSelectionCarriesThreeIndependentCues() {
        let resolved = appearance(selected: true)
        XCTAssertNotNil(resolved.fill)
        XCTAssertNotNil(resolved.rail)
        XCTAssertNotEqual(resolved.titleWeight, TerminalSidebarRowHighlight.Appearance.rest.titleWeight)
    }

    // MARK: - Geometry

    func testHighlightGeometryMatchesSpec() {
        let expectedInsetXPX: CGFloat = 4
        let expectedInsetYPX: CGFloat = 2
        let expectedCornerRadiusPX: CGFloat = 6
        let expectedRailWidthPX: CGFloat = 2
        let expectedRailRadiusPX: CGFloat = 1
        let expectedFocusRingWidthPX: CGFloat = 2
        let expectedFocusRingOutsetPX: CGFloat = 1

        XCTAssertEqual(TerminalSidebarRowHighlight.Geometry.insetXPX, expectedInsetXPX)
        XCTAssertEqual(TerminalSidebarRowHighlight.Geometry.insetYPX, expectedInsetYPX)
        XCTAssertEqual(TerminalSidebarRowHighlight.Geometry.cornerRadiusPX, expectedCornerRadiusPX)
        XCTAssertEqual(TerminalSidebarRowHighlight.Geometry.railWidthPX, expectedRailWidthPX)
        XCTAssertEqual(TerminalSidebarRowHighlight.Geometry.railCornerRadiusPX, expectedRailRadiusPX)
        XCTAssertEqual(TerminalSidebarRowHighlight.Geometry.focusRingWidthPX, expectedFocusRingWidthPX)
        XCTAssertEqual(TerminalSidebarRowHighlight.Geometry.focusRingOutsetPX, expectedFocusRingOutsetPX)
    }

    func testHighlightRailAndFocusRingRectsDeriveFromTheHighlightInset() {
        let rowBounds = NSRect(x: 0, y: 0, width: 200, height: 24)
        let highlight = TerminalSidebarRowHighlight.Geometry.highlightRect(in: rowBounds)
        XCTAssertEqual(highlight, NSRect(x: 4, y: 2, width: 192, height: 20))

        let rail = TerminalSidebarRowHighlight.Geometry.railRect(in: rowBounds)
        XCTAssertEqual(rail.minX, highlight.minX)
        XCTAssertEqual(rail.width, TerminalSidebarRowHighlight.Geometry.railWidthPX)
        XCTAssertEqual(rail.height, highlight.height, "the rail spans the full row highlight height")

        let ring = TerminalSidebarRowHighlight.Geometry.focusRingRect(in: rowBounds)
        XCTAssertEqual(ring, highlight.insetBy(dx: -1, dy: -1))
        XCTAssertEqual(
            TerminalSidebarRowHighlight.Geometry.focusRingCornerRadiusPX,
            TerminalSidebarRowHighlight.Geometry.cornerRadiusPX
                + TerminalSidebarRowHighlight.Geometry.focusRingOutsetPX
        )
    }

    func testPaintIsANoOpForAnEmptyRow() {
        TerminalSidebarRowHighlight.paint(appearance(selected: true), in: .zero)
    }

    // MARK: - Title weight ladder

    func testTitleWeightEmphasisStepsUpFromTheCellBaseWeight() {
        // Re-pointed onto the type ramp: cells now name a role, never a weight,
        // so the ladder is exercised through `rowTitle` (.regular) and
        // `windowTitle` (.semibold) instead of the retired `sidebar*FontSizePT`
        // constants.
        let regularStyler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.rowTitle,
            restColor: theme.textPrimary,
            chromeTheme: theme
        )
        XCTAssertEqual(regularStyler.resolvedWeight(for: appearance()), .regular)
        XCTAssertEqual(regularStyler.resolvedWeight(for: appearance(selected: true)), .medium)

        let semiboldStyler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.windowTitle,
            restColor: theme.textPrimary,
            chromeTheme: theme
        )
        XCTAssertEqual(semiboldStyler.resolvedWeight(for: appearance()), .semibold)
        XCTAssertEqual(semiboldStyler.resolvedWeight(for: appearance(selected: true)), .bold)
    }

    func testInactiveSelectionDemotesTitleColorToSecondary() {
        let styler = TerminalSidebarRowTitleStyler(
            role: DesignTokens.Typography.monoBody,
            restColor: theme.textPrimary,
            chromeTheme: theme
        )
        let label = NSTextField(labelWithString: "kurotty")
        styler.apply(appearance(selected: true, windowActive: false), to: label)
        XCTAssertEqual(label.textColor, theme.textSecondary)

        styler.apply(appearance(selected: true), to: label)
        XCTAssertEqual(label.textColor, theme.textPrimary)
    }

    // MARK: - No implicit animation

    func testRowLayerDisablesImplicitAnimationForHighlightKeys() throws {
        let expectedKeys = ["backgroundColor", "position", "bounds"]
        XCTAssertEqual(TerminalSidebarRowHighlight.LayerAnimation.disabledKeys, expectedKeys)

        let actions = TerminalSidebarRowHighlight.LayerAnimation.disabledActions
        for key in expectedKeys {
            XCTAssertTrue(actions[key] is NSNull, "\(key) must resolve to NSNull, not a CAAnimation")
        }

        let rowView = TerminalCommandHistorySidebarRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let layerActions = try XCTUnwrap(rowView.layer?.actions)
        for key in expectedKeys {
            XCTAssertTrue(layerActions[key] is NSNull, "row layer must not animate \(key)")
        }
    }

    func testExplorerAndHistoryRowsSharePainterByConstruction() {
        let historyRow: AnyObject = TerminalCommandHistorySidebarRowView(frame: .zero)
        let explorerRow: AnyObject = TerminalFileExplorerSidebarRowView(frame: .zero)
        XCTAssertTrue(historyRow is TerminalSidebarRowView)
        XCTAssertTrue(explorerRow is TerminalSidebarRowView)
    }

    func testRowViewDerivesHighlightStateFromAppKitFlags() {
        let rowView = TerminalCommandHistorySidebarRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        rowView.chromeTheme = theme
        XCTAssertEqual(rowView.highlightState, TerminalSidebarRowHighlight.State.rest)

        rowView.isSelected = true
        XCTAssertTrue(rowView.highlightState.isSelected)
        // Detached from any window, the row must read as an inactive selection.
        XCTAssertFalse(rowView.highlightState.isWindowActive)
        XCTAssertFalse(rowView.highlightState.isListFocused)
    }
}
