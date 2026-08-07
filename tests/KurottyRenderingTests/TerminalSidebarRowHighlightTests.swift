import AppKit
import XCTest

@testable import KurottyApp

/// The row-highlight painter resolves state as a pure function, so the whole
/// three-state system is testable without a window or a first responder.
@MainActor
final class TerminalSidebarRowHighlightTests: XCTestCase {
    private let theme = DesignTokens.ChromeTheme.dark

    /// Lets a row paint a chosen state without a key window. Row state is read
    /// off AppKit (`window?.isKeyWindow`), and a test process never gets one,
    /// so an active selection is unreachable any other way.
    private final class FixedStateRowView: TerminalSidebarRowView {
        var forcedState = TerminalSidebarRowHighlight.State.rest

        override var highlightState: TerminalSidebarRowHighlight.State { forcedState }
    }

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
        XCTAssertNil(resolved.border, "a wash is not an object; only a pill is bordered")
        XCTAssertNil(resolved.shadow, "only a surface is elevated")
        XCTAssertEqual(resolved.titleWeight, .regular)
    }

    func testHoverAndSelectionAreDistinctPaint() {
        XCTAssertNotEqual(appearance(hovered: true).fill, appearance(selected: true).fill)
        XCTAssertNil(appearance(hovered: true).rail)
        XCTAssertNotNil(appearance(selected: true).rail)
    }

    func testSelectedInActiveWindowIsAnElevatedRaisedSurface() {
        let resolved = appearance(selected: true)
        XCTAssertEqual(resolved.fill, theme.surfaceRaised)
        XCTAssertEqual(resolved.border, theme.borderStrong)
        XCTAssertEqual(resolved.rail, theme.accent)
        XCTAssertEqual(resolved.shadow, DesignTokens.Elevation.sidebarSelectedRowDark)
        XCTAssertNil(resolved.focusRing)
        XCTAssertEqual(resolved.titleWeight, .medium)
        XCTAssertEqual(resolved.titleColorRole, .primary)
    }

    /// The pill has to be a surface, not a tint over one. A translucent fill is
    /// what made a selected row's text land on a colour nothing had measured.
    func testSelectedFillIsAnOpaqueRampSurfaceInBothThemes() throws {
        for theme in [DesignTokens.ChromeTheme.dark, .light] {
            for state in [
                TerminalSidebarRowHighlight.State(isSelected: true, isWindowActive: true),
                TerminalSidebarRowHighlight.State(isSelected: true),
            ] {
                let fill = try XCTUnwrap(
                    TerminalSidebarRowHighlight.appearance(for: state, theme: theme).fill
                )
                XCTAssertEqual(fill, theme.surfaceRaised)
                XCTAssertEqual(fill.alphaComponent, 1)
            }
        }
    }

    /// Elevation is a token, and the two ramps do not share one: the same
    /// shadow is invisible on dark chrome and a smudge on light.
    func testSelectionShadowComesFromTheElevationRampAndIsThemeOwned() {
        XCTAssertEqual(
            TerminalSidebarRowHighlight.appearance(
                for: .init(isSelected: true, isWindowActive: true),
                theme: .light
            ).shadow,
            DesignTokens.Elevation.sidebarSelectedRowLight
        )
        XCTAssertNotEqual(
            DesignTokens.Elevation.sidebarSelectedRowLight,
            DesignTokens.Elevation.sidebarSelectedRowDark
        )
        // A row pill is a fraction of a floating panel. The reference's wide
        // blur under a 26pt pill is a smudge repeated down the whole list.
        XCTAssertLessThan(
            DesignTokens.Elevation.sidebarSelectedRowDark.radiusPX,
            DesignTokens.Elevation.floatingDark.radiusPX
        )
        XCTAssertLessThan(
            DesignTokens.Elevation.sidebarSelectedRowLight.radiusPX,
            DesignTokens.Elevation.floatingLight.radiusPX
        )
    }

    func testSelectedInInactiveWindowKeepsTheSurfaceAndDropsEverythingActive() {
        let resolved = appearance(selected: true, windowActive: false)
        // The surface survives so the row can still be found; what goes is
        // everything that says the user is acting on it.
        XCTAssertEqual(resolved.fill, theme.surfaceRaised)
        XCTAssertNil(resolved.rail)
        XCTAssertNil(resolved.shadow)
        XCTAssertNil(resolved.focusRing)
        XCTAssertEqual(resolved.titleWeight, .regular)
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

        // Pressing a selected row pushes it down: the pill stays, the lift goes.
        let selectedPress = appearance(selected: true, pressed: true)
        XCTAssertEqual(selectedPress.fill, theme.surfaceRaised)
        XCTAssertEqual(selectedPress.rail, theme.accent)
        XCTAssertNil(selectedPress.shadow)
    }

    func testSelectionCarriesFourIndependentCues() {
        let resolved = appearance(selected: true)
        XCTAssertNotNil(resolved.fill)
        XCTAssertNotNil(resolved.rail)
        XCTAssertNotNil(resolved.shadow)
        XCTAssertNotEqual(resolved.titleWeight, TerminalSidebarRowHighlight.Appearance.rest.titleWeight)
        // The rail used to be accent drawn on an accent wash, which is one cue
        // wearing two hats. On a neutral pill it is genuinely separate.
        XCTAssertNotEqual(resolved.rail, resolved.fill)
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

    /// A section-header row reserves air above its content. Painting over it
    /// would turn the gap between two directories back into one tall row.
    func testHighlightStopsShortOfASectionHeadersAir() {
        let rowBounds = NSRect(x: 0, y: 0, width: 200, height: 44)
        let airPX: CGFloat = 12
        let plain = TerminalSidebarRowHighlight.Geometry.highlightRect(in: rowBounds)
        let withAir = TerminalSidebarRowHighlight.Geometry.highlightRect(
            in: rowBounds,
            topInsetPX: airPX
        )
        // Unflipped geometry: the air is at the high-y edge, so the pill keeps
        // its origin and loses height.
        XCTAssertEqual(withAir.minY, plain.minY)
        XCTAssertEqual(withAir.minX, plain.minX)
        XCTAssertEqual(withAir.width, plain.width)
        XCTAssertEqual(withAir.maxY, plain.maxY - airPX)

        // Every derived shape follows the pill, or the cues drift apart.
        let rail = TerminalSidebarRowHighlight.Geometry.railRect(in: rowBounds, topInsetPX: airPX)
        XCTAssertEqual(rail.height, withAir.height)
        XCTAssertEqual(rail.maxY, withAir.maxY)
        let ring = TerminalSidebarRowHighlight.Geometry.focusRingRect(in: rowBounds, topInsetPX: airPX)
        XCTAssertEqual(ring, withAir.insetBy(dx: -1, dy: -1))
        XCTAssertEqual(
            TerminalSidebarRowHighlight.Geometry.highlightPath(in: rowBounds, topInsetPX: airPX)
                .boundingBoxOfPath,
            withAir
        )
    }

    /// Air taller than the row leaves no pill rather than a negative one.
    func testHighlightCollapsesRatherThanInvertingWhenTheAirExceedsTheRow() {
        let rect = TerminalSidebarRowHighlight.Geometry.highlightRect(
            in: NSRect(x: 0, y: 0, width: 200, height: 20),
            topInsetPX: 999
        )
        XCTAssertEqual(rect.height, 0)
    }

    // MARK: - Shadow plumbing

    /// The shadow has to hang off the layer, not off `draw(_:)`. A layer-backed
    /// row renders into a backing store the size of its own bounds, so a
    /// Core Graphics shadow would be sheared into a hard line at the row edge.
    func testSelectedRowHangsItsShadowOffTheLayerPath() throws {
        let rowBounds = NSRect(x: 0, y: 0, width: 220, height: 30)
        let rowView = FixedStateRowView(frame: rowBounds)
        rowView.chromeTheme = theme
        rowView.forcedState = .init(isSelected: true, isWindowActive: true)
        rowView.isSelected = true
        rowView.layout()

        let layer = try XCTUnwrap(rowView.layer)
        XCTAssertFalse(layer.masksToBounds, "a clipping row would cut the shadow into an edge")
        XCTAssertEqual(
            layer.shadowPath,
            TerminalSidebarRowHighlight.Geometry.highlightPath(in: rowBounds)
        )
        XCTAssertEqual(layer.shadowOpacity, DesignTokens.Elevation.sidebarSelectedRowDark.opacity)
        XCTAssertEqual(layer.shadowRadius, DesignTokens.Elevation.sidebarSelectedRowDark.radiusPX)
        // Unflipped layer geometry pushes a shadow down with a negative height.
        XCTAssertEqual(
            layer.shadowOffset.height,
            -DesignTokens.Elevation.sidebarSelectedRowDark.downwardOffsetPX
        )
    }

    func testUnselectedRowCarriesNoShadow() throws {
        let rowView = FixedStateRowView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        rowView.chromeTheme = theme
        rowView.forcedState = .init(isHovered: true, isWindowActive: true)
        rowView.layout()

        let layer = try XCTUnwrap(rowView.layer)
        XCTAssertEqual(layer.shadowOpacity, 0)
        XCTAssertNil(layer.shadowPath)
    }

    /// A row that was selected and then was not must give the shadow back.
    func testDeselectingARowClearsItsShadow() throws {
        let rowView = FixedStateRowView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        rowView.chromeTheme = theme
        rowView.forcedState = .init(isSelected: true, isWindowActive: true)
        rowView.layout()
        XCTAssertGreaterThan(try XCTUnwrap(rowView.layer).shadowOpacity, 0)

        rowView.forcedState = .rest
        rowView.layout()
        XCTAssertEqual(try XCTUnwrap(rowView.layer).shadowOpacity, 0)
    }

    /// A section-header row's shadow has to follow its shortened pill.
    func testSectionHeaderRowShadowFollowsTheShortenedPill() throws {
        let rowBounds = NSRect(x: 0, y: 0, width: 220, height: 44)
        let rowView = FixedStateRowView(frame: rowBounds)
        rowView.chromeTheme = theme
        rowView.highlightTopInsetPX = DesignTokens.Component.commandHistoryGroupRowTopAirPX
        rowView.forcedState = .init(isSelected: true, isWindowActive: true)
        rowView.layout()

        XCTAssertEqual(
            try XCTUnwrap(rowView.layer).shadowPath,
            TerminalSidebarRowHighlight.Geometry.highlightPath(
                in: rowBounds,
                topInsetPX: DesignTokens.Component.commandHistoryGroupRowTopAirPX
            )
        )
    }

    // MARK: - Filter key

    func testBareSlashJumpsToTheFilterFieldAndAModifiedOneDoesNot() throws {
        func event(_ characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: 44
                )
            )
        }
        XCTAssertTrue(TerminalSidebarFilterKey.matches(try event("/", modifiers: [])))
        XCTAssertFalse(TerminalSidebarFilterKey.matches(try event("/", modifiers: .command)))
        XCTAssertFalse(TerminalSidebarFilterKey.matches(try event("/", modifiers: .option)))
        XCTAssertFalse(TerminalSidebarFilterKey.matches(try event("a", modifiers: [])))
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
        let expectedKeys = [
            "backgroundColor",
            "position",
            "bounds",
            "shadowColor",
            "shadowOffset",
            "shadowOpacity",
            "shadowPath",
            "shadowRadius",
        ]
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
