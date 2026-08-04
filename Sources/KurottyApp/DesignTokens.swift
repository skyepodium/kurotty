import AppKit
import KurottyCore
import simd

enum DesignTokens {
    @MainActor
    struct ChromeTheme {
        let windowBackground: NSColor
        let topChromeBackground: NSColor
        let activeTabBackground: NSColor
        let inactiveTabBackground: NSColor
        let inactiveTabHoverBackground: NSColor
        let paneHeaderBackground: NSColor
        let paneHeaderHoverBackground: NSColor
        let borderHairline: NSColor
        let divider: NSColor
        let textPrimary: NSColor
        let textSecondary: NSColor
        let textMuted: NSColor
        let activeIndicator: NSColor
        let activeStatusDot: NSColor
        let inactiveStatusDot: NSColor
        let activeBorder: NSColor
        let windowAppearance: NSAppearance?

        static func theme(for settings: AppSettings) -> ChromeTheme {
            settings.terminal.colors.backgroundColor.isLightTerminalBackground ? .light : .dark
        }

        static let dark = ChromeTheme(
            windowBackground: Color.windowBackground,
            topChromeBackground: Color.topChromeBackground,
            activeTabBackground: Color.activeTabBackground,
            inactiveTabBackground: Color.inactiveTabBackground,
            inactiveTabHoverBackground: Color.inactiveTabHoverBackground,
            paneHeaderBackground: Color.paneHeaderBackground,
            paneHeaderHoverBackground: Color.paneHeaderHoverBackground,
            borderHairline: Color.borderHairline,
            divider: Color.divider,
            textPrimary: Color.textPrimary,
            textSecondary: Color.textSecondary,
            textMuted: Color.textMuted,
            activeIndicator: Color.accentBlue,
            activeStatusDot: Color.successGreen,
            inactiveStatusDot: Color.accentPurple.withAlphaComponent(0.45),
            activeBorder: Color.accentPurple.withAlphaComponent(0.45),
            windowAppearance: NSAppearance(named: .darkAqua)
        )

        static let light = ChromeTheme(
            windowBackground: NSColor(calibratedRed: 250.0 / 255.0, green: 250.0 / 255.0, blue: 250.0 / 255.0, alpha: 1),
            topChromeBackground: NSColor(calibratedRed: 241.0 / 255.0, green: 241.0 / 255.0, blue: 241.0 / 255.0, alpha: 1),
            activeTabBackground: NSColor.white,
            inactiveTabBackground: NSColor(calibratedRed: 233.0 / 255.0, green: 233.0 / 255.0, blue: 233.0 / 255.0, alpha: 1),
            inactiveTabHoverBackground: NSColor(calibratedRed: 245.0 / 255.0, green: 245.0 / 255.0, blue: 245.0 / 255.0, alpha: 1),
            paneHeaderBackground: NSColor(calibratedRed: 246.0 / 255.0, green: 246.0 / 255.0, blue: 246.0 / 255.0, alpha: 1),
            paneHeaderHoverBackground: NSColor(calibratedRed: 251.0 / 255.0, green: 251.0 / 255.0, blue: 251.0 / 255.0, alpha: 1),
            borderHairline: NSColor(calibratedRed: 221.0 / 255.0, green: 221.0 / 255.0, blue: 221.0 / 255.0, alpha: 1),
            divider: NSColor(calibratedRed: 224.0 / 255.0, green: 224.0 / 255.0, blue: 224.0 / 255.0, alpha: 1),
            textPrimary: NSColor(calibratedRed: 36.0 / 255.0, green: 36.0 / 255.0, blue: 36.0 / 255.0, alpha: 1),
            textSecondary: NSColor(calibratedRed: 119.0 / 255.0, green: 119.0 / 255.0, blue: 119.0 / 255.0, alpha: 1),
            textMuted: NSColor(calibratedRed: 153.0 / 255.0, green: 153.0 / 255.0, blue: 153.0 / 255.0, alpha: 1),
            activeIndicator: Color.accentBlue,
            activeStatusDot: Color.successGreen,
            inactiveStatusDot: Color.accentPurple.withAlphaComponent(0.45),
            activeBorder: Color.accentPurple.withAlphaComponent(0.45),
            windowAppearance: NSAppearance(named: .aqua)
        )
    }

    enum Color {
        static let windowBackground = NSColor(calibratedRed: 31.0 / 255.0, green: 34.0 / 255.0, blue: 40.0 / 255.0, alpha: 1)
        static let topChromeBackground = NSColor(calibratedRed: 31.0 / 255.0, green: 34.0 / 255.0, blue: 40.0 / 255.0, alpha: 1)
        static let activeTabBackground = NSColor(calibratedRed: 37.0 / 255.0, green: 40.0 / 255.0, blue: 47.0 / 255.0, alpha: 1)
        static let inactiveTabBackground = NSColor(calibratedRed: 27.0 / 255.0, green: 30.0 / 255.0, blue: 36.0 / 255.0, alpha: 1)
        static let inactiveTabHoverBackground = NSColor(calibratedRed: 43.0 / 255.0, green: 46.0 / 255.0, blue: 54.0 / 255.0, alpha: 1)
        static let paneHeaderBackground = NSColor(calibratedRed: 31.0 / 255.0, green: 34.0 / 255.0, blue: 40.0 / 255.0, alpha: 1)
        static let paneHeaderHoverBackground = NSColor(calibratedRed: 43.0 / 255.0, green: 46.0 / 255.0, blue: 54.0 / 255.0, alpha: 1)
        static let paneDropTargetBorder = NSColor(calibratedRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 0.72)
        static let paneDropTargetBackground = NSColor(calibratedRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 0.08)
        static let inputStatusBackground = NSColor(calibratedRed: 37.0 / 255.0, green: 40.0 / 255.0, blue: 47.0 / 255.0, alpha: 1)
        static let borderHairline = NSColor(calibratedRed: 76.0 / 255.0, green: 80.0 / 255.0, blue: 89.0 / 255.0, alpha: 1)
        static let divider = NSColor(calibratedRed: 60.0 / 255.0, green: 64.0 / 255.0, blue: 72.0 / 255.0, alpha: 1)
        static let textPrimary = NSColor(calibratedRed: 229.0 / 255.0, green: 231.0 / 255.0, blue: 235.0 / 255.0, alpha: 1)
        static let textSecondary = NSColor(calibratedRed: 179.0 / 255.0, green: 183.0 / 255.0, blue: 192.0 / 255.0, alpha: 1)
        static let textMuted = NSColor(calibratedRed: 125.0 / 255.0, green: 131.0 / 255.0, blue: 142.0 / 255.0, alpha: 1)
        static let accentBlue = NSColor(calibratedRed: 91.0 / 255.0, green: 124.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
        static let accentPurple = NSColor(calibratedRed: 139.0 / 255.0, green: 92.0 / 255.0, blue: 246.0 / 255.0, alpha: 1)
        static let successGreen = NSColor(calibratedRed: 47.0 / 255.0, green: 191.0 / 255.0, blue: 113.0 / 255.0, alpha: 1)
        static let warningOrange = NSColor(calibratedRed: 233.0 / 255.0, green: 148.0 / 255.0, blue: 26.0 / 255.0, alpha: 1)
        static let errorRed = NSColor(calibratedRed: 255.0 / 255.0, green: 95.0 / 255.0, blue: 103.0 / 255.0, alpha: 1)
        static let cyanTerminalAccent = NSColor(calibratedRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 1)
        static let scrollerThumb = NSColor(calibratedRed: 207.0 / 255.0, green: 207.0 / 255.0, blue: 207.0 / 255.0, alpha: 0.72)
        static let scrollerThumbHover = NSColor(calibratedRed: 176.0 / 255.0, green: 176.0 / 255.0, blue: 176.0 / 255.0, alpha: 0.88)
        static let scrollerThumbActive = NSColor(calibratedRed: 138.0 / 255.0, green: 138.0 / 255.0, blue: 138.0 / 255.0, alpha: 0.96)

        static let terminalBackground = NSColor(
            calibratedRed: 34.0 / 255.0,
            green: 37.0 / 255.0,
            blue: 43.0 / 255.0,
            alpha: 1
        )
        static let terminalForeground = TerminalColorDefaults.foreground
        static let terminalCursor = TerminalColorDefaults.cursor
        static let terminalDefaultBackground = TerminalColorDefaults.background

        static let ansiNormal = TerminalPalette.ansiNormal
        static let ansiBright = TerminalPalette.ansiBright
    }

    enum Typography {
        static let terminalFontSizePT: CGFloat = 15
        static let labelFontSizePT: CGFloat = 13
        static let paneHeaderFontSizePT: CGFloat = 12
        static let statusFontSizePT: CGFloat = 12
        static let sidebarSectionHeaderFontSizePT: CGFloat = 11
        static let sidebarGroupNameFontSizePT: CGFloat = 13
        static let sidebarSecondaryFontSizePT: CGFloat = 11
        static let sidebarCommandFontSizePT: CGFloat = 12
        static let sidebarBadgeFontSizePT: CGFloat = 10
        static let sidebarSearchFontSizePT: CGFloat = 12
        static let codeEditorFontSizePT: CGFloat = 13
        static let codeEditorGutterFontSizePT: CGFloat = 11
    }

    enum Space {
        static let terminalTopPX: CGFloat = 8
        static let terminalLeftPX: CGFloat = 6
        static let terminalBottomPX: CGFloat = 8
        static let terminalRightPX: CGFloat = 6
        static let preferencesInsetPX: CGFloat = 24
        static let preferencesGapPX: CGFloat = 14
    }

    enum Component {
        /// Quick Commands editor window layout.
        static let quickCommandEditorWidthPX: CGFloat = 620
        static let quickCommandEditorHeightPX: CGFloat = 460
        static let quickCommandEditorPaddingPX: CGFloat = 16
        static let quickCommandEditorRowSpacingPX: CGFloat = 8
        static let quickCommandEditorSectionSpacingPX: CGFloat = 12
        static let quickCommandTableHeightPX: CGFloat = 170
        static let quickCommandTableRowHeightPX: CGFloat = 22
        static let quickCommandCommandTextHeightPX: CGFloat = 74
        static let quickCommandFieldLabelWidthPX: CGFloat = 120
        static let quickCommandNameColumnWidthPX: CGFloat = 200
        static let quickCommandScopeColumnWidthPX: CGFloat = 190
        static let quickCommandActionColumnWidthPX: CGFloat = 160
        static let quickCommandToolbarButtonWidthPX: CGFloat = 32

        static let commandPaletteWidthPX: CGFloat = 680
        static let commandPaletteHeightPX: CGFloat = 500
        static let preferencesWidthPX: CGFloat = 820
        static let preferencesHeightPX: CGFloat = 640
        static let preferencesControlWidthPX: CGFloat = 240
        static let preferencesStatusHeightPX: CGFloat = 18
        static let preferencesButtonWidthPX: CGFloat = 84
        static let preferencesButtonHeightPX: CGFloat = 30
        static let preferencesTextFieldWidthPX: CGFloat = 160
        static let settingsEditorFontSizePT: CGFloat = 12
        static let glyphAtlasSizePX = 4096
        static let glyphSlotWidthPX = 128
        static let glyphSlotHeightPX = 128
        static let glyphAtlasOversampleScale: CGFloat = 1
        static let glyphSlotPaddingPX: CGFloat = 6
        static let partialRedrawPendingScissorRectBudgetCount = 64
        static let terminalScrollerWidthPX: CGFloat = 12
        static let terminalScrollerThumbWidthPX: CGFloat = 9
        static let terminalScrollerMinThumbHeightPX: CGFloat = 32
        static let terminalScrollerMinKnobProportion: CGFloat = 0.05
        static let terminalPreciseScrollMultiplierRATIO: CGFloat = 1.5
        static let terminalDiscreteScrollRowsPerTick = 2
        static let terminalSearchWidthPX: CGFloat = 340
        static let terminalSearchHeightPX: CGFloat = 44
        static let terminalSearchCornerRadiusPX: CGFloat = 10
        static let terminalSearchInsetPX: CGFloat = 12
        static let terminalTabBarHeightPX: CGFloat = 40
        static let terminalTopBarCornerRadiusPX: CGFloat = 0
        static let terminalTabBarHorizontalInsetPX: CGFloat = 0
        static let terminalTrafficLightClearancePX: CGFloat = 72
        static let terminalTabBarSideButtonInsetPX: CGFloat = 7
        static let terminalTabHeightPX: CGFloat = 30
        static let sidebarToggleSizePX: CGFloat = 26
        static let sidebarDividerGrabPaddingPX: CGFloat = 4
        static let sidebarToggleEdgeInsetPX: CGFloat = 9
        static let sidebarToggleSymbolPointSizePT: CGFloat = 13
        static let terminalTabCornerRadiusPX: CGFloat = 7
        static let terminalTabMinWidthPX: CGFloat = 110
        static let terminalTabMaxWidthPX: CGFloat = 260
        static let terminalTabPlusWidthPX: CGFloat = 26
        static let terminalTabCloseWidthPX: CGFloat = 18
        static let terminalTabStackGapPX: CGFloat = 4
        static let terminalTabStackInsetTopPX: CGFloat = 4
        static let terminalTabStackInsetLeftPX: CGFloat = 8
        static let terminalTabStackInsetBottomPX: CGFloat = 4
        static let terminalTabStackInsetRightPX: CGFloat = 8
        static let terminalTabBorderWidthPX: CGFloat = 1
        static let terminalTabShadowOffsetYPX: CGFloat = -1
        static let terminalTabShadowRadiusPX: CGFloat = 3
        static let terminalTabShadowOpacity: Float = 0
        static let terminalTabTitleLeadingPX: CGFloat = 11
        static let terminalTabTitleCloseGapPX: CGFloat = 4
        static let terminalTabCloseTrailingPX: CGFloat = 5
        static let commandHistoryPanelDefaultWidthPX: CGFloat = 350
        static let commandHistoryPanelMinWidthPX: CGFloat = 200
        static let commandHistoryPanelMaxWidthPX: CGFloat = 460
        static let commandHistoryPanelCornerRadiusPX: CGFloat = 0
        static let commandHistoryPanelInsetXPX: CGFloat = 12
        static let commandHistoryPanelInsetYPX: CGFloat = 12
        static let commandHistorySearchPillHeightPX: CGFloat = 26
        static let commandHistorySearchPillCornerRadiusPX: CGFloat = 7
        static let commandHistorySearchIconGapPX: CGFloat = 6
        static let commandHistorySearchPillTextInsetXPX: CGFloat = 6
        static let commandHistorySectionHeaderTopGapPX: CGFloat = 14
        static let commandHistorySectionHeaderBottomGapPX: CGFloat = 6
        static let commandHistorySectionHeaderInsetXPX: CGFloat = 12
        static let commandHistoryGroupRowHeightPX: CGFloat = 28
        static let commandHistoryCommandRowHeightPX: CGFloat = 25
        static let commandHistoryStatusDotSizePX: CGFloat = 8
        static let commandHistoryRowInsetXPX: CGFloat = 8
        static let commandHistoryRowGapPX: CGFloat = 6
        static let commandHistoryRowCornerRadiusPX: CGFloat = 5
        static let commandHistoryRowHighlightInsetXPX: CGFloat = 4
        static let commandHistoryRowHighlightInsetYPX: CGFloat = 1
        static let commandHistoryTimeLabelMinWidthPX: CGFloat = 28
        static let commandHistoryBadgeHeightPX: CGFloat = 16
        static let commandHistoryBadgeTextInsetXPX: CGFloat = 6
        static let commandHistoryBadgeMinWidthPX: CGFloat = 20
        static let commandHistoryGroupIconPointSizePT: CGFloat = 12
        static let commandHistoryEmptyStateIconPointSizePT: CGFloat = 18
        static let commandHistoryEmptyStateGapPX: CGFloat = 8
        static let commandHistoryOutlineIndentationPX: CGFloat = 6
        static let commandHistoryDefaultExpandedGroupCount = 3
        static let commandHistorySearchPillBackgroundAlphaRATIO: CGFloat = 0.08
        static let commandHistoryHoverBackgroundAlphaRATIO: CGFloat = 0.07
        static let commandHistorySelectionBackgroundAlphaRATIO: CGFloat = 0.24
        static let commandHistoryBadgeBackgroundAlphaRATIO: CGFloat = 0.10
        static let fileExplorerPanelDefaultWidthPX: CGFloat = 350
        static let fileExplorerPanelMinWidthPX: CGFloat = 210
        static let fileExplorerPanelMaxWidthPX: CGFloat = 460
        static let fileExplorerPanelCornerRadiusPX: CGFloat = 0
        static let fileExplorerPanelInsetXPX: CGFloat = 12
        static let fileExplorerPanelInsetYPX: CGFloat = 12
        static let fileExplorerHeaderGapPX: CGFloat = 3
        static let fileExplorerControlGapPX: CGFloat = 8
        static let fileExplorerRefreshButtonSizePX: CGFloat = 24
        static let fileExplorerSearchPillHeightPX: CGFloat = 26
        static let fileExplorerSearchPillCornerRadiusPX: CGFloat = 7
        static let fileExplorerSearchPillTextInsetXPX: CGFloat = 6
        static let fileExplorerRowHeightPX: CGFloat = 24
        static let fileExplorerRowCornerRadiusPX: CGFloat = 5
        static let fileExplorerRowHighlightInsetXPX: CGFloat = 4
        static let fileExplorerRowHighlightInsetYPX: CGFloat = 1
        static let fileExplorerSearchPillBackgroundAlphaRATIO: CGFloat = 0.08
        static let fileExplorerHoverBackgroundAlphaRATIO: CGFloat = 0.07
        static let fileExplorerSelectionBackgroundAlphaRATIO: CGFloat = 0.24
        // Agent-session sidebar. Shared metrics (search pill, badges, row
        // highlight, indentation) intentionally reuse the commandHistory*
        // tokens so both left-panel sections stay pixel-identical.
        static let agentSessionRowHeightPX: CGFloat = 42
        static let agentSessionRowTextGapPY: CGFloat = 2
        static let agentSessionAgentIconPointSizePT: CGFloat = 12
        static let agentSessionEmptyStateIconPointSizePT: CGFloat = 18
        static let agentSessionDefaultExpandedGroupCount = 3
        static let leftSidebarSegmentedControlHeightPX: CGFloat = 22
        static let leftSidebarSegmentedControlInsetXPX: CGFloat = 12
        static let leftSidebarSegmentedControlTopInsetPX: CGFloat = 10
        static let leftSidebarSegmentedControlBottomGapPX: CGFloat = 2
        static let imagePreviewInsetPX: CGFloat = 24
        static let codeEditorGutterWidthPX: CGFloat = 44
        static let codeEditorGutterLabelTrailingPX: CGFloat = 8
        static let codeEditorTextInsetXPX: CGFloat = 6
        static let codeEditorTextInsetYPX: CGFloat = 8
        static let codeEditorPathBarInsetXPX: CGFloat = 12
        static let codeEditorPathBarInsetYPX: CGFloat = 8
        static let paneDropTargetBorderWidthPX: CGFloat = 2
        static let terminalPaneChromeHeightPX: CGFloat = 32
        static let terminalPaneChromeCloseWidthPX: CGFloat = 28
        static let terminalPaneChromeDotSizePX: CGFloat = 8
        static let agentActivityIndicatorSizePX: CGFloat = 12
        static let agentActivityIndicatorDotSizePX: CGFloat = 7
        static let agentActivityIndicatorRingWidthPX: CGFloat = 1.5
        static let agentActivityIndicatorSpinSeconds: CFTimeInterval = 1.1
        static let agentActivityIndicatorArcRatio: CGFloat = 0.7
        static let terminalPaneDragPreviewMinWidthPX: CGFloat = 220
        static let terminalPaneDragPreviewMaxWidthPX: CGFloat = 420
        static let terminalPaneDragPreviewCornerRadiusPX: CGFloat = 6
        static let terminalPaneDragPreviewTextInsetXPX: CGFloat = 12
        static let terminalPaneDragPreviewTextInsetYPX: CGFloat = 8
        static let terminalSplitDividerHitAreaPX: CGFloat = 8
        static let terminalSplitDividerLinePX: CGFloat = 1
        static let radiusSmallPX: CGFloat = 6
        static let radiusMediumPX: CGFloat = 8
        static let hairlinePX: CGFloat = 1
        static let ptyOutputCoalescingDelaySeconds: TimeInterval = 0.006
    }
}

extension SIMD4 where Scalar == Float {
    var cgColor: CGColor {
        CGColor(
            red: CGFloat(x),
            green: CGFloat(y),
            blue: CGFloat(z),
            alpha: CGFloat(w)
        )
    }

    var isLightTerminalBackground: Bool {
        (0.2126 * x + 0.7152 * y + 0.0722 * z) > 0.5
    }
}
