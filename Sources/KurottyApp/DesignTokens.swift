import AppKit
import KurottyCore
import simd

enum DesignTokens {
    /// Chrome theme = one full instance of the semantic color ramp.
    ///
    /// Every role below is theme-owned. Status colors in particular must not be
    /// shared between themes: the dark `success` (`#4ADE80`) measures about
    /// 1.6:1 on a white light-theme surface, so light needs its own darker
    /// status hues. The legacy role names (`windowBackground`,
    /// `activeTabBackground`, `textMuted`, ...) are kept as computed aliases
    /// onto the ramp so existing chrome call sites read the same tokens.
    @MainActor
    struct ChromeTheme {
        // MARK: Surfaces, back to front
        let surfaceCanvas: NSColor
        let surfaceChrome: NSColor
        let surfaceSidebar: NSColor
        let surfaceRaised: NSColor

        // MARK: Separation
        let hairline: NSColor
        let borderStrong: NSColor

        // MARK: Text ranks
        let textPrimary: NSColor
        let textSecondary: NSColor
        let textTertiary: NSColor

        // MARK: Accent and status
        let accent: NSColor
        let success: NSColor
        let warning: NSColor
        let error: NSColor

        // MARK: Interaction fills
        /// Selected-row wash. Chromatic, derived from `accent`.
        let selectionFill: NSColor
        /// Hover wash. Deliberately achromatic so hover can never be confused
        /// with selection.
        let hoverFill: NSColor
        /// Mouse-down wash, achromatic and one step stronger than hover.
        let pressFill: NSColor
        /// Keyboard-focus ring stroke for the focused list.
        let focusRing: NSColor

        let windowAppearance: NSAppearance?

        // MARK: Legacy role aliases

        var windowBackground: NSColor { surfaceCanvas }
        var topChromeBackground: NSColor { surfaceChrome }
        var activeTabBackground: NSColor { surfaceRaised }
        var inactiveTabBackground: NSColor { surfaceChrome }
        var inactiveTabHoverBackground: NSColor { surfaceSidebar }
        var paneHeaderBackground: NSColor { surfaceChrome }
        var paneHeaderHoverBackground: NSColor { surfaceSidebar }
        var borderHairline: NSColor { hairline }
        var divider: NSColor { hairline }
        var textMuted: NSColor { textTertiary }
        var activeIndicator: NSColor { accent }
        var activeStatusDot: NSColor { success }
        /// Purple has been purged from chrome; an idle dot is simply quiet text.
        var inactiveStatusDot: NSColor {
            textTertiary.withAlphaComponent(Color.inactiveStatusDotAlphaRATIO)
        }
        var activeBorder: NSColor {
            accent.withAlphaComponent(Color.activeBorderAlphaRATIO)
        }

        static func theme(for settings: AppSettings) -> ChromeTheme {
            settings.terminal.colors.backgroundColor.isLightTerminalBackground ? .light : .dark
        }

        static let dark = ChromeTheme(
            surfaceCanvas: Color.Dark.surfaceCanvas,
            surfaceChrome: Color.Dark.surfaceChrome,
            surfaceSidebar: Color.Dark.surfaceSidebar,
            surfaceRaised: Color.Dark.surfaceRaised,
            hairline: Color.Dark.hairline,
            borderStrong: Color.Dark.borderStrong,
            textPrimary: Color.Dark.textPrimary,
            textSecondary: Color.Dark.textSecondary,
            textTertiary: Color.Dark.textTertiary,
            accent: Color.Dark.accent,
            success: Color.Dark.success,
            warning: Color.Dark.warning,
            error: Color.Dark.error,
            selectionFill: Color.Dark.selectionFill,
            hoverFill: Color.Dark.hoverFill,
            pressFill: Color.Dark.pressFill,
            focusRing: Color.Dark.focusRing,
            windowAppearance: NSAppearance(named: .darkAqua)
        )

        static let light = ChromeTheme(
            surfaceCanvas: Color.Light.surfaceCanvas,
            surfaceChrome: Color.Light.surfaceChrome,
            surfaceSidebar: Color.Light.surfaceSidebar,
            surfaceRaised: Color.Light.surfaceRaised,
            hairline: Color.Light.hairline,
            borderStrong: Color.Light.borderStrong,
            textPrimary: Color.Light.textPrimary,
            textSecondary: Color.Light.textSecondary,
            textTertiary: Color.Light.textTertiary,
            accent: Color.Light.accent,
            success: Color.Light.success,
            warning: Color.Light.warning,
            error: Color.Light.error,
            selectionFill: Color.Light.selectionFill,
            hoverFill: Color.Light.hoverFill,
            pressFill: Color.Light.pressFill,
            focusRing: Color.Light.focusRing,
            windowAppearance: NSAppearance(named: .aqua)
        )
    }

    enum Color {
        /// Alpha applied to `textTertiary` for an idle status dot.
        static let inactiveStatusDotAlphaRATIO: CGFloat = 0.55
        /// Alpha applied to `accent` for an active-surface border.
        static let activeBorderAlphaRATIO: CGFloat = 0.40
        /// Alpha applied to `accent` for the keyboard-focus ring.
        static let focusRingAlphaRATIO: CGFloat = 0.55

        /// Dark ramp. Hex values are sRGB and are built with
        /// `NSColor(srgbRed:…)`; a generic-RGB constructor does not reproduce
        /// the specified hex on screen.
        enum Dark {
            static let surfaceCanvas = NSColor.designTokenSRGB(0x16_18_1D)
            static let surfaceChrome = NSColor.designTokenSRGB(0x1B_1E_24)
            static let surfaceSidebar = NSColor.designTokenSRGB(0x1F_22_28)
            static let surfaceRaised = NSColor.designTokenSRGB(0x26_2A_31)
            static let hairline = NSColor.designTokenSRGB(0x2E_32_3A)
            static let borderStrong = NSColor.designTokenSRGB(0x3A_3F_49)
            static let textPrimary = NSColor.designTokenSRGB(0xE6_E8_EC)
            static let textSecondary = NSColor.designTokenSRGB(0xA6_AD_BB)
            static let textTertiary = NSColor.designTokenSRGB(0x7B_82_8F)
            static let accent = NSColor.designTokenSRGB(0x5B_9D_FF)
            static let success = NSColor.designTokenSRGB(0x4A_DE_80)
            static let warning = NSColor.designTokenSRGB(0xF5_B8_40)
            static let error = NSColor.designTokenSRGB(0xFF_7A_7A)

            static let selectionFillAlphaRATIO: CGFloat = 0.24
            static let hoverFillAlphaRATIO: CGFloat = 0.06
            static let pressFillAlphaRATIO: CGFloat = 0.10

            static let selectionFill = accent.withAlphaComponent(selectionFillAlphaRATIO)
            static let hoverFill = NSColor.designTokenSRGB(0xFF_FF_FF, alpha: hoverFillAlphaRATIO)
            static let pressFill = NSColor.designTokenSRGB(0xFF_FF_FF, alpha: pressFillAlphaRATIO)
            static let focusRing = accent.withAlphaComponent(focusRingAlphaRATIO)
        }

        /// Light ramp. Status hues are darkened versions of the dark ramp so
        /// they stay legible on white; sharing the dark values would drop
        /// `success` to roughly 1.6:1 against `surfaceCanvas`.
        enum Light {
            static let surfaceCanvas = NSColor.designTokenSRGB(0xFF_FF_FF)
            static let surfaceChrome = NSColor.designTokenSRGB(0xF1_F2_F4)
            static let surfaceSidebar = NSColor.designTokenSRGB(0xF7_F8_FA)
            static let surfaceRaised = NSColor.designTokenSRGB(0xFF_FF_FF)
            static let hairline = NSColor.designTokenSRGB(0xDC_DF_E4)
            static let borderStrong = NSColor.designTokenSRGB(0xC3_C7_CE)
            static let textPrimary = NSColor.designTokenSRGB(0x1C_1E_22)
            static let textSecondary = NSColor.designTokenSRGB(0x5A_61_6B)
            static let textTertiary = NSColor.designTokenSRGB(0x7C_83_8E)
            static let accent = NSColor.designTokenSRGB(0x0B_62_E4)
            static let success = NSColor.designTokenSRGB(0x17_72_45)
            static let warning = NSColor.designTokenSRGB(0x8A_53_00)
            static let error = NSColor.designTokenSRGB(0xC0_27_1F)

            static let selectionFillAlphaRATIO: CGFloat = 0.14
            static let hoverFillAlphaRATIO: CGFloat = 0.05
            static let pressFillAlphaRATIO: CGFloat = 0.09

            static let selectionFill = accent.withAlphaComponent(selectionFillAlphaRATIO)
            static let hoverFill = NSColor.designTokenSRGB(0x00_00_00, alpha: hoverFillAlphaRATIO)
            static let pressFill = NSColor.designTokenSRGB(0x00_00_00, alpha: pressFillAlphaRATIO)
            static let focusRing = accent.withAlphaComponent(focusRingAlphaRATIO)
        }

        // MARK: Theme-neutral chrome

        static let paneDropTargetBorder = NSColor(srgbRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 0.72)
        static let paneDropTargetBackground = NSColor(srgbRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 0.08)
        static let inputStatusBackground = Dark.surfaceRaised
        static let cyanTerminalAccent = NSColor(srgbRed: 53.0 / 255.0, green: 201.0 / 255.0, blue: 201.0 / 255.0, alpha: 1)
        static let scrollerThumb = NSColor(srgbRed: 207.0 / 255.0, green: 207.0 / 255.0, blue: 207.0 / 255.0, alpha: 0.72)
        static let scrollerThumbHover = NSColor(srgbRed: 176.0 / 255.0, green: 176.0 / 255.0, blue: 176.0 / 255.0, alpha: 0.88)
        static let scrollerThumbActive = NSColor(srgbRed: 138.0 / 255.0, green: 138.0 / 255.0, blue: 138.0 / 255.0, alpha: 0.96)

        // MARK: Dark-ramp aliases for chrome that has no theme at the call site

        static let windowBackground = Dark.surfaceCanvas
        static let topChromeBackground = Dark.surfaceChrome
        static let activeTabBackground = Dark.surfaceRaised
        static let inactiveTabBackground = Dark.surfaceChrome
        static let inactiveTabHoverBackground = Dark.surfaceSidebar
        static let paneHeaderBackground = Dark.surfaceChrome
        static let paneHeaderHoverBackground = Dark.surfaceSidebar
        static let borderHairline = Dark.hairline
        static let divider = Dark.hairline
        static let textPrimary = Dark.textPrimary
        static let textSecondary = Dark.textSecondary
        static let textMuted = Dark.textTertiary
        static let accentBlue = Dark.accent
        static let successGreen = Dark.success
        static let warningOrange = Dark.warning
        static let errorRed = Dark.error

        static let terminalBackground = NSColor(
            srgbRed: 34.0 / 255.0,
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

    /// The chrome type ramp.
    ///
    /// Naming note: the spec calls this scale `DesignTokens.Type`. `Type` is not
    /// usable as a nested type name in Swift — `DesignTokens.Type` always parses
    /// as the metatype of `DesignTokens`, so member lookup fails. The ramp
    /// therefore lives in the existing `Typography` namespace, which is where
    /// the retired `*FontSizePT` constants used to sit.
    ///
    /// Every chrome label takes a `Role`. Call sites must not pass a weight of
    /// their own: a role is the single place where size, weight, line height,
    /// tracking, and font design are decided together.
    enum Typography {
        /// One rung of the ramp.
        struct Role: Equatable, Sendable {
            /// Which system font family the role renders in. Monospaced digits
            /// are their own case because a changing number must not reflow the
            /// label that holds it.
            enum FontDesign: Sendable {
                case system
                case monospaced
                case monospacedDigit
            }

            let sizePT: CGFloat
            let weight: NSFont.Weight
            let lineHeightPX: CGFloat
            let tracking: CGFloat
            let design: FontDesign

            init(
                sizePT: CGFloat,
                weight: NSFont.Weight,
                lineHeightPX: CGFloat,
                tracking: CGFloat = 0,
                design: FontDesign = .system
            ) {
                self.sizePT = sizePT
                self.weight = weight
                self.lineHeightPX = lineHeightPX
                self.tracking = tracking
                self.design = design
            }

            var font: NSFont {
                switch design {
                case .system:
                    return NSFont.systemFont(ofSize: sizePT, weight: weight)
                case .monospaced:
                    return NSFont.monospacedSystemFont(ofSize: sizePT, weight: weight)
                case .monospacedDigit:
                    return NSFont.monospacedDigitSystemFont(ofSize: sizePT, weight: weight)
                }
            }

            /// The same role expressed as an SF Symbol configuration, so a glyph
            /// beside a label inherits the label's size and weight.
            var symbolConfiguration: NSImage.SymbolConfiguration {
                NSImage.SymbolConfiguration(pointSize: sizePT, weight: symbolWeight)
            }

            /// Applies font, color, and tracking to a label. Roles with tracking
            /// must go through an attributed string: `NSTextField` has no kerning
            /// property of its own.
            @MainActor
            func apply(to field: NSTextField, color: NSColor) {
                field.font = font
                field.textColor = color
                guard tracking != 0 else {
                    return
                }
                field.attributedStringValue = attributedString(field.stringValue, color: color)
            }

            @MainActor
            func attributedString(_ text: String, color: NSColor) -> NSAttributedString {
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .kern: tracking,
                    ]
                )
            }

            private var symbolWeight: NSFont.Weight { weight }
        }

        static let windowTitle = Role(sizePT: 13, weight: .semibold, lineHeightPX: 18)
        static let tabLabel = Role(sizePT: 12, weight: .medium, lineHeightPX: 16)
        static let tabLabelSel = Role(sizePT: 12, weight: .semibold, lineHeightPX: 16)
        /// Uppercased at the call site; tracking opens the caps back up.
        static let sectionHeader = Role(sizePT: 11, weight: .semibold, lineHeightPX: 15, tracking: 0.55)
        static let rowTitle = Role(sizePT: 12, weight: .regular, lineHeightPX: 16)
        static let rowTitleSel = Role(sizePT: 12, weight: .medium, lineHeightPX: 16)
        static let rowSecondary = Role(sizePT: 11, weight: .regular, lineHeightPX: 15)
        static let badge = Role(sizePT: 10, weight: .medium, lineHeightPX: 14)
        static let statusBar = Role(sizePT: 11, weight: .regular, lineHeightPX: 15)
        static let statusBarNum = Role(
            sizePT: 11,
            weight: .medium,
            lineHeightPX: 15,
            design: .monospacedDigit
        )
        static let monoBody = Role(sizePT: 12, weight: .regular, lineHeightPX: 16, design: .monospaced)
        static let paneHeader = Role(sizePT: 11, weight: .medium, lineHeightPX: 15)

        static let terminalFontSizePT: CGFloat = 15
        /// Not part of the ramp: still referenced by chrome outside this scale
        /// (`ChromeIconButton`, `TerminalSearchBarView`, `TerminalCodeEditorView`,
        /// `TerminalPaneDragCoordinator`).
        static let labelFontSizePT: CGFloat = 13
        static let paneHeaderFontSizePT: CGFloat = 12
        static let statusFontSizePT: CGFloat = 12
        static let codeEditorFontSizePT: CGFloat = 13
        static let codeEditorGutterFontSizePT: CGFloat = 11
    }

    /// Layout rhythm. Every chrome gap, inset, and pad in the window shell picks
    /// one of these six steps; ad-hoc point values are the thing this scale
    /// exists to prevent.
    enum Space {
        static let x1PX: CGFloat = 4
        static let x2PX: CGFloat = 6
        static let x3PX: CGFloat = 8
        static let x4PX: CGFloat = 12
        static let x5PX: CGFloat = 16
        static let x6PX: CGFloat = 24

        /// Exempt from the scale: these are cell-grid alignment for the terminal
        /// surface, not layout rhythm, so they must not be rounded onto a step.
        static let terminalTopPX: CGFloat = 8
        static let terminalLeftPX: CGFloat = 6
        static let terminalBottomPX: CGFloat = 8
        static let terminalRightPX: CGFloat = 6
        static let preferencesInsetPX: CGFloat = 24
        static let preferencesGapPX: CGFloat = 14
    }

    /// Corner-radius scale. `fullPX` is the pill radius; a control only earns it
    /// when its shape is the meaning (a status pill), never for data.
    enum Radius {
        static let xsPX: CGFloat = 4
        static let smPX: CGFloat = 6
        static let mdPX: CGFloat = 8
        static let lgPX: CGFloat = 12
        static let fullPX: CGFloat = 999
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
        static let terminalTabBarHeightPX: CGFloat = 38
        static let terminalTopBarCornerRadiusPX: CGFloat = 0
        static let terminalTabBarHorizontalInsetPX: CGFloat = 0
        static let terminalTrafficLightClearancePX: CGFloat = 78
        static let terminalTabBarSideButtonInsetPX = Space.x3PX
        static let terminalTabHeightPX: CGFloat = 28
        static let sidebarToggleSizePX: CGFloat = 26
        static let sidebarDividerGrabPaddingPX = Space.x1PX
        static let sidebarToggleEdgeInsetPX = Space.x3PX
        static let sidebarToggleSymbolPointSizePT: CGFloat = 13
        static let terminalTabMinWidthPX: CGFloat = 120
        static let terminalTabMaxWidthPX: CGFloat = 240
        static let terminalTabPlusWidthPX: CGFloat = 26
        /// Close affordance: a 20x20 hit target carrying a 10pt glyph. 18x18 was
        /// below the comfortable pointer target for a control this small.
        static let terminalTabCloseWidthPX: CGFloat = 20
        static let terminalTabCloseGlyphPointSizePT: CGFloat = 10
        static let terminalTabStackGapPX = Space.x1PX
        static let terminalTabStackInsetTopPX = Space.x1PX
        static let terminalTabStackInsetLeftPX = Space.x3PX
        static let terminalTabStackInsetBottomPX = Space.x1PX
        static let terminalTabStackInsetRightPX = Space.x3PX
        /// Selected tabs are marked by an accent rail across the tab's top edge,
        /// not by an outline: a border reads as a box, a rail reads as "current".
        static let terminalTabTopRailHeightPX: CGFloat = 2
        static let terminalTabTitleLeadingPX = Space.x4PX
        static let terminalTabTitleCloseGapPX = Space.x2PX
        static let terminalTabCloseTrailingPX = Space.x3PX
        static let commandHistoryPanelDefaultWidthPX: CGFloat = 350
        static let commandHistoryPanelMinWidthPX: CGFloat = 200
        static let commandHistoryPanelMaxWidthPX: CGFloat = 460
        static let commandHistoryPanelCornerRadiusPX: CGFloat = 0
        static let commandHistoryPanelInsetXPX = Space.x4PX
        static let commandHistoryPanelInsetYPX = Space.x4PX
        static let commandHistorySectionHeaderTopGapPX = Space.x5PX
        static let commandHistorySectionHeaderBottomGapPX = Space.x2PX
        static let commandHistorySectionHeaderInsetXPX = Space.x4PX
        static let commandHistoryGroupRowHeightPX: CGFloat = 28
        static let commandHistoryCommandRowHeightPX: CGFloat = 26
        static let commandHistoryStatusDotSizePX: CGFloat = 6
        static let commandHistoryRowInsetXPX = Space.x3PX
        /// Status dot to command text, and folder icon to group name.
        static let commandHistoryRowGapPX = Space.x3PX
        static let commandHistoryTimeLabelMinWidthPX: CGFloat = 32
        static let commandHistoryBadgeHeightPX: CGFloat = 16
        static let commandHistoryBadgeTextInsetXPX = Space.x2PX
        static let commandHistoryBadgeMinWidthPX: CGFloat = 18
        static let commandHistoryGroupIconPointSizePT: CGFloat = 12
        static let commandHistoryDisclosurePointSizePT: CGFloat = 9
        static let commandHistoryDisclosureBoxSizePX: CGFloat = 16
        static let commandHistoryEmptyStateIconPointSizePT: CGFloat = 18
        static let commandHistoryEmptyStateGapPX = Space.x3PX
        /// One outline level has to read as one level; 6pt did not.
        static let commandHistoryOutlineIndentationPX = Space.x4PX
        static let commandHistoryDefaultExpandedGroupCount = 3
        static let commandHistoryBadgeBackgroundAlphaRATIO: CGFloat = 0.10
        static let fileExplorerPanelDefaultWidthPX: CGFloat = 350
        static let fileExplorerPanelMinWidthPX: CGFloat = 210
        static let fileExplorerPanelMaxWidthPX: CGFloat = 460
        static let fileExplorerPanelCornerRadiusPX: CGFloat = 0
        static let fileExplorerPanelInsetXPX = Space.x4PX
        static let fileExplorerPanelInsetYPX = Space.x4PX
        static let fileExplorerHeaderGapPX = Space.x1PX
        static let fileExplorerControlGapPX = Space.x3PX
        static let fileExplorerRefreshButtonSizePX: CGFloat = 24
        static let fileExplorerRowHeightPX: CGFloat = 26
        static let fileExplorerRowIconPointSizePT: CGFloat = 13
        /// Fixed-width git column: a dot in a reserved slot cannot shift the row
        /// beside it, which the old `M`/`U`/`⊘` letters did every repaint.
        static let fileExplorerGitSlotSizePX: CGFloat = 14
        static let fileExplorerGitDotSizePX: CGFloat = 5
        static let fileExplorerGitConflictPointSizePT: CGFloat = 10
        static let fileExplorerFolderIconAlphaRATIO: CGFloat = 0.85
        static let fileExplorerDimmedTextAlphaRATIO: CGFloat = 0.50

        // MARK: Shared sidebar search pill

        /// One pill shape for all three sidebar sections. A solid raised fill
        /// (not a translucent wash) is what makes it read as a control instead
        /// of a smudge over whatever happens to be behind it.
        static let sidebarSearchPillHeightPX: CGFloat = 28
        static let sidebarSearchPillTextInsetXPX = Space.x3PX
        static let sidebarSearchPillEdgeInsetXPX = Space.x2PX
        static let sidebarSearchIconGapPX = Space.x2PX
        static let sidebarSearchIconPointSizePT: CGFloat = 11
        static let sidebarSearchClearGlyphPointSizePT: CGFloat = 11
        static let sidebarSearchClearHitSizePX: CGFloat = 20
        static let sidebarSearchPillBorderWidthPX: CGFloat = 1
        static let sidebarSearchPillFocusRingWidthPX: CGFloat = 2
        static let sidebarSearchPillFocusRingOutsetPX: CGFloat = 1
        // Agent-session sidebar. Shared metrics (search pill, badges, row
        // highlight, indentation) intentionally reuse the commandHistory*
        // tokens so both left-panel sections stay pixel-identical.
        static let agentSessionRowHeightPX: CGFloat = 42
        static let agentSessionRowTextGapPY: CGFloat = 2
        static let agentSessionAgentIconPointSizePT: CGFloat = 12
        static let agentSessionEmptyStateIconPointSizePT: CGFloat = 18
        static let agentSessionDefaultExpandedGroupCount = 3
        // Read-only agent transcript viewer. Flat inline rows: a tool run is one
        // line that expands in place, so detail rows are indented rather than
        // boxed.
        static let agentTranscriptRowInsetXPX: CGFloat = 14
        static let agentTranscriptRowInsetYPX: CGFloat = 4
        static let agentTranscriptDetailInsetXPX: CGFloat = 30
        static let agentTranscriptHeaderTopPaddingPX: CGFloat = 10
        static let agentTranscriptBodyFontSizePT: CGFloat = 12
        static let agentTranscriptHeaderFontSizePT: CGFloat = 10
        static let agentTranscriptMonospacedFontSizePT: CGFloat = 11
        static let agentTranscriptDetailBackgroundAlphaRATIO: CGFloat = 0.06
        static let agentTranscriptDiffBackgroundAlphaRATIO: CGFloat = 0.10
        // Shared three-state row highlight. Command history, agent sessions,
        // and the file explorer all paint through
        // `TerminalSidebarRowHighlight`, so the geometry lives once here.
        static let sidebarRowHighlightInsetXPX = Space.x1PX
        static let sidebarRowHighlightInsetYPX: CGFloat = 2
        static let sidebarRowHighlightCornerRadiusPX = Radius.smPX
        static let sidebarRowSelectionRailWidthPX: CGFloat = 2
        static let sidebarRowSelectionRailCornerRadiusPX: CGFloat = 1
        static let sidebarRowFocusRingWidthPX: CGFloat = 2
        static let sidebarRowFocusRingOutsetPX: CGFloat = 1
        /// Selected row in a background window: achromatic, so an inactive
        /// window never claims the accent.
        static let sidebarRowInactiveSelectionAlphaRATIO: CGFloat = 0.07

        // MARK: Left-sidebar section strip
        //
        // A custom two-item strip, not `NSSegmentedControl`. AppKit has no legal
        // 22pt segmented-control height, so the old control rendered squashed
        // and needed `setWidth(0…)` plus compression-resistance workarounds to
        // stay inside the panel at all.
        static let leftSidebarSectionStripHeightPX: CGFloat = 30
        static let leftSidebarSectionStripTopInsetPX = Space.x3PX
        static let leftSidebarSectionStripInsetXPX = Space.x4PX
        static let leftSidebarSectionStripBottomGapPX = Space.x3PX
        static let leftSidebarSectionUnderlineHeightPX: CGFloat = 2
        /// Underline is inset from the item's own width so two adjacent
        /// selections could never read as one continuous rule.
        static let leftSidebarSectionUnderlineInsetXPX = Space.x1PX
        static let leftSidebarSectionHoverInsetPX: CGFloat = 2
        static let leftSidebarSectionFocusRingWidthPX: CGFloat = 2
        static let leftSidebarSectionFocusRingOutsetPX: CGFloat = 1
        static let imagePreviewInsetPX = Space.x6PX
        static let codeEditorGutterWidthPX: CGFloat = 44
        static let codeEditorGutterLabelTrailingPX: CGFloat = 8
        static let codeEditorTextInsetXPX: CGFloat = 6
        static let codeEditorTextInsetYPX: CGFloat = 8
        static let codeEditorPathBarInsetXPX: CGFloat = 12
        static let codeEditorPathBarInsetYPX: CGFloat = 8
        static let paneDropTargetBorderWidthPX: CGFloat = 2
        static let terminalPaneChromeHeightPX: CGFloat = 28
        static let terminalPaneChromeCloseWidthPX: CGFloat = 24
        static let terminalPaneChromeCloseGlyphPointSizePT: CGFloat = 10
        static let terminalPaneChromeDotSizePX: CGFloat = 6
        static let terminalPaneChromeDotInsetXPX = Space.x4PX
        /// The active pane is marked on its header's leading edge. A full-width
        /// bottom bar reads as a divider between header and terminal; a leading
        /// rail reads as "this pane".
        static let terminalPaneChromeActiveRailWidthPX: CGFloat = 2
        static let agentActivityIndicatorSizePX: CGFloat = 12
        static let agentActivityIndicatorDotSizePX: CGFloat = 6
        static let agentActivityIndicatorRingWidthPX: CGFloat = 1.5
        static let agentActivityIndicatorSpinSeconds: CFTimeInterval = 1.1
        static let agentActivityIndicatorArcRatio: CGFloat = 0.75
        static let agentActivityIndicatorArcAlphaRATIO: CGFloat = 0.85
        static let terminalPaneDragPreviewMinWidthPX: CGFloat = 220
        static let terminalPaneDragPreviewMaxWidthPX: CGFloat = 420
        static let terminalPaneDragPreviewTextInsetXPX = Space.x4PX
        static let terminalPaneDragPreviewTextInsetYPX = Space.x3PX
        static let terminalSplitDividerHitAreaPX = Space.x3PX
        static let terminalSplitDividerLinePX: CGFloat = 1
        /// Retained: `ChromeIconButton` and `TerminalSearchBarView` still read it
        /// and are owned by another change. New chrome uses `Radius`.
        static let radiusSmallPX = Radius.smPX
        static let hairlinePX: CGFloat = 1
        static let ptyOutputCoalescingDelaySeconds: TimeInterval = 0.006
    }
}

extension NSColor {
    /// Builds a ramp color from an sRGB hex triplet.
    ///
    /// The design ramp is specified in sRGB hex. The generic-RGB constructor
    /// builds a color in a different space, which renders a visibly different
    /// value, so every design token color goes through this sRGB constructor.
    static func designTokenSRGB(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        let maxChannelValue: CGFloat = 255
        let redShift: UInt32 = 16
        let greenShift: UInt32 = 8
        let channelMask: UInt32 = 0xFF
        return NSColor(
            srgbRed: CGFloat((hex >> redShift) & channelMask) / maxChannelValue,
            green: CGFloat((hex >> greenShift) & channelMask) / maxChannelValue,
            blue: CGFloat(hex & channelMask) / maxChannelValue,
            alpha: alpha
        )
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
